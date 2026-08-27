let without name values = List.remove_assoc name values

let load_without_replay_path () =
  Runtime_config.load
    ~get:
      (Config_test_support.get_from
         (Config_test_support.with_values [] |> without "REPLAY_STORE_PATH"))
  |> Config_test_support.require_ok |> Runtime_config.data

let test_default_uses_durable_replay_directory () =
  Alcotest.(check string)
    "default replay database lives under the durable replay root"
    "./data/replays/replay.duckdb"
    (load_without_replay_path ()).replay_store_path

let test_explicit_path_is_trimmed_without_rewriting () =
  let data =
    Config_test_support.load
      ~replacements:[ ("REPLAY_STORE_PATH", "  ./data/replays/custom.duckdb  ") ]
      ()
    |> Config_test_support.require_ok |> Runtime_config.data
  in
  Alcotest.(check string)
    "explicit replay database path remains operator-owned"
    "./data/replays/custom.duckdb" data.replay_store_path

let test_blank_path_fails_closed () =
  let variables =
    Config_test_support.load
      ~replacements:[ ("REPLAY_STORE_PATH", "   ") ]
      ()
    |> Config_test_support.error_variables
  in
  Alcotest.(check bool)
    "blank replay database path is rejected" true
    (List.mem "REPLAY_STORE_PATH" variables)

let () =
  Alcotest.run "local storage runtime configuration"
    [
      ( "replay path",
        [
          Alcotest.test_case "durable default" `Quick
            test_default_uses_durable_replay_directory;
          Alcotest.test_case "explicit override" `Quick
            test_explicit_path_is_trimmed_without_rewriting;
          Alcotest.test_case "blank override" `Quick test_blank_path_fails_closed;
        ] );
    ]
