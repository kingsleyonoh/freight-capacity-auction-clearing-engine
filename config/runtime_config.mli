module Secret : sig
  type t

  val with_value : t -> (string -> 'a) -> 'a
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

type t

val known_variables : string list
val load : get:(string -> string option) -> (t, validation_error list) result
val from_process_env : unit -> (t, validation_error list) result
val app : t -> app_config
val data : t -> data_config
val tenant : t -> tenant_config
val auth : t -> auth_config
val import : t -> import_config
val solver : t -> solver_config
val policy : t -> policy_config
val integrations : t -> integrations_config
val observability : t -> observability_config
val redacted_summary : t -> Yojson.Safe.t
val errors_to_yojson : validation_error list -> Yojson.Safe.t
