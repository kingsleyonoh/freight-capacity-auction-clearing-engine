let load replacements = Config_test_support.load ~replacements ()

let require_error variable replacements =
  let variables = load replacements |> Config_test_support.error_variables in
  Alcotest.(check bool)
    (variable ^ " rejected") true
    (List.mem variable variables)

let absent_in text value =
  let value_length = String.length value in
  let rec contains index =
    index + value_length <= String.length text
    && (String.sub text index value_length = value || contains (index + 1))
  in
  Alcotest.(check bool) (value ^ " is redacted") false (contains 0)

let production replacements =
  replacements
  @ [
      ("APP_ENV", "production");
      ("APP_BASE_URL", "https://auction.example.com");
      ("NOTIFICATION_HUB_URL", "https://notification.example.com");
      ("WORKFLOW_ENGINE_URL", "https://workflow.example.com");
      ("WEBHOOK_ENGINE_URL", "https://webhook.example.com");
    ]

let test_receiver_secret_contract () =
  let blank =
    load [ ("WEBHOOK_ENGINE_RECEIVER_SECRET", "   ") ]
    |> Config_test_support.require_ok |> Runtime_config.integrations
  in
  Alcotest.(check (option reject))
    "blank receiver secret is absent" None blank.webhook.receiver_secret;
  require_error "WEBHOOK_ENGINE_RECEIVER_SECRET"
    [
      ("WEBHOOK_ENGINE_ENABLED", "true");
      ("WEBHOOK_ENGINE_API_KEY", "webhook-test-api-key");
      ("WEBHOOK_ENGINE_RECEIVER_SECRET", "");
    ];
  let secret = "receiver-secret-never-rendered" in
  let config =
    load [ ("WEBHOOK_ENGINE_RECEIVER_SECRET", secret) ]
    |> Config_test_support.require_ok
  in
  let configured =
    (Runtime_config.integrations config).webhook.receiver_secret
  in
  let observed =
    Option.fold ~none:false
      ~some:(fun value ->
        Runtime_config.Secret.with_value value (String.equal secret))
      configured
  in
  Alcotest.(check bool) "secret available only through callback" true observed;
  Runtime_config.redacted_summary config |> Yojson.Safe.to_string
  |> fun summary -> absent_in summary secret

let test_integration_timeout_budget () =
  [ "0"; "-1"; "1.5"; "301"; "999999999999999999999999" ]
  |> List.iter (fun value ->
      require_error "INTEGRATION_HTTP_TIMEOUT_SECONDS"
        [ ("INTEGRATION_HTTP_TIMEOUT_SECONDS", value) ]);
  [ 1; 300 ]
  |> List.iter (fun seconds ->
      let config =
        load [ ("INTEGRATION_HTTP_TIMEOUT_SECONDS", string_of_int seconds) ]
        |> Config_test_support.require_ok
      in
      let budget =
        float_of_int (Runtime_config.integrations config).http_timeout_seconds
      in
      let common attempt_timeout_s =
        Http_client.policy ~total_timeout_s:budget ~attempt_timeout_s
          ~max_attempts:1 ~initial_backoff_s:0. ~max_backoff_s:0.
          ~max_retry_after_s:0. ~max_request_bytes:1 ~max_response_bytes:1
      in
      Alcotest.(check bool)
        "configured seconds form a valid total policy budget" true
        (Result.is_ok (common budget));
      Alcotest.(check bool)
        "an attempt cannot exceed the configured total budget" true
        (Result.is_error (common (budget +. 0.001))))

let test_health_check_default_and_boolean () =
  let values =
    Config_test_support.with_values []
    |> List.remove_assoc "INTEGRATION_HEALTH_CHECK_ENABLED"
  in
  let config =
    Runtime_config.load ~get:(Config_test_support.get_from values)
    |> Config_test_support.require_ok
  in
  Alcotest.(check bool)
    "integration health checks default on" true
    (Runtime_config.integrations config).health_check_enabled;
  [ "TRUE"; "False"; "1"; "yes"; "" ]
  |> List.iter (fun value ->
      require_error "INTEGRATION_HEALTH_CHECK_ENABLED"
        [ ("INTEGRATION_HEALTH_CHECK_ENABLED", value) ])

let test_sentry_sensitive_optional_uri () =
  let blank =
    load [ ("SENTRY_DSN", "   ") ]
    |> Config_test_support.require_ok |> Runtime_config.observability
  in
  Alcotest.(check (option reject))
    "blank Sentry DSN is absent" None blank.sentry_dsn;
  [ "relative/dsn"; "ftp://sentry.example.com/1" ]
  |> List.iter (fun value ->
      require_error "SENTRY_DSN" [ ("SENTRY_DSN", value) ]);
  let password = "pw-marker" in
  let token = "query-marker" in
  let dsn =
    "https://public:" ^ password ^ "@sentry.example.com/1?token=" ^ token
  in
  let config = load [ ("SENTRY_DSN", dsn) ] |> Config_test_support.require_ok in
  let summary =
    Runtime_config.redacted_summary config |> Yojson.Safe.to_string
  in
  absent_in summary password;
  absent_in summary token;
  Alcotest.(check string)
    "Sentry summary exposes state only" "configured"
    (Runtime_config.redacted_summary config
    |> Yojson.Safe.Util.member "observability"
    |> Yojson.Safe.Util.member "sentry_dsn"
    |> Yojson.Safe.Util.to_string)

let test_otlp_optional_uri_and_production_https () =
  let blank =
    load [ ("OTEL_EXPORTER_OTLP_ENDPOINT", "   ") ]
    |> Config_test_support.require_ok |> Runtime_config.observability
  in
  Alcotest.(check (option string))
    "blank OTLP endpoint is absent" None
    (Option.map Uri.to_string blank.otel_exporter_otlp_endpoint);
  [ "collector:4318"; "/v1/traces"; "grpc://collector.example.com" ]
  |> List.iter (fun value ->
      require_error "OTEL_EXPORTER_OTLP_ENDPOINT"
        [ ("OTEL_EXPORTER_OTLP_ENDPOINT", value) ]);
  require_error "OTEL_EXPORTER_OTLP_ENDPOINT"
    (production
       [
         ( "OTEL_EXPORTER_OTLP_ENDPOINT",
           "http://collector.example.com/v1/traces" );
       ]);
  production
    [
      ("OTEL_EXPORTER_OTLP_ENDPOINT", "https://collector.example.com/v1/traces");
    ]
  |> load |> Config_test_support.require_ok |> ignore

let () =
  Alcotest.run "webhook and observability runtime config"
    [
      ( "configuration",
        [
          Alcotest.test_case "receiver secret" `Quick
            test_receiver_secret_contract;
          Alcotest.test_case "integration timeout budget" `Quick
            test_integration_timeout_budget;
          Alcotest.test_case "health check flag" `Quick
            test_health_check_default_and_boolean;
          Alcotest.test_case "Sentry DSN" `Quick
            test_sentry_sensitive_optional_uri;
          Alcotest.test_case "OTLP endpoint" `Quick
            test_otlp_optional_uri_and_production_https;
        ] );
    ]
