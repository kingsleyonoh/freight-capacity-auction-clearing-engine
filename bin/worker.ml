let json_member name json = Yojson.Safe.Util.member name json

let string_member name json =
  match json_member name json with
  | `String value -> Some value
  | _ -> None

let int_member name json =
  match json_member name json with
  | `Int value -> Some value
  | `Intlit value -> int_of_string_opt value
  | _ -> None

let float_member name json =
  match json_member name json with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | `Intlit value -> float_of_string_opt value
  | _ -> None

let list_member name json =
  match json_member name json with `List values -> Some values | _ -> None

let parse_input json =
  try
    let policy = json_member "policy" json in
    let loads =
      json |> list_member "loads" |> Option.get
      |> List.map (fun value ->
             Model_builder.{
               id = Option.get (string_member "id" value);
               reserve_cents = Option.get (int_member "reserve_cents" value);
               equipment = Option.get (string_member "equipment" value);
             })
    in
    let bids =
      json |> list_member "bids" |> Option.get
      |> List.map (fun value ->
             Model_builder.{
               id = Option.get (string_member "id" value);
               load_id = Option.get (string_member "load_id" value);
               carrier_id = Option.get (string_member "carrier_id" value);
               amount_cents = Option.get (int_member "amount_cents" value);
               service_score_milli = Option.get (int_member "service_score_milli" value);
               capacity_units = Option.value ~default:1 (int_member "capacity_units" value);
             })
    in
    let max_risk = Option.get (float_member "max_service_risk" policy) in
    let max_share = Option.get (float_member "max_single_carrier_share" policy) in
    let reserve_behavior = Option.get (string_member "reserve_price_behavior" policy) in
    Ok (Model_builder.make ~loads ~bids ~policy:Model_builder.{ max_service_risk_milli = int_of_float (max_risk *. 1_000.); max_carrier_share_milli = int_of_float (max_share *. 1_000.); reserve_behavior })
  with _ -> Error "SOLVER_INPUT_INVALID"

let join_ints values = String.concat ", " (List.map string_of_int values)

let dzn_of_model (model : Model_builder.t) =
  let load_index = List.mapi (fun index (load : Model_builder.load) -> (load.Model_builder.id, index + 1)) model.loads in
  let carrier_index =
    model.bids |> List.map (fun bid -> bid.Model_builder.carrier_id) |> List.sort_uniq String.compare
    |> List.mapi (fun index carrier -> (carrier, index + 1))
  in
  let lookup key values = match List.assoc_opt key values with Some value -> value | None -> 1 in
  let bid_load = List.map (fun bid -> lookup bid.Model_builder.load_id load_index) model.bids in
  let bid_carrier = List.map (fun bid -> lookup bid.Model_builder.carrier_id carrier_index) model.bids in
  String.concat "\n"
    [ "load_count = " ^ string_of_int (List.length model.loads) ^ ";";
      "bid_count = " ^ string_of_int (List.length model.bids) ^ ";";
      "reserve_cents = [" ^ join_ints (List.map (fun load -> load.Model_builder.reserve_cents) model.loads) ^ "];";
      "bid_load = [" ^ join_ints bid_load ^ "];";
      "bid_amount_cents = [" ^ join_ints (List.map (fun bid -> bid.Model_builder.amount_cents) model.bids) ^ "];";
      "bid_service_milli = [" ^ join_ints (List.map (fun bid -> bid.Model_builder.service_score_milli) model.bids) ^ "];";
      "bid_carrier = [" ^ join_ints bid_carrier ^ "];" ]

let write_file path value =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () -> output_string channel value)

let worker_source = Logs.Src.create "fca.worker"

let trace job ?status ?error_code message =
  match Logging.context ~job_id:job.Job_store.id () with
  | Error _ -> ()
  | Ok context ->
      (match Logging.event ~context ?status ?error_code ~message () with
       | Ok event -> Logging.emit ~src:worker_source Logs.Info event
       | Error _ -> ())

let model_path () =
  let candidates =
    Option.to_list (Sys.getenv_opt "FCA_MINIZINC_MODEL_PATH")
    @ [ "/app/models/single_round.mzn"; Filename.concat (Sys.getcwd ()) "src/solver/models/single_round.mzn" ]
  in
  List.find_opt Sys.file_exists candidates

let clear_job job =
  trace job "started";
  match parse_input job.Job_store.input with
  | Error _ -> trace job "invalid_input"; Job_store.mark_failed job ~error_code:"SOLVER_INPUT_INVALID" ~error_message:"The immutable clearing input could not be parsed."
  | Ok model when model.loads = [] || model.bids = [] ->
      trace job "empty_model";
      Job_store.mark_infeasible job ~reason:"NO_ELIGIBLE_BIDS" ~relaxations:(Yojson.Safe.to_string (`List (List.map (fun relaxation -> `Assoc [ ("rank", `Int relaxation.Clearing_service.rank); ("constraint_name", `String relaxation.constraint_name); ("proposal", `String relaxation.proposal); ("expected_tradeoff", `String relaxation.expected_tradeoff) ]) (Clearing_service.rank_relaxations ~reasons:[ "NO_FEASIBLE_ASSIGNMENT" ]))))
  | Ok model ->
      let runner = Process_runner.create ~allowed_env:[] in
      match Solver_backend.config_from_lookup ~get:Sys.getenv_opt with
      | Error _ -> trace job "invalid_solver_config"; Job_store.mark_failed job ~error_code:"SOLVER_CONFIG_INVALID" ~error_message:"The configured solver backend is invalid."
      | Ok _config when Solver_backend.selected_name (match Sys.getenv_opt "SOLVER_BACKEND" with Some "ortools" -> `Ortools | _ -> `Minizinc) <> "minizinc" -> Job_store.mark_failed job ~error_code:"SOLVER_BACKEND_UNSUPPORTED" ~error_message:"No production adapter is configured for the selected backend."
      | Ok config ->
          (match (Solver_backend.selected_executable config, model_path ()) with
           | Some executable, Some model_file ->
               let open Lwt.Syntax in
               let* probe = Solver_backend.probe_selected runner config in
               trace job ("probe=" ^ Yojson.Safe.to_string (Solver_backend.selected_report_to_yojson probe));
               (match Solver_backend.available_version probe.availability with
                | None -> trace job "probe_failed"; Job_store.mark_failed job ~error_code:"SOLVER_UNAVAILABLE" ~error_message:"The selected solver did not return a usable terminal capability."
                | Some version ->
                    let directory = Filename.concat (Filename.get_temp_dir_name ()) ("fca-solver-" ^ job.id) in
                    (try Unix.mkdir directory 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
                    let data_file = Filename.concat directory "input.dzn" in
                    write_file data_file (dzn_of_model model);
                    let* result = Solver_execution.run runner ~executable ~model_path:model_file ~data_path:data_file ~timeout:(Solver_backend.timeout config) in
                    trace job (match result with Ok solver -> "solver=" ^ solver.Solver_execution.terminal_status | Error error -> "solver_error=" ^ error);
                    (try Sys.remove data_file with _ -> ());
                    (try Unix.rmdir directory with _ -> ());
                    (match result with
                     | Error _ -> Job_store.mark_failed job ~error_code:"SOLVER_EXECUTION_FAILED" ~error_message:"The selected solver failed before producing terminal evidence."
                     | Ok solver ->
                         let evidence = Capability_registry.production ~backend:"minizinc" ~version ~terminal_status:solver.terminal_status ~input_hash:solver.input_hash ~output_hash:solver.output_hash in
                         (match evidence, Clearing_service.clear model ~evidence:(Result.to_option evidence) with
                         | Ok _, Clearing_service.Feasible { awards; _ } ->
                              Metrics.track "clearing_succeeded";
                              trace job (Printf.sprintf "clearing_feasible awards=%d" (List.length awards));
                              let* stored = Job_store.mark_succeeded job ~solver_version:version ~input_hash:solver.input_hash ~output_hash:solver.output_hash ~assignments:(List.map (fun award -> (award.Clearing_service.load_id, award.Clearing_service.bid_id)) awards) in
                              trace job (match stored with Ok () -> "stored_success" | Error error -> "store_error=" ^ error);
                              Lwt.return stored
                         | _, Clearing_service.Infeasible { reasons; relaxations; _ } ->
                              Metrics.track "clearing_infeasible";
                              trace job "clearing_rejected";
                              let suggestions = `List (List.map (fun relaxation -> `Assoc [ ("rank", `Int relaxation.Clearing_service.rank); ("constraint_name", `String relaxation.constraint_name); ("proposal", `String relaxation.proposal); ("expected_tradeoff", `String relaxation.expected_tradeoff) ]) relaxations) in
                              let reason = match reasons with first :: _ -> first | [] -> "NO_FEASIBLE_ASSIGNMENT" in
                              Job_store.mark_infeasible job ~reason ~relaxations:(Yojson.Safe.to_string suggestions)
                          | _, _ -> trace job "clearing_rejected"; Job_store.mark_infeasible job ~reason:"SOLVER_EVIDENCE_REQUIRED" ~relaxations:"[]")))
           | _ -> trace job "executable_or_model_missing"; Job_store.mark_failed job ~error_code:"SOLVER_CONFIG_INVALID" ~error_message:"The selected solver executable or model is unavailable.")

open Lwt.Infix

let http_client () =
  match
    Http_client.policy ~total_timeout_s:5. ~attempt_timeout_s:5.
      ~max_attempts:1 ~initial_backoff_s:0.1 ~max_backoff_s:0.1
      ~max_retry_after_s:1. ~max_request_bytes:1_048_576
      ~max_response_bytes:1_048_576
  with
  | Error _ -> None
  | Ok policy -> Result.to_option (Http_client.create ~max_concurrency:4 policy)

let env_url name =
  match Sys.getenv_opt name with
  | Some value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let append_path base path =
  let rec trim index =
    if index > 0 && base.[index - 1] = '/' then trim (index - 1)
    else String.sub base 0 index
  in
  let base = trim (String.length base) in
  Uri.of_string (base ^ path)

let string_field name json =
  match Yojson.Safe.Util.member name json with
  | `String value -> Some value
  | _ -> None

let integration_request client (item : Maintenance.integration_outbox) =
  let target, body, headers =
    match item.integration_name with
    | "notification_hub" ->
        ( Option.map (fun value -> append_path value "/api/events") (env_url "NOTIFICATION_HUB_URL"),
          `Assoc
            [ ("event_type", `String item.event_type);
              ("event_id", `String item.id);
              ("payload", item.payload) ],
          Option.to_list (Option.map (fun key -> ("X-API-Key", key)) (Sys.getenv_opt "NOTIFICATION_HUB_API_KEY")) )
    | "workflow_engine" ->
        let workflow_id = string_field "workflow_id" item.payload in
        ( match (env_url "WORKFLOW_ENGINE_URL", workflow_id) with
        | Some base, Some id when id <> "" ->
            ( Some (append_path base ("/api/workflows/" ^ Uri.pct_encode id ^ "/execute")),
              `Assoc [ ("trigger_data", item.payload) ],
              Option.to_list (Option.map (fun key -> ("X-API-Key", key)) (Sys.getenv_opt "WORKFLOW_ENGINE_API_KEY")) )
        | _ -> (None, `Null, []) )
    | _ -> (None, `Null, [])
  in
  match target with
  | None -> Lwt.return (Error "INTEGRATION_TARGET_UNCONFIGURED")
  | Some uri ->
      (match
         Http_client.request ~meth:`POST ~uri
           ~headers:(("Content-Type", "application/json") :: headers)
           ~body:(Bytes.of_string (Yojson.Safe.to_string body))
           ~idempotency_key:item.idempotency_key ()
       with
       | Error error -> Lwt.return (Error (Errors.Code.to_string (Http_client.error_code error)))
       | Ok request ->
           if item.integration_name = "workflow_engine" then
             Http_client.call client ~decoder:Http_client.json request >|= function
             | Error error -> Error (Errors.Code.to_string (Http_client.error_code error))
             | Ok response when Http_client.status response >= 200 && Http_client.status response < 300 ->
                 Ok (string_field "execution_ref" (Http_client.body response))
             | Ok response -> Error ("INTEGRATION_HTTP_" ^ string_of_int (Http_client.status response))
           else
             Http_client.call client ~decoder:Http_client.bytes request >|= function
             | Error error -> Error (Errors.Code.to_string (Http_client.error_code error))
             | Ok response when Http_client.status response >= 200 && Http_client.status response < 300 -> Ok None
             | Ok response -> Error ("INTEGRATION_HTTP_" ^ string_of_int (Http_client.status response)))

let process_integration () =
  match Lwt_main.run (Maintenance.claim_integration_outbox ()) with
  | Error _ | Ok None -> ()
  | Ok (Some item) ->
      (match http_client () with
       | None -> ignore (Lwt_main.run (Maintenance.mark_integration_retry ~id:item.id ~tenant_id:item.tenant_id ~error_code:"HTTP_CLIENT_INVALID" ~error_message:"The integration HTTP client could not be configured."))
       | Some client ->
           let result = Lwt_main.run (integration_request client item) in
           (match result with
            | Ok execution_id ->
                ignore (Lwt_main.run (Maintenance.mark_integration_succeeded ~id:item.id ~tenant_id:item.tenant_id));
                (match execution_id, string_field "award_id" item.payload with
                 | Some execution_id, Some award_id -> ignore (Lwt_main.run (Maintenance.record_workflow_execution ~tenant_id:item.tenant_id ~award_id ~execution_id))
                 | _ -> ());
                ignore (Lwt_main.run (Maintenance.update_integration_health ~tenant_id:item.tenant_id ~integration_name:item.integration_name ~status:"healthy"))
            | Error error ->
                ignore (Lwt_main.run (Maintenance.mark_integration_retry ~id:item.id ~tenant_id:item.tenant_id ~error_code:"INTEGRATION_DELIVERY_FAILED" ~error_message:error));
                ignore (Lwt_main.run (Maintenance.update_integration_health ~tenant_id:item.tenant_id ~integration_name:item.integration_name ~status:"degraded"))))

let workflow_poll_last_run = ref 0.

let process_workflow_poll () =
  if Sys.getenv_opt "WORKFLOW_STATUS_POLLING_ENABLED" <> Some "true" then ()
  else
    let now = Unix.gettimeofday () in
    if now -. !workflow_poll_last_run < 300. then ()
    else begin
      workflow_poll_last_run := now;
      match Lwt_main.run (Maintenance.claim_workflow_execution ()) with
      | Error _ | Ok None -> ()
      | Ok (Some execution) ->
          (match http_client (), env_url "WORKFLOW_ENGINE_URL" with
           | Some client, Some base ->
               let uri = append_path base ("/api/executions/" ^ Uri.pct_encode execution.execution_id) in
               (match Http_client.request ~meth:`GET ~uri ~headers:(Option.to_list (Option.map (fun key -> ("X-API-Key", key)) (Sys.getenv_opt "WORKFLOW_ENGINE_API_KEY"))) () with
                | Error _ -> ignore (Lwt_main.run (Maintenance.mark_workflow_failed ~tenant_id:execution.tenant_id ~approval_id:execution.approval_id))
                | Ok request ->
                    (match Lwt_main.run (Http_client.call client ~decoder:Http_client.json request) with
                     | Ok response when Http_client.status response >= 200 && Http_client.status response < 300 ->
                         let json = Http_client.body response in
                         let status = string_field "status" json in
                         let decision = string_field "decision" json in
                         (match status, decision with
                          | Some "completed", Some decision -> ignore (Lwt_main.run (Maintenance.apply_workflow_decision ~tenant_id:execution.tenant_id ~approval_id:execution.approval_id ~decision))
                          | Some value, _ when List.mem value [ "failed"; "cancelled" ] -> ignore (Lwt_main.run (Maintenance.mark_workflow_failed ~tenant_id:execution.tenant_id ~approval_id:execution.approval_id))
                          | _ -> ())
                     | _ -> ignore (Lwt_main.run (Maintenance.mark_workflow_failed ~tenant_id:execution.tenant_id ~approval_id:execution.approval_id))))
           | _ -> ())
    end

let replay_store () =
  let replay_path = Option.value ~default:"./data/replays/replay.duckdb" (Sys.getenv_opt "REPLAY_STORE_PATH") in
  let root = Filename.dirname replay_path in
  let rec ensure_directory path =
    if path = "" || path = "." || path = "/" || Sys.file_exists path then ()
    else begin
      ensure_directory (Filename.dirname path);
      try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  ensure_directory root;
  let runner = Process_runner.create ~allowed_env:[] in
  let executable =
    match Sys.getenv_opt "FCA_DUCKDB_BINARY" with
    | Some value when value <> "" -> value
    | _ -> if Sys.file_exists "/usr/local/bin/duckdb" then "/usr/local/bin/duckdb" else "duckdb"
  in
  Duckdb_store.create ~runner ~executable ~replay_root:root ~database_path:replay_path
    ~timeout:60. ~output_limit:1_048_576 ~max_rows:1_000_000

let replay_metrics (benchmark : Duckdb_store.benchmark) baseline =
  let baseline =
    match baseline with
    | "lowest_cost" -> Replay_runner.Lowest_cost
    | "first_acceptable" -> Replay_runner.First_acceptable
    | "incumbent_preference" -> Replay_runner.Incumbent_preference
    | _ -> Replay_runner.Historical_awards
  in
  let total_cost_cents =
    match int_of_string_opt benchmark.landed_cost_sum with Some value -> value | None -> 0
  in
  `Assoc
    [ ("row_count", `Int benchmark.row_count);
      ("tenant_count", `Int benchmark.tenant_count);
      ("month_count", `Int benchmark.month_count);
      ("auction_count", `Int benchmark.auction_count);
      ("load_count", `Int benchmark.load_count);
      ("bid_count", `Int benchmark.bid_count);
      ("baseline", `String (Replay_runner.baseline_to_string baseline));
      ("assigned", `Int benchmark.baseline_eligible_count);
      ("total_cost_cents", `Int total_cost_cents);
      ("service_score_milli", `Int 0);
      ("promotion_gate", `Bool false);
      ("promotion_gate_reason", `String "POLICY_COMPARISON_EVIDENCE_REQUIRED");
      ("live_award_mutation", `Bool false);
      ("external_events", `Bool false) ]

let process_replay () =
  match Lwt_main.run (Maintenance.claim_replay ()) with
  | Error _ | Ok None -> ()
  | Ok (Some replay) ->
      (match replay_store () with
       | Error error -> ignore (Lwt_main.run (Maintenance.fail_replay ~id:replay.id ~tenant_id:replay.tenant_id ~error_code:(Duckdb_store.error_code error) ~error_message:(Duckdb_store.error_to_string error)))
       | Ok store ->
           let result = Lwt_main.run (Duckdb_store.benchmark_dataset store ~dataset_path:replay.dataset_uri) in
           (match result with
            | Error error -> ignore (Lwt_main.run (Maintenance.fail_replay ~id:replay.id ~tenant_id:replay.tenant_id ~error_code:(Duckdb_store.error_code error) ~error_message:(Duckdb_store.error_to_string error)))
            | Ok benchmark ->
                Metrics.track "replay_completed";
                let metrics = Yojson.Safe.to_string (replay_metrics benchmark replay.baseline_strategy) in
                ignore (Lwt_main.run (Maintenance.complete_replay ~id:replay.id ~tenant_id:replay.tenant_id ~metrics))))

let maintenance_last_run = ref 0.
let maintenance_nightly_day = ref ""

let maintenance_tick () =
  let now = Unix.gettimeofday () in
  if now -. !maintenance_last_run >= 1. then begin
    maintenance_last_run := now;
    ignore (Lwt_main.run (Maintenance.close_expired_auctions ()));
    let expiry = Option.value ~default:24 (Option.bind (Sys.getenv_opt "APPROVAL_EXPIRY_HOURS") int_of_string_opt) in
    ignore (Lwt_main.run (Maintenance.expire_approvals ~cutoff_hours:expiry));
    ignore (Lwt_main.run (Maintenance.deliver_notifications ()))
  end;
  let day = Unix.gmtime now |> fun tm -> Printf.sprintf "%04d-%03d" (tm.Unix.tm_year + 1900) tm.Unix.tm_yday in
  if day <> !maintenance_nightly_day && Unix.gmtime now |> fun tm -> tm.Unix.tm_hour = 2 && tm.Unix.tm_min = 0 then begin
    maintenance_nightly_day := day;
    ignore (Lwt_main.run (Maintenance.refresh_carrier_scores ()));
    ignore (Lwt_main.run (Maintenance.compact_report_artifacts ()))
  end

let rec loop () =
  maintenance_tick ();
  match Lwt_main.run (Job_store.claim ()) with
  | Error _ -> process_integration (); process_workflow_poll (); process_replay (); Unix.sleep 1; loop ()
  | Ok None -> process_integration (); process_workflow_poll (); process_replay (); Unix.sleep 1; loop ()
  | Ok (Some job) -> ignore (Lwt_main.run (clear_job job)); loop ()

let () =
  Logging.configure ~level:(Some Logs.Info) ();
  match Runtime_config.from_process_env () with
  | Error _ -> exit 2
  | Ok config ->
      let data = Runtime_config.data config in
      Runtime_config.Secret.with_value data.database_url (fun database_url ->
          match Lwt_main.run (Db_pool.start (Uri.of_string database_url)) with
          | Error _ -> exit 1
          | Ok _ -> loop ())
