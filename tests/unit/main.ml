open Alcotest

module Runtime_config = Freight_capacity_auction_clearing_engine_config.Runtime_config
module Infra = Freight_capacity_auction_clearing_engine.Shared.Service_infrastructure
module Cache = Freight_capacity_auction_clearing_engine.Shared.Cache
module Db_pool = Freight_capacity_auction_clearing_engine.Shared.Db_pool
module Errors = Freight_capacity_auction_clearing_engine.Shared.Errors
module Event_outbox = Freight_capacity_auction_clearing_engine.Shared.Event_outbox
module Http_client = Freight_capacity_auction_clearing_engine.Shared.Http_client
module Redis_queue = Freight_capacity_auction_clearing_engine.Shared.Redis_queue
module Tenant_context = Freight_capacity_auction_clearing_engine.Shared.Tenant_context
module Solver_adapter = Freight_capacity_auction_clearing_engine.Solver.Process_adapter
module Console = Freight_capacity_auction_clearing_engine.Ui.Operations_console

let env pairs key = List.assoc_opt key pairs

let contains haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index =
    index + needle_len <= haystack_len
    && (String.sub haystack index needle_len = needle || loop (index + 1))
  in
  needle_len = 0 || loop 0

let config_reads_safe_defaults () =
  let config = Runtime_config.load ~getenv:(env []) () in
  check string "default app env" "development" config.app_env;
  check int "default app port" 8080 config.app_port;
  check string "default redis" "redis://localhost:16439/0" config.redis_url;
  check string "default replay store" "./data/replay.duckdb" config.replay_store_path;
  check string "optional hub API key remains empty" "" config.notification_hub_api_key

let config_rejects_invalid_numeric_values () =
  check_raises "invalid APP_PORT is rejected"
    (Invalid_argument "APP_PORT must be an integer")
    (fun () -> ignore (Runtime_config.load ~getenv:(env [ ("APP_PORT", "not-a-port") ]) ()))

let infrastructure_declares_local_services () =
  let config = Runtime_config.load ~getenv:(env []) () in
  let names = Infra.service_names config in
  check (list string) "foundation services" [ "postgres"; "redis"; "duckdb"; "solver" ] names;
  check bool "solver live binary is optional" true (Infra.solver_is_optional config)

let cached_helper_computes_once_and_can_clear () =
  let calls = ref 0 in
  let cache = Cache.create "policy-snapshot" in
  let compute () =
    incr calls;
    "snapshot-v" ^ string_of_int !calls
  in
  check string "first value" "snapshot-v1" (Cache.get_or_compute cache ~compute);
  check string "cached value" "snapshot-v1" (Cache.get_or_compute cache ~compute);
  check int "producer called once" 1 !calls;
  Cache.clear cache;
  check string "recomputed after clear" "snapshot-v2" (Cache.get_or_compute cache ~compute);
  check int "producer called again after clear" 2 !calls

let tenant_context_rejects_cross_tenant_access () =
  let context =
    Tenant_context.create ~tenant_id:"tenant-a" ~user_id:"user-1"
      ~role:Tenant_context.Auction_manager ~request_id:"req-1" ()
  in
  check (result unit string) "same tenant allowed" (Ok ())
    (Tenant_context.require_same_tenant context ~resource_tenant_id:"tenant-a");
  check (result unit string) "other tenant rejected"
    (Error "TENANT_SCOPE_VIOLATION: expected tenant-a but got tenant-b")
    (Tenant_context.require_same_tenant context ~resource_tenant_id:"tenant-b");
  let carrier_context =
    Tenant_context.create ~tenant_id:"tenant-a" ~user_id:"user-2"
      ~carrier_id:"carrier-1" ~role:Tenant_context.Carrier_viewer
      ~request_id:"req-2" ()
  in
  check bool "carrier can access own records" true
    (Tenant_context.can_access_carrier carrier_context ~carrier_id:"carrier-1");
  check bool "carrier cannot access competitor records" false
    (Tenant_context.can_access_carrier carrier_context ~carrier_id:"carrier-2")

let error_envelope_is_machine_readable_and_redacted () =
  let envelope =
    Errors.create ~code:"TENANT_SCOPE_VIOLATION"
      ~message:"Requested resource belongs to another tenant" ~status:403
      ~request_id:"req-tenant" ~details:[ ("resource", "auction") ] ()
  in
  let json = Errors.to_json_string envelope in
  check bool "code present" true (contains json "TENANT_SCOPE_VIOLATION");
  check bool "status present" true (contains json "\"status\":403");
  check bool "request id present" true (contains json "req-tenant");
  check bool "stack traces omitted" false (contains json "stack")

let db_pool_descriptor_is_cached_and_redacts_credentials () =
  let config =
    Runtime_config.load
      ~getenv:
        (env
           [
             ( "DATABASE_URL",
               "postgresql://freight_app:${POSTGRES_PASSWORD}@localhost:15439/freight_auction" );
           ])
      ()
  in
  let cache = Cache.create "db-pool" in
  let first = Db_pool.get_or_create cache config in
  let second = Db_pool.get_or_create cache config in
  check string "same database url" first.database_url second.database_url;
  check int "default max size" 10 first.max_size;
  check bool "redacts password" true (contains first.safe_database_url "<redacted>");
  check bool "does not expose password placeholder" false (contains first.safe_database_url "POSTGRES_PASSWORD");
  check string "tenant predicate" "auction.tenant_id = $tenant_id"
    (Db_pool.tenant_predicate ~table_alias:"auction")

let redis_queue_commands_are_tenant_scoped_and_idempotent () =
  let job =
    Redis_queue.create_job ~tenant_id:"tenant-a" ~queue:"clearing"
      ~idempotency_key:"auction-1-clear" ~payload_json:"{\"auction_id\":\"auction-1\"}" ()
  in
  let command = Redis_queue.enqueue_command job in
  check string "stream tenant scoped" "tenant:tenant-a:queue:clearing" command.stream;
  check string "dedupe key tenant scoped" "tenant:tenant-a:job:auction-1-clear"
    (Redis_queue.dedupe_key job);
  check bool "payload field emitted" true
    (List.mem ("payload_json", "{\"auction_id\":\"auction-1\"}") command.fields)

let http_client_redacts_sensitive_headers_and_uses_config_timeout () =
  let config = Runtime_config.load ~getenv:(env [ ("INTEGRATION_HTTP_TIMEOUT_SECONDS", "7") ]) () in
  let request =
    Http_client.from_config config ~http_method:"POST" ~url:"https://notification.example/api/events"
      ~headers:
        [
          ("Authorization", "Bearer secret-token");
          ("X-API-Key", "secret-key");
          ("Content-Type", "application/json");
        ]
      ~body:"{}" ()
  in
  check int "timeout from config" 7 request.timeout_seconds;
  let safe_headers = Http_client.redacted_headers request.headers in
  check bool "authorization redacted" true (List.mem ("Authorization", "<redacted>") safe_headers);
  check bool "api key redacted" true (List.mem ("X-API-Key", "<redacted>") safe_headers);
  check bool "content type retained" true (List.mem ("Content-Type", "application/json") safe_headers)

let event_outbox_keys_and_transitions_are_tenant_scoped () =
  let event =
    Event_outbox.create ~tenant_id:"tenant-a" ~integration:Event_outbox.Notification_hub
      ~event_type:"freight_auction.clearing.succeeded" ~aggregate_id:"auction-1"
      ~payload_json:"{}" ()
  in
  check string "idempotency key" "tenant-a:notification_hub:freight_auction.clearing.succeeded:auction-1"
    event.idempotency_key;
  check bool "new event retryable" true (Event_outbox.ready_for_retry event);
  let sent = Event_outbox.mark_succeeded event in
  check bool "sent event no longer retryable" false (Event_outbox.ready_for_retry sent)

let solver_adapter_rejects_heuristic_as_production_success () =
  let config = Runtime_config.load ~getenv:(env [ ("SOLVER_BACKEND", "heuristic_baseline") ]) () in
  let request =
    Solver_adapter.create_request config ~tenant_id:"tenant-a" ~auction_id:"auction-1"
      ~job_id:"job-1" ~model_path:"artifacts/job-1/model.mzn"
      ~output_path:"artifacts/job-1/output.json" ()
  in
  check bool "heuristic cannot satisfy production clearing" false
    (Solver_adapter.production_success_allowed request);
  check string "artifact prefix is tenant/job scoped" "tenant-a/auction-1/job-1"
    (Solver_adapter.artifact_prefix request)

let operations_console_has_privacy_and_accessibility_baseline () =
  let html = Console.render () in
  check bool "has main landmark" true (contains html "<main");
  check bool "labels sealed-bid privacy" true (contains html "sealed-bid privacy");
  check bool "contains privacy scope attribute" true
    (contains html "data-privacy-scope=\"sealed-bid\"");
  check bool "includes table caption" true (contains html "Auction readiness");
  check bool "does not expose sample competitor price" false
    (contains html "$")

let () =
  run "freight_capacity_auction_clearing_engine"
    [
      ( "runtime config",
        [
          test_case "reads safe defaults" `Quick config_reads_safe_defaults;
          test_case "rejects invalid numeric env" `Quick config_rejects_invalid_numeric_values;
        ] );
      ( "service infrastructure",
        [ test_case "declares local dependencies" `Quick infrastructure_declares_local_services ] );
      ( "shared architecture",
        [
          test_case "cached helper computes once" `Quick cached_helper_computes_once_and_can_clear;
          test_case "tenant context guards cross-tenant access" `Quick tenant_context_rejects_cross_tenant_access;
          test_case "error envelope is JSON and redacted" `Quick error_envelope_is_machine_readable_and_redacted;
          test_case "db pool descriptor redacts and caches" `Quick db_pool_descriptor_is_cached_and_redacts_credentials;
          test_case "redis queue command is tenant scoped" `Quick redis_queue_commands_are_tenant_scoped_and_idempotent;
          test_case "http client redacts sensitive headers" `Quick http_client_redacts_sensitive_headers_and_uses_config_timeout;
          test_case "event outbox is tenant scoped" `Quick event_outbox_keys_and_transitions_are_tenant_scoped;
          test_case "solver adapter blocks heuristic production success" `Quick solver_adapter_rejects_heuristic_as_production_success;
        ] );
      ( "operations console",
        [ test_case "has privacy and accessibility baseline" `Quick operations_console_has_privacy_and_accessibility_baseline ] );
    ]
