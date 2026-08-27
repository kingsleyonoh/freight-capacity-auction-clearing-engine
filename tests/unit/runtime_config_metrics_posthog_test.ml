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

let test_metrics_strict_boolean_and_default () =
  let values =
    Config_test_support.with_values [] |> List.remove_assoc "METRICS_ENABLED"
  in
  let default =
    Runtime_config.load ~get:(Config_test_support.get_from values)
    |> Config_test_support.require_ok |> Runtime_config.observability
  in
  Alcotest.(check bool) "metrics default enabled" true default.metrics_enabled;
  [ "TRUE"; "False"; "1"; "yes"; "" ]
  |> List.iter (fun value ->
      require_error "METRICS_ENABLED" [ ("METRICS_ENABLED", value) ]);
  let disabled =
    load [ ("METRICS_ENABLED", "false") ]
    |> Config_test_support.require_ok |> Runtime_config.observability
  in
  Alcotest.(check bool) "explicit false retained" false disabled.metrics_enabled

let test_posthog_key_is_optional_abstract_and_redacted () =
  let blank =
    load [ ("POSTHOG_KEY", "   ") ]
    |> Config_test_support.require_ok |> Runtime_config.observability
  in
  Alcotest.(check (option reject)) "blank key is absent" None blank.posthog_key;
  let key = "posthog-test-key-never-rendered" in
  let config =
    load
      [ ("POSTHOG_KEY", key); ("POSTHOG_HOST", "https://posthog.example.com") ]
    |> Config_test_support.require_ok
  in
  let observed =
    Option.fold ~none:false
      ~some:(fun secret ->
        Runtime_config.Secret.with_value secret (String.equal key))
      (Runtime_config.observability config).posthog_key
  in
  Alcotest.(check bool) "key available only through callback" true observed;
  let summary =
    Runtime_config.redacted_summary config |> Yojson.Safe.to_string
  in
  absent_in summary key;
  Alcotest.(check string)
    "key summary is state only" "configured"
    (Runtime_config.redacted_summary config
    |> Yojson.Safe.Util.member "observability"
    |> Yojson.Safe.Util.member "posthog_key"
    |> Yojson.Safe.Util.to_string)

let test_posthog_host_optional_uri_and_production_https () =
  let blank =
    load [ ("POSTHOG_HOST", "   ") ]
    |> Config_test_support.require_ok |> Runtime_config.observability
  in
  Alcotest.(check (option string))
    "blank host is absent" None
    (Option.map Uri.to_string blank.posthog_host);
  [ "posthog.example.com"; "/relative"; "ftp://posthog.example.com" ]
  |> List.iter (fun value ->
      require_error "POSTHOG_HOST" [ ("POSTHOG_HOST", value) ]);
  require_error "POSTHOG_HOST"
    (production [ ("POSTHOG_HOST", "http://posthog.example.com") ]);
  production [ ("POSTHOG_HOST", "https://posthog.example.com") ]
  |> load |> Config_test_support.require_ok |> ignore

let test_posthog_key_host_dependency () =
  require_error "POSTHOG_HOST"
    [ ("POSTHOG_KEY", "posthog-test-key"); ("POSTHOG_HOST", "") ];
  let host_only =
    load
      [ ("POSTHOG_KEY", ""); ("POSTHOG_HOST", "https://posthog.example.com") ]
    |> Config_test_support.require_ok |> Runtime_config.observability
  in
  Alcotest.(check (option reject))
    "host does not imply a key" None host_only.posthog_key;
  Alcotest.(check (option string))
    "host-only configuration is allowed" (Some "https://posthog.example.com")
    (Option.map Uri.to_string host_only.posthog_host)

let test_posthog_summary_strips_sensitive_uri_parts () =
  let token = "posthog-query-marker" in
  let config =
    load
      [ ("POSTHOG_HOST", "https://posthog.example.com/capture?token=" ^ token) ]
    |> Config_test_support.require_ok
  in
  let summary =
    Runtime_config.redacted_summary config |> Yojson.Safe.to_string
  in
  absent_in summary token;
  Alcotest.(check string)
    "summary retains only safe host path" "https://posthog.example.com/capture"
    (Runtime_config.redacted_summary config
    |> Yojson.Safe.Util.member "observability"
    |> Yojson.Safe.Util.member "posthog_host"
    |> Yojson.Safe.Util.to_string)

let () =
  Alcotest.run "metrics and PostHog runtime config"
    [
      ( "configuration",
        [
          Alcotest.test_case "metrics boolean" `Quick
            test_metrics_strict_boolean_and_default;
          Alcotest.test_case "PostHog key" `Quick
            test_posthog_key_is_optional_abstract_and_redacted;
          Alcotest.test_case "PostHog host" `Quick
            test_posthog_host_optional_uri_and_production_https;
          Alcotest.test_case "PostHog dependency" `Quick
            test_posthog_key_host_dependency;
          Alcotest.test_case "PostHog summary" `Quick
            test_posthog_summary_strips_sensitive_uri_parts;
        ] );
    ]
