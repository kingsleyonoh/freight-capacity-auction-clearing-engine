type job = { id : string; tenant_id : string; auction_id : string; input : Yojson.Safe.t }

open Lwt.Infix

let claim_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->! Caqti_type.string)
    "WITH next_job AS (SELECT id FROM clearing_jobs WHERE status = 'queued' ORDER BY queued_at FOR UPDATE SKIP LOCKED LIMIT 1), claimed AS (UPDATE clearing_jobs AS job SET status = 'running', started_at = now(), updated_at = now() FROM next_job WHERE job.id = next_job.id RETURNING job.*) SELECT COALESCE((SELECT json_build_object('id', c.id::text, 'tenant_id', c.tenant_id::text, 'auction_id', c.auction_id::text, 'input', json_build_object('policy', c.policy_snapshot, 'loads', COALESCE((SELECT json_agg(json_build_object('id', l.id::text, 'reserve_cents', round(ln.reserve_price * 100)::int, 'equipment', l.equipment_type) ORDER BY l.id) FROM loads l JOIN lanes ln ON ln.id = l.lane_id AND ln.tenant_id = l.tenant_id WHERE l.tenant_id = c.tenant_id AND l.auction_id = c.auction_id), '[]'::json), 'bids', COALESCE((SELECT json_agg(json_build_object('id', b.id::text, 'load_id', b.load_id::text, 'carrier_id', b.carrier_id::text, 'amount_cents', round(b.bid_amount * 100)::int, 'service_score_milli', round(b.service_score_snapshot * 1000)::int, 'capacity_units', b.capacity_units) ORDER BY b.id) FROM bids b WHERE b.tenant_id = c.tenant_id AND b.auction_id = c.auction_id AND b.status IN ('submitted','eligible')), '[]'::json))) FROM claimed c), 'null'::json)::text"

let mark_infeasible_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t7 string string string string string string string) ->. Caqti_type.unit)
    "WITH changed AS (UPDATE clearing_jobs SET status = 'infeasible', error_code = ?, error_message = left(?, 500), infeasibility_snapshot = jsonb_build_object('reason', ?), relaxation_suggestions = ?::jsonb, finished_at = now(), updated_at = now() WHERE id = ?::uuid AND tenant_id = ?::uuid AND auction_id = ?::uuid RETURNING id, tenant_id, auction_id, error_code), decisions AS (INSERT INTO clearing_decisions (id, tenant_id, clearing_job_id, auction_id, load_id, decision_type, binding_constraints, infeasibility_details, redaction_scope, explanation_snapshot) SELECT gen_random_uuid(), c.tenant_id, c.id, c.auction_id, l.id, 'unassigned', '[]'::jsonb, jsonb_build_object('reason', c.error_code), 'operator', jsonb_build_object('reason', c.error_code) FROM changed c JOIN loads l ON l.tenant_id = c.tenant_id AND l.auction_id = c.auction_id RETURNING id) UPDATE auctions SET status = 'infeasible', summary_metrics = jsonb_build_object('reason', (SELECT error_code FROM changed)), updated_at = now() WHERE id = (SELECT auction_id FROM changed) AND tenant_id = (SELECT tenant_id FROM changed) AND (SELECT count(*) >= 0 FROM decisions)"

let complete_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t9 string string string string string string string string string) ->. Caqti_type.unit)
    "WITH target AS (SELECT * FROM clearing_jobs WHERE id = ?::uuid AND tenant_id = ?::uuid AND auction_id = ?::uuid), assignment AS (SELECT (value->>'load_id')::uuid AS load_id, (value->>'bid_id')::uuid AS bid_id FROM jsonb_array_elements(?::jsonb) value), inserted_awards AS (INSERT INTO awards (id, tenant_id, auction_id, load_id, bid_id, carrier_id, clearing_job_id, award_amount, service_score, total_score, status, explanation_snapshot) SELECT gen_random_uuid(), j.tenant_id, j.auction_id, a.load_id, b.id, b.carrier_id, j.id, b.bid_amount, b.service_score_snapshot, b.bid_amount, 'approval_required', jsonb_build_object('binding_constraints', jsonb_build_array('one_award_per_load', 'deterministic_tiebreak'), 'solver_input_hash', ?::text, 'solver_output_hash', ?::text) FROM assignment a JOIN bids b ON b.id = a.bid_id AND b.load_id = a.load_id JOIN target j ON j.tenant_id = b.tenant_id RETURNING id, tenant_id, auction_id, clearing_job_id, load_id, bid_id, explanation_snapshot), awarded_decisions AS (INSERT INTO clearing_decisions (id, tenant_id, clearing_job_id, auction_id, bid_id, load_id, decision_type, binding_constraints, rejected_reason, infeasibility_details, redaction_scope, explanation_snapshot) SELECT gen_random_uuid(), tenant_id, clearing_job_id, auction_id, bid_id, load_id, 'awarded', explanation_snapshot->'binding_constraints', NULL, '{}'::jsonb, 'operator', explanation_snapshot FROM inserted_awards RETURNING id), rejected_decisions AS (INSERT INTO clearing_decisions (id, tenant_id, clearing_job_id, auction_id, bid_id, load_id, decision_type, binding_constraints, rejected_reason, infeasibility_details, redaction_scope, explanation_snapshot) SELECT gen_random_uuid(), j.tenant_id, j.id, j.auction_id, b.id, b.load_id, 'rejected_policy', jsonb_build_array('one_award_per_load', 'deterministic_tiebreak'), 'NOT_SELECTED', '{}'::jsonb, 'operator', jsonb_build_object('reason', 'NOT_SELECTED', 'bid_amount_cents', round(b.bid_amount * 100)::int, 'service_score_milli', round(b.service_score_snapshot * 1000)::int) FROM bids b JOIN target j ON j.tenant_id = b.tenant_id AND j.auction_id = b.auction_id WHERE b.status IN ('submitted','eligible') AND NOT EXISTS (SELECT 1 FROM assignment a WHERE a.bid_id = b.id) RETURNING id), unassigned_decisions AS (INSERT INTO clearing_decisions (id, tenant_id, clearing_job_id, auction_id, load_id, decision_type, binding_constraints, rejected_reason, infeasibility_details, redaction_scope, explanation_snapshot) SELECT gen_random_uuid(), j.tenant_id, j.id, j.auction_id, l.id, 'unassigned', jsonb_build_array('one_award_per_load', 'capacity_or_policy_constraints'), 'NO_FEASIBLE_ASSIGNMENT', '{}'::jsonb, 'operator', jsonb_build_object('reason', 'NO_FEASIBLE_ASSIGNMENT') FROM loads l JOIN target j ON j.tenant_id = l.tenant_id AND j.auction_id = l.auction_id WHERE NOT EXISTS (SELECT 1 FROM assignment a WHERE a.load_id = l.id) RETURNING id), updated_bids AS (UPDATE bids b SET status = CASE WHEN b.id IN (SELECT bid_id FROM assignment) THEN 'awarded' ELSE 'rejected_policy' END, updated_at = now() WHERE b.tenant_id = (SELECT tenant_id FROM target) AND b.auction_id = (SELECT auction_id FROM target) AND b.status IN ('submitted','eligible') RETURNING b.id), updated_loads AS (UPDATE loads l SET status = CASE WHEN EXISTS (SELECT 1 FROM assignment a WHERE a.load_id = l.id) THEN 'awarded' ELSE 'unassigned' END, updated_at = now() WHERE l.tenant_id = (SELECT tenant_id FROM target) AND l.auction_id = (SELECT auction_id FROM target) AND l.status IN ('eligible','bid_open','clearing') RETURNING l.id), updated_job AS (UPDATE clearing_jobs SET status = 'succeeded', solver_input_uri = 'sha256:' || ?, solver_output_uri = 'sha256:' || ?, solver_version = ?, finished_at = now(), updated_at = now() WHERE id = (SELECT id FROM target) AND (SELECT count(*) FROM awarded_decisions) + (SELECT count(*) FROM rejected_decisions) + (SELECT count(*) FROM unassigned_decisions) + (SELECT count(*) FROM updated_bids) + (SELECT count(*) FROM updated_loads) >= 0 RETURNING id, tenant_id, auction_id), notifications AS (INSERT INTO notifications (id, tenant_id, user_id, event_type, template_id, channel, urgency, payload_snapshot, status) SELECT gen_random_uuid(), j.tenant_id, u.id, 'clearing_succeeded', 'clearing-succeeded-v1', 'in_app', 'high', jsonb_build_object('job_id', j.id::text, 'auction_id', j.auction_id::text), 'queued' FROM updated_job j JOIN users u ON u.tenant_id = j.tenant_id AND u.is_active AND u.role IN ('tenant_admin','auction_manager') RETURNING id) UPDATE auctions SET status = CASE WHEN EXISTS (SELECT 1 FROM inserted_awards ia WHERE ia.tenant_id = (SELECT tenant_id FROM updated_job) AND ia.auction_id = (SELECT auction_id FROM updated_job) AND ia.clearing_job_id = (SELECT id FROM updated_job)) THEN 'pending_approval' ELSE 'awarded' END, updated_at = now() WHERE tenant_id = (SELECT tenant_id FROM updated_job) AND id = (SELECT auction_id FROM updated_job) AND (SELECT count(*) >= 0 FROM notifications)"

let parse_job value =
  try
    let json = Yojson.Safe.from_string value in
    let open Yojson.Safe.Util in
    if json = `Null then Ok None else Ok (Some { id = json |> member "id" |> to_string; tenant_id = json |> member "tenant_id" |> to_string; auction_id = json |> member "auction_id" |> to_string; input = json |> member "input" })
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> Error "JOB_PAYLOAD_INVALID"

let claim () =
  let open Lwt.Syntax in
  let* result = Db_pool.with_connection (fun (module Connection : Caqti_lwt.CONNECTION) -> Connection.find claim_request ()) in
  match result with Error _ -> Lwt.return (Error "DATABASE_UNAVAILABLE") | Ok value -> Lwt.return (parse_job value)

let mark_infeasible job ~reason ~relaxations =
  let open Lwt.Syntax in
  let infeasible_notifications =
    let open Caqti_request.Infix in
    (Caqti_type.(t3 string string string) ->. Caqti_type.unit)
      "INSERT INTO notifications (id, tenant_id, user_id, event_type, template_id, channel, urgency, payload_snapshot, status) SELECT gen_random_uuid(), j.tenant_id, u.id, 'clearing_infeasible', 'clearing-infeasible-v1', 'in_app', 'high', jsonb_build_object('job_id', j.id::text, 'auction_id', j.auction_id::text), 'queued' FROM clearing_jobs j JOIN users u ON u.tenant_id = j.tenant_id AND u.is_active AND u.role = 'auction_manager' WHERE j.id = ?::uuid AND j.tenant_id = ?::uuid AND j.auction_id = ?::uuid AND NOT EXISTS (SELECT 1 FROM notifications n WHERE n.tenant_id = j.tenant_id AND n.user_id = u.id AND n.event_type = 'clearing_infeasible' AND n.payload_snapshot->>'job_id' = j.id::text)"
  in
  let* result = Db_pool.with_connection (fun (module Connection : Caqti_lwt.CONNECTION) -> Connection.with_transaction (fun () -> Connection.exec mark_infeasible_request (reason, reason, reason, relaxations, job.id, job.tenant_id, job.auction_id) >>= function Error error -> Lwt.return (Error error) | Ok () -> Connection.exec infeasible_notifications (job.id, job.tenant_id, job.auction_id))) in
  Lwt.return (match result with Ok () -> Ok () | Error _ -> Error "DATABASE_UNAVAILABLE")

let mark_failed_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t5 string string string string string) ->. Caqti_type.unit)
    "UPDATE clearing_jobs SET status = 'failed', error_code = ?, error_message = left(?, 500), finished_at = now(), updated_at = now() WHERE id = ?::uuid AND tenant_id = ?::uuid AND auction_id = ?::uuid AND status = 'running'"

let mark_failed job ~error_code ~error_message =
  let open Lwt.Syntax in
  let* result = Db_pool.with_connection (fun (module Connection : Caqti_lwt.CONNECTION) -> Connection.exec mark_failed_request (error_code, error_message, job.id, job.tenant_id, job.auction_id)) in
  Lwt.return (match result with Ok () -> Ok () | Error _ -> Error "DATABASE_UNAVAILABLE")

let cancel_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 string string) ->. Caqti_type.unit)
    "UPDATE clearing_jobs SET status = 'cancelled', finished_at = now(), updated_at = now() WHERE tenant_id = ?::uuid AND id = ?::uuid AND status IN ('queued','running','retry_scheduled')"

let cancel ~tenant_id ~job_id =
  let open Lwt.Syntax in
  let* result = Db_pool.with_connection (fun (module Connection : Caqti_lwt.CONNECTION) -> Connection.exec cancel_request (tenant_id, job_id)) in
  Lwt.return (match result with Ok () -> Ok () | Error _ -> Error "DATABASE_UNAVAILABLE")

let retry_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 string string) ->. Caqti_type.unit)
    "UPDATE clearing_jobs SET status = 'queued', retry_count = retry_count + 1, error_code = NULL, error_message = NULL, finished_at = NULL, started_at = NULL, updated_at = now() WHERE tenant_id = ?::uuid AND id = ?::uuid AND status IN ('failed','infeasible','cancelled')"

let retry ~tenant_id ~job_id =
  let open Lwt.Syntax in
  let* result = Db_pool.with_connection (fun (module Connection : Caqti_lwt.CONNECTION) -> Connection.exec retry_request (tenant_id, job_id)) in
  Lwt.return (match result with Ok () -> Ok () | Error _ -> Error "DATABASE_UNAVAILABLE")

let mark_succeeded job ~solver_version ~input_hash ~output_hash ~assignments =
  let open Lwt.Syntax in
  let assignment_json = Yojson.Safe.to_string (`List (List.map (fun (load_id, bid_id) -> `Assoc [ ("load_id", `String load_id); ("bid_id", `String bid_id) ]) assignments)) in
  let parameters = (job.id, job.tenant_id, job.auction_id, assignment_json, input_hash, output_hash, input_hash, output_hash, solver_version) in
  let ensure_approval_request =
    let open Caqti_request.Infix in
    (Caqti_type.(t4 string string string string) ->. Caqti_type.unit)
      "INSERT INTO approval_requests (id, tenant_id, auction_id, award_id, status, reason, payload_snapshot, requested_by_user_id) SELECT gen_random_uuid(), a.tenant_id, a.auction_id, a.id, 'pending', 'approval_threshold', jsonb_build_object('award_id', a.id::text, 'auction_id', a.auction_id::text, 'solver_input_hash', ?::text, 'solver_output_hash', ?::text), j.requested_by_user_id FROM awards a JOIN clearing_jobs j ON j.tenant_id = a.tenant_id AND j.id = a.clearing_job_id WHERE a.tenant_id = ?::uuid AND a.clearing_job_id = ?::uuid AND a.status = 'approval_required' AND NOT EXISTS (SELECT 1 FROM approval_requests existing WHERE existing.tenant_id = a.tenant_id AND existing.award_id = a.id AND existing.status IN ('pending','approved'))"
  in
  let queue_approval_notifications =
    let open Caqti_request.Infix in
    (Caqti_type.(t2 string string) ->. Caqti_type.unit)
      "INSERT INTO notifications (id, tenant_id, user_id, event_type, template_id, channel, urgency, payload_snapshot, status) SELECT gen_random_uuid(), ar.tenant_id, u.id, 'award_approval_required', 'award-approval-required-v1', 'in_app', 'critical', jsonb_build_object('award_id', ar.award_id::text, 'auction_id', ar.auction_id::text), 'queued' FROM approval_requests ar JOIN users u ON u.tenant_id = ar.tenant_id AND u.is_active AND u.role = 'tenant_admin' WHERE ar.tenant_id = ?::uuid AND ar.status = 'pending' AND ar.award_id IN (SELECT a.id FROM awards a WHERE a.clearing_job_id = ?::uuid) AND NOT EXISTS (SELECT 1 FROM notifications n WHERE n.tenant_id = ar.tenant_id AND n.user_id = u.id AND n.event_type = 'award_approval_required' AND n.payload_snapshot->>'award_id' = ar.award_id::text)"
  in
  let queue_bid_notifications =
    let open Caqti_request.Infix in
    (Caqti_type.(t2 string string) ->. Caqti_type.unit)
      "INSERT INTO notifications (id, tenant_id, user_id, event_type, template_id, channel, urgency, payload_snapshot, status) SELECT gen_random_uuid(), d.tenant_id, u.id, 'carrier_bid_rejected', 'carrier-bid-rejected-v1', 'in_app', 'low', jsonb_build_object('bid_id', d.bid_id::text, 'auction_id', d.auction_id::text, 'reason', COALESCE(d.rejected_reason, 'NOT_SELECTED')), 'queued' FROM clearing_decisions d JOIN bids b ON b.id = d.bid_id AND b.tenant_id = d.tenant_id JOIN users u ON u.tenant_id = b.tenant_id AND u.carrier_id = b.carrier_id AND u.is_active AND u.role = 'carrier_viewer' WHERE d.tenant_id = ?::uuid AND d.clearing_job_id = ?::uuid AND d.decision_type = 'rejected_policy' AND NOT EXISTS (SELECT 1 FROM notifications n WHERE n.tenant_id = d.tenant_id AND n.user_id = u.id AND n.event_type = 'carrier_bid_rejected' AND n.payload_snapshot->>'bid_id' = d.bid_id::text)"
  in
  let* result = Db_pool.with_connection (fun (module Connection : Caqti_lwt.CONNECTION) -> Connection.with_transaction (fun () -> Connection.exec complete_request parameters >>= function Error error -> Lwt.return (Error error) | Ok () -> Connection.exec ensure_approval_request (input_hash, output_hash, job.tenant_id, job.id) >>= function Error error -> Lwt.return (Error error) | Ok () -> Connection.exec queue_approval_notifications (job.tenant_id, job.id) >>= function Error error -> Lwt.return (Error error) | Ok () -> Connection.exec queue_bid_notifications (job.tenant_id, job.id))) in
  Lwt.return (match result with Ok () -> Ok () | Error _ -> Error "DATABASE_UNAVAILABLE")
