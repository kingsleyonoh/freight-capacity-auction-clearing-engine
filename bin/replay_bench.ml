type expected = {
  row_count : int;
  tenant_count : int;
  month_count : int;
  auction_count : int;
  load_count : int;
  bid_count : int;
}

let json_error reason =
  print_endline
    (Yojson.Safe.to_string
       (`Assoc [ ("benchmark", `String "failed"); ("reason", `String reason) ]))

let parse_fixture_argument () =
  match Array.to_list Sys.argv |> List.tl with
  | [ "--fixture"; path ] when String.trim path <> "" -> Ok path
  | _ -> Error "REPLAY_BENCH_ARGUMENTS_INVALID"

let strict_positive_env name default maximum =
  match Sys.getenv_opt name with
  | None -> Ok default
  | Some raw -> (
      match int_of_string_opt raw with
      | Some value when value >= 1 && value <= maximum -> Ok value
      | _ -> Error "REPLAY_BENCH_ROW_BUDGET_INVALID")

let expected_int json name =
  match Yojson.Safe.Util.member name json with
  | `Int value when value >= 0 -> Ok value
  | _ -> Error "REPLAY_BENCH_EXPECTED_INVALID"

let load_expected fixture =
  let path = Filename.remove_extension fixture ^ ".expected.json" in
  try
    let json = Yojson.Safe.from_file path in
    match
      ( expected_int json "row_count",
        expected_int json "tenant_count",
        expected_int json "month_count",
        expected_int json "auction_count",
        expected_int json "load_count",
        expected_int json "bid_count" )
    with
    | ( Ok row_count,
        Ok tenant_count,
        Ok month_count,
        Ok auction_count,
        Ok load_count,
        Ok bid_count ) ->
        Ok
          {
            row_count;
            tenant_count;
            month_count;
            auction_count;
            load_count;
            bid_count;
          }
    | _ -> Error "REPLAY_BENCH_EXPECTED_INVALID"
  with _ -> Error "REPLAY_BENCH_EXPECTED_UNREADABLE"

let matches expected (actual : Duckdb_store.benchmark) =
  actual.row_count = expected.row_count
  && actual.tenant_count = expected.tenant_count
  && actual.month_count = expected.month_count
  && actual.auction_count = expected.auction_count
  && actual.load_count = expected.load_count
  && actual.bid_count = expected.bid_count

let result_json version (result : Duckdb_store.benchmark) =
  `Assoc
    [
      ("benchmark", `String "passed");
      ("scope", `String "scenario_replay_fixture");
      ("duckdb_version", `String version);
      ("deterministic_runs", `Int 2);
      ("row_count", `Int result.row_count);
      ("tenant_count", `Int result.tenant_count);
      ("month_count", `Int result.month_count);
      ("auction_count", `Int result.auction_count);
      ("load_count", `Int result.load_count);
      ("bid_count", `Int result.bid_count);
      ("baseline_eligible_count", `Int result.baseline_eligible_count);
      ("landed_cost_sum", `String result.landed_cost_sum);
      ("live_award_mutation", `Bool false);
      ("external_events", `Bool false);
    ]

let cleanup_database database =
  List.iter
    (fun path ->
      if Sys.file_exists path then try Sys.remove path with _ -> ())
    [ database; database ^ ".wal" ]

let run fixture max_rows =
  let fixture = Unix.realpath fixture in
  let root = Filename.dirname fixture |> Unix.realpath in
  let database, channel =
    Filename.open_temp_file ~temp_dir:root ".replay-bench-" ".duckdb"
  in
  close_out channel;
  Sys.remove database;
  Fun.protect
    ~finally:(fun () -> cleanup_database database)
    (fun () ->
      let runner = Process_runner.create ~allowed_env:[] in
      let executable =
        Option.value ~default:"duckdb" (Sys.getenv_opt "FCA_DUCKDB_BINARY")
      in
      match
        Duckdb_store.create ~runner ~executable ~replay_root:root
          ~database_path:database ~timeout:30. ~output_limit:65536 ~max_rows
      with
      | Error error -> Error (Duckdb_store.error_code error)
      | Ok store ->
          let open Lwt.Syntax in
          Lwt_main.run
            (let* first =
               Duckdb_store.benchmark_parquet store ~fixture_path:fixture
             in
             let* second =
               Duckdb_store.benchmark_parquet store ~fixture_path:fixture
             in
             Lwt.return
               (match (first, second) with
               | Ok first, Ok second when first = second ->
                   Ok (first.duckdb_version, first)
               | Error error, _ | _, Error error ->
                   Error (Duckdb_store.error_code error)
               | _ -> Error "REPLAY_BENCH_NONDETERMINISTIC")))

let main () =
  match
    ( parse_fixture_argument (),
      strict_positive_env "REPLAY_MAX_ROWS" 1_000_000 10_000_000 )
  with
  | Error reason, _ | _, Error reason ->
      json_error reason;
      2
  | Ok fixture, Ok max_rows -> (
      match load_expected fixture with
      | Error reason ->
          json_error reason;
          2
      | Ok expected -> (
          try
            match run fixture max_rows with
            | Error reason ->
                json_error reason;
                1
            | Ok (version, result) when matches expected result ->
                print_endline
                  (Yojson.Safe.to_string (result_json version result));
                0
            | Ok _ ->
                json_error "REPLAY_BENCH_EXPECTATION_MISMATCH";
                1
          with _ ->
            json_error "REPLAY_BENCH_FIXTURE_INVALID";
            2))

let () = exit (main ())
