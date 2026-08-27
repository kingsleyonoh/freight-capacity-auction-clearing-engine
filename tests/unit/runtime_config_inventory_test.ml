let expected_variables =
  [ "APP_ENV"; "APP_BASE_URL"; "APP_PORT"; "LOG_LEVEL"; "SECRET_KEY_BASE";
    "DATABASE_URL"; "REDIS_URL"; "REPLAY_STORE_PATH"; "MIGRATIONS_AUTO_RUN";
    "SELF_REGISTRATION_ENABLED"; "DEFAULT_TENANT_NAME"; "DEFAULT_ADMIN_EMAIL";
    "SEED_SAMPLE_DATA"; "AUTH_TOKEN_TTL_MINUTES"; "API_KEY_PREFIX";
    "MAX_CSV_UPLOAD_MB"; "DEFAULT_CURRENCY"; "BID_LATE_GRACE_SECONDS";
    "UNKNOWN_CARRIER_POLICY"; "SOLVER_BACKEND"; "SOLVER_TIMEOUT_SECONDS";
    "PRODUCTION_CLEARING_REQUIRES_SOLVER"; "HEURISTIC_FALLBACK_FOR_REPLAY";
    "MINIZINC_BINARY_PATH"; "ORTOOLS_WORKER_PATH"; "REPLAY_MAX_ROWS";
    "REPLAY_ALLOW_EXTERNAL_EVENTS"; "DEFAULT_SERVICE_RISK_CAP";
    "DEFAULT_MAX_CARRIER_SHARE"; "APPROVAL_EXPIRY_HOURS"; "AUDIT_RETENTION_DAYS";
    "SOLVER_ARTIFACT_RETENTION_DAYS"; "NOTIFICATION_HUB_ENABLED";
    "NOTIFICATION_HUB_URL"; "NOTIFICATION_HUB_API_KEY";
    "NOTIFICATION_RETRY_ENABLED"; "WORKFLOW_ENGINE_ENABLED"; "WORKFLOW_ENGINE_URL";
    "WORKFLOW_ENGINE_API_KEY"; "WORKFLOW_HIGH_VALUE_APPROVAL_ID";
    "WORKFLOW_STATUS_POLLING_ENABLED"; "WEBHOOK_ENGINE_ENABLED";
    "WEBHOOK_ENGINE_URL"; "WEBHOOK_ENGINE_API_KEY";
    "WEBHOOK_ENGINE_RECEIVER_SECRET"; "INTEGRATION_HTTP_TIMEOUT_SECONDS";
    "INTEGRATION_HEALTH_CHECK_ENABLED"; "SENTRY_DSN";
    "OTEL_EXPORTER_OTLP_ENDPOINT"; "METRICS_ENABLED"; "POSTHOG_KEY";
    "POSTHOG_HOST" ]

let env_names path =
  let channel = open_in path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
      In_channel.input_lines channel
      |> List.filter_map (fun line ->
             match String.index_opt line '=' with
             | Some index when index > 0 && line.[0] <> '#' -> Some (String.sub line 0 index)
             | _ -> None))

let check_secret_state expected secret =
  let state = Option.map (fun value -> Runtime_config.Secret.with_value value (fun _ -> "configured")) secret in
  Alcotest.(check (option string)) "secret state" expected state

let test_inventory () =
  Alcotest.(check (list string)) "52 exact variables" expected_variables Runtime_config.known_variables;
  let duplicates =
    List.filter (fun name -> List.length (List.filter (( = ) name) Runtime_config.known_variables) <> 1)
      Runtime_config.known_variables
  in
  Alcotest.(check (list string)) "no duplicates" [] duplicates;
  let names = env_names (Filename.concat (Config_test_support.project_root ()) ".env.example") in
  let missing = List.filter (fun name -> not (List.mem name names)) expected_variables in
  Alcotest.(check (list string)) ".env.example inventory" [] missing

let check_app_and_data config =
  let app = Runtime_config.app config and data = Runtime_config.data config in
  Alcotest.(check bool) "test env" true (app.environment = `Test);
  Alcotest.(check string) "base URL" "http://localhost:8080" (Uri.to_string app.base_url);
  Alcotest.(check int) "port" 8080 app.port;
  Alcotest.(check bool) "log level" true (app.log_level = `Info);
  Runtime_config.Secret.with_value app.secret_key_base (fun value ->
      Alcotest.(check bool) "secret opaque" true (String.length value >= 32));
  Runtime_config.Secret.with_value data.database_url (fun value ->
      Alcotest.(check bool) "database parsed" true (String.starts_with ~prefix:"postgresql:" value));
  Runtime_config.Secret.with_value data.redis_url (fun value ->
      Alcotest.(check bool) "redis parsed" true (String.starts_with ~prefix:"redis:" value));
  Alcotest.(check string) "replay path" "./data/test-replay.duckdb" data.replay_store_path;
  Alcotest.(check bool) "migration flag" false data.migrations_auto_run

let check_tenant_auth_import config =
  let tenant = Runtime_config.tenant config and auth = Runtime_config.auth config in
  let import = Runtime_config.import config in
  Alcotest.(check bool) "registration" true tenant.self_registration_enabled;
  Alcotest.(check string) "tenant name" "Test Freight Tenant" tenant.default_tenant_name;
  Alcotest.(check string) "admin email" "admin@example.com" tenant.default_admin_email;
  Alcotest.(check bool) "seed flag" true tenant.seed_sample_data;
  Alcotest.(check int) "ttl" 60 auth.token_ttl_minutes;
  Alcotest.(check string) "prefix" "fca_test" auth.api_key_prefix;
  Alcotest.(check int) "upload" 50 import.max_csv_upload_mb;
  Alcotest.(check string) "currency" "USD" import.default_currency;
  Alcotest.(check int) "grace" 0 import.bid_late_grace_seconds;
  Alcotest.(check bool) "carrier policy" true (import.unknown_carrier_policy = `Reject)

let check_solver_and_policy config =
  let solver = Runtime_config.solver config and policy = Runtime_config.policy config in
  Alcotest.(check bool) "backend" true (solver.backend = `Minizinc);
  Alcotest.(check int) "timeout" 30 solver.timeout_seconds;
  Alcotest.(check bool) "production solver" true solver.production_clearing_requires_solver;
  Alcotest.(check bool) "replay fallback" true solver.heuristic_fallback_for_replay;
  Alcotest.(check string) "minizinc" "minizinc" solver.minizinc_binary_path;
  Alcotest.(check (option string)) "ortools" None solver.ortools_worker_path;
  Alcotest.(check int) "replay rows" 1000000 solver.replay_max_rows;
  Alcotest.(check bool) "external replay" false solver.replay_allow_external_events;
  Alcotest.(check (float 0.0001)) "risk" 0.15 policy.default_service_risk_cap;
  Alcotest.(check (float 0.0001)) "share" 0.30 policy.default_max_carrier_share;
  Alcotest.(check int) "approval expiry" 24 policy.approval_expiry_hours;
  Alcotest.(check int) "audit retention" 365 policy.audit_retention_days;
  Alcotest.(check int) "artifact retention" 90 policy.solver_artifact_retention_days

let check_integrations_and_observability config =
  let integrations = Runtime_config.integrations config in
  let observability = Runtime_config.observability config in
  Alcotest.(check bool) "notification disabled" false integrations.notification.enabled;
  Alcotest.(check string) "notification URL" "http://localhost:3847" (Uri.to_string integrations.notification.url);
  check_secret_state None integrations.notification.api_key;
  Alcotest.(check bool) "retry configured" true integrations.notification.retry_enabled;
  Alcotest.(check bool) "workflow disabled" false integrations.workflow.enabled;
  Alcotest.(check string) "workflow URL" "http://localhost:8000" (Uri.to_string integrations.workflow.url);
  check_secret_state None integrations.workflow.api_key;
  Alcotest.(check (option string)) "workflow id" None integrations.workflow.high_value_approval_id;
  Alcotest.(check bool) "polling configured" true integrations.workflow.status_polling_enabled;
  Alcotest.(check bool) "webhook disabled" false integrations.webhook.enabled;
  Alcotest.(check string) "webhook URL" "http://localhost:3000" (Uri.to_string integrations.webhook.url);
  check_secret_state None integrations.webhook.api_key;
  check_secret_state None integrations.webhook.receiver_secret;
  Alcotest.(check int) "HTTP timeout" 5 integrations.http_timeout_seconds;
  Alcotest.(check bool) "health flag" true integrations.health_check_enabled;
  check_secret_state None observability.sentry_dsn;
  Alcotest.(check (option string)) "OTLP" None (Option.map Uri.to_string observability.otel_exporter_otlp_endpoint);
  Alcotest.(check bool) "metrics" true observability.metrics_enabled;
  check_secret_state None observability.posthog_key;
  Alcotest.(check (option string)) "PostHog host" None (Option.map Uri.to_string observability.posthog_host)

let test_typed_snapshot () =
  let config = Config_test_support.load () |> Config_test_support.require_ok in
  check_app_and_data config;
  check_tenant_auth_import config;
  check_solver_and_policy config;
  check_integrations_and_observability config

let () =
  Alcotest.run "runtime config inventory"
    [ ("inventory", [ Alcotest.test_case "exact names" `Quick test_inventory;
                       Alcotest.test_case "typed snapshot" `Quick test_typed_snapshot ]) ]
