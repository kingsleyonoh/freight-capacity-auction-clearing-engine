let expect_error variable replacements =
  let variables =
    Config_test_support.load ~replacements ()
    |> Config_test_support.error_variables
  in
  Alcotest.(check bool) (variable ^ " error") true (List.mem variable variables)

let production_values extra =
  extra
  @ [
      ("APP_ENV", "production");
      ("APP_BASE_URL", "https://auction.example.com");
      ("NOTIFICATION_HUB_URL", "https://notification.example.com");
      ("WORKFLOW_ENGINE_URL", "https://workflow.example.com");
      ("WEBHOOK_ENGINE_URL", "https://webhook.example.com");
    ]

let test_production_invariants () =
  expect_error "APP_BASE_URL"
    [
      ("APP_ENV", "production"); ("APP_BASE_URL", "http://auction.example.com");
    ];
  expect_error "PRODUCTION_CLEARING_REQUIRES_SOLVER"
    (production_values [ ("PRODUCTION_CLEARING_REQUIRES_SOLVER", "false") ]);
  expect_error "REPLAY_ALLOW_EXTERNAL_EVENTS"
    [ ("REPLAY_ALLOW_EXTERNAL_EVENTS", "true") ];
  expect_error "SECRET_KEY_BASE"
    (production_values [ ("SECRET_KEY_BASE", "replace-me") ])

let test_replay_external_events_fail_closed_in_every_environment () =
  [
    ("development", "http://localhost:8080");
    ("test", "http://localhost:8080");
    ("production", "https://auction.example.com");
  ]
  |> List.iter (fun (environment, base_url) ->
      expect_error "REPLAY_ALLOW_EXTERNAL_EVENTS"
        [
          ("APP_ENV", environment);
          ("APP_BASE_URL", base_url);
          ("REPLAY_ALLOW_EXTERNAL_EVENTS", "true");
        ])

let test_adapter_credentials () =
  expect_error "NOTIFICATION_HUB_API_KEY"
    [ ("NOTIFICATION_HUB_ENABLED", "true"); ("NOTIFICATION_HUB_API_KEY", "") ];
  expect_error "WORKFLOW_ENGINE_API_KEY"
    [ ("WORKFLOW_ENGINE_ENABLED", "true"); ("WORKFLOW_ENGINE_API_KEY", "") ];
  Config_test_support.load
    ~replacements:
      [
        ("NOTIFICATION_HUB_ENABLED", "false");
        ("NOTIFICATION_HUB_API_KEY", "");
        ("WORKFLOW_ENGINE_ENABLED", "false");
        ("WORKFLOW_ENGINE_API_KEY", "");
      ]
    ()
  |> Config_test_support.require_ok |> ignore;
  let webhook =
    [
      ("WEBHOOK_ENGINE_ENABLED", "true");
      ("WEBHOOK_ENGINE_API_KEY", "");
      ("WEBHOOK_ENGINE_RECEIVER_SECRET", "");
    ]
  in
  let errors =
    Config_test_support.load ~replacements:webhook ()
    |> Config_test_support.error_variables
  in
  Alcotest.(check bool)
    "webhook API key required" true
    (List.mem "WEBHOOK_ENGINE_API_KEY" errors);
  Alcotest.(check bool)
    "receiver secret required" true
    (List.mem "WEBHOOK_ENGINE_RECEIVER_SECRET" errors)

let test_notification_hub_https_in_production () =
  expect_error "NOTIFICATION_HUB_URL"
    (production_values
       [
         ("NOTIFICATION_HUB_ENABLED", "true");
         ("NOTIFICATION_HUB_API_KEY", "hub-test-key");
         ("NOTIFICATION_HUB_URL", "http://notification.example.com");
       ])

let test_workflow_https_in_production () =
  expect_error "WORKFLOW_ENGINE_URL"
    (production_values
       [
         ("WORKFLOW_ENGINE_ENABLED", "true");
         ("WORKFLOW_ENGINE_API_KEY", "workflow-test-key");
         ("WORKFLOW_ENGINE_URL", "http://workflow.example.com");
       ])

let test_webhook_https_in_production () =
  expect_error "WEBHOOK_ENGINE_URL"
    (production_values
       [
         ("WEBHOOK_ENGINE_ENABLED", "true");
         ("WEBHOOK_ENGINE_API_KEY", "webhook-test-key");
         ("WEBHOOK_ENGINE_RECEIVER_SECRET", "receiver-test-secret");
         ("WEBHOOK_ENGINE_URL", "http://webhook.example.com");
       ])

let test_posthog_dependency () =
  expect_error "POSTHOG_HOST"
    [ ("POSTHOG_KEY", "test-posthog-key"); ("POSTHOG_HOST", "") ]

let assert_absent rendered value =
  Alcotest.(check bool)
    "sensitive value redacted" false
    (String.starts_with ~prefix:value rendered
    ||
    let value_length = String.length value in
    let rec contains index =
      index + value_length <= String.length rendered
      && (String.sub rendered index value_length = value || contains (index + 1))
    in
    contains 0)

let test_adapter_errors_are_value_free () =
  [
    ("NOTIFICATION_HUB_URL", "ftp://notification.example.com");
    ("WORKFLOW_ENGINE_URL", "ftp://workflow.example.com");
  ]
  |> List.iter (fun (variable, base) ->
      let supplied = base ^ "/private?token=must-not-leak" in
      let rendered =
        Config_test_support.load ~replacements:[ (variable, supplied) ] ()
        |> Config_test_support.rendered_errors
      in
      assert_absent rendered supplied;
      assert_absent rendered "must-not-leak")

let test_adapter_keys_are_abstract_and_redacted () =
  let hub_key = "hub-secret-must-not-leak" in
  let workflow_key = "workflow-secret-must-not-leak" in
  let config =
    Config_test_support.load
      ~replacements:
        [
          ("NOTIFICATION_HUB_API_KEY", hub_key);
          ("WORKFLOW_ENGINE_API_KEY", workflow_key);
        ]
      ()
    |> Config_test_support.require_ok
  in
  let integrations = Runtime_config.integrations config in
  let hub_seen =
    Option.fold ~none:false
      ~some:(fun secret ->
        Runtime_config.Secret.with_value secret (String.equal hub_key))
      integrations.notification.api_key
  and workflow_seen =
    Option.fold ~none:false
      ~some:(fun secret ->
        Runtime_config.Secret.with_value secret (String.equal workflow_key))
      integrations.workflow.api_key
  in
  Alcotest.(check bool) "Hub secret available only via callback" true hub_seen;
  Alcotest.(check bool)
    "Workflow secret available only via callback" true workflow_seen;
  let summary_json = Runtime_config.redacted_summary config in
  let summary = Yojson.Safe.to_string summary_json in
  assert_absent summary hub_key;
  assert_absent summary workflow_key;
  let integrations_json = Yojson.Safe.Util.member "integrations" summary_json in
  Alcotest.(check string)
    "Hub summary is state only" "configured"
    (Yojson.Safe.Util.member "notification_hub_api_key" integrations_json
    |> Yojson.Safe.Util.to_string);
  Alcotest.(check string)
    "Workflow summary is state only" "configured"
    (Yojson.Safe.Util.member "workflow_engine_api_key" integrations_json
    |> Yojson.Safe.Util.to_string)

let test_webhook_api_key_is_abstract_and_redacted () =
  let api_key = "webhook-api-key-must-not-leak" in
  let config =
    Config_test_support.load
      ~replacements:[ ("WEBHOOK_ENGINE_API_KEY", api_key) ]
      ()
    |> Config_test_support.require_ok
  in
  let webhook = (Runtime_config.integrations config).webhook in
  let seen =
    Option.fold ~none:false
      ~some:(fun secret ->
        Runtime_config.Secret.with_value secret (String.equal api_key))
      webhook.api_key
  in
  Alcotest.(check bool) "Webhook key available only via callback" true seen;
  let summary_json = Runtime_config.redacted_summary config in
  let summary = Yojson.Safe.to_string summary_json in
  assert_absent summary api_key;
  Alcotest.(check string)
    "Webhook summary is state only" "configured"
    (Yojson.Safe.Util.member "integrations" summary_json
    |> Yojson.Safe.Util.member "webhook_engine_api_key"
    |> Yojson.Safe.Util.to_string);
  Config_test_support.load
    ~replacements:
      [ ("WEBHOOK_ENGINE_ENABLED", "false"); ("WEBHOOK_ENGINE_API_KEY", "   ") ]
    ()
  |> Config_test_support.require_ok |> ignore

let test_default_admin_email_is_non_credential_metadata () =
  let email = "config-admin@example.com" in
  let config =
    Config_test_support.load ~replacements:[ ("DEFAULT_ADMIN_EMAIL", email) ] ()
    |> Config_test_support.require_ok
  in
  Alcotest.(check string)
    "admin contact retained as typed metadata" email
    (Runtime_config.tenant config).default_admin_email;
  Runtime_config.redacted_summary config |> Yojson.Safe.to_string
  |> fun summary ->
  assert_absent summary email;
  let invalid = "not-a-secret-admin-email" in
  let rendered =
    Config_test_support.load
      ~replacements:[ ("DEFAULT_ADMIN_EMAIL", invalid) ]
      ()
    |> Config_test_support.rendered_errors
  in
  assert_absent rendered invalid

let test_redacted_errors_and_summary () =
  let invalid_secret = "supplied-secret-must-never-appear" in
  let rendered_errors =
    Config_test_support.load
      ~replacements:[ ("DATABASE_URL", invalid_secret) ]
      ()
    |> Config_test_support.rendered_errors
  in
  assert_absent rendered_errors invalid_secret;
  let values =
    [
      ( "DATABASE_URL",
        "postgresql://user:"
        ^ "db-password@localhost:5432/fca?token=db-query-token" );
      ( "REDIS_URL",
        "redis://:" ^ "redis-password@localhost:6379/0?token=redis-query-token"
      );
      ( "SENTRY_DSN",
        "https://sentry-user:sentry-password@sentry.example.com/1?token=sentry-token"
      );
      ("POSTHOG_KEY", "posthog-secret-key");
      ("POSTHOG_HOST", "https://posthog.example.com?token=posthog-query-token");
    ]
  in
  let config =
    Config_test_support.load ~replacements:values ()
    |> Config_test_support.require_ok
  in
  let summary =
    Runtime_config.redacted_summary config |> Yojson.Safe.to_string
  in
  [
    "db-password";
    "db-query-token";
    "redis-password";
    "redis-query-token";
    "sentry-password";
    "sentry-token";
    "posthog-secret-key";
    "posthog-query-token";
  ]
  |> List.iter (assert_absent summary)

let () =
  Alcotest.run "runtime config security"
    [
      ( "security",
        [
          Alcotest.test_case "production invariants" `Quick
            test_production_invariants;
          Alcotest.test_case "replay events fail closed" `Quick
            test_replay_external_events_fail_closed_in_every_environment;
          Alcotest.test_case "adapter credentials" `Quick
            test_adapter_credentials;
          Alcotest.test_case "Notification Hub HTTPS" `Quick
            test_notification_hub_https_in_production;
          Alcotest.test_case "Workflow Engine HTTPS" `Quick
            test_workflow_https_in_production;
          Alcotest.test_case "Webhook Engine HTTPS" `Quick
            test_webhook_https_in_production;
          Alcotest.test_case "adapter error redaction" `Quick
            test_adapter_errors_are_value_free;
          Alcotest.test_case "adapter key redaction" `Quick
            test_adapter_keys_are_abstract_and_redacted;
          Alcotest.test_case "Webhook API key redaction" `Quick
            test_webhook_api_key_is_abstract_and_redacted;
          Alcotest.test_case "PostHog host" `Quick test_posthog_dependency;
          Alcotest.test_case "admin email metadata" `Quick
            test_default_admin_email_is_non_credential_metadata;
          Alcotest.test_case "redacted output" `Quick
            test_redacted_errors_and_summary;
        ] );
    ]
