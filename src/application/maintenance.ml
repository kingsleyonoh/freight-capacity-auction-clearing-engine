open Lwt.Syntax
open Lwt.Infix

type integration_outbox = {
  id : string;
  tenant_id : string;
  integration_name : string;
  event_type : string;
  target_url_env_var : string;
  payload : Yojson.Safe.t;
  idempotency_key : string;
}

type replay_job = {
  id : string;
  tenant_id : string;
  dataset_uri : string;
  baseline_strategy : string;
  created_by_user_id : string;
}

let find request parameters =
  Db_pool.with_connection (fun (module Connection : Caqti_lwt.CONNECTION) ->
      Connection.find request parameters)
  >|= function
  | Ok value -> Ok value
  | Error _ -> Error "DATABASE_UNAVAILABLE"

let exec request parameters =
  Db_pool.with_connection (fun (module Connection : Caqti_lwt.CONNECTION) ->
      Connection.exec request parameters)
  >|= function
  | Ok () -> Ok ()
  | Error _ -> Error "DATABASE_UNAVAILABLE"

let close_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->! Caqti_type.int)
    "WITH closed AS (UPDATE auctions SET status = 'closed', updated_at = now() WHERE status = 'open' AND bid_close_at <= now() RETURNING tenant_id, id, created_by_user_id), notifications AS (INSERT INTO notifications (id, tenant_id, user_id, event_type, template_id, channel, urgency, payload_snapshot, status) SELECT gen_random_uuid(), c.tenant_id, u.id, 'auction_bid_window_closed', 'auction-bid-window-closed-v1', 'in_app', 'medium', jsonb_build_object('auction_id', c.id::text), 'queued' FROM closed c JOIN users u ON u.tenant_id = c.tenant_id AND u.is_active AND u.role = 'auction_manager' RETURNING id) SELECT count(*)::int FROM closed"

let auto_clear_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->! Caqti_type.int)
    "WITH target AS (SELECT a.id AS auction_id, a.tenant_id, a.created_by_user_id, p.max_service_risk, p.max_single_carrier_share, p.reserve_price_behavior FROM auctions a JOIN auction_policies p ON p.id = a.policy_id AND p.tenant_id = a.tenant_id WHERE a.status = 'closed' AND a.auto_clear_on_close AND a.clearing_job_id IS NULL), snapshot AS (SELECT target.*, jsonb_build_object('policy', jsonb_build_object('max_service_risk', target.max_service_risk, 'max_single_carrier_share', target.max_single_carrier_share, 'reserve_price_behavior', target.reserve_price_behavior), 'loads', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', l.id::text, 'reserve_cents', round(ln.reserve_price * 100)::int, 'equipment', l.equipment_type) ORDER BY l.id) FROM loads l JOIN lanes ln ON ln.id = l.lane_id AND ln.tenant_id = l.tenant_id WHERE l.tenant_id = target.tenant_id AND l.auction_id = target.auction_id), '[]'::jsonb), 'bids', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', b.id::text, 'load_id', b.load_id::text, 'carrier_id', b.carrier_id::text, 'amount_cents', round(b.bid_amount * 100)::int, 'service_score_milli', round(b.service_score_snapshot * 1000)::int, 'capacity_units', b.capacity_units) ORDER BY b.id) FROM bids b WHERE b.tenant_id = target.tenant_id AND b.auction_id = target.auction_id AND b.status IN ('submitted','eligible')), '[]'::jsonb)) AS input_snapshot FROM target), jobs AS (INSERT INTO clearing_jobs (id, tenant_id, auction_id, status, requested_by_user_id, policy_snapshot, input_snapshot, solver_backend, solver_version) SELECT gen_random_uuid(), tenant_id, auction_id, 'queued', created_by_user_id, jsonb_build_object('max_service_risk', max_service_risk, 'max_single_carrier_share', max_single_carrier_share, 'reserve_price_behavior', reserve_price_behavior), input_snapshot, 'minizinc', 'configured' FROM snapshot RETURNING id, tenant_id, auction_id), updated AS (UPDATE auctions a SET status = 'clearing_queued', clearing_job_id = j.id, updated_at = now() FROM jobs j WHERE a.id = j.auction_id AND a.tenant_id = j.tenant_id AND a.clearing_job_id IS NULL RETURNING a.id) SELECT count(*)::int FROM updated"

let close_expired_auctions () =
  let open Lwt.Syntax in
  let* closed = find close_request () in
  match closed with
  | Error error -> Lwt.return (Error error)
  | Ok closed_count ->
      let* queued = find auto_clear_request () in
      Lwt.return (Result.map (fun queued_count -> closed_count + queued_count) queued)

let expire_request =
  let open Caqti_request.Infix in
  (Caqti_type.int ->! Caqti_type.int)
    "WITH expired AS (UPDATE approval_requests SET status = 'expired', decided_at = now(), updated_at = now() WHERE status = 'pending' AND requested_at < now() - (?::text || ' hours')::interval RETURNING id, tenant_id, award_id), blocked AS (UPDATE awards a SET explanation_snapshot = a.explanation_snapshot || jsonb_build_object('approval_status', 'expired'), updated_at = now() FROM expired e WHERE a.tenant_id = e.tenant_id AND a.id = e.award_id AND a.status = 'approval_required' RETURNING a.id) SELECT count(*)::int FROM expired"

let expire_approvals ~cutoff_hours =
  if cutoff_hours < 1 || cutoff_hours > 8_760 then Lwt.return (Error "APPROVAL_EXPIRY_INVALID")
  else find expire_request cutoff_hours

let deliver_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->! Caqti_type.int)
    "WITH candidates AS (SELECT n.id FROM notifications n LEFT JOIN notification_preferences p ON p.tenant_id = n.tenant_id AND p.user_id = n.user_id AND p.event_type = n.event_type AND p.channel = n.channel WHERE n.channel = 'in_app' AND n.status = 'queued' AND (n.urgency = 'critical' OR COALESCE(p.enabled, true)) AND (p.id IS NULL OR p.quiet_hours = '{}'::jsonb OR NOT (CASE WHEN (p.quiet_hours->>'start_hour') ~ '^[0-9]+$' AND (p.quiet_hours->>'end_hour') ~ '^[0-9]+$' THEN CASE WHEN (p.quiet_hours->>'start_hour')::int <= (p.quiet_hours->>'end_hour')::int THEN extract(hour FROM now())::int BETWEEN (p.quiet_hours->>'start_hour')::int AND (p.quiet_hours->>'end_hour')::int ELSE extract(hour FROM now())::int >= (p.quiet_hours->>'start_hour')::int OR extract(hour FROM now())::int <= (p.quiet_hours->>'end_hour')::int END ELSE false END))), delivered AS (UPDATE notifications n SET status = 'delivered', delivered_at = now(), updated_at = now() FROM candidates c WHERE n.id = c.id RETURNING n.id) SELECT count(*)::int FROM delivered"

let deliver_notifications () = find deliver_request ()

let claim_outbox_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->! Caqti_type.string)
    "WITH next_item AS (SELECT o.id FROM integration_outbox o JOIN integration_settings s ON s.tenant_id = o.tenant_id AND s.integration_name = o.integration_name AND s.enabled WHERE o.status IN ('queued','retry_scheduled') AND (o.next_attempt_at IS NULL OR o.next_attempt_at <= now()) ORDER BY o.created_at FOR UPDATE SKIP LOCKED LIMIT 1), claimed AS (UPDATE integration_outbox o SET status = 'running', updated_at = now() FROM next_item n WHERE o.id = n.id RETURNING o.id, o.tenant_id, o.integration_name, o.event_type, o.target_url_env_var, o.payload, o.idempotency_key) SELECT COALESCE((SELECT json_build_object('id', id::text, 'tenant_id', tenant_id::text, 'integration_name', integration_name, 'event_type', event_type, 'target_url_env_var', target_url_env_var, 'payload', payload, 'idempotency_key', idempotency_key)::text FROM claimed), '')"

let parse_outbox value =
  if value = "" then Ok None
  else
    try
      let open Yojson.Safe.Util in
      let json = Yojson.Safe.from_string value in
      Ok
        (Some
           {
             id = json |> member "id" |> to_string;
             tenant_id = json |> member "tenant_id" |> to_string;
             integration_name = json |> member "integration_name" |> to_string;
             event_type = json |> member "event_type" |> to_string;
             target_url_env_var = json |> member "target_url_env_var" |> to_string;
             payload = json |> member "payload";
             idempotency_key = json |> member "idempotency_key" |> to_string;
           })
    with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> Error "OUTBOX_PAYLOAD_INVALID"

let claim_integration_outbox () =
  let* result = find claim_outbox_request () in
  match result with Error error -> Lwt.return (Error error) | Ok value -> Lwt.return (parse_outbox value)

let succeeded_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 string string) ->. Caqti_type.unit)
    "UPDATE integration_outbox SET status = 'succeeded', updated_at = now(), last_error_code = NULL, last_error_message = NULL WHERE id = ?::uuid AND tenant_id = ?::uuid AND status = 'running'"

let mark_integration_succeeded ~id ~tenant_id = exec succeeded_request (id, tenant_id)

let retry_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t4 string string string string) ->. Caqti_type.unit)
    "UPDATE integration_outbox SET retry_count = retry_count + 1, status = CASE WHEN retry_count + 1 >= 5 THEN 'dead_lettered' ELSE 'retry_scheduled' END, next_attempt_at = CASE WHEN retry_count + 1 >= 5 THEN NULL ELSE now() + interval '1 minute' END, last_error_code = ?, last_error_message = left(?, 500), updated_at = now() WHERE id = ?::uuid AND tenant_id = ?::uuid AND status = 'running'"

let mark_integration_retry ~id ~tenant_id ~error_code ~error_message =
  exec retry_request (error_code, error_message, id, tenant_id)

let health_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t3 string string string) ->. Caqti_type.unit)
    "WITH changed AS (UPDATE integration_settings SET last_health_status = ?, last_checked_at = now(), updated_at = now() WHERE tenant_id = ?::uuid AND integration_name = ? RETURNING tenant_id, integration_name), notified AS (INSERT INTO notifications (id, tenant_id, user_id, event_type, template_id, channel, urgency, payload_snapshot, status) SELECT gen_random_uuid(), c.tenant_id, u.id, 'integration_degraded', 'integration-degraded-v1', 'in_app', 'medium', jsonb_build_object('integration_name', c.integration_name), 'queued' FROM changed c JOIN users u ON u.tenant_id = c.tenant_id AND u.is_active AND u.role = 'tenant_admin' WHERE (SELECT last_health_status FROM integration_settings WHERE tenant_id = c.tenant_id AND integration_name = c.integration_name) = 'degraded' AND NOT EXISTS (SELECT 1 FROM notifications n WHERE n.tenant_id = c.tenant_id AND n.user_id = u.id AND n.event_type = 'integration_degraded' AND n.payload_snapshot->>'integration_name' = c.integration_name AND n.status IN ('queued','delivered','read')) RETURNING id) UPDATE integration_settings SET updated_at = updated_at WHERE false"

let update_integration_health ~tenant_id ~integration_name ~status =
  if not (List.mem status [ "unknown"; "healthy"; "degraded"; "failed"; "disabled" ]) then
    Lwt.return (Error "INTEGRATION_HEALTH_INVALID")
  else exec health_request (status, tenant_id, integration_name)

let claim_replay_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->! Caqti_type.string)
    "WITH next_item AS (SELECT id FROM replay_runs WHERE status = 'queued' ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1), claimed AS (UPDATE replay_runs r SET status = 'running', started_at = now(), updated_at = now() FROM next_item n WHERE r.id = n.id RETURNING r.id, r.tenant_id, r.dataset_uri, r.baseline_strategy, r.created_by_user_id) SELECT COALESCE((SELECT json_build_object('id', id::text, 'tenant_id', tenant_id::text, 'dataset_uri', dataset_uri, 'baseline_strategy', baseline_strategy, 'created_by_user_id', created_by_user_id::text)::text FROM claimed), '')"

let parse_replay value =
  if value = "" then Ok None
  else
    try
      let open Yojson.Safe.Util in
      let json = Yojson.Safe.from_string value in
      Ok
        (Some
           {
             id = json |> member "id" |> to_string;
             tenant_id = json |> member "tenant_id" |> to_string;
             dataset_uri = json |> member "dataset_uri" |> to_string;
             baseline_strategy = json |> member "baseline_strategy" |> to_string;
             created_by_user_id = json |> member "created_by_user_id" |> to_string;
           })
    with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> Error "REPLAY_PAYLOAD_INVALID"

let claim_replay () =
  let* result = find claim_replay_request () in
  match result with Error error -> Lwt.return (Error error) | Ok value -> Lwt.return (parse_replay value)

let complete_replay_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t3 string string string) ->. Caqti_type.unit)
    "WITH completed AS (UPDATE replay_runs SET status = 'succeeded', metrics_snapshot = ?::jsonb, finished_at = now(), updated_at = now() WHERE id = ?::uuid AND tenant_id = ?::uuid AND status = 'running' RETURNING id, tenant_id, created_by_user_id), notification AS (INSERT INTO notifications (id, tenant_id, user_id, event_type, template_id, channel, urgency, payload_snapshot, status) SELECT gen_random_uuid(), tenant_id, created_by_user_id, 'replay_completed', 'replay-completed-v1', 'in_app', 'medium', jsonb_build_object('replay_id', id::text), 'queued' FROM completed RETURNING id) UPDATE replay_runs SET updated_at = updated_at WHERE id IN (SELECT id FROM completed)"

let complete_replay ~id ~tenant_id ~metrics = exec complete_replay_request (metrics, id, tenant_id)

let fail_replay_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t4 string string string string) ->. Caqti_type.unit)
    "UPDATE replay_runs SET status = 'failed', metrics_snapshot = jsonb_build_object('error_code', ?, 'error_message', left(?, 500)), finished_at = now(), updated_at = now() WHERE id = ?::uuid AND tenant_id = ?::uuid AND status = 'running'"

let fail_replay ~id ~tenant_id ~error_code ~error_message =
  exec fail_replay_request (error_code, error_message, id, tenant_id)
