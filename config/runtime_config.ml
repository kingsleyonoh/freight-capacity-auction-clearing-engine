type t = {
  app_env : string;
  app_base_url : string;
  app_port : int;
  log_level : string;
  secret_key_base : string;
  database_url : string;
  redis_url : string;
  replay_store_path : string;
  migrations_auto_run : bool;
  self_registration_enabled : bool;
  default_tenant_name : string;
  default_admin_email : string;
  seed_sample_data : bool;
  auth_token_ttl_minutes : int;
  api_key_prefix : string;
  max_csv_upload_mb : int;
  default_currency : string;
  bid_late_grace_seconds : int;
  unknown_carrier_policy : string;
  solver_backend : string;
  solver_timeout_seconds : int;
  production_clearing_requires_solver : bool;
  heuristic_fallback_for_replay : bool;
  minizinc_binary_path : string;
  ortools_worker_path : string;
  replay_max_rows : int;
  replay_allow_external_events : bool;
  default_service_risk_cap : float;
  default_max_carrier_share : float;
  approval_expiry_hours : int;
  audit_retention_days : int;
  solver_artifact_retention_days : int;
  notification_hub_enabled : bool;
  notification_hub_url : string;
  notification_hub_api_key : string;
  notification_retry_enabled : bool;
  workflow_engine_enabled : bool;
  workflow_engine_url : string;
  workflow_engine_api_key : string;
  workflow_high_value_approval_id : string;
  workflow_status_polling_enabled : bool;
  webhook_engine_enabled : bool;
  webhook_engine_url : string;
  webhook_engine_api_key : string;
  webhook_engine_receiver_secret : string;
  integration_http_timeout_seconds : int;
  integration_health_check_enabled : bool;
  sentry_dsn : string;
  otel_exporter_otlp_endpoint : string;
  metrics_enabled : bool;
  posthog_key : string;
  posthog_host : string;
}

let get ~getenv key fallback =
  match getenv key with Some value when value <> "" -> value | _ -> fallback

let parse_int key value =
  match int_of_string_opt value with
  | Some parsed -> parsed
  | None -> invalid_arg (key ^ " must be an integer")

let parse_float key value =
  match float_of_string_opt value with
  | Some parsed -> parsed
  | None -> invalid_arg (key ^ " must be a number")

let parse_bool key value =
  match String.lowercase_ascii value with
  | "true" | "1" | "yes" | "on" -> true
  | "false" | "0" | "no" | "off" -> false
  | _ -> invalid_arg (key ^ " must be a boolean")

let load ?(getenv = Sys.getenv_opt) () =
  let string key fallback = get ~getenv key fallback in
  let int key fallback = parse_int key (string key fallback) in
  let float key fallback = parse_float key (string key fallback) in
  let bool key fallback = parse_bool key (string key fallback) in
  {
    app_env = string "APP_ENV" "development";
    app_base_url = string "APP_BASE_URL" "http://localhost:8080";
    app_port = int "APP_PORT" "8080";
    log_level = string "LOG_LEVEL" "info";
    secret_key_base = string "SECRET_KEY_BASE" "change-me-in-local-env";
    database_url =
      string "DATABASE_URL"
        "postgresql://localhost:15439/freight_auction?user=freight_app";
    redis_url = string "REDIS_URL" "redis://localhost:16439/0";
    replay_store_path = string "REPLAY_STORE_PATH" "./data/replay.duckdb";
    migrations_auto_run = bool "MIGRATIONS_AUTO_RUN" "false";
    self_registration_enabled = bool "SELF_REGISTRATION_ENABLED" "true";
    default_tenant_name = string "DEFAULT_TENANT_NAME" "Default Freight Auction Tenant";
    default_admin_email = string "DEFAULT_ADMIN_EMAIL" "admin@example.com";
    seed_sample_data = bool "SEED_SAMPLE_DATA" "true";
    auth_token_ttl_minutes = int "AUTH_TOKEN_TTL_MINUTES" "60";
    api_key_prefix = string "API_KEY_PREFIX" "fca_local";
    max_csv_upload_mb = int "MAX_CSV_UPLOAD_MB" "50";
    default_currency = string "DEFAULT_CURRENCY" "USD";
    bid_late_grace_seconds = int "BID_LATE_GRACE_SECONDS" "0";
    unknown_carrier_policy = string "UNKNOWN_CARRIER_POLICY" "reject";
    solver_backend = string "SOLVER_BACKEND" "minizinc";
    solver_timeout_seconds = int "SOLVER_TIMEOUT_SECONDS" "30";
    production_clearing_requires_solver = bool "PRODUCTION_CLEARING_REQUIRES_SOLVER" "true";
    heuristic_fallback_for_replay = bool "HEURISTIC_FALLBACK_FOR_REPLAY" "true";
    minizinc_binary_path = string "MINIZINC_BINARY_PATH" "minizinc";
    ortools_worker_path = string "ORTOOLS_WORKER_PATH" "";
    replay_max_rows = int "REPLAY_MAX_ROWS" "1000000";
    replay_allow_external_events = bool "REPLAY_ALLOW_EXTERNAL_EVENTS" "false";
    default_service_risk_cap = float "DEFAULT_SERVICE_RISK_CAP" "0.15";
    default_max_carrier_share = float "DEFAULT_MAX_CARRIER_SHARE" "0.30";
    approval_expiry_hours = int "APPROVAL_EXPIRY_HOURS" "24";
    audit_retention_days = int "AUDIT_RETENTION_DAYS" "365";
    solver_artifact_retention_days = int "SOLVER_ARTIFACT_RETENTION_DAYS" "90";
    notification_hub_enabled = bool "NOTIFICATION_HUB_ENABLED" "false";
    notification_hub_url = string "NOTIFICATION_HUB_URL" "http://localhost:3847";
    notification_hub_api_key = string "NOTIFICATION_HUB_API_KEY" "";
    notification_retry_enabled = bool "NOTIFICATION_RETRY_ENABLED" "true";
    workflow_engine_enabled = bool "WORKFLOW_ENGINE_ENABLED" "false";
    workflow_engine_url = string "WORKFLOW_ENGINE_URL" "http://localhost:8000";
    workflow_engine_api_key = string "WORKFLOW_ENGINE_API_KEY" "";
    workflow_high_value_approval_id = string "WORKFLOW_HIGH_VALUE_APPROVAL_ID" "";
    workflow_status_polling_enabled = bool "WORKFLOW_STATUS_POLLING_ENABLED" "true";
    webhook_engine_enabled = bool "WEBHOOK_ENGINE_ENABLED" "false";
    webhook_engine_url = string "WEBHOOK_ENGINE_URL" "http://localhost:3000";
    webhook_engine_api_key = string "WEBHOOK_ENGINE_API_KEY" "";
    webhook_engine_receiver_secret = string "WEBHOOK_ENGINE_RECEIVER_SECRET" "";
    integration_http_timeout_seconds = int "INTEGRATION_HTTP_TIMEOUT_SECONDS" "5";
    integration_health_check_enabled = bool "INTEGRATION_HEALTH_CHECK_ENABLED" "true";
    sentry_dsn = string "SENTRY_DSN" "";
    otel_exporter_otlp_endpoint = string "OTEL_EXPORTER_OTLP_ENDPOINT" "";
    metrics_enabled = bool "METRICS_ENABLED" "true";
    posthog_key = string "POSTHOG_KEY" "";
    posthog_host = string "POSTHOG_HOST" "";
  }
