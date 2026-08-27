let expect_variable variable replacements =
  let variables =
    Config_test_support.load ~replacements ()
    |> Config_test_support.error_variables
  in
  Alcotest.(check bool)
    (variable ^ " rejected") true
    (List.mem variable variables)

let test_strict_booleans () =
  [
    "MIGRATIONS_AUTO_RUN";
    "SELF_REGISTRATION_ENABLED";
    "SEED_SAMPLE_DATA";
    "PRODUCTION_CLEARING_REQUIRES_SOLVER";
    "HEURISTIC_FALLBACK_FOR_REPLAY";
    "REPLAY_ALLOW_EXTERNAL_EVENTS";
    "NOTIFICATION_HUB_ENABLED";
    "NOTIFICATION_RETRY_ENABLED";
    "WORKFLOW_ENGINE_ENABLED";
    "WORKFLOW_STATUS_POLLING_ENABLED";
    "WEBHOOK_ENGINE_ENABLED";
    "INTEGRATION_HEALTH_CHECK_ENABLED";
    "METRICS_ENABLED";
  ]
  |> List.iter (fun variable -> expect_variable variable [ (variable, "TRUE") ])

let test_enums_and_boundaries () =
  expect_variable "APP_ENV" [ ("APP_ENV", "staging") ];
  expect_variable "LOG_LEVEL" [ ("LOG_LEVEL", "verbose") ];
  expect_variable "UNKNOWN_CARRIER_POLICY"
    [ ("UNKNOWN_CARRIER_POLICY", "accept") ];
  expect_variable "SOLVER_BACKEND" [ ("SOLVER_BACKEND", "heuristic") ];
  expect_variable "APP_PORT" [ ("APP_PORT", "0") ];
  expect_variable "APP_PORT" [ ("APP_PORT", "65536") ];
  expect_variable "MAX_CSV_UPLOAD_MB" [ ("MAX_CSV_UPLOAD_MB", "0") ];
  expect_variable "BID_LATE_GRACE_SECONDS" [ ("BID_LATE_GRACE_SECONDS", "-1") ];
  expect_variable "DEFAULT_SERVICE_RISK_CAP"
    [ ("DEFAULT_SERVICE_RISK_CAP", "-0.1") ];
  expect_variable "DEFAULT_MAX_CARRIER_SHARE"
    [ ("DEFAULT_MAX_CARRIER_SHARE", "0") ];
  expect_variable "DEFAULT_MAX_CARRIER_SHARE"
    [ ("DEFAULT_MAX_CARRIER_SHARE", "1.1") ]

let test_structured_values () =
  expect_variable "APP_BASE_URL" [ ("APP_BASE_URL", "localhost") ];
  expect_variable "DATABASE_URL" [ ("DATABASE_URL", "mysql://localhost/db") ];
  expect_variable "DATABASE_URL" [ ("DATABASE_URL", "postgresql:/relative") ];
  expect_variable "REDIS_URL" [ ("REDIS_URL", "http://localhost") ];
  expect_variable "REDIS_URL" [ ("REDIS_URL", "redis:/relative") ];
  expect_variable "REPLAY_STORE_PATH" [ ("REPLAY_STORE_PATH", "   ") ];
  expect_variable "DEFAULT_ADMIN_EMAIL"
    [ ("DEFAULT_ADMIN_EMAIL", "not-an-email") ];
  expect_variable "DEFAULT_CURRENCY" [ ("DEFAULT_CURRENCY", "usd") ];
  expect_variable "API_KEY_PREFIX" [ ("API_KEY_PREFIX", "bad prefix") ]

let without_values names =
  Config_test_support.with_values []
  |> List.filter (fun (name, _) -> not (List.mem name names))

let test_tenant_auth_defaults () =
  let defaults =
    Runtime_config.load
      ~get:
        (Config_test_support.get_from
           (without_values
              [
                "SELF_REGISTRATION_ENABLED";
                "DEFAULT_TENANT_NAME";
                "DEFAULT_ADMIN_EMAIL";
                "SEED_SAMPLE_DATA";
                "AUTH_TOKEN_TTL_MINUTES";
              ]))
    |> Config_test_support.require_ok
  in
  let tenant = Runtime_config.tenant defaults in
  Alcotest.(check bool)
    "self-hosted registration default" true tenant.self_registration_enabled;
  Alcotest.(check string)
    "tenant name default" "Default Freight Auction Tenant"
    tenant.default_tenant_name;
  Alcotest.(check string)
    "admin email default" "admin@example.com" tenant.default_admin_email;
  Alcotest.(check bool)
    "development sample-data default" true tenant.seed_sample_data;
  Alcotest.(check int)
    "auth TTL default" 60 (Runtime_config.auth defaults).token_ttl_minutes

let test_registration_requires_explicit_override () =
  let managed =
    Config_test_support.load
      ~replacements:
        [
          ("APP_ENV", "production");
          ("APP_BASE_URL", "https://auction.example.com");
          ("SELF_REGISTRATION_ENABLED", "false");
        ]
      ()
    |> Config_test_support.require_ok |> Runtime_config.tenant
  in
  Alcotest.(check bool)
    "managed hosting explicitly disables registration" false
    managed.self_registration_enabled;
  let production_values =
    without_values [ "SELF_REGISTRATION_ENABLED" ]
    |> List.remove_assoc "APP_ENV"
    |> List.remove_assoc "APP_BASE_URL"
    |> List.cons ("APP_ENV", "production")
    |> List.cons ("APP_BASE_URL", "https://auction.example.com")
  in
  let production_default =
    Runtime_config.load ~get:(Config_test_support.get_from production_values)
    |> Config_test_support.require_ok |> Runtime_config.tenant
  in
  Alcotest.(check bool)
    "deployment mode is not inferred" true
    production_default.self_registration_enabled

let test_tenant_identity_validation () =
  let normalized =
    Config_test_support.load
      ~replacements:[ ("DEFAULT_TENANT_NAME", "  Freight Desk  ") ]
      ()
    |> Config_test_support.require_ok |> Runtime_config.tenant
  in
  Alcotest.(check string)
    "tenant name trimmed" "Freight Desk" normalized.default_tenant_name;
  expect_variable "DEFAULT_TENANT_NAME" [ ("DEFAULT_TENANT_NAME", "   ") ];
  expect_variable "DEFAULT_ADMIN_EMAIL"
    [ ("DEFAULT_ADMIN_EMAIL", "admin@example") ]

let test_auth_ttl_boundaries () =
  [ "0"; "-1"; "10081"; "999999999999999999999999999999999999" ]
  |> List.iter (fun value ->
      expect_variable "AUTH_TOKEN_TTL_MINUTES"
        [ ("AUTH_TOKEN_TTL_MINUTES", value) ]);
  [ "1"; "10080" ]
  |> List.iter (fun value ->
      Config_test_support.load
        ~replacements:[ ("AUTH_TOKEN_TTL_MINUTES", value) ]
        ()
      |> Config_test_support.require_ok |> ignore)

let test_import_auth_formatting_and_bounds () =
  [
    "";
    "fca_";
    "fca-live";
    "fca.live";
    "fca_abcdefghijklmnopqrstuvwxyz0123456789";
  ]
  |> List.iter (fun value ->
      expect_variable "API_KEY_PREFIX" [ ("API_KEY_PREFIX", value) ]);
  [ "0"; "1025"; "999999999999999999999999999999999999" ]
  |> List.iter (fun value ->
      expect_variable "MAX_CSV_UPLOAD_MB" [ ("MAX_CSV_UPLOAD_MB", value) ]);
  [ "-1"; "86401"; "999999999999999999999999999999999999" ]
  |> List.iter (fun value ->
      expect_variable "BID_LATE_GRACE_SECONDS"
        [ ("BID_LATE_GRACE_SECONDS", value) ]);
  [ "usd"; "US"; "USDD"; "U1D" ]
  |> List.iter (fun value ->
      expect_variable "DEFAULT_CURRENCY" [ ("DEFAULT_CURRENCY", value) ]);
  [ "accept"; "skip"; "REJECT" ]
  |> List.iter (fun value ->
      expect_variable "UNKNOWN_CARRIER_POLICY"
        [ ("UNKNOWN_CARRIER_POLICY", value) ]);
  [
    ("API_KEY_PREFIX", "fca_a");
    ("API_KEY_PREFIX", "fca_abcdefghijklmnopqrstuvwxyz01");
    ("MAX_CSV_UPLOAD_MB", "1");
    ("MAX_CSV_UPLOAD_MB", "1024");
    ("BID_LATE_GRACE_SECONDS", "0");
    ("BID_LATE_GRACE_SECONDS", "86400");
    ("DEFAULT_CURRENCY", " EUR ");
    ("UNKNOWN_CARRIER_POLICY", " quarantine ");
  ]
  |> List.iter (fun replacement ->
      Config_test_support.load ~replacements:[ replacement ] ()
      |> Config_test_support.require_ok |> ignore);
  let defaults =
    Runtime_config.load
      ~get:
        (Config_test_support.get_from
           (without_values
              [
                "API_KEY_PREFIX";
                "MAX_CSV_UPLOAD_MB";
                "DEFAULT_CURRENCY";
                "BID_LATE_GRACE_SECONDS";
                "UNKNOWN_CARRIER_POLICY";
              ]))
    |> Config_test_support.require_ok
  in
  let auth = Runtime_config.auth defaults
  and import = Runtime_config.import defaults in
  Alcotest.(check string)
    "safe formatting prefix default" "fca_live" auth.api_key_prefix;
  Alcotest.(check int) "upload default" 50 import.max_csv_upload_mb;
  Alcotest.(check string)
    "single-currency code default" "USD" import.default_currency;
  Alcotest.(check int)
    "closed late grace default" 0 import.bid_late_grace_seconds;
  Alcotest.(check bool)
    "unknown carriers reject by default" true
    (import.unknown_carrier_policy = `Reject)

let test_solver_configuration_contract () =
  [ "heuristic"; "MINIZINC"; "" ]
  |> List.iter (fun value ->
      expect_variable "SOLVER_BACKEND" [ ("SOLVER_BACKEND", value) ]);
  [
    "0";
    "-1";
    "1.5";
    "3601";
    "nan";
    "inf";
    "999999999999999999999999999999999999";
  ]
  |> List.iter (fun value ->
      expect_variable "SOLVER_TIMEOUT_SECONDS"
        [ ("SOLVER_TIMEOUT_SECONDS", value) ]);
  [ "1"; "3600" ]
  |> List.iter (fun value ->
      Config_test_support.load
        ~replacements:[ ("SOLVER_TIMEOUT_SECONDS", value) ]
        ()
      |> Config_test_support.require_ok |> ignore);
  expect_variable "MINIZINC_BINARY_PATH" [ ("MINIZINC_BINARY_PATH", "   ") ];
  let config = Config_test_support.load () |> Config_test_support.require_ok in
  let solver = Runtime_config.solver config in
  Alcotest.(check bool)
    "MiniZinc selected explicitly" true
    (solver.backend = `Minizinc);
  Alcotest.(check int) "bounded process deadline" 30 solver.timeout_seconds;
  Alcotest.(check bool)
    "production requires a real solver" true
    solver.production_clearing_requires_solver;
  Alcotest.(check bool)
    "replay fallback is typed and enabled" true
    solver.heuristic_fallback_for_replay;
  Alcotest.(check string)
    "safe MiniZinc command" "minizinc" solver.minizinc_binary_path;
  Alcotest.(check (option string))
    "blank OR-Tools path normalizes" None solver.ortools_worker_path;
  expect_variable "ORTOOLS_WORKER_PATH"
    [ ("SOLVER_BACKEND", "ortools"); ("ORTOOLS_WORKER_PATH", "") ]

let test_replay_and_policy_limits_are_strict () =
  [ "0"; "-1"; "10000001"; "999999999999999999999999999999999999" ]
  |> List.iter (fun value ->
      expect_variable "REPLAY_MAX_ROWS" [ ("REPLAY_MAX_ROWS", value) ]);
  [ "1"; "10000000" ]
  |> List.iter (fun value ->
      Config_test_support.load ~replacements:[ ("REPLAY_MAX_ROWS", value) ] ()
      |> Config_test_support.require_ok |> ignore);
  [ "nan"; "inf"; "-inf"; "-0.1"; "1.1" ]
  |> List.iter (fun value ->
      expect_variable "DEFAULT_SERVICE_RISK_CAP"
        [ ("DEFAULT_SERVICE_RISK_CAP", value) ]);
  [ "nan"; "inf"; "-inf"; "0"; "-0.1"; "1.1" ]
  |> List.iter (fun value ->
      expect_variable "DEFAULT_MAX_CARRIER_SHARE"
        [ ("DEFAULT_MAX_CARRIER_SHARE", value) ]);
  let defaults =
    Runtime_config.load
      ~get:
        (Config_test_support.get_from
           (without_values
              [
                "REPLAY_MAX_ROWS";
                "REPLAY_ALLOW_EXTERNAL_EVENTS";
                "DEFAULT_SERVICE_RISK_CAP";
                "DEFAULT_MAX_CARRIER_SHARE";
              ]))
    |> Config_test_support.require_ok
  in
  let solver = Runtime_config.solver defaults
  and policy = Runtime_config.policy defaults in
  Alcotest.(check int)
    "default replay row budget" 1_000_000 solver.replay_max_rows;
  Alcotest.(check bool)
    "external replay events default closed" false
    solver.replay_allow_external_events;
  Alcotest.(check (float 0.))
    "default service risk cap" 0.15 policy.default_service_risk_cap;
  Alcotest.(check (float 0.))
    "default carrier share" 0.30 policy.default_max_carrier_share;
  let configured =
    Config_test_support.load
      ~replacements:
        [
          ("REPLAY_MAX_ROWS", "17");
          ("DEFAULT_SERVICE_RISK_CAP", "0");
          ("DEFAULT_MAX_CARRIER_SHARE", "1");
        ]
      ()
    |> Config_test_support.require_ok
  in
  Alcotest.(check int)
    "configured row budget retained without clamping" 17
    (Runtime_config.solver configured).replay_max_rows;
  Alcotest.(check (float 0.))
    "inclusive zero risk cap" 0.
    (Runtime_config.policy configured).default_service_risk_cap;
  Alcotest.(check (float 0.))
    "inclusive carrier share upper bound" 1.
    (Runtime_config.policy configured).default_max_carrier_share

let test_retention_and_approval_limits_are_strict () =
  let limits =
    [
      ("APPROVAL_EXPIRY_HOURS", 8_760);
      ("AUDIT_RETENTION_DAYS", 36_500);
      ("SOLVER_ARTIFACT_RETENTION_DAYS", 3_650);
    ]
  in
  limits
  |> List.iter (fun (variable, maximum) ->
      [
        "0";
        "-1";
        string_of_int (maximum + 1);
        "999999999999999999999999999999999999";
      ]
      |> List.iter (fun value -> expect_variable variable [ (variable, value) ]);
      [ "1"; string_of_int maximum ]
      |> List.iter (fun value ->
          Config_test_support.load ~replacements:[ (variable, value) ] ()
          |> Config_test_support.require_ok |> ignore));
  let defaults =
    Runtime_config.load
      ~get:
        (Config_test_support.get_from
           (without_values
              [
                "APPROVAL_EXPIRY_HOURS";
                "AUDIT_RETENTION_DAYS";
                "SOLVER_ARTIFACT_RETENTION_DAYS";
              ]))
    |> Config_test_support.require_ok |> Runtime_config.policy
  in
  Alcotest.(check int)
    "approval expiry default" 24 defaults.approval_expiry_hours;
  Alcotest.(check int)
    "audit retention default" 365 defaults.audit_retention_days;
  Alcotest.(check int)
    "solver artifact retention default" 90
    defaults.solver_artifact_retention_days

let test_notification_hub_defaults_and_url_validation () =
  let defaults =
    Runtime_config.load
      ~get:
        (Config_test_support.get_from
           (without_values
              [ "NOTIFICATION_HUB_ENABLED"; "NOTIFICATION_HUB_URL" ]))
    |> Config_test_support.require_ok
  in
  let notification = (Runtime_config.integrations defaults).notification in
  Alcotest.(check bool) "Hub disabled by default" false notification.enabled;
  Alcotest.(check string)
    "safe local URL default" "http://localhost:3847"
    (Uri.to_string notification.url);
  [ "localhost:3847"; "/relative"; "ftp://notification.example.com" ]
  |> List.iter (fun value ->
      expect_variable "NOTIFICATION_HUB_URL"
        [
          ("NOTIFICATION_HUB_ENABLED", "false"); ("NOTIFICATION_HUB_URL", value);
        ])

let test_optional_adapter_keys_and_workflow_defaults () =
  let defaults =
    Runtime_config.load
      ~get:
        (Config_test_support.get_from
           (without_values
              [
                "NOTIFICATION_HUB_API_KEY";
                "WORKFLOW_ENGINE_ENABLED";
                "WORKFLOW_ENGINE_URL";
                "WORKFLOW_ENGINE_API_KEY";
              ]))
    |> Config_test_support.require_ok |> Runtime_config.integrations
  in
  Alcotest.(check (option reject))
    "missing Hub key is absent" None defaults.notification.api_key;
  Alcotest.(check bool)
    "Workflow Engine disabled by default" false defaults.workflow.enabled;
  Alcotest.(check string)
    "safe Workflow URL default" "http://localhost:8000"
    (Uri.to_string defaults.workflow.url);
  Alcotest.(check (option reject))
    "missing Workflow key is absent" None defaults.workflow.api_key;
  let blank =
    Config_test_support.load
      ~replacements:
        [
          ("NOTIFICATION_HUB_API_KEY", "   "); ("WORKFLOW_ENGINE_API_KEY", "   ");
        ]
      ()
    |> Config_test_support.require_ok |> Runtime_config.integrations
  in
  Alcotest.(check (option reject))
    "blank Hub key normalizes to absent" None blank.notification.api_key;
  Alcotest.(check (option reject))
    "blank Workflow key normalizes to absent" None blank.workflow.api_key;
  [ "localhost:8000"; "/relative"; "ftp://workflow.example.com" ]
  |> List.iter (fun value ->
      expect_variable "WORKFLOW_ENGINE_URL"
        [ ("WORKFLOW_ENGINE_ENABLED", "false"); ("WORKFLOW_ENGINE_URL", value) ])

let test_workflow_and_webhook_configuration_contract () =
  let defaults =
    Runtime_config.load
      ~get:
        (Config_test_support.get_from
           (without_values
              [
                "WORKFLOW_HIGH_VALUE_APPROVAL_ID";
                "WORKFLOW_STATUS_POLLING_ENABLED";
                "WEBHOOK_ENGINE_ENABLED";
                "WEBHOOK_ENGINE_URL";
                "WEBHOOK_ENGINE_API_KEY";
              ]))
    |> Config_test_support.require_ok |> Runtime_config.integrations
  in
  Alcotest.(check (option string))
    "workflow ID defaults absent" None defaults.workflow.high_value_approval_id;
  Alcotest.(check bool)
    "workflow polling defaults configured on" true
    defaults.workflow.status_polling_enabled;
  Alcotest.(check bool)
    "Webhook Engine disabled by default" false defaults.webhook.enabled;
  Alcotest.(check string)
    "safe Webhook URL default" "http://localhost:3000"
    (Uri.to_string defaults.webhook.url);
  Alcotest.(check (option reject))
    "missing Webhook API key is absent" None defaults.webhook.api_key;
  let configured =
    Config_test_support.load
      ~replacements:
        [
          ("WORKFLOW_HIGH_VALUE_APPROVAL_ID", "  wf.high-value_2026-07  ");
          ("WEBHOOK_ENGINE_API_KEY", "   ");
        ]
      ()
    |> Config_test_support.require_ok |> Runtime_config.integrations
  in
  Alcotest.(check (option string))
    "safe workflow ID retained and trimmed" (Some "wf.high-value_2026-07")
    configured.workflow.high_value_approval_id;
  Alcotest.(check (option reject))
    "blank Webhook API key normalizes to absent" None configured.webhook.api_key;
  [
    "workflow/id";
    ".relative";
    "contains space";
    "workflow?id=value";
    String.make 129 'a';
  ]
  |> List.iter (fun value ->
      expect_variable "WORKFLOW_HIGH_VALUE_APPROVAL_ID"
        [ ("WORKFLOW_HIGH_VALUE_APPROVAL_ID", value) ]);
  [ "localhost:3000"; "/relative"; "ftp://webhook.example.com" ]
  |> List.iter (fun value ->
      expect_variable "WEBHOOK_ENGINE_URL"
        [ ("WEBHOOK_ENGINE_ENABLED", "false"); ("WEBHOOK_ENGINE_URL", value) ])

let test_solver_defaults_are_explicit_and_replay_scoped () =
  let defaults =
    Runtime_config.load
      ~get:
        (Config_test_support.get_from
           (without_values
              [
                "SOLVER_BACKEND";
                "SOLVER_TIMEOUT_SECONDS";
                "PRODUCTION_CLEARING_REQUIRES_SOLVER";
                "HEURISTIC_FALLBACK_FOR_REPLAY";
                "MINIZINC_BINARY_PATH";
              ]))
    |> Config_test_support.require_ok |> Runtime_config.solver
  in
  Alcotest.(check bool)
    "default selected backend" true
    (defaults.backend = `Minizinc);
  Alcotest.(check int) "default deadline" 30 defaults.timeout_seconds;
  Alcotest.(check bool)
    "production solver required by default" true
    defaults.production_clearing_requires_solver;
  Alcotest.(check bool)
    "replay fallback enabled by default" true
    defaults.heuristic_fallback_for_replay;
  Alcotest.(check string)
    "default MiniZinc command" "minizinc" defaults.minizinc_binary_path

let test_data_normalization_and_defaults () =
  let normalized =
    Config_test_support.load
      ~replacements:[ ("REPLAY_STORE_PATH", "  ./data/normalized.duckdb  ") ]
      ()
    |> Config_test_support.require_ok |> Runtime_config.data
  in
  Alcotest.(check string)
    "replay path trimmed" "./data/normalized.duckdb"
    normalized.replay_store_path;
  let values =
    Config_test_support.with_values []
    |> List.remove_assoc "MIGRATIONS_AUTO_RUN"
  in
  let without_migrations =
    Runtime_config.load ~get:(Config_test_support.get_from values)
    |> Config_test_support.require_ok |> Runtime_config.data
  in
  Alcotest.(check bool)
    "migration auto-run defaults off" false
    without_migrations.migrations_auto_run

let () =
  Alcotest.run "runtime config validation"
    [
      ( "validation",
        [
          Alcotest.test_case "strict booleans" `Quick test_strict_booleans;
          Alcotest.test_case "enums and boundaries" `Quick
            test_enums_and_boundaries;
          Alcotest.test_case "structured values" `Quick test_structured_values;
          Alcotest.test_case "tenant and auth defaults" `Quick
            test_tenant_auth_defaults;
          Alcotest.test_case "registration override" `Quick
            test_registration_requires_explicit_override;
          Alcotest.test_case "tenant identity validation" `Quick
            test_tenant_identity_validation;
          Alcotest.test_case "auth TTL boundaries" `Quick
            test_auth_ttl_boundaries;
          Alcotest.test_case "import/auth formatting and bounds" `Quick
            test_import_auth_formatting_and_bounds;
          Alcotest.test_case "solver configuration contract" `Quick
            test_solver_configuration_contract;
          Alcotest.test_case "replay and policy limits" `Quick
            test_replay_and_policy_limits_are_strict;
          Alcotest.test_case "retention and approval limits" `Quick
            test_retention_and_approval_limits_are_strict;
          Alcotest.test_case "Notification Hub defaults and URL" `Quick
            test_notification_hub_defaults_and_url_validation;
          Alcotest.test_case "optional keys and Workflow defaults" `Quick
            test_optional_adapter_keys_and_workflow_defaults;
          Alcotest.test_case "Workflow/Webhook configuration" `Quick
            test_workflow_and_webhook_configuration_contract;
          Alcotest.test_case "solver defaults" `Quick
            test_solver_defaults_are_explicit_and_replay_scoped;
          Alcotest.test_case "data normalization and defaults" `Quick
            test_data_normalization_and_defaults;
        ] );
    ]
