module Secret = struct
  type t = string

  let create value = value
  let with_value value consume = consume value
end

type error_code = [ `Missing | `Invalid | `Invariant | `Required ]

type validation_error = {
  variable : string;
  code : error_code;
  message : string;
}

type app_config = {
  environment : [ `Development | `Test | `Production ];
  base_url : Uri.t;
  port : int;
  log_level : [ `Debug | `Info | `Warning | `Error ];
  secret_key_base : Secret.t;
}

type data_config = {
  database_url : Secret.t;
  redis_url : Secret.t;
  replay_store_path : string;
  migrations_auto_run : bool;
}

type tenant_config = {
  self_registration_enabled : bool;
  default_tenant_name : string;
  default_admin_email : string;
  seed_sample_data : bool;
}

type auth_config = { token_ttl_minutes : int; api_key_prefix : string }

type import_config = {
  max_csv_upload_mb : int;
  default_currency : string;
  bid_late_grace_seconds : int;
  unknown_carrier_policy : [ `Reject | `Quarantine ];
}

type solver_config = {
  backend : [ `Minizinc | `Ortools ];
  timeout_seconds : int;
  production_clearing_requires_solver : bool;
  heuristic_fallback_for_replay : bool;
  minizinc_binary_path : string;
  ortools_worker_path : string option;
  replay_max_rows : int;
  replay_allow_external_events : bool;
}

type policy_config = {
  default_service_risk_cap : float;
  default_max_carrier_share : float;
  approval_expiry_hours : int;
  audit_retention_days : int;
  solver_artifact_retention_days : int;
}

type notification_config = {
  enabled : bool;
  url : Uri.t;
  api_key : Secret.t option;
  retry_enabled : bool;
}

type workflow_config = {
  enabled : bool;
  url : Uri.t;
  api_key : Secret.t option;
  high_value_approval_id : string option;
  status_polling_enabled : bool;
}

type webhook_config = {
  enabled : bool;
  url : Uri.t;
  api_key : Secret.t option;
  receiver_secret : Secret.t option;
}

type integrations_config = {
  notification : notification_config;
  workflow : workflow_config;
  webhook : webhook_config;
  http_timeout_seconds : int;
  health_check_enabled : bool;
}

type observability_config = {
  sentry_dsn : Secret.t option;
  otel_exporter_otlp_endpoint : Uri.t option;
  metrics_enabled : bool;
  posthog_key : Secret.t option;
  posthog_host : Uri.t option;
}

type t = {
  app : app_config;
  data : data_config;
  tenant : tenant_config;
  auth : auth_config;
  import : import_config;
  solver : solver_config;
  policy : policy_config;
  integrations : integrations_config;
  observability : observability_config;
}

type context = {
  get : string -> string option;
  mutable errors : validation_error list;
}

let known_variables =
  [
    "APP_ENV";
    "APP_BASE_URL";
    "APP_PORT";
    "LOG_LEVEL";
    "SECRET_KEY_BASE";
    "DATABASE_URL";
    "REDIS_URL";
    "REPLAY_STORE_PATH";
    "MIGRATIONS_AUTO_RUN";
    "SELF_REGISTRATION_ENABLED";
    "DEFAULT_TENANT_NAME";
    "DEFAULT_ADMIN_EMAIL";
    "SEED_SAMPLE_DATA";
    "AUTH_TOKEN_TTL_MINUTES";
    "API_KEY_PREFIX";
    "MAX_CSV_UPLOAD_MB";
    "DEFAULT_CURRENCY";
    "BID_LATE_GRACE_SECONDS";
    "UNKNOWN_CARRIER_POLICY";
    "SOLVER_BACKEND";
    "SOLVER_TIMEOUT_SECONDS";
    "PRODUCTION_CLEARING_REQUIRES_SOLVER";
    "HEURISTIC_FALLBACK_FOR_REPLAY";
    "MINIZINC_BINARY_PATH";
    "ORTOOLS_WORKER_PATH";
    "REPLAY_MAX_ROWS";
    "REPLAY_ALLOW_EXTERNAL_EVENTS";
    "DEFAULT_SERVICE_RISK_CAP";
    "DEFAULT_MAX_CARRIER_SHARE";
    "APPROVAL_EXPIRY_HOURS";
    "AUDIT_RETENTION_DAYS";
    "SOLVER_ARTIFACT_RETENTION_DAYS";
    "NOTIFICATION_HUB_ENABLED";
    "NOTIFICATION_HUB_URL";
    "NOTIFICATION_HUB_API_KEY";
    "NOTIFICATION_RETRY_ENABLED";
    "WORKFLOW_ENGINE_ENABLED";
    "WORKFLOW_ENGINE_URL";
    "WORKFLOW_ENGINE_API_KEY";
    "WORKFLOW_HIGH_VALUE_APPROVAL_ID";
    "WORKFLOW_STATUS_POLLING_ENABLED";
    "WEBHOOK_ENGINE_ENABLED";
    "WEBHOOK_ENGINE_URL";
    "WEBHOOK_ENGINE_API_KEY";
    "WEBHOOK_ENGINE_RECEIVER_SECRET";
    "INTEGRATION_HTTP_TIMEOUT_SECONDS";
    "INTEGRATION_HEALTH_CHECK_ENABLED";
    "SENTRY_DSN";
    "OTEL_EXPORTER_OTLP_ENDPOINT";
    "METRICS_ENABLED";
    "POSTHOG_KEY";
    "POSTHOG_HOST";
  ]

let add_error context variable code message =
  context.errors <- { variable; code; message } :: context.errors

let trimmed value = String.trim value

let optional context name =
  match context.get name with
  | None -> None
  | Some value ->
      let value = trimmed value in
      if value = "" then None else Some value

let value context ~default name =
  match context.get name with
  | None -> default
  | Some supplied -> trimmed supplied

let required context name =
  match optional context name with
  | Some supplied -> supplied
  | None ->
      add_error context name `Missing "is required";
      ""

let parse_with context name raw parse message fallback =
  match parse raw with
  | Some parsed -> parsed
  | None ->
      add_error context name `Invalid message;
      fallback

let parse_bool context ~default name =
  let raw = value context ~default:(string_of_bool default) name in
  parse_with context name raw
    (function "true" -> Some true | "false" -> Some false | _ -> None)
    "must be exactly true or false" default

let int_value raw = try Some (int_of_string raw) with Failure _ -> None

let float_value raw =
  try
    let value = float_of_string raw in
    if Float.is_finite value then Some value else None
  with Failure _ -> None

let parse_int context ~default ~valid ~message name =
  let raw = value context ~default:(string_of_int default) name in
  parse_with context name raw
    (fun supplied ->
      Option.bind (int_value supplied) (fun number ->
          if valid number then Some number else None))
    message default

let parse_float context ~default ~valid ~message name =
  let raw = value context ~default:(string_of_float default) name in
  parse_with context name raw
    (fun supplied ->
      Option.bind (float_value supplied) (fun number ->
          if valid number then Some number else None))
    message default

let parse_enum context ~default ~choices name =
  let raw = value context ~default name in
  parse_with context name raw
    (fun supplied -> List.assoc_opt supplied choices)
    "must be one of the documented values"
    (List.assoc default choices)

let parse_non_empty context ~default name =
  let raw = value context ~default name in
  parse_with context name raw
    (fun supplied -> if supplied = "" then None else Some supplied)
    "must not be empty" default

let valid_uri schemes raw =
  let uri = Uri.of_string raw in
  match (Uri.scheme uri, Uri.host uri) with
  | Some scheme, Some host when host <> "" && List.mem scheme schemes ->
      Some uri
  | _ -> None

let parse_uri context ~default ~schemes name =
  let raw = value context ~default name in
  parse_with context name raw (valid_uri schemes)
    "must be a valid URL with an allowed scheme" (Uri.of_string default)

let parse_optional_uri context ~schemes name =
  match optional context name with
  | None -> None
  | Some raw -> (
      match valid_uri schemes raw with
      | Some uri -> Some uri
      | None ->
          add_error context name `Invalid
            "must be a valid URL with an allowed scheme";
          None)

let valid_email value =
  match String.split_on_char '@' value with
  | [ local; domain ] ->
      local <> "" && domain <> "" && String.contains domain '.'
      && not (String.contains value ' ')
  | _ -> false

let parse_email context ~default name =
  let raw = value context ~default name in
  parse_with context name raw
    (fun supplied -> if valid_email supplied then Some supplied else None)
    "must be a syntactically valid email address" default

let valid_prefix value =
  let valid_character = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
    | _ -> false
  in
  let length = String.length value in
  length >= 5 && length <= 32
  && String.starts_with ~prefix:"fca_" value
  && String.for_all valid_character value

let parse_prefix context ~default name =
  let raw = value context ~default name in
  parse_with context name raw
    (fun supplied -> if valid_prefix supplied then Some supplied else None)
    "must be 5 to 32 characters, start with fca_, and contain only letters, \
     digits, or underscores"
    default

let parse_currency context ~default name =
  let raw = value context ~default name in
  let valid value =
    String.length value = 3
    && String.for_all (function 'A' .. 'Z' -> true | _ -> false) value
  in
  parse_with context name raw
    (fun supplied -> if valid supplied then Some supplied else None)
    "must be exactly three uppercase ASCII letters" default

let parse_optional_identifier context name =
  let valid_first = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
    | _ -> false
  in
  let valid_character character =
    valid_first character || List.mem character [ '_'; '-'; '.' ]
  in
  match optional context name with
  | None -> None
  | Some supplied ->
      if
        String.length supplied <= 128
        && valid_first supplied.[0]
        && String.for_all valid_character supplied
      then Some supplied
      else (
        add_error context name `Invalid
          "must be at most 128 characters, begin with an ASCII letter or \
           digit, and contain only letters, digits, underscores, hyphens, or \
           periods";
        None)

let secret_optional context name =
  Option.map Secret.create (optional context name)

let parse_sensitive_uri context ~schemes name =
  let raw = required context name in
  let valid = valid_uri schemes raw in
  if raw <> "" && Option.is_none valid then
    add_error context name `Invalid
      "must be a valid connection URL with an allowed scheme";
  Secret.create raw

let secret_key context =
  let raw = required context "SECRET_KEY_BASE" in
  let lowered = String.lowercase_ascii raw in
  let placeholder =
    List.mem lowered [ "xxxxx"; "replace-me"; "change-me"; "secret" ]
  in
  if raw <> "" && (String.length raw < 32 || placeholder) then
    add_error context "SECRET_KEY_BASE" `Invalid
      "must be a non-placeholder value of at least 32 bytes";
  Secret.create raw

let load_app context =
  {
    environment =
      parse_enum context ~default:"development"
        ~choices:
          [
            ("development", `Development);
            ("test", `Test);
            ("production", `Production);
          ]
        "APP_ENV";
    base_url =
      parse_uri context ~default:"http://localhost:8080"
        ~schemes:[ "http"; "https" ] "APP_BASE_URL";
    port =
      parse_int context ~default:8080
        ~valid:(fun value -> value >= 1 && value <= 65535)
        ~message:"must be an integer from 1 through 65535" "APP_PORT";
    log_level =
      parse_enum context ~default:"info"
        ~choices:
          [
            ("debug", `Debug);
            ("info", `Info);
            ("warning", `Warning);
            ("error", `Error);
          ]
        "LOG_LEVEL";
    secret_key_base = secret_key context;
  }

let load_data context =
  {
    database_url =
      parse_sensitive_uri context
        ~schemes:[ "postgres"; "postgresql" ]
        "DATABASE_URL";
    redis_url =
      parse_sensitive_uri context ~schemes:[ "redis"; "rediss" ] "REDIS_URL";
    replay_store_path =
      parse_non_empty context ~default:"./data/replays/replay.duckdb"
        "REPLAY_STORE_PATH";
    migrations_auto_run =
      parse_bool context ~default:false "MIGRATIONS_AUTO_RUN";
  }

let load_tenant context =
  {
    self_registration_enabled =
      parse_bool context ~default:true "SELF_REGISTRATION_ENABLED";
    default_tenant_name =
      parse_non_empty context ~default:"Default Freight Auction Tenant"
        "DEFAULT_TENANT_NAME";
    default_admin_email =
      parse_email context ~default:"admin@example.com" "DEFAULT_ADMIN_EMAIL";
    seed_sample_data = parse_bool context ~default:true "SEED_SAMPLE_DATA";
  }

let load_auth context =
  {
    token_ttl_minutes =
      parse_int context ~default:60
        ~valid:(fun value -> value >= 1 && value <= 10_080)
        ~message:"must be an integer from 1 through 10080"
        "AUTH_TOKEN_TTL_MINUTES";
    api_key_prefix = parse_prefix context ~default:"fca_live" "API_KEY_PREFIX";
  }

let load_import context =
  {
    max_csv_upload_mb =
      parse_int context ~default:50
        ~valid:(fun value -> value >= 1 && value <= 1_024)
        ~message:"must be an integer from 1 through 1024" "MAX_CSV_UPLOAD_MB";
    default_currency = parse_currency context ~default:"USD" "DEFAULT_CURRENCY";
    bid_late_grace_seconds =
      parse_int context ~default:0
        ~valid:(fun value -> value >= 0 && value <= 86_400)
        ~message:"must be an integer from 0 through 86400"
        "BID_LATE_GRACE_SECONDS";
    unknown_carrier_policy =
      parse_enum context ~default:"reject"
        ~choices:[ ("reject", `Reject); ("quarantine", `Quarantine) ]
        "UNKNOWN_CARRIER_POLICY";
  }

let load_solver context =
  {
    backend =
      parse_enum context ~default:"minizinc"
        ~choices:[ ("minizinc", `Minizinc); ("ortools", `Ortools) ]
        "SOLVER_BACKEND";
    timeout_seconds =
      parse_int context ~default:30
        ~valid:(fun value -> value >= 1 && value <= 3_600)
        ~message:"must be an integer from 1 through 3600"
        "SOLVER_TIMEOUT_SECONDS";
    production_clearing_requires_solver =
      parse_bool context ~default:true "PRODUCTION_CLEARING_REQUIRES_SOLVER";
    heuristic_fallback_for_replay =
      parse_bool context ~default:true "HEURISTIC_FALLBACK_FOR_REPLAY";
    minizinc_binary_path =
      parse_non_empty context ~default:"minizinc" "MINIZINC_BINARY_PATH";
    ortools_worker_path = optional context "ORTOOLS_WORKER_PATH";
    replay_max_rows =
      parse_int context ~default:1_000_000
        ~valid:(fun value -> value >= 1 && value <= 10_000_000)
        ~message:"must be an integer from 1 through 10000000" "REPLAY_MAX_ROWS";
    replay_allow_external_events =
      parse_bool context ~default:false "REPLAY_ALLOW_EXTERNAL_EVENTS";
  }

let load_policy context =
  {
    default_service_risk_cap =
      parse_float context ~default:0.15
        ~valid:(fun value -> value >= 0. && value <= 1.)
        ~message:"must be between 0 and 1" "DEFAULT_SERVICE_RISK_CAP";
    default_max_carrier_share =
      parse_float context ~default:0.30
        ~valid:(fun value -> value > 0. && value <= 1.)
        ~message:"must be greater than 0 and at most 1"
        "DEFAULT_MAX_CARRIER_SHARE";
    approval_expiry_hours =
      parse_int context ~default:24
        ~valid:(fun value -> value >= 1 && value <= 8_760)
        ~message:"must be an integer from 1 through 8760"
        "APPROVAL_EXPIRY_HOURS";
    audit_retention_days =
      parse_int context ~default:365
        ~valid:(fun value -> value >= 1 && value <= 36_500)
        ~message:"must be an integer from 1 through 36500"
        "AUDIT_RETENTION_DAYS";
    solver_artifact_retention_days =
      parse_int context ~default:90
        ~valid:(fun value -> value >= 1 && value <= 3_650)
        ~message:"must be an integer from 1 through 3650"
        "SOLVER_ARTIFACT_RETENTION_DAYS";
  }

let load_notification context =
  {
    enabled = parse_bool context ~default:false "NOTIFICATION_HUB_ENABLED";
    url =
      parse_uri context ~default:"http://localhost:3847"
        ~schemes:[ "http"; "https" ] "NOTIFICATION_HUB_URL";
    api_key = secret_optional context "NOTIFICATION_HUB_API_KEY";
    retry_enabled =
      parse_bool context ~default:true "NOTIFICATION_RETRY_ENABLED";
  }

let load_workflow context =
  {
    enabled = parse_bool context ~default:false "WORKFLOW_ENGINE_ENABLED";
    url =
      parse_uri context ~default:"http://localhost:8000"
        ~schemes:[ "http"; "https" ] "WORKFLOW_ENGINE_URL";
    api_key = secret_optional context "WORKFLOW_ENGINE_API_KEY";
    high_value_approval_id =
      parse_optional_identifier context "WORKFLOW_HIGH_VALUE_APPROVAL_ID";
    status_polling_enabled =
      parse_bool context ~default:true "WORKFLOW_STATUS_POLLING_ENABLED";
  }

let load_webhook context =
  {
    enabled = parse_bool context ~default:false "WEBHOOK_ENGINE_ENABLED";
    url =
      parse_uri context ~default:"http://localhost:3000"
        ~schemes:[ "http"; "https" ] "WEBHOOK_ENGINE_URL";
    api_key = secret_optional context "WEBHOOK_ENGINE_API_KEY";
    receiver_secret = secret_optional context "WEBHOOK_ENGINE_RECEIVER_SECRET";
  }

let load_integrations context =
  {
    notification = load_notification context;
    workflow = load_workflow context;
    webhook = load_webhook context;
    http_timeout_seconds =
      parse_int context ~default:5
        ~valid:(fun value -> value >= 1 && value <= 300)
        ~message:"must be an integer from 1 through 300"
        "INTEGRATION_HTTP_TIMEOUT_SECONDS";
    health_check_enabled =
      parse_bool context ~default:true "INTEGRATION_HEALTH_CHECK_ENABLED";
  }

let load_observability context =
  let sentry_dsn =
    match optional context "SENTRY_DSN" with
    | None -> None
    | Some raw ->
        if Option.is_none (valid_uri [ "http"; "https" ] raw) then
          add_error context "SENTRY_DSN" `Invalid
            "must be a valid HTTP or HTTPS DSN";
        Some (Secret.create raw)
  in
  {
    sentry_dsn;
    otel_exporter_otlp_endpoint =
      parse_optional_uri context ~schemes:[ "http"; "https" ]
        "OTEL_EXPORTER_OTLP_ENDPOINT";
    metrics_enabled = parse_bool context ~default:true "METRICS_ENABLED";
    posthog_key = secret_optional context "POSTHOG_KEY";
    posthog_host =
      parse_optional_uri context ~schemes:[ "http"; "https" ] "POSTHOG_HOST";
  }

let require_when context condition variable configured message =
  if condition && not configured then
    add_error context variable `Required message

let require_https context condition variable uri =
  if condition && Uri.scheme uri <> Some "https" then
    add_error context variable `Invariant
      "must use HTTPS in production when enabled"

let validate_invariants context config =
  let production = config.app.environment = `Production in
  require_https context production "APP_BASE_URL" config.app.base_url;
  if production && not config.solver.production_clearing_requires_solver then
    add_error context "PRODUCTION_CLEARING_REQUIRES_SOLVER" `Invariant
      "must be true in production";
  if config.solver.replay_allow_external_events then
    add_error context "REPLAY_ALLOW_EXTERNAL_EVENTS" `Invariant
      "must remain false";
  require_when context
    (config.solver.backend = `Ortools)
    "ORTOOLS_WORKER_PATH"
    (Option.is_some config.solver.ortools_worker_path)
    "is required for the OR-Tools backend";
  let integrations = config.integrations in
  require_https context
    (production && integrations.notification.enabled)
    "NOTIFICATION_HUB_URL" integrations.notification.url;
  require_https context
    (production && integrations.workflow.enabled)
    "WORKFLOW_ENGINE_URL" integrations.workflow.url;
  require_https context
    (production && integrations.webhook.enabled)
    "WEBHOOK_ENGINE_URL" integrations.webhook.url;
  require_when context integrations.notification.enabled
    "NOTIFICATION_HUB_API_KEY"
    (Option.is_some integrations.notification.api_key)
    "is required when Notification Hub is enabled";
  require_when context integrations.workflow.enabled "WORKFLOW_ENGINE_API_KEY"
    (Option.is_some integrations.workflow.api_key)
    "is required when Workflow Engine is enabled";
  require_when context integrations.webhook.enabled "WEBHOOK_ENGINE_API_KEY"
    (Option.is_some integrations.webhook.api_key)
    "is required when Webhook Engine is enabled";
  require_when context integrations.webhook.enabled
    "WEBHOOK_ENGINE_RECEIVER_SECRET"
    (Option.is_some integrations.webhook.receiver_secret)
    "is required when Webhook Engine is enabled";
  Option.iter
    (require_https context production "OTEL_EXPORTER_OTLP_ENDPOINT")
    config.observability.otel_exporter_otlp_endpoint;
  Option.iter
    (require_https context production "POSTHOG_HOST")
    config.observability.posthog_host;
  require_when context
    (Option.is_some config.observability.posthog_key)
    "POSTHOG_HOST"
    (Option.is_some config.observability.posthog_host)
    "is required when POSTHOG_KEY is configured"

let load ~get =
  let context = { get; errors = [] } in
  let app = load_app context in
  let data = load_data context in
  let tenant = load_tenant context in
  let auth = load_auth context in
  let import = load_import context in
  let solver = load_solver context in
  let policy = load_policy context in
  let integrations = load_integrations context in
  let observability = load_observability context in
  let config =
    {
      app;
      data;
      tenant;
      auth;
      import;
      solver;
      policy;
      integrations;
      observability;
    }
  in
  validate_invariants context config;
  match List.rev context.errors with [] -> Ok config | errors -> Error errors

let from_process_env () = load ~get:Sys.getenv_opt
let app config = config.app
let data config = config.data
let tenant config = config.tenant
let auth config = config.auth
let import config = config.import
let solver config = config.solver
let policy config = config.policy
let integrations config = config.integrations
let observability config = config.observability

let secret_state = function
  | None -> `String "unset"
  | Some _ -> `String "configured"

let safe_uri uri =
  let scheme = Option.value ~default:"" (Uri.scheme uri) in
  let host = Option.value ~default:"" (Uri.host uri) in
  let port =
    Option.fold ~none:""
      ~some:(fun value -> ":" ^ string_of_int value)
      (Uri.port uri)
  in
  let path = Uri.path uri in
  scheme ^ "://" ^ host ^ port ^ path

let app_env_name = function
  | `Development -> "development"
  | `Test -> "test"
  | `Production -> "production"

let redacted_summary config =
  `Assoc
    [
      ( "app",
        `Assoc
          [
            ("environment", `String (app_env_name config.app.environment));
            ("base_url", `String (safe_uri config.app.base_url));
            ("secret_key_base", `String "configured");
          ] );
      ( "data",
        `Assoc
          [
            ("database_url", `String "configured");
            ("redis_url", `String "configured");
            ("replay_store_path", `String config.data.replay_store_path);
          ] );
      ( "integrations",
        `Assoc
          [
            ( "notification_hub_api_key",
              secret_state config.integrations.notification.api_key );
            ( "workflow_engine_api_key",
              secret_state config.integrations.workflow.api_key );
            ( "webhook_engine_api_key",
              secret_state config.integrations.webhook.api_key );
            ( "webhook_engine_receiver_secret",
              secret_state config.integrations.webhook.receiver_secret );
          ] );
      ( "observability",
        `Assoc
          [
            ("sentry_dsn", secret_state config.observability.sentry_dsn);
            ("posthog_key", secret_state config.observability.posthog_key);
            ( "posthog_host",
              Option.fold ~none:`Null
                ~some:(fun uri -> `String (safe_uri uri))
                config.observability.posthog_host );
          ] );
    ]

let error_code_name = function
  | `Missing -> "missing"
  | `Invalid -> "invalid"
  | `Invariant -> "invariant"
  | `Required -> "required"

let errors_to_yojson errors =
  `List
    (List.map
       (fun error ->
         `Assoc
           [
             ("variable", `String error.variable);
             ("code", `String (error_code_name error.code));
             ("message", `String error.message);
           ])
       errors)
