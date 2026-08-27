type actor = { user_id : string; tenant_id : string; role : string; carrier_id : string option }
type error = Unavailable | Not_found | Conflict | Invalid of string

let auth_request =
  let open Caqti_request.Infix in
  (Caqti_type.string ->! Caqti_type.(t5 string string string string bool))
    "SELECT u.id::text, u.tenant_id::text, u.role, COALESCE(u.carrier_id::text, ''), t.is_active FROM users u JOIN tenants t ON t.id = u.tenant_id WHERE t.api_key_hash = encode(digest(?, 'sha256'), 'hex') AND u.is_active"

let health_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->! Caqti_type.int) "SELECT 1"

let list_request =
  let open Caqti_request.Infix in
  (Caqti_type.string ->! Caqti_type.string)
    "SELECT COALESCE(json_agg(row_to_json(items)), '[]'::json)::text FROM (SELECT id::text, name, mode, status, bid_open_at::text, bid_close_at::text, summary_metrics FROM auctions WHERE tenant_id = ? ORDER BY created_at DESC) items"

let tenant_request =
  let open Caqti_request.Infix in
  (Caqti_type.string ->! Caqti_type.string)
    "SELECT json_build_object('id', id::text, 'name', name, 'legal_name', legal_name, 'full_legal_name', full_legal_name, 'display_name', display_name, 'timezone', timezone, 'default_currency', default_currency, 'is_active', is_active, 'contact', contact)::text FROM tenants WHERE id = ?::uuid"

let detail_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t4 string string string string) ->! Caqti_type.string)
    "SELECT json_build_object('id', a.id::text, 'name', a.name, 'mode', a.mode, 'status', a.status, 'bid_open_at', a.bid_open_at::text, 'bid_close_at', a.bid_close_at::text, 'loads', COALESCE((SELECT json_agg(row_to_json(l)) FROM (SELECT id::text, external_ref, equipment_type, status FROM loads WHERE tenant_id = a.tenant_id AND auction_id = a.id ORDER BY created_at) l), '[]'::json), 'bids', COALESCE((SELECT json_agg(row_to_json(b)) FROM (SELECT id::text, load_id::text, carrier_id::text, bid_amount, currency, service_score_snapshot, status, submitted_at::text FROM bids WHERE tenant_id = a.tenant_id AND auction_id = a.id AND (? = '' OR carrier_id::text = ?) ORDER BY submitted_at) b), '[]'::json))::text FROM auctions a WHERE a.tenant_id = ? AND a.id = ?"

let bids_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t4 string string string string) ->! Caqti_type.string)
    "SELECT COALESCE(json_agg(row_to_json(items)), '[]'::json)::text FROM (SELECT id::text, load_id::text, carrier_id::text, bid_amount, currency, service_score_snapshot, status, submitted_at::text FROM bids WHERE tenant_id = ? AND auction_id = ? AND (? = '' OR carrier_id::text = ?) ORDER BY submitted_at) items"

let close_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 string string) ->! Caqti_type.string)
    "UPDATE auctions SET status = 'closed', updated_at = now() WHERE tenant_id = ? AND id = ? AND status IN ('draft','open') RETURNING id::text"

let update_auction_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t7 string string string string string string string) ->! Caqti_type.string)
    "UPDATE auctions SET name = ?, bid_open_at = ?::timestamp, bid_close_at = ?::timestamp, updated_at = now() WHERE tenant_id = ?::uuid AND id = ?::uuid AND status IN ('draft','open') AND ?::timestamp > ?::timestamp RETURNING json_build_object('id', id::text, 'name', name, 'mode', mode, 'status', status, 'bid_open_at', bid_open_at::text, 'bid_close_at', bid_close_at::text)::text"

let enqueue_clear_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t3 string string string) ->! Caqti_type.string)
    "WITH target AS (SELECT a.id AS auction_id, a.tenant_id, p.max_service_risk, p.max_single_carrier_share, p.reserve_price_behavior FROM auctions a JOIN auction_policies p ON p.id = a.policy_id AND p.tenant_id = a.tenant_id WHERE a.tenant_id = ? AND a.id = ? AND a.status = 'closed'), snapshot AS (SELECT target.*, jsonb_build_object('policy', jsonb_build_object('max_service_risk', target.max_service_risk, 'max_single_carrier_share', target.max_single_carrier_share, 'reserve_price_behavior', target.reserve_price_behavior), 'loads', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', l.id::text, 'reserve_cents', round(ln.reserve_price * 100)::int, 'equipment', l.equipment_type) ORDER BY l.id) FROM loads l JOIN lanes ln ON ln.id = l.lane_id AND ln.tenant_id = l.tenant_id WHERE l.tenant_id = target.tenant_id AND l.auction_id = target.auction_id), '[]'::jsonb), 'bids', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', b.id::text, 'load_id', b.load_id::text, 'carrier_id', b.carrier_id::text, 'amount_cents', round(b.bid_amount * 100)::int, 'service_score_milli', round(b.service_score_snapshot * 1000)::int, 'capacity_units', b.capacity_units) ORDER BY b.id) FROM bids b WHERE b.tenant_id = target.tenant_id AND b.auction_id = target.auction_id AND b.status IN ('submitted','eligible')), '[]'::jsonb)) AS input_snapshot FROM target), job AS (INSERT INTO clearing_jobs (id, tenant_id, auction_id, status, requested_by_user_id, policy_snapshot, input_snapshot, solver_backend, solver_version) SELECT gen_random_uuid(), tenant_id, auction_id, 'queued', ?, jsonb_build_object('max_service_risk', max_service_risk, 'max_single_carrier_share', max_single_carrier_share, 'reserve_price_behavior', reserve_price_behavior), input_snapshot, 'minizinc', 'configured' FROM snapshot RETURNING id, tenant_id, auction_id) UPDATE auctions SET status = 'clearing_queued', clearing_job_id = job.id, updated_at = now() FROM job WHERE auctions.id = job.auction_id AND auctions.tenant_id = job.tenant_id RETURNING job.id::text"

let with_find (type parameter) (type row)
    (request : (parameter, row, [< `One ]) Caqti_request.t)
    (parameters : parameter) =
  let open Lwt.Syntax in
  let* result = Db_pool.with_connection (fun (module Connection : Caqti_lwt.CONNECTION) -> Connection.find request parameters) in
  Lwt.return (match result with Error error when Errors.Code.to_string (Db_pool.error_code error) = "DATABASE_OPERATION_NOT_FOUND" -> Error Not_found | Error _ -> Error Unavailable | Ok value -> Ok value)

let with_exec (type parameter)
    (request : (parameter, unit, [< `Zero ]) Caqti_request.t)
    (parameters : parameter) =
  let open Lwt.Syntax in
  let* result = Db_pool.with_connection (fun (module Connection : Caqti_lwt.CONNECTION) -> Connection.exec request parameters) in
  Lwt.return (match result with Error _ -> Error Unavailable | Ok value -> Ok value)

let health () =
  let open Lwt.Syntax in
  let* result = with_find health_request () in
  Lwt.return (match result with Ok 1 -> true | _ -> false)

let authenticate ~api_key =
  let open Lwt.Syntax in
  if api_key = "" || String.length api_key > 256 then Lwt.return (Error (Invalid "API_KEY_INVALID"))
  else
    let* result = with_find auth_request api_key in
    Lwt.return (match result with Ok (user_id, tenant_id, role, carrier, true) -> Ok { user_id; tenant_id; role; carrier_id = if carrier = "" then None else Some carrier } | Ok _ -> Error Not_found | Error error -> Error error)

let seed_demo () =
  let request =
    let open Caqti_request.Infix in
      (Caqti_type.(t5 string string string string string) ->! Caqti_type.string)
      "INSERT INTO tenants (id, name, legal_name, full_legal_name, display_name, api_key_hash, contact) VALUES ('11111111-1111-4111-8111-111111111111', ?, ?, ?, ?, encode(digest(?, 'sha256'), 'hex'), '{}'::jsonb) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, api_key_hash = EXCLUDED.api_key_hash, updated_at = now() RETURNING api_key_hash"
  in
  let open Lwt.Syntax in
  let* result = with_find request ("Freight Demo", "Freight Demo LLC", "Freight Demo LLC", "Freight Demo", "fca_demo_key_2026") in
  match result with
  | Error error -> Lwt.return (Error error)
  | Ok _hash ->
      let tenant_request =
        let open Caqti_request.Infix in
        (Caqti_type.string ->! Caqti_type.string) "SELECT id::text FROM tenants WHERE name = ?"
      in
      let* tenant = with_find tenant_request "Freight Demo" in
      (match tenant with
       | Error error -> Lwt.return (Error error)
       | Ok tenant_id ->
           let user_request =
             let open Caqti_request.Infix in
             (Caqti_type.(t2 string string) ->. Caqti_type.unit)
               "INSERT INTO users (id, tenant_id, email, name, role, password_hash) VALUES (gen_random_uuid(), ?, ?, 'Demo Admin', 'tenant_admin', NULL) ON CONFLICT (tenant_id, email) DO NOTHING"
           in
           let* user = with_exec user_request (tenant_id, "admin@freight.demo") in
           let carrier_request =
             let open Caqti_request.Infix in
             (Caqti_type.string ->. Caqti_type.unit)
               "INSERT INTO carriers (id, tenant_id, legal_name, display_name, equipment_types, status) VALUES ('33333333-3333-4333-8333-333333333333', ?, 'Demo Carrier LLC', 'Demo Carrier', ARRAY['dry_van']::text[], 'active') ON CONFLICT (id) DO UPDATE SET tenant_id = EXCLUDED.tenant_id, status = 'active'"
           in
           let* carrier = with_exec carrier_request tenant_id in
           let lane_request =
             let open Caqti_request.Infix in
             (Caqti_type.string ->. Caqti_type.unit)
               "INSERT INTO lanes (id, tenant_id, origin_region, destination_region, equipment_type, distance_miles, reserve_price, status) VALUES ('44444444-4444-4444-8444-444444444444', ?, 'Lagos', 'Abuja', 'dry_van', 475, 100.00, 'active') ON CONFLICT (id) DO UPDATE SET tenant_id = EXCLUDED.tenant_id, status = 'active'"
           in
           let* lane = with_exec lane_request tenant_id in
           let policy_request =
             let open Caqti_request.Infix in
             (Caqti_type.string ->. Caqti_type.unit)
               "INSERT INTO auction_policies (id, tenant_id, name, status, reserve_price_behavior) VALUES (gen_random_uuid(), ?, 'default', 'active', 'hard_reject') ON CONFLICT (tenant_id, name, version) DO NOTHING"
           in
           let* policy = with_exec policy_request tenant_id in
           Lwt.return (match (user, carrier, lane, policy) with Ok (), Ok (), Ok (), Ok () -> Ok (tenant_id, "fca_demo_key_2026") | Error error, _, _, _ | _, Error error, _, _ | _, _, Error error, _ | _, _, _, Error error -> Error error))

let register ~tenant_name ~email ~name =
  if tenant_name = "" || email = "" || name = "" then Lwt.return (Error (Invalid "REGISTRATION_INPUT_INVALID"))
  else
    let key =
      let seed = Printf.sprintf "%f:%d:%s" (Unix.gettimeofday ()) (Random.bits ()) email in
      "fca_" ^ (Digestif.SHA256.digest_string seed |> Digestif.SHA256.to_hex)
    in
    let request =
      let open Caqti_request.Infix in
      (Caqti_type.(t7 string string string string string string string) ->! Caqti_type.string)
        "WITH tenant AS (INSERT INTO tenants (id, name, legal_name, full_legal_name, display_name, api_key_hash) VALUES (gen_random_uuid(), ?, ?, ?, ?, encode(digest(?, 'sha256'), 'hex')) RETURNING id), new_user AS (INSERT INTO users (id, tenant_id, email, name, role) SELECT gen_random_uuid(), id, ?, ?, 'tenant_admin' FROM tenant RETURNING id, tenant_id), policy AS (INSERT INTO auction_policies (id, tenant_id, name, status, reserve_price_behavior) SELECT gen_random_uuid(), tenant_id, 'default', 'active', 'hard_reject' FROM new_user) SELECT json_build_object('user_id', id::text, 'tenant_id', tenant_id::text)::text FROM new_user"
    in
    let open Lwt.Syntax in
    let* result = with_find request (tenant_name, tenant_name, tenant_name, tenant_name, key, email, name) in
    Lwt.return (match result with Error error -> Error error | Ok json -> try let value = Yojson.Safe.from_string json in let open Yojson.Safe.Util in let user_id = value |> member "user_id" |> to_string in let tenant_id = value |> member "tenant_id" |> to_string in Ok ({ user_id; tenant_id; role = "tenant_admin"; carrier_id = None }, key) with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> Error (Invalid "REGISTRATION_RESPONSE_INVALID"))

let list_auctions ~tenant_id =
  let open Lwt.Syntax in
  let* result = with_find list_request tenant_id in
  Lwt.return (Result.bind result (fun value -> try Ok (Yojson.Safe.from_string value) with Yojson.Json_error _ -> Error (Invalid "RESPONSE_INVALID")))

let get_auction ~tenant_id ~auction_id ~carrier_id =
  let open Lwt.Syntax in
  let carrier = Option.value ~default:"" carrier_id in
  let* result = with_find detail_request (carrier, carrier, tenant_id, auction_id) in
  Lwt.return (Result.bind result (fun value -> try Ok (Yojson.Safe.from_string value) with Yojson.Json_error _ -> Error (Invalid "RESPONSE_INVALID")))

let list_bids ~tenant_id ~auction_id ~carrier_id =
  let open Lwt.Syntax in
  let carrier = Option.value ~default:"" carrier_id in
  let* result = with_find bids_request (tenant_id, auction_id, carrier, carrier) in
  Lwt.return (Result.bind result (fun value -> try Ok (Yojson.Safe.from_string value) with Yojson.Json_error _ -> Error (Invalid "RESPONSE_INVALID")))

let create_auction ~auto_clear_on_close ~tenant_id ~user_id ~name ~mode ~bid_open_at ~bid_close_at =
  if name = "" || mode = "" then Lwt.return (Error (Invalid "AUCTION_INPUT_INVALID"))
  else if Result.is_error (Capability_registry.production_mode mode) then Lwt.return (Error (Invalid "AUCTION_MODE_UNSUPPORTED"))
  else
    let request =
      let open Caqti_request.Infix in
      (Caqti_type.(t8 string string string string string bool string string) ->! Caqti_type.string)
        "INSERT INTO auctions (id, tenant_id, name, mode, status, bid_open_at, bid_close_at, auto_clear_on_close, policy_id, created_by_user_id) SELECT gen_random_uuid(), ?, ?, ?, 'open', ?::timestamp, ?::timestamp, ?, p.id, ? FROM auction_policies p WHERE p.tenant_id = ? AND p.status = 'active' ORDER BY p.version DESC LIMIT 1 RETURNING id::text"
    in
    let open Lwt.Syntax in
    let* result = with_find request (tenant_id, name, mode, bid_open_at, bid_close_at, auto_clear_on_close, user_id, tenant_id) in
    Lwt.return (match result with Ok id -> Ok id | Error error -> Error error)

let update_auction ~tenant_id ~auction_id ~name ~bid_open_at ~bid_close_at =
  if name = "" then Lwt.return (Error (Invalid "AUCTION_INPUT_INVALID"))
  else
    let open Lwt.Syntax in
    let* result = with_find update_auction_request (name, bid_open_at, bid_close_at, tenant_id, auction_id, bid_close_at, bid_open_at) in
    Lwt.return (Result.bind result (fun value -> try Ok (Yojson.Safe.from_string value) with Yojson.Json_error _ -> Error (Invalid "RESPONSE_INVALID")))

let close_auction ~tenant_id ~auction_id =
  let open Lwt.Syntax in
  let* result = with_find close_request (tenant_id, auction_id) in
  Lwt.return (match result with Ok _ -> Ok () | Error Unavailable -> Error Not_found | Error error -> Error error)

let enqueue_clear ~tenant_id ~auction_id ~user_id =
  let open Lwt.Syntax in
  let* result = with_find enqueue_clear_request (tenant_id, auction_id, user_id) in
  Lwt.return (match result with Ok id -> Ok id | Error Unavailable -> Error Not_found | Error error -> Error error)

let add_load ~tenant_id ~auction_id ~lane_id ~external_ref ~pickup_start ~pickup_end ~delivery_start ~delivery_end ~weight_lbs ~equipment_type =
  if weight_lbs <= 0 then Lwt.return (Error (Invalid "WEIGHT_INVALID"))
  else
    let request =
      let open Caqti_request.Infix in
      (Caqti_type.(t10 string string string string string string string string int string) ->! Caqti_type.string)
        "WITH owned AS (SELECT id AS auction_id, tenant_id FROM auctions WHERE tenant_id = ? AND id = ?) INSERT INTO loads (id, tenant_id, auction_id, lane_id, external_ref, pickup_window_start, pickup_window_end, delivery_window_start, delivery_window_end, weight_lbs, equipment_type, service_priority, status) SELECT gen_random_uuid(), owned.tenant_id, owned.auction_id, ?, ?, ?::timestamp, ?::timestamp, ?::timestamp, ?::timestamp, ?, ?, 'standard', 'eligible' FROM owned RETURNING id::text"
    in
    let open Lwt.Syntax in
    let* result = with_find request (tenant_id, auction_id, lane_id, external_ref, pickup_start, pickup_end, delivery_start, delivery_end, weight_lbs, equipment_type) in
    Lwt.return result

let submit_bid ~tenant_id ~auction_id ~load_id ~carrier_id ~idempotency_key ~bid_amount_cents ~service_score_milli ~submitted_at =
  if bid_amount_cents < 0 || service_score_milli < 0 || service_score_milli > 1_000 then Lwt.return (Error (Invalid "BID_INPUT_INVALID"))
  else
    let request =
      let open Caqti_request.Infix in
      (Caqti_type.(t9 string string string string string int int string string) ->! Caqti_type.string)
        "WITH owned AS (SELECT a.id AS auction_id, a.tenant_id, a.bid_close_at, l.id AS load_id, c.id AS carrier_id FROM auctions a JOIN loads l ON l.auction_id = a.id AND l.tenant_id = a.tenant_id JOIN lanes ln ON ln.id = l.lane_id AND ln.tenant_id = l.tenant_id JOIN carriers c ON c.id = ?::uuid AND c.tenant_id = a.tenant_id AND c.status = 'active' AND l.equipment_type = ANY(c.equipment_types) WHERE a.tenant_id = ? AND a.id = ? AND a.status IN ('open','draft') AND l.id = ?) INSERT INTO bids (id, tenant_id, auction_id, load_id, carrier_id, idempotency_key, bid_amount, service_score_snapshot, submitted_at, source, status) SELECT gen_random_uuid(), owned.tenant_id, owned.auction_id, owned.load_id, owned.carrier_id, ?, ? / 100.0, ? / 1000.0, ?::timestamp, 'api', CASE WHEN ?::timestamp > owned.bid_close_at THEN 'late' ELSE 'submitted' END FROM owned ON CONFLICT (tenant_id, auction_id, idempotency_key) DO UPDATE SET updated_at = bids.updated_at RETURNING id::text"
    in
    let open Lwt.Syntax in
    let* result = with_find request (carrier_id, tenant_id, auction_id, load_id, idempotency_key, bid_amount_cents, service_score_milli, submitted_at, submitted_at) in
    Lwt.return result

let json_request sql =
  let open Caqti_request.Infix in
  (Caqti_type.string ->! Caqti_type.string) sql

let json_result result =
  Result.bind result (fun value -> try Ok (Yojson.Safe.from_string value) with Yojson.Json_error _ -> Error (Invalid "RESPONSE_INVALID"))

let list_carriers_request = json_request
  "SELECT COALESCE(json_agg(row_to_json(items)), '[]'::json)::text FROM (SELECT id::text, legal_name, display_name, status, equipment_types, reliability_score, historical_otd_rate, withdrawal_rate FROM carriers WHERE tenant_id = ? ORDER BY display_name, id) items"

let get_carrier_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 string string) ->! Caqti_type.string)
  "SELECT json_build_object('id', id::text, 'legal_name', legal_name, 'display_name', display_name, 'mc_number', mc_number, 'dot_number', dot_number, 'equipment_types', equipment_types, 'service_regions', service_regions, 'reliability_score', reliability_score, 'historical_otd_rate', historical_otd_rate, 'withdrawal_rate', withdrawal_rate, 'status', status, 'risk_flags', risk_flags)::text FROM carriers WHERE tenant_id = ? AND id = ?::uuid"

let create_carrier_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t7 string string string string string string string) ->! Caqti_type.string)
    "INSERT INTO carriers (id, tenant_id, legal_name, display_name, mc_number, dot_number, equipment_types, status) VALUES (gen_random_uuid(), ?::uuid, ?, ?, nullif(?, ''), nullif(?, ''), ARRAY[?]::text[], ?) RETURNING id::text"

let update_carrier_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t6 string string string string string string) ->! Caqti_type.string)
    "UPDATE carriers SET legal_name = ?, display_name = ?, equipment_types = ARRAY[?]::text[], status = ?, updated_at = now() WHERE tenant_id = ?::uuid AND id = ?::uuid RETURNING json_build_object('id', id::text, 'legal_name', legal_name, 'display_name', display_name, 'equipment_types', equipment_types, 'status', status)::text"

let list_carrier_bids_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 string string) ->! Caqti_type.string)
  "SELECT COALESCE(json_agg(row_to_json(items)), '[]'::json)::text FROM (SELECT b.id::text, b.auction_id::text, a.name AS auction_name, b.load_id::text, b.bid_amount, b.currency, b.service_score_snapshot, b.status, b.rejection_reason, b.submitted_at::text FROM bids b JOIN auctions a ON a.id = b.auction_id AND a.tenant_id = b.tenant_id WHERE b.tenant_id = ? AND b.carrier_id = ?::uuid ORDER BY b.submitted_at DESC, b.id) items"

let list_users_request = json_request
  "SELECT COALESCE(json_agg(row_to_json(items)), '[]'::json)::text FROM (SELECT id::text, email, name, role, COALESCE(carrier_id::text, '') AS carrier_id, is_active, last_login_at::text, created_at::text FROM users WHERE tenant_id = ? ORDER BY name, id) items"

let get_user_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 string string) ->! Caqti_type.string)
    "SELECT json_build_object('id', id::text, 'email', email, 'name', name, 'role', role, 'carrier_id', COALESCE(carrier_id::text, ''), 'is_active', is_active, 'last_login_at', last_login_at::text)::text FROM users WHERE tenant_id = ? AND id = ?::uuid"

let create_user_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t5 string string string string string) ->! Caqti_type.string)
    "INSERT INTO users (id, tenant_id, email, name, role, carrier_id) VALUES (gen_random_uuid(), ?::uuid, ?, ?, ?, nullif(?, '')::uuid) RETURNING id::text"

let update_user_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t5 string string string string string) ->! Caqti_type.string)
    "UPDATE users SET name = ?, role = ?, carrier_id = nullif(?, '')::uuid, updated_at = now() WHERE tenant_id = ?::uuid AND id = ?::uuid RETURNING json_build_object('id', id::text, 'email', email, 'name', name, 'role', role, 'carrier_id', COALESCE(carrier_id::text, ''), 'is_active', is_active)::text"

let list_policies_request = json_request
  "SELECT COALESCE(json_agg(row_to_json(items)), '[]'::json)::text FROM (SELECT id::text, name, version, status, max_service_risk, max_single_carrier_share, reserve_price_behavior, fairness_rules, relaxation_order, approval_thresholds FROM auction_policies WHERE tenant_id = ? ORDER BY name, version DESC) items"

let create_policy_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t7 string string string string string string string) ->! Caqti_type.string)
    "WITH next_version AS (SELECT COALESCE(MAX(version), 0) + 1 AS value FROM auction_policies WHERE tenant_id = ?::uuid AND name = ?) INSERT INTO auction_policies (id, tenant_id, name, version, status, max_service_risk, max_single_carrier_share, reserve_price_behavior) SELECT gen_random_uuid(), ?::uuid, ?, value, 'draft', ?::numeric, ?::numeric, ? FROM next_version RETURNING json_build_object('id', id::text, 'name', name, 'version', version, 'status', status, 'max_service_risk', max_service_risk, 'max_single_carrier_share', max_single_carrier_share, 'reserve_price_behavior', reserve_price_behavior)::text"

let activate_policy_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 string string) ->! Caqti_type.string)
    "WITH target AS (SELECT id, tenant_id, name FROM auction_policies WHERE tenant_id = ?::uuid AND id = ?::uuid AND status = 'draft'), retired AS (UPDATE auction_policies SET status = 'retired', updated_at = now() WHERE tenant_id = (SELECT tenant_id FROM target) AND name = (SELECT name FROM target) AND status = 'active'), activated AS (UPDATE auction_policies SET status = 'active', updated_at = now() WHERE id = (SELECT id FROM target) RETURNING id::text, name, version, status) SELECT json_build_object('id', id, 'name', name, 'version', version, 'status', status)::text FROM activated"

let list_jobs_request = json_request
  "SELECT COALESCE(json_agg(row_to_json(items)), '[]'::json)::text FROM (SELECT id::text, auction_id::text, status, solver_backend, solver_version, error_code, queued_at::text, started_at::text, finished_at::text FROM clearing_jobs WHERE tenant_id = ? ORDER BY queued_at DESC) items"

let get_job_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 string string) ->! Caqti_type.string)
    "SELECT json_build_object('id', id::text, 'auction_id', auction_id::text, 'status', status, 'solver_backend', solver_backend, 'solver_version', solver_version, 'solver_input_uri', solver_input_uri, 'solver_output_uri', solver_output_uri, 'infeasibility_snapshot', infeasibility_snapshot, 'relaxation_suggestions', relaxation_suggestions, 'error_code', error_code, 'error_message', error_message, 'queued_at', queued_at::text, 'started_at', started_at::text, 'finished_at', finished_at::text)::text FROM clearing_jobs WHERE tenant_id = ? AND id = ?::uuid"

let list_awards_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t7 string string string string string string string) ->! Caqti_type.string)
    "SELECT COALESCE(json_agg(row_to_json(items)), '[]'::json)::text FROM (SELECT id::text, auction_id::text, load_id::text, bid_id::text, CASE WHEN ? = '' THEN carrier_id::text ELSE NULL END AS carrier_id, award_amount, service_score, total_score, status, approval_id::text, CASE WHEN ? = '' THEN explanation_snapshot ELSE jsonb_build_object('status', status, 'load_id', load_id::text) END AS explanation_snapshot FROM awards WHERE tenant_id = ? AND (? = '' OR auction_id::text = ?) AND (? = '' OR carrier_id::text = ?) ORDER BY created_at, id) items"

let list_approvals_request = json_request
  "SELECT COALESCE(json_agg(row_to_json(items)), '[]'::json)::text FROM (SELECT id::text, auction_id::text, award_id::text, status, reason, workflow_execution_id, requested_at::text, decided_at::text FROM approval_requests WHERE tenant_id = ? ORDER BY requested_at DESC) items"

let list_notifications_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t3 string string string) ->! Caqti_type.string)
    "SELECT COALESCE(json_agg(row_to_json(items)), '[]'::json)::text FROM (SELECT id::text, user_id::text, event_type, template_id, channel, urgency, status, created_at::text, delivered_at::text, read_at::text FROM notifications WHERE tenant_id = ?::uuid AND (? = '' OR user_id::text = ? OR user_id IS NULL) ORDER BY created_at DESC) items"

let mark_notification_read_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t3 string string string) ->. Caqti_type.unit)
    "UPDATE notifications SET status = CASE WHEN status IN ('queued','delivered') THEN 'read' ELSE status END, read_at = COALESCE(read_at, now()), updated_at = now() WHERE tenant_id = ?::uuid AND user_id = ?::uuid AND id = ?::uuid"

let list_integrations_request = json_request
  "SELECT COALESCE(json_agg(row_to_json(items)), '[]'::json)::text FROM (SELECT names.integration_name, COALESCE(i.enabled, false) AS enabled, COALESCE(i.config, '{}'::jsonb) AS config, COALESCE(i.last_health_status, 'disabled') AS last_health_status, i.last_checked_at::text FROM (VALUES ('notification_hub'), ('workflow_engine'), ('webhook_engine')) names(integration_name) LEFT JOIN integration_settings i ON i.tenant_id = ? AND i.integration_name = names.integration_name ORDER BY names.integration_name) items"

let update_integration_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t5 string string bool string bool) ->! Caqti_type.string)
    "INSERT INTO integration_settings (id, tenant_id, integration_name, enabled, config, last_health_status) VALUES (gen_random_uuid(), ?::uuid, ?, ?, ?::jsonb, CASE WHEN ? THEN 'unknown' ELSE 'disabled' END) ON CONFLICT (tenant_id, integration_name) DO UPDATE SET enabled = EXCLUDED.enabled, config = EXCLUDED.config, last_health_status = CASE WHEN EXCLUDED.enabled THEN 'unknown' ELSE 'disabled' END, updated_at = now() RETURNING json_build_object('integration_name', integration_name, 'enabled', enabled, 'config', config, 'last_health_status', last_health_status)::text"

let enqueue_integration_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t6 string string string string string string) ->! Caqti_type.string)
    "INSERT INTO integration_outbox (id, tenant_id, integration_name, event_type, target_url_env_var, payload, idempotency_key, status) VALUES (gen_random_uuid(), ?::uuid, ?, ?, ?, ?::jsonb, ?, 'queued') ON CONFLICT (tenant_id, integration_name, idempotency_key) DO UPDATE SET updated_at = now() RETURNING json_build_object('id', id::text, 'integration_name', integration_name, 'event_type', event_type, 'idempotency_key', idempotency_key, 'status', status)::text"

let list_reports_request = json_request
  "SELECT COALESCE(json_agg(row_to_json(items)), '[]'::json)::text FROM (SELECT id::text, auction_id::text, source_type, source_id::text, format, template_id, template_version, redaction_scope, status, created_at::text FROM report_exports WHERE tenant_id = ? ORDER BY created_at DESC) items"

let list_audit_request = json_request
  "SELECT COALESCE(json_agg(row_to_json(items)), '[]'::json)::text FROM (SELECT id::text, actor_user_id::text, entity_type, entity_id::text, event_type, event_payload, request_id, created_at::text FROM audit_events WHERE tenant_id = ? ORDER BY created_at DESC) items"

let list_decisions_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t10 string string string string string string string string string string) ->! Caqti_type.string)
    "SELECT COALESCE(json_agg(row_to_json(items)), '[]'::json)::text FROM (SELECT d.id::text, d.load_id::text, CASE WHEN ? = 'operator' THEN d.bid_id::text ELSE NULL END AS bid_id, d.decision_type, CASE WHEN ? = 'operator' THEN d.binding_constraints ELSE '[]'::jsonb END AS binding_constraints, CASE WHEN ? = 'operator' THEN d.rejected_reason ELSE NULL END AS rejected_reason, CASE WHEN ? = 'operator' THEN d.infeasibility_details ELSE jsonb_build_object('message', 'Decision details are redacted outside operator scope') END AS infeasibility_details, CASE WHEN ? = 'operator' THEN d.redaction_scope ELSE 'carrier' END AS redaction_scope, CASE WHEN ? = 'operator' THEN d.explanation_snapshot ELSE jsonb_build_object('decision_type', d.decision_type, 'generalized_reason', CASE WHEN d.decision_type = 'awarded' THEN 'Awarded under the tenant policy.' ELSE 'The bid was not selected under the tenant policy.' END) END AS explanation_snapshot, d.created_at::text FROM clearing_decisions d WHERE d.tenant_id = ? AND d.auction_id = ?::uuid AND (? = 'operator' OR EXISTS (SELECT 1 FROM bids b WHERE b.id = d.bid_id AND b.tenant_id = d.tenant_id AND b.carrier_id::text = ?)) ORDER BY d.created_at, d.id) items"

let list_replays_request = json_request
  "SELECT COALESCE(json_agg(row_to_json(items)), '[]'::json)::text FROM (SELECT id::text, name, status, dataset_uri, baseline_strategy, policy_id::text, metrics_snapshot, started_at::text, finished_at::text, created_at::text FROM replay_runs WHERE tenant_id = ? ORDER BY created_at DESC) items"

let list_with request parameters =
  let open Lwt.Syntax in
  let* result = with_find request parameters in
  Lwt.return (json_result result)

let list_carriers ~tenant_id = list_with list_carriers_request tenant_id
let get_carrier ~tenant_id ~carrier_id =
  let open Lwt.Syntax in
  let* result = with_find get_carrier_request (tenant_id, carrier_id) in
  Lwt.return (json_result result)

let create_carrier ~tenant_id ~legal_name ~display_name ~mc_number ~dot_number ~equipment_type ~status =
  if legal_name = "" || display_name = "" || equipment_type = "" || not (List.mem status [ "active"; "suspended"; "inactive"; "pending_review" ]) then
    Lwt.return (Error (Invalid "CARRIER_INPUT_INVALID"))
  else
    let open Lwt.Syntax in
    let* result = with_find create_carrier_request (tenant_id, legal_name, display_name, mc_number, dot_number, equipment_type, status) in
    Lwt.return result

let update_carrier ~tenant_id ~carrier_id ~legal_name ~display_name ~equipment_type ~status =
  if legal_name = "" || display_name = "" || equipment_type = "" || not (List.mem status [ "active"; "suspended"; "inactive"; "pending_review" ]) then
    Lwt.return (Error (Invalid "CARRIER_INPUT_INVALID"))
  else
    let open Lwt.Syntax in
    let* result = with_find update_carrier_request (legal_name, display_name, equipment_type, status, tenant_id, carrier_id) in
    Lwt.return (json_result result)

let list_carrier_bids ~tenant_id ~carrier_id = list_with list_carrier_bids_request (tenant_id, carrier_id)

let list_users ~tenant_id = list_with list_users_request tenant_id
let get_user ~tenant_id ~user_id =
  let open Lwt.Syntax in
  let* result = with_find get_user_request (tenant_id, user_id) in
  Lwt.return (json_result result)

let create_user ~tenant_id ~email ~name ~role ~carrier_id =
  if email = "" || name = "" || not (List.mem role [ "tenant_admin"; "auction_manager"; "procurement_analyst"; "carrier_viewer" ]) || (role = "carrier_viewer" && Option.is_none carrier_id) then
    Lwt.return (Error (Invalid "USER_INPUT_INVALID"))
  else
    let open Lwt.Syntax in
    let* result = with_find create_user_request (tenant_id, email, name, role, Option.value ~default:"" carrier_id) in
    Lwt.return result

let update_user ~tenant_id ~user_id ~name ~role ~carrier_id =
  if name = "" || not (List.mem role [ "tenant_admin"; "auction_manager"; "procurement_analyst"; "carrier_viewer" ]) || (role = "carrier_viewer" && Option.is_none carrier_id) then
    Lwt.return (Error (Invalid "USER_INPUT_INVALID"))
  else
    let open Lwt.Syntax in
    let* result = with_find update_user_request (name, role, Option.value ~default:"" carrier_id, tenant_id, user_id) in
    Lwt.return (json_result result)

let get_tenant ~tenant_id =
  let open Lwt.Syntax in
  let* result = with_find tenant_request tenant_id in
  Lwt.return (json_result result)
let list_policies ~tenant_id = list_with list_policies_request tenant_id
let create_policy ~tenant_id ~name ~max_service_risk ~max_single_carrier_share ~reserve_price_behavior =
  if name = "" || not (List.mem reserve_price_behavior [ "hard_reject"; "approval_required"; "allow_with_reason" ]) then
    Lwt.return (Error (Invalid "POLICY_INPUT_INVALID"))
  else
    let open Lwt.Syntax in
    let* result = with_find create_policy_request (tenant_id, name, tenant_id, name, max_service_risk, max_single_carrier_share, reserve_price_behavior) in
    Lwt.return (json_result result)

let activate_policy ~tenant_id ~policy_id =
  let open Lwt.Syntax in
  let* result = with_find activate_policy_request (tenant_id, policy_id) in
  Lwt.return (json_result result)

let list_clearing_jobs ~tenant_id = list_with list_jobs_request tenant_id
let get_clearing_job ~tenant_id ~job_id =
  let open Lwt.Syntax in
  let* result = with_find get_job_request (tenant_id, job_id) in
  Lwt.return (json_result result)
let list_approvals ~tenant_id = list_with list_approvals_request tenant_id
let list_notifications ~tenant_id ~user_id =
  list_with list_notifications_request
    (tenant_id, Option.value ~default:"" user_id, Option.value ~default:"" user_id)
let mark_notification_read ~tenant_id ~user_id ~notification_id =
  with_exec mark_notification_read_request (tenant_id, user_id, notification_id)
let list_integrations ~tenant_id = list_with list_integrations_request tenant_id
let update_integration ~tenant_id ~integration_name ~enabled ~config =
  if not (List.mem integration_name [ "notification_hub"; "workflow_engine"; "webhook_engine" ]) then
    Lwt.return (Error (Invalid "INTEGRATION_NAME_INVALID"))
  else
    let open Lwt.Syntax in
    let* result = with_find update_integration_request (tenant_id, integration_name, enabled, config, enabled) in
    Lwt.return (json_result result)

let enqueue_integration ~tenant_id ~integration_name ~event_type ~target_url_env_var ~payload ~idempotency_key =
  if not (List.mem integration_name [ "notification_hub"; "workflow_engine"; "webhook_engine" ]) || event_type = "" || idempotency_key = "" then
    Lwt.return (Error (Invalid "INTEGRATION_REQUEST_INVALID"))
  else
    let open Lwt.Syntax in
    let* result = with_find enqueue_integration_request (tenant_id, integration_name, event_type, target_url_env_var, payload, idempotency_key) in
    Lwt.return (json_result result)
let list_reports ~tenant_id = list_with list_reports_request tenant_id
let list_replays ~tenant_id = list_with list_replays_request tenant_id
let list_audit_events ~tenant_id = list_with list_audit_request tenant_id

let list_awards ~tenant_id ~auction_id ~carrier_id =
  let auction = Option.value ~default:"" auction_id in
  let carrier = Option.value ~default:"" carrier_id in
  list_with list_awards_request (carrier, carrier, tenant_id, auction, auction, carrier, carrier)

let list_decisions ~tenant_id ~auction_id ~redaction_scope ~carrier_id =
  list_with list_decisions_request (redaction_scope, redaction_scope, redaction_scope, redaction_scope, redaction_scope, redaction_scope, tenant_id, auction_id, redaction_scope, Option.value ~default:"" carrier_id)

let record_audit_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t6 string string string string string string) ->. Caqti_type.unit)
    "INSERT INTO audit_events (id, tenant_id, actor_user_id, entity_type, entity_id, event_type, event_payload, request_id) VALUES (gen_random_uuid(), ?::uuid, ?::uuid, ?, ?::uuid, ?, ?::jsonb, NULL)"

let record_audit ~tenant_id ~user_id ~entity_type ~entity_id ~event_type ~payload =
  let open Lwt.Syntax in
  let* result = with_exec record_audit_request (tenant_id, user_id, entity_type, entity_id, event_type, payload) in
  Lwt.return result

let approve_award_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t4 string string string string) ->! Caqti_type.string)
    "WITH target AS (SELECT * FROM awards WHERE tenant_id = ?::uuid AND id = ?::uuid AND status IN ('proposed','approval_required','approved')), resolved AS (SELECT ar.id, ar.award_id, ar.tenant_id FROM approval_requests ar JOIN target t ON t.tenant_id = ar.tenant_id AND t.id = ar.award_id WHERE ar.status = 'pending' UNION ALL SELECT ar.id, ar.award_id, ar.tenant_id FROM approval_requests ar JOIN target t ON t.tenant_id = ar.tenant_id AND t.id = ar.award_id WHERE ar.status = 'approved' AND NOT EXISTS (SELECT 1 FROM approval_requests pending WHERE pending.tenant_id = ar.tenant_id AND pending.award_id = ar.award_id AND pending.status = 'pending')), decided AS (UPDATE approval_requests ar SET status = 'approved', decided_by_user_id = ?::uuid, decided_at = now(), payload_snapshot = ar.payload_snapshot || jsonb_build_object('note', ?::text), updated_at = now() FROM target t WHERE ar.tenant_id = t.tenant_id AND ar.award_id = t.id AND ar.status = 'pending' RETURNING ar.id, ar.award_id, ar.tenant_id), selected AS (SELECT id, award_id, tenant_id FROM decided UNION ALL SELECT id, award_id, tenant_id FROM resolved WHERE NOT EXISTS (SELECT 1 FROM decided)), updated AS (UPDATE awards a SET status = 'approved', approval_id = s.id, updated_at = now() FROM selected s WHERE a.tenant_id = s.tenant_id AND a.id = s.award_id RETURNING s.id) SELECT COALESCE((SELECT id::text FROM updated), '')"

let reject_award_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t4 string string string string) ->! Caqti_type.string)
    "UPDATE awards SET status = 'rejected_by_operator', updated_at = now(), explanation_snapshot = explanation_snapshot || jsonb_build_object('rejection_reason', ?, 'rejected_by_user_id', ?) WHERE tenant_id = ? AND id = ?::uuid AND status IN ('proposed','approval_required') RETURNING id::text"

let approve_award ~tenant_id ~user_id ~award_id ~note =
  let open Lwt.Syntax in
  let* result = Db_pool.with_connection (fun (module Connection : Caqti_lwt.CONNECTION) -> Connection.with_transaction (fun () -> Connection.find approve_award_request (tenant_id, award_id, user_id, note))) in
  match result with
  | Ok id when id <> "" ->
      let* audit = record_audit ~tenant_id ~user_id ~entity_type:"award" ~entity_id:award_id ~event_type:"award_approved" ~payload:(Yojson.Safe.to_string (`Assoc [ ("approval_id", `String id) ])) in
      (match audit with
       | Error error -> Lwt.return (Error error)
       | Ok () ->
           let queue_export_ready =
             let open Caqti_request.Infix in
             (Caqti_type.(t2 string string) ->. Caqti_type.unit)
               "INSERT INTO notifications (id, tenant_id, user_id, event_type, template_id, channel, urgency, payload_snapshot, status) SELECT gen_random_uuid(), a.tenant_id, u.id, 'award_export_ready', 'award-export-ready-v1', 'in_app', 'high', jsonb_build_object('award_id', a.id::text, 'auction_id', a.auction_id::text), 'queued' FROM awards a JOIN users u ON u.tenant_id = a.tenant_id AND u.is_active AND u.role = 'auction_manager' WHERE a.tenant_id = ?::uuid AND a.id = ?::uuid AND NOT EXISTS (SELECT 1 FROM notifications n WHERE n.tenant_id = a.tenant_id AND n.user_id = u.id AND n.event_type = 'award_export_ready' AND n.payload_snapshot->>'award_id' = a.id::text)"
           in
           let* notification = with_exec queue_export_ready (tenant_id, award_id) in
           Lwt.return (match notification with Ok () -> Ok id | Error error -> Error error))
  | Ok _ -> Lwt.return (Error Not_found)
  | Error _ -> Lwt.return (Error Unavailable)

let reject_award ~tenant_id ~user_id ~award_id ~reason =
  let open Lwt.Syntax in
  let* result = with_find reject_award_request (reason, user_id, tenant_id, award_id) in
  match result with
  | Ok id ->
      let* audit = record_audit ~tenant_id ~user_id ~entity_type:"award" ~entity_id:award_id ~event_type:"award_rejected" ~payload:(Yojson.Safe.to_string (`Assoc [ ("reason", `String reason) ])) in
      Lwt.return (match audit with Ok () -> Ok id | Error error -> Error error)
  | Error Unavailable -> Lwt.return (Error Not_found)
  | Error error -> Lwt.return (Error error)

let withdraw_award_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t4 string string string string) ->! Caqti_type.string)
    "WITH target AS (SELECT id, tenant_id, auction_id, bid_id, load_id FROM awards WHERE tenant_id = ?::uuid AND id = ?::uuid AND status IN ('proposed','approval_required','approved','published') AND (? = '' OR carrier_id::text = ?)), changed_award AS (UPDATE awards a SET status = 'carrier_withdrawn', updated_at = now(), explanation_snapshot = a.explanation_snapshot || jsonb_build_object('withdrawn', true) FROM target t WHERE a.tenant_id = t.tenant_id AND a.id = t.id RETURNING a.auction_id), changed_bid AS (UPDATE bids b SET status = 'withdrawn', updated_at = now(), rejection_reason = 'CARRIER_WITHDRAWAL' FROM target t WHERE b.tenant_id = t.tenant_id AND b.id = t.bid_id RETURNING b.id), changed_load AS (UPDATE loads l SET status = 'eligible', updated_at = now() FROM target t WHERE l.tenant_id = t.tenant_id AND l.id = t.load_id RETURNING l.id), closed AS (UPDATE auctions a SET status = 'closed', updated_at = now() FROM changed_award c WHERE a.tenant_id = (SELECT tenant_id FROM target) AND a.id = c.auction_id RETURNING a.id) SELECT COALESCE((SELECT id::text FROM changed_award), '')"

let withdraw_award ~tenant_id ~award_id ~carrier_id =
  let carrier = Option.value ~default:"" carrier_id in
  let open Lwt.Syntax in
  let* result = with_find withdraw_award_request (tenant_id, award_id, carrier, carrier) in
  match result with
  | Ok auction_id when auction_id <> "" -> Lwt.return (Ok auction_id)
  | Ok _ -> Lwt.return (Error Not_found)
  | Error error -> Lwt.return (Error error)

let pending_export_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 string string) ->! Caqti_type.int)
    "SELECT count(*)::int FROM awards WHERE tenant_id = ? AND auction_id = ?::uuid AND status IN ('proposed','approval_required')"

let export_snapshot ~tenant_id ~auction_id ~format ~user_id =
  let request =
    let open Caqti_request.Infix in
    (Caqti_type.(t8 string string string string string string string string) ->! Caqti_type.(t2 string string))
      "WITH snapshot AS (SELECT json_build_object('auction_id', a.id::text, 'tenant_id', a.tenant_id::text, 'generated_at', now()::text, 'awards', COALESCE(json_agg(json_build_object('load_id', aw.load_id::text, 'carrier_id', aw.carrier_id::text, 'amount_cents', round(aw.award_amount * 100)::int)) FILTER (WHERE aw.id IS NOT NULL), '[]'::json)) AS value FROM auctions a LEFT JOIN awards aw ON aw.tenant_id = a.tenant_id AND aw.auction_id = a.id AND aw.status IN ('approved','published','exported') WHERE a.tenant_id = ? AND a.id = ?::uuid GROUP BY a.id, a.tenant_id), created AS (INSERT INTO report_exports (id, tenant_id, auction_id, clearing_job_id, source_type, source_id, format, template_id, template_version, snapshot_json, redaction_scope, status, generated_by_user_id) SELECT gen_random_uuid(), ?::uuid, ?::uuid, a.clearing_job_id, 'auction', a.id, ?::text, 'auction-report', '1', snapshot.value, 'operator', 'rendered', ?::uuid FROM snapshot JOIN auctions a ON a.tenant_id = ?::uuid AND a.id = ?::uuid RETURNING id, tenant_id, auction_id, snapshot_json), updated_awards AS (UPDATE awards aw SET status = 'exported', updated_at = now() FROM created c WHERE aw.tenant_id = c.tenant_id AND aw.auction_id = c.auction_id AND aw.status IN ('approved','published') RETURNING aw.id), updated_auction AS (UPDATE auctions a SET status = 'exported', updated_at = now() FROM created c WHERE a.tenant_id = c.tenant_id AND a.id = c.auction_id RETURNING a.id) SELECT id::text, snapshot_json::text FROM created WHERE (SELECT count(*) >= 0 FROM updated_awards) AND (SELECT count(*) >= 0 FROM updated_auction)"
  in
  let open Lwt.Syntax in
  let* pending = with_find pending_export_request (tenant_id, auction_id) in
  match pending with
  | Error error -> Lwt.return (Error error)
  | Ok count when count > 0 -> Lwt.return (Error Conflict)
  | Ok _ ->
      let* result = with_find request (tenant_id, auction_id, tenant_id, auction_id, format, user_id, tenant_id, auction_id) in
      (match result with
       | Ok (id, snapshot) ->
           (try
              let value = Yojson.Safe.from_string snapshot in
              let* audit = record_audit ~tenant_id ~user_id ~entity_type:"auction" ~entity_id:auction_id ~event_type:"export_downloaded" ~payload:(Yojson.Safe.to_string (`Assoc [ ("report_id", `String id); ("format", `String format) ])) in
              Lwt.return (match audit with Ok () -> Ok (id, value) | Error error -> Error error)
            with Yojson.Json_error _ -> Lwt.return (Error (Invalid "REPORT_SNAPSHOT_INVALID")))
       | Error Unavailable -> Lwt.return (Error Not_found)
       | Error error -> Lwt.return (Error error))

let get_report_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 string string) ->! Caqti_type.(t3 string string string))
    "SELECT id::text, format, snapshot_json::text FROM report_exports WHERE tenant_id = ? AND id = ?::uuid"

let get_report ~tenant_id ~report_id =
  let open Lwt.Syntax in
  let* result = with_find get_report_request (tenant_id, report_id) in
  Lwt.return (match result with Ok (id, format, snapshot) -> (try Ok (id, format, Yojson.Safe.from_string snapshot) with Yojson.Json_error _ -> Error (Invalid "REPORT_SNAPSHOT_INVALID")) | Error Unavailable -> Error Not_found | Error error -> Error error)

let update_tenant_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t3 string string string) ->! Caqti_type.string)
    "UPDATE tenants SET name = ?, display_name = ?, updated_at = now() WHERE id = ?::uuid AND is_active RETURNING json_build_object('id', id::text, 'name', name, 'display_name', display_name, 'timezone', timezone, 'default_currency', default_currency)::text"

let update_tenant ~tenant_id ~name ~display_name =
  let open Lwt.Syntax in
  let* result = with_find update_tenant_request (name, display_name, tenant_id) in
  Lwt.return (json_result result)

let create_import_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t9 string string string string string string string string string) ->! Caqti_type.string)
    "WITH payload AS (SELECT ?::jsonb AS value), created AS (INSERT INTO import_runs (id, tenant_id, auction_id, resource_type, source_filename, source_format, status, mapping_snapshot, validation_summary, row_count, valid_row_count, invalid_row_count, requested_by_user_id, previewed_at) SELECT gen_random_uuid(), ?::uuid, nullif(?, '')::uuid, ?, ?, ?, CASE WHEN (payload.value->>'invalid_row_count')::int > 0 THEN 'quarantined' ELSE 'validated' END, ?::jsonb, payload.value, (payload.value->>'row_count')::int, (payload.value->>'valid_row_count')::int, (payload.value->>'invalid_row_count')::int, ?::uuid, now() FROM payload RETURNING id, tenant_id, auction_id, resource_type), staged AS (INSERT INTO import_staging_rows (id, tenant_id, import_run_id, auction_id, row_number, resource_type, raw_payload, normalized_payload, status) SELECT gen_random_uuid(), c.tenant_id, c.id, c.auction_id, input.row_number::int, c.resource_type, input.value, input.value, 'valid' FROM created c CROSS JOIN jsonb_array_elements(?::jsonb) WITH ORDINALITY AS input(value, row_number) RETURNING id) SELECT c.id::text FROM created c WHERE (SELECT count(*) >= 0 FROM staged)"

let create_import ~tenant_id ~user_id ~resource_type ~source_filename ~source_format ~auction_id ~mapping ~staging_rows ~row_count ~valid_row_count ~invalid_row_count =
  if row_count < 0 || valid_row_count < 0 || invalid_row_count < 0 || valid_row_count + invalid_row_count > row_count then
    Lwt.return (Error (Invalid "IMPORT_COUNTS_INVALID"))
  else
    let summary = Yojson.Safe.to_string (`Assoc [ ("row_count", `Int row_count); ("valid_row_count", `Int valid_row_count); ("invalid_row_count", `Int invalid_row_count) ]) in
    let open Lwt.Syntax in
    let* result = with_find create_import_request (summary, tenant_id, Option.value ~default:"" auction_id, resource_type, source_filename, source_format, mapping, user_id, staging_rows) in
    Lwt.return result

let get_import_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 string string) ->! Caqti_type.string)
    "SELECT json_build_object('id', id::text, 'resource_type', resource_type, 'source_filename', source_filename, 'source_format', source_format, 'status', status, 'mapping', mapping_snapshot, 'validation_summary', validation_summary, 'row_count', row_count, 'valid_row_count', valid_row_count, 'invalid_row_count', invalid_row_count, 'staging_preview', COALESCE((SELECT json_agg(json_build_object('row_number', s.row_number, 'raw_payload', s.raw_payload, 'status', s.status) ORDER BY s.row_number) FROM import_staging_rows s WHERE s.tenant_id = import_runs.tenant_id AND s.import_run_id = import_runs.id), '[]'::json), 'previewed_at', previewed_at::text, 'committed_at', committed_at::text)::text FROM import_runs WHERE tenant_id = ?::uuid AND id = ?::uuid"

let get_import ~tenant_id ~import_id =
  let open Lwt.Syntax in
  let* result = with_find get_import_request (tenant_id, import_id) in
  Lwt.return (json_result result)

let commit_import_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t3 string string string) ->! Caqti_type.string)
    "WITH target AS (SELECT * FROM import_runs WHERE tenant_id = ?::uuid AND id = ?::uuid AND ? = 'true' AND status IN ('validated','uploaded') AND invalid_row_count = 0), carrier_rows AS (INSERT INTO carriers (id, tenant_id, legal_name, display_name, equipment_types, status) SELECT gen_random_uuid(), t.tenant_id, COALESCE(NULLIF(s.raw_payload->>'legal_name', ''), s.raw_payload->>'name'), COALESCE(NULLIF(s.raw_payload->>'display_name', ''), s.raw_payload->>'legal_name', s.raw_payload->>'name'), ARRAY[COALESCE(NULLIF(s.raw_payload->>'equipment_type', ''), 'dry_van')]::text[], COALESCE(NULLIF(s.raw_payload->>'status', ''), 'active') FROM target t JOIN import_staging_rows s ON s.tenant_id = t.tenant_id AND s.import_run_id = t.id WHERE t.resource_type = 'carriers' AND s.status = 'valid' AND COALESCE(NULLIF(s.raw_payload->>'legal_name', ''), s.raw_payload->>'name', '') <> '' ON CONFLICT (tenant_id, mc_number) DO NOTHING), lane_rows AS (INSERT INTO lanes (id, tenant_id, origin_region, destination_region, equipment_type, distance_miles, reserve_price, status) SELECT gen_random_uuid(), t.tenant_id, s.raw_payload->>'origin_region', s.raw_payload->>'destination_region', COALESCE(NULLIF(s.raw_payload->>'equipment_type', ''), 'dry_van'), GREATEST(COALESCE(NULLIF(s.raw_payload->>'distance_miles', '')::int, 1), 1), GREATEST(COALESCE(NULLIF(s.raw_payload->>'reserve_price', '')::numeric, 0), 0), COALESCE(NULLIF(s.raw_payload->>'status', ''), 'active') FROM target t JOIN import_staging_rows s ON s.tenant_id = t.tenant_id AND s.import_run_id = t.id WHERE t.resource_type = 'lanes' AND s.status = 'valid' AND COALESCE(s.raw_payload->>'origin_region', '') <> '' AND COALESCE(s.raw_payload->>'destination_region', '') <> '' ON CONFLICT (tenant_id, origin_region, destination_region, equipment_type) DO NOTHING), load_rows AS (INSERT INTO loads (id, tenant_id, auction_id, lane_id, external_ref, pickup_window_start, pickup_window_end, delivery_window_start, delivery_window_end, weight_lbs, equipment_type, service_priority, status) SELECT gen_random_uuid(), t.tenant_id, t.auction_id, (s.raw_payload->>'lane_id')::uuid, COALESCE(NULLIF(s.raw_payload->>'external_ref', ''), s.raw_payload->>'external_id'), (s.raw_payload->>'pickup_start')::timestamp, (s.raw_payload->>'pickup_end')::timestamp, (s.raw_payload->>'delivery_start')::timestamp, (s.raw_payload->>'delivery_end')::timestamp, GREATEST(COALESCE(NULLIF(s.raw_payload->>'weight_lbs', '')::int, 1), 1), COALESCE(NULLIF(s.raw_payload->>'equipment_type', ''), 'dry_van'), COALESCE(NULLIF(s.raw_payload->>'service_priority', ''), 'standard'), 'eligible' FROM target t JOIN import_staging_rows s ON s.tenant_id = t.tenant_id AND s.import_run_id = t.id WHERE t.resource_type = 'loads' AND t.auction_id IS NOT NULL AND s.status = 'valid' AND COALESCE(s.raw_payload->>'lane_id', '') <> '' AND COALESCE(s.raw_payload->>'external_ref', s.raw_payload->>'external_id', '') <> '' ON CONFLICT (tenant_id, auction_id, external_ref) DO NOTHING), bid_rows AS (INSERT INTO bids (id, tenant_id, auction_id, load_id, carrier_id, idempotency_key, bid_amount, service_score_snapshot, submitted_at, source, status) SELECT gen_random_uuid(), t.tenant_id, t.auction_id, (s.raw_payload->>'load_id')::uuid, (s.raw_payload->>'carrier_id')::uuid, COALESCE(NULLIF(s.raw_payload->>'idempotency_key', ''), 'import-' || s.row_number::text), GREATEST(COALESCE(NULLIF(s.raw_payload->>'bid_amount', '')::numeric, 0), 0), LEAST(GREATEST(COALESCE(NULLIF(s.raw_payload->>'service_score', '')::numeric, 0.75), 0), 1), (s.raw_payload->>'submitted_at')::timestamp, 'csv_import', 'submitted' FROM target t JOIN import_staging_rows s ON s.tenant_id = t.tenant_id AND s.import_run_id = t.id WHERE t.resource_type = 'bids' AND t.auction_id IS NOT NULL AND s.status = 'valid' AND COALESCE(s.raw_payload->>'load_id', '') <> '' AND COALESCE(s.raw_payload->>'carrier_id', '') <> '' AND COALESCE(s.raw_payload->>'submitted_at', '') <> '' ON CONFLICT (tenant_id, auction_id, idempotency_key) DO NOTHING), staged AS (UPDATE import_staging_rows s SET status = 'committed', updated_at = now() FROM target t WHERE s.tenant_id = t.tenant_id AND s.import_run_id = t.id AND s.status = 'valid' RETURNING s.id), finished AS (UPDATE import_runs i SET status = 'committed', committed_at = now(), updated_at = now() FROM target t WHERE i.id = t.id AND i.tenant_id = t.tenant_id AND (SELECT count(*) >= 0 FROM staged) RETURNING i.id, i.status, i.row_count, i.valid_row_count, i.invalid_row_count) SELECT json_build_object('id', id::text, 'status', status, 'row_count', row_count, 'valid_row_count', valid_row_count, 'invalid_row_count', invalid_row_count)::text FROM finished"

let commit_import ~tenant_id ~import_id ~confirm =
  let open Lwt.Syntax in
  let* result = with_find commit_import_request (tenant_id, import_id, if confirm then "true" else "false") in
  Lwt.return (json_result result)

let notification_preferences_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 string string) ->! Caqti_type.string)
  "SELECT COALESCE(json_agg(row_to_json(items)), '[]'::json)::text FROM (SELECT event_type, channel, enabled, quiet_hours FROM notification_preferences WHERE tenant_id = ? AND user_id = ?::uuid ORDER BY event_type, channel) items"

let update_notification_preference_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t6 string string string string bool string) ->! Caqti_type.string)
    "INSERT INTO notification_preferences (id, tenant_id, user_id, event_type, channel, enabled, quiet_hours) VALUES (gen_random_uuid(), ?::uuid, ?::uuid, ?, ?, ?, ?::jsonb) ON CONFLICT (tenant_id, user_id, event_type, channel) DO UPDATE SET enabled = EXCLUDED.enabled, quiet_hours = EXCLUDED.quiet_hours, updated_at = now() RETURNING json_build_object('event_type', event_type, 'channel', channel, 'enabled', enabled, 'quiet_hours', quiet_hours)::text"

let create_replay_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t6 string string string string string string) ->! Caqti_type.string)
    "INSERT INTO replay_runs (id, tenant_id, name, status, dataset_uri, baseline_strategy, policy_id, created_by_user_id) VALUES (gen_random_uuid(), ?::uuid, ?, 'queued', ?, ?, ?::uuid, ?::uuid) RETURNING id::text"

let get_replay_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 string string) ->! Caqti_type.string)
    "SELECT json_build_object('id', id::text, 'name', name, 'status', status, 'dataset_uri', dataset_uri, 'baseline_strategy', baseline_strategy, 'policy_id', policy_id::text, 'metrics_snapshot', metrics_snapshot, 'started_at', started_at::text, 'finished_at', finished_at::text)::text FROM replay_runs WHERE tenant_id = ?::uuid AND id = ?::uuid"

let list_notification_preferences ~tenant_id ~user_id = list_with notification_preferences_request (tenant_id, user_id)

let valid_quiet_hours value =
  try
    match Yojson.Safe.from_string value with
    | `Assoc fields ->
        let valid_hour name =
          match List.assoc_opt name fields with
          | None -> true
          | Some (`Int hour) -> hour >= 0 && hour <= 23
          | Some (`Intlit hour) -> (match int_of_string_opt hour with Some value -> value >= 0 && value <= 23 | None -> false)
          | _ -> false
        in
        valid_hour "start_hour" && valid_hour "end_hour"
    | _ -> false
  with Yojson.Json_error _ -> false

let update_notification_preference ~tenant_id ~user_id ~event_type ~channel ~enabled ~quiet_hours =
  if event_type = "" || not (List.mem channel [ "in_app"; "email"; "workflow" ]) then Lwt.return (Error (Invalid "NOTIFICATION_PREFERENCE_INVALID"))
  else if (not enabled) && channel = "in_app" && List.mem event_type [ "award_approval_required"; "clearing_infeasible" ] then Lwt.return (Error (Invalid "NOTIFICATION_CRITICAL_REQUIRED"))
  else if not (valid_quiet_hours quiet_hours) then Lwt.return (Error (Invalid "NOTIFICATION_QUIET_HOURS_INVALID"))
  else
    let open Lwt.Syntax in
    let* result = with_find update_notification_preference_request (tenant_id, user_id, event_type, channel, enabled, quiet_hours) in
    Lwt.return (json_result result)

let create_replay ~tenant_id ~user_id ~name ~dataset_uri ~baseline_strategy ~policy_id =
  if name = "" || dataset_uri = "" || not (List.mem baseline_strategy [ "lowest_cost"; "first_acceptable"; "incumbent_preference"; "historical_awards" ]) then Lwt.return (Error (Invalid "REPLAY_INPUT_INVALID"))
  else
    let open Lwt.Syntax in
    let* result = with_find create_replay_request (tenant_id, name, dataset_uri, baseline_strategy, policy_id, user_id) in
    Lwt.return result

let get_replay ~tenant_id ~replay_id =
  let open Lwt.Syntax in
  let* result = with_find get_replay_request (tenant_id, replay_id) in
  Lwt.return (json_result result)
