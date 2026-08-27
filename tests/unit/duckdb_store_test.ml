let fixture = Sys.getenv "FCA_PROCESS_FIXTURE" |> Unix.realpath
let run_lwt value = Lwt_main.run value
let runner () = Process_runner.create ~allowed_env:[]

let temporary_directory prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path

let expect_created = function
  | Ok store -> store
  | Error error -> Alcotest.fail (Duckdb_store.error_to_string error)

let expect_error_code expected = function
  | Ok _ -> Alcotest.fail "expected DuckDB adapter error"
  | Error error ->
      Alcotest.(check string)
        "stable error" expected
        (Duckdb_store.error_code error)

let create_with_budget max_rows root database =
  Duckdb_store.create ~runner:(runner ()) ~executable:fixture ~replay_root:root
    ~database_path:database ~timeout:3. ~output_limit:4096 ~max_rows

let create root database = create_with_budget 1_000_000 root database
let read_invocation database = Yojson.Safe.from_file (database ^ ".invocation")

let member_string name json =
  Yojson.Safe.Util.(json |> member name |> to_string)

let member_strings name json =
  Yojson.Safe.Util.(json |> member name |> to_list |> List.map to_string)

let contains haystack needle =
  let length = String.length needle in
  let rec loop index =
    index + length <= String.length haystack
    && (String.sub haystack index length = needle || loop (index + 1))
  in
  length = 0 || loop 0

let test_fixed_health_protocol () =
  let root = temporary_directory "fca-duckdb" in
  let database = Filename.concat root "health.duckdb" in
  let store = create root database |> expect_created in
  let health =
    match run_lwt (Duckdb_store.health store) with
    | Ok value -> value
    | Error error -> Alcotest.fail (Duckdb_store.error_to_string error)
  in
  Alcotest.(check string) "version" "v1.3.2" health.version;
  let invocation = read_invocation database in
  let argv = member_strings "argv" invocation in
  let required =
    [ "-batch"; "-bail"; "-nofollow"; "-init"; "-json"; database ]
  in
  List.iter
    (fun flag ->
      Alcotest.(check bool) ("argv " ^ flag) true (List.mem flag argv))
    required;
  let stdin_text = member_string "stdin" invocation in
  List.iter
    (fun setting ->
      Alcotest.(check bool) setting true (contains stdin_text setting))
    [
      "autoinstall_known_extensions=false";
      "autoload_known_extensions=false";
      "allow_community_extensions=false";
      "allowed_directories=['" ^ Unix.realpath root ^ "']";
      "enable_external_access=false";
      "lock_configuration=true";
      "SELECT version() AS duckdb_version";
    ];
  Alcotest.(check bool) "no INSTALL" false (contains stdin_text "INSTALL");
  Sys.remove (database ^ ".invocation");
  Unix.rmdir root

let test_typed_capability_queries () =
  let root = temporary_directory "fca-duckdb-cap" in
  let csv_db = Filename.concat root "csv.duckdb" in
  let parquet_db = Filename.concat root "parquet.duckdb" in
  let csv = create root csv_db |> expect_created in
  let parquet = create root parquet_db |> expect_created in
  let capability call =
    match run_lwt call with
    | Ok true -> ()
    | Ok false -> Alcotest.fail "expected fixture capability"
    | Error error -> Alcotest.fail (Duckdb_store.error_to_string error)
  in
  capability (Duckdb_store.csv_capability csv);
  capability (Duckdb_store.parquet_capability parquet);
  let csv_sql = read_invocation csv_db |> member_string "stdin" in
  let parquet_sql = read_invocation parquet_db |> member_string "stdin" in
  Alcotest.(check bool)
    "fixed CSV query" true
    (contains csv_sql "csv_supported");
  Alcotest.(check bool)
    "fixed Parquet query" true
    (contains parquet_sql "parquet_supported");
  Alcotest.(check bool)
    "no arbitrary SQL surface" false
    (contains parquet_sql "INSTALL");
  List.iter Sys.remove [ csv_db ^ ".invocation"; parquet_db ^ ".invocation" ];
  Unix.rmdir root

let test_bounded_parquet_benchmark_query_and_parser () =
  let root = temporary_directory "fca-duckdb-benchmark" in
  let fixture_path = Filename.concat root "golden.parquet" in
  let fixture_channel = open_out_bin fixture_path in
  close_out fixture_channel;
  let database = Filename.concat root "benchmark.duckdb" in
  let store = create root database |> expect_created in
  let result =
    match run_lwt (Duckdb_store.benchmark_parquet store ~fixture_path) with
    | Ok value -> value
    | Error error -> Alcotest.fail (Duckdb_store.error_to_string error)
  in
  Alcotest.(check string) "DuckDB version" "v1.3.2" result.duckdb_version;
  Alcotest.(check int) "bounded rows" 432 result.row_count;
  Alcotest.(check int) "tenants" 2 result.tenant_count;
  Alcotest.(check int) "months" 12 result.month_count;
  Alcotest.(check int) "auctions" 48 result.auction_count;
  Alcotest.(check int) "loads" 144 result.load_count;
  Alcotest.(check int) "bids" 432 result.bid_count;
  Alcotest.(check int) "baseline eligible" 288 result.baseline_eligible_count;
  Alcotest.(check string) "landed cost" "889488.00" result.landed_cost_sum;
  Alcotest.(check bool)
    "persistent database not used" false
    (Sys.file_exists (database ^ ".invocation"));
  Sys.remove fixture_path;
  Unix.rmdir root

let test_bounded_parquet_row_reader () =
  let root = temporary_directory "fca-duckdb-rows" in
  let fixture_path = Filename.concat root "rows.parquet" in
  let fixture_channel = open_out_bin fixture_path in
  close_out fixture_channel;
  let store = create root (Filename.concat root "rows.duckdb") |> expect_created in
  let rows =
    match run_lwt (Duckdb_store.read_parquet_rows store ~fixture_path) with
    | Ok rows -> rows
    | Error error -> Alcotest.fail (Duckdb_store.error_to_string error)
  in
  Alcotest.(check int) "bounded row count" 1 (List.length rows);
  Alcotest.(check string)
    "typed row field" "tenant-fixture"
    (Yojson.Safe.Util.(List.hd rows |> member "tenant_id" |> to_string));
  Sys.remove fixture_path;
  Unix.rmdir root

let test_paths_reject_traversal_extension_and_symlink () =
  let root = temporary_directory "fca-duckdb-path" in
  let outside = Filename.concat (Filename.dirname root) "outside.duckdb" in
  create root outside |> expect_error_code "DUCKDB_PATH_INVALID";
  create root (Filename.concat root "wrong.db")
  |> expect_error_code "DUCKDB_PATH_INVALID";
  let target = Filename.concat root "target.duckdb" in
  let channel = open_out_bin target in
  close_out channel;
  let link = Filename.concat root "link.duckdb" in
  Unix.symlink target link;
  create root link |> expect_error_code "DUCKDB_PATH_INVALID";
  let outside_root = temporary_directory "fca-duckdb-linked" in
  let root_link = root ^ "-link" in
  Unix.symlink outside_root root_link;
  create root_link (Filename.concat root_link "linked.duckdb")
  |> expect_error_code "DUCKDB_PATH_INVALID";
  Sys.remove root_link;
  Unix.rmdir outside_root;
  Sys.remove link;
  Sys.remove target;
  Unix.rmdir root

let test_runtime_row_budget_is_consumed_without_allocation () =
  let root = temporary_directory "fca-duckdb-budget" in
  let database = Filename.concat root "budget.duckdb" in
  let config =
    Config_test_support.load ~replacements:[ ("REPLAY_MAX_ROWS", "17") ] ()
    |> Config_test_support.require_ok
  in
  let max_rows = (Runtime_config.solver config).replay_max_rows in
  let store = create_with_budget max_rows root database |> expect_created in
  Alcotest.(check (result unit string))
    "exact configured budget accepted" (Ok ())
    (Duckdb_store.check_row_count store 17
    |> Result.map_error Duckdb_store.error_code);
  Alcotest.(check (result unit string))
    "budget plus one rejected" (Error "DUCKDB_ROW_BUDGET_EXCEEDED")
    (Duckdb_store.check_row_count store 18
    |> Result.map_error Duckdb_store.error_code);
  Alcotest.(check (result unit string))
    "negative observed count rejected" (Error "DUCKDB_PATH_INVALID")
    (Duckdb_store.check_row_count store (-1)
    |> Result.map_error Duckdb_store.error_code);
  Unix.rmdir root

let test_malformed_and_nonzero_are_redacted () =
  let root = temporary_directory "fca-duckdb-errors" in
  let malformed_db = Filename.concat root "malformed.duckdb" in
  let malformed = create root malformed_db |> expect_created in
  run_lwt (Duckdb_store.health malformed)
  |> expect_error_code "DUCKDB_MALFORMED_OUTPUT";
  let missing =
    Duckdb_store.create ~runner:(runner ())
      ~executable:(Filename.concat root "missing-duckdb")
      ~replay_root:root
      ~database_path:(Filename.concat root "missing.duckdb")
      ~timeout:0.2 ~output_limit:128 ~max_rows:1_000_000
    |> expect_created
  in
  let result = run_lwt (Duckdb_store.health missing) in
  expect_error_code "DUCKDB_PROCESS_FAILED" result;
  let rendered =
    match result with
    | Error error -> Duckdb_store.error_to_string error
    | Ok _ -> ""
  in
  Alcotest.(check bool) "absolute path redacted" false (contains rendered root);
  Sys.remove (malformed_db ^ ".invocation");
  Unix.rmdir root

let () =
  Alcotest.run "typed DuckDB CLI replay store"
    [
      ( "protocol",
        [
          Alcotest.test_case "fixed health argv/stdin/output" `Quick
            test_fixed_health_protocol;
          Alcotest.test_case "typed CSV and Parquet capabilities" `Quick
            test_typed_capability_queries;
          Alcotest.test_case "bounded Parquet benchmark" `Quick
            test_bounded_parquet_benchmark_query_and_parser;
          Alcotest.test_case "bounded Parquet row reader" `Quick
            test_bounded_parquet_row_reader;
        ] );
      ( "safety",
        [
          Alcotest.test_case "canonical paths and symlinks" `Quick
            test_paths_reject_traversal_extension_and_symlink;
          Alcotest.test_case "runtime row budget" `Quick
            test_runtime_row_budget_is_consumed_without_allocation;
          Alcotest.test_case "stable redacted errors" `Quick
            test_malformed_and_nonzero_are_redacted;
        ] );
    ]
