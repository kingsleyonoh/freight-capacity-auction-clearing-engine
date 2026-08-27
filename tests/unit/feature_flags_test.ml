let flags replacements =
  Config_test_support.load ~replacements ()
  |> Config_test_support.require_ok |> Feature_flags.of_runtime_config

let test_disabled_by_default () =
  let flags = flags [] in
  Alcotest.(check bool) "notification disabled" false flags.notification_hub;
  Alcotest.(check bool)
    "notification retry ineffective" false flags.notification_retry;
  Alcotest.(check bool) "workflow disabled" false flags.workflow_engine;
  Alcotest.(check bool)
    "workflow polling ineffective" false flags.workflow_status_polling;
  Alcotest.(check bool) "webhook disabled" false flags.webhook_engine

let test_subordinate_flags_require_parent () =
  let flags =
    flags
      [
        ("NOTIFICATION_RETRY_ENABLED", "true");
        ("WORKFLOW_STATUS_POLLING_ENABLED", "true");
      ]
  in
  Alcotest.(check bool) "retry remains off" false flags.notification_retry;
  Alcotest.(check bool)
    "polling remains off" false flags.workflow_status_polling

let test_valid_enabled_adapters () =
  let enabled =
    flags
      [
        ("NOTIFICATION_HUB_ENABLED", "true");
        ("NOTIFICATION_HUB_API_KEY", "test-notification-key");
        ("WORKFLOW_ENGINE_ENABLED", "true");
        ("WORKFLOW_ENGINE_API_KEY", "test-workflow-key");
      ]
  in
  Alcotest.(check bool) "hub enabled" true enabled.notification_hub;
  Alcotest.(check bool) "retry effective" true enabled.notification_retry;
  Alcotest.(check bool) "workflow enabled" true enabled.workflow_engine;
  Alcotest.(check bool)
    "polling effective under enabled Workflow Engine" true
    enabled.workflow_status_polling;
  let no_polling =
    flags
      [
        ("WORKFLOW_ENGINE_ENABLED", "true");
        ("WORKFLOW_ENGINE_API_KEY", "test-workflow-key");
        ("WORKFLOW_STATUS_POLLING_ENABLED", "false");
      ]
  in
  Alcotest.(check bool)
    "strict false disables polling under enabled Workflow Engine" false
    no_polling.workflow_status_polling;
  let no_retry =
    flags
      [
        ("NOTIFICATION_HUB_ENABLED", "true");
        ("NOTIFICATION_HUB_API_KEY", "test-notification-key");
        ("NOTIFICATION_RETRY_ENABLED", "false");
      ]
  in
  Alcotest.(check bool)
    "strict false disables retry under enabled Hub" false
    no_retry.notification_retry

let test_heuristic_fallback_has_no_production_authority () =
  let enabled = flags [ ("HEURISTIC_FALLBACK_FOR_REPLAY", "true") ] in
  Alcotest.(check bool)
    "scenario replay may use configured fallback" true
    (Feature_flags.heuristic_fallback_allowed enabled `Scenario_replay);
  Alcotest.(check bool)
    "local diagnostics may use configured fallback" true
    (Feature_flags.heuristic_fallback_allowed enabled `Local_diagnostic);
  Alcotest.(check bool)
    "production clearing never gains heuristic authority" false
    (Feature_flags.heuristic_fallback_allowed enabled `Production_clearing);
  let disabled = flags [ ("HEURISTIC_FALLBACK_FOR_REPLAY", "false") ] in
  Alcotest.(check bool)
    "replay fallback can be disabled" false
    (Feature_flags.heuristic_fallback_allowed disabled `Scenario_replay)

let test_replay_external_events_have_no_feature_scope () =
  let configured = flags [] in
  [ `Production_clearing; `Scenario_replay; `Local_diagnostic ]
  |> List.iter (fun scope ->
      Alcotest.(check bool)
        "external events always denied" false
        (Feature_flags.replay_external_events_allowed configured scope))

let () =
  Alcotest.run "effective feature flags"
    [
      ( "flags",
        [
          Alcotest.test_case "disabled defaults" `Quick test_disabled_by_default;
          Alcotest.test_case "parent gating" `Quick
            test_subordinate_flags_require_parent;
          Alcotest.test_case "enabled adapters" `Quick
            test_valid_enabled_adapters;
          Alcotest.test_case "heuristic scope" `Quick
            test_heuristic_fallback_has_no_production_authority;
          Alcotest.test_case "replay events have no feature scope" `Quick
            test_replay_external_events_have_no_feature_scope;
        ] );
    ]
