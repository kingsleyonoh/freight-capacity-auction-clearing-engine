let project_root () =
  let rec ascend path candidate =
    let candidate = if Sys.file_exists (Filename.concat path "dune-project") then Some path else candidate in
    let parent = Filename.dirname path in
    if parent = path then Option.value ~default:(Sys.getcwd ()) candidate
    else ascend parent candidate
  in
  ascend (Sys.getcwd ()) None

let values =
  [ ("APP_ENV", "test"); ("APP_BASE_URL", "http://localhost:8080");
    ("APP_PORT", "8080"); ("LOG_LEVEL", "info");
    ("SECRET_KEY_BASE", "test-secret-key-base-at-least-thirty-two-bytes");
    ("DATABASE_URL", "postgresql://localhost:5432/fca_test");
    ("REDIS_URL", "redis://localhost:6379/0");
    ("REPLAY_STORE_PATH", "./data/test-replay.duckdb");
    ("MIGRATIONS_AUTO_RUN", "false"); ("SELF_REGISTRATION_ENABLED", "true");
    ("DEFAULT_TENANT_NAME", "Test Freight Tenant");
    ("DEFAULT_ADMIN_EMAIL", "admin@example.com"); ("SEED_SAMPLE_DATA", "true");
    ("AUTH_TOKEN_TTL_MINUTES", "60"); ("API_KEY_PREFIX", "fca_test");
    ("MAX_CSV_UPLOAD_MB", "50"); ("DEFAULT_CURRENCY", "USD");
    ("BID_LATE_GRACE_SECONDS", "0"); ("UNKNOWN_CARRIER_POLICY", "reject");
    ("SOLVER_BACKEND", "minizinc"); ("SOLVER_TIMEOUT_SECONDS", "30");
    ("PRODUCTION_CLEARING_REQUIRES_SOLVER", "true");
    ("HEURISTIC_FALLBACK_FOR_REPLAY", "true");
    ("MINIZINC_BINARY_PATH", "minizinc"); ("ORTOOLS_WORKER_PATH", "");
    ("REPLAY_MAX_ROWS", "1000000"); ("REPLAY_ALLOW_EXTERNAL_EVENTS", "false");
    ("DEFAULT_SERVICE_RISK_CAP", "0.15");
    ("DEFAULT_MAX_CARRIER_SHARE", "0.30"); ("APPROVAL_EXPIRY_HOURS", "24");
    ("AUDIT_RETENTION_DAYS", "365"); ("SOLVER_ARTIFACT_RETENTION_DAYS", "90");
    ("NOTIFICATION_HUB_ENABLED", "false");
    ("NOTIFICATION_HUB_URL", "http://localhost:3847");
    ("NOTIFICATION_HUB_API_KEY", ""); ("NOTIFICATION_RETRY_ENABLED", "true");
    ("WORKFLOW_ENGINE_ENABLED", "false");
    ("WORKFLOW_ENGINE_URL", "http://localhost:8000");
    ("WORKFLOW_ENGINE_API_KEY", ""); ("WORKFLOW_HIGH_VALUE_APPROVAL_ID", "");
    ("WORKFLOW_STATUS_POLLING_ENABLED", "true");
    ("WEBHOOK_ENGINE_ENABLED", "false");
    ("WEBHOOK_ENGINE_URL", "http://localhost:3000");
    ("WEBHOOK_ENGINE_API_KEY", ""); ("WEBHOOK_ENGINE_RECEIVER_SECRET", "");
    ("INTEGRATION_HTTP_TIMEOUT_SECONDS", "5");
    ("INTEGRATION_HEALTH_CHECK_ENABLED", "true"); ("SENTRY_DSN", "");
    ("OTEL_EXPORTER_OTLP_ENDPOINT", ""); ("METRICS_ENABLED", "true");
    ("POSTHOG_KEY", ""); ("POSTHOG_HOST", "") ]

let with_values replacements =
  let replacement_names = List.map fst replacements in
  replacements @ List.filter (fun (name, _) -> not (List.mem name replacement_names)) values

let get_from values name = List.assoc_opt name values

let load ?(replacements = []) () =
  Runtime_config.load ~get:(get_from (with_values replacements))

let require_ok = function
  | Ok config -> config
  | Error errors ->
      Alcotest.failf "expected valid config, got %s"
        (Yojson.Safe.to_string (Runtime_config.errors_to_yojson errors))

let error_variables = function
  | Ok _ -> Alcotest.fail "expected validation failure"
  | Error errors -> List.map (fun (error : Runtime_config.validation_error) -> error.variable) errors

let rendered_errors = function
  | Ok _ -> Alcotest.fail "expected validation failure"
  | Error errors -> Yojson.Safe.to_string (Runtime_config.errors_to_yojson errors)
