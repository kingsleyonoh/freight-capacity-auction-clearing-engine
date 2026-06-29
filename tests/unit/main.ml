open Alcotest

module Runtime_config = Freight_capacity_auction_clearing_engine_config.Runtime_config
module Infra = Freight_capacity_auction_clearing_engine.Shared.Service_infrastructure
module Console = Freight_capacity_auction_clearing_engine.Ui.Operations_console

let env pairs key = List.assoc_opt key pairs

let contains haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index =
    index + needle_len <= haystack_len
    && (String.sub haystack index needle_len = needle || loop (index + 1))
  in
  needle_len = 0 || loop 0

let config_reads_safe_defaults () =
  let config = Runtime_config.load ~getenv:(env []) () in
  check string "default app env" "development" config.app_env;
  check int "default app port" 8080 config.app_port;
  check string "default redis" "redis://localhost:16439/0" config.redis_url;
  check string "default replay store" "./data/replay.duckdb" config.replay_store_path;
  check string "optional hub API key remains empty" "" config.notification_hub_api_key

let config_rejects_invalid_numeric_values () =
  check_raises "invalid APP_PORT is rejected"
    (Invalid_argument "APP_PORT must be an integer")
    (fun () -> ignore (Runtime_config.load ~getenv:(env [ ("APP_PORT", "not-a-port") ]) ()))

let infrastructure_declares_local_services () =
  let config = Runtime_config.load ~getenv:(env []) () in
  let names = Infra.service_names config in
  check (list string) "foundation services" [ "postgres"; "redis"; "duckdb"; "solver" ] names;
  check bool "solver live binary is optional" true (Infra.solver_is_optional config)

let operations_console_has_privacy_and_accessibility_baseline () =
  let html = Console.render () in
  check bool "has main landmark" true (contains html "<main");
  check bool "labels sealed-bid privacy" true (contains html "sealed-bid privacy");
  check bool "contains privacy scope attribute" true
    (contains html "data-privacy-scope=\"sealed-bid\"");
  check bool "includes table caption" true (contains html "Auction readiness");
  check bool "does not expose sample competitor price" false
    (contains html "$")

let () =
  run "freight_capacity_auction_clearing_engine"
    [
      ( "runtime config",
        [
          test_case "reads safe defaults" `Quick config_reads_safe_defaults;
          test_case "rejects invalid numeric env" `Quick config_rejects_invalid_numeric_values;
        ] );
      ( "service infrastructure",
        [ test_case "declares local dependencies" `Quick infrastructure_declares_local_services ] );
      ( "operations console",
        [ test_case "has privacy and accessibility baseline" `Quick operations_console_has_privacy_and_accessibility_baseline ] );
    ]
