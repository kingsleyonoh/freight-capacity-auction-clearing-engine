open Lwt.Infix

type t = {
  runner : Process_runner.t;
  executable : string;
  replay_root : string;
  database_path : string;
  timeout : float;
  output_limit : int;
  max_rows : int;
}

type health = { version : string }

type benchmark = {
  duckdb_version : string;
  row_count : int;
  tenant_count : int;
  month_count : int;
  auction_count : int;
  load_count : int;
  bid_count : int;
  baseline_eligible_count : int;
  landed_cost_sum : string;
}

type error =
  | Path_invalid
  | Process_failed
  | Malformed_output
  | Row_budget_exceeded

let error_code = function
  | Path_invalid -> "DUCKDB_PATH_INVALID"
  | Process_failed -> "DUCKDB_PROCESS_FAILED"
  | Malformed_output -> "DUCKDB_MALFORMED_OUTPUT"
  | Row_budget_exceeded -> "DUCKDB_ROW_BUDGET_EXCEEDED"

let error_to_string = error_code

let has_parent_reference path =
  String.split_on_char Filename.dir_sep.[0] path |> List.exists (( = ) "..")

let extension_is_duckdb path =
  String.lowercase_ascii (Filename.extension path) = ".duckdb"

let beneath ~root path =
  path = root || String.starts_with ~prefix:(root ^ Filename.dir_sep) path

let has_symlink_component path =
  if Sys.win32 then (Unix.lstat path).st_kind = Unix.S_LNK
  else
    let components =
      String.split_on_char '/' path |> List.filter (fun value -> value <> "")
    in
    let start = if Filename.is_relative path then Sys.getcwd () else "/" in
    let _, found =
      List.fold_left
        (fun (current, found) component ->
          let current = Filename.concat current component in
          (current, found || (Unix.lstat current).st_kind = Unix.S_LNK))
        (start, false) components
    in
    found

let root_is_safe root =
  try
    let stat = Unix.lstat root in
    stat.st_kind = Unix.S_DIR
    && (not (has_parent_reference root))
    && not (has_symlink_component root)
  with _ -> false

let regular_file_beneath ~root ~extension path =
  if
    has_parent_reference path
    || String.lowercase_ascii (Filename.extension path) <> extension
  then None
  else
    try
      let canonical = Unix.realpath path in
      let stat = Unix.lstat canonical in
      if
        stat.st_kind = Unix.S_REG && beneath ~root canonical
        && not (has_symlink_component path)
      then Some canonical
      else None
    with _ -> None

let database_is_safe ~root database =
  if has_parent_reference database || not (extension_is_duckdb database) then
    None
  else
    try
      let parent = Filename.dirname database |> Unix.realpath in
      if not (beneath ~root parent) then None
      else if Sys.file_exists database then
        let stat = Unix.lstat database in
        if
          stat.st_kind = Unix.S_LNK || stat.st_kind = Unix.S_DIR
          || has_symlink_component database
        then None
        else
          let canonical = Unix.realpath database in
          if beneath ~root canonical then Some canonical else None
      else Some (Filename.concat parent (Filename.basename database))
    with _ -> None

let create ~runner ~executable ~replay_root ~database_path ~timeout
    ~output_limit ~max_rows =
  if
    executable = ""
    || String.contains executable '\000'
    || timeout <= 0. || output_limit <= 0 || max_rows < 1
    || max_rows > 10_000_000
    || not (root_is_safe replay_root)
  then Error Path_invalid
  else
    let root = Unix.realpath replay_root in
    match database_is_safe ~root database_path with
    | None -> Error Path_invalid
    | Some database_path ->
        Ok
          {
            runner;
            executable;
            replay_root = root;
            database_path;
            timeout;
            output_limit;
            max_rows;
          }

let check_row_count store observed_rows =
  if observed_rows < 0 then Error Path_invalid
  else if observed_rows > store.max_rows then Error Row_budget_exceeded
  else Ok ()

let sql_literal value = String.split_on_char '\'' value |> String.concat "''"

let base_settings root =
  "SET autoinstall_known_extensions=false;\n\
   SET autoload_known_extensions=false;\n\
   SET allow_community_extensions=false;\n\
   SET allowed_directories=['" ^ sql_literal root
  ^ "'];\nSET enable_external_access=false;\nSET lock_configuration=true;\n"

let health_query root =
  base_settings root ^ "SELECT version() AS duckdb_version;\n"

let csv_query root =
  base_settings root
  ^ "SELECT count(*) > 0 AS csv_supported FROM duckdb_functions() "
  ^ "WHERE function_name='read_csv';\n"

let parquet_query root =
  base_settings root
  ^ "SELECT count(*) > 0 AS parquet_supported FROM duckdb_functions() "
  ^ "WHERE function_name='read_parquet';\n"

let with_empty_init root operation =
  let path, channel =
    Filename.open_temp_file ~temp_dir:root ".duckdb-empty-init-" ".sql"
  in
  close_out channel;
  Lwt.finalize
    (fun () -> operation path)
    (fun () ->
      (try Sys.remove path with _ -> ());
      Lwt.return_unit)

let run_query store argv query =
  let request =
    Process_runner.request ~executable:store.executable ~argv ~env:[]
      ~stdin:query ~stdin_limit:(String.length query)
      ~stdout_limit:store.output_limit ~stderr_limit:16384
      ~timeout:store.timeout ~term_grace:0.2 ()
  in
  Process_runner.run store.runner request >|= function
  | Ok output -> Ok output.stdout
  | Error _ -> Error Process_failed

let invoke store query =
  with_empty_init store.replay_root (fun init_path ->
      run_query store
        [
          "-batch";
          "-bail";
          "-nofollow";
          "-init";
          init_path;
          "-json";
          store.database_path;
        ]
        query)

let invoke_memory store query =
  with_empty_init store.replay_root (fun init_path ->
      run_query store
        [ "-batch"; "-bail"; "-init"; init_path; "-json"; ":memory:" ]
        query)

let first_object value =
  try
    match Yojson.Safe.from_string value with
    | `List (`Assoc fields :: _) -> Some fields
    | `Assoc fields -> Some fields
    | _ -> None
  with _ -> None

let string_field name value =
  Option.bind (first_object value) (fun fields ->
      match List.assoc_opt name fields with
      | Some (`String value) -> Some value
      | _ -> None)

let bool_field name value =
  Option.bind (first_object value) (fun fields ->
      match List.assoc_opt name fields with
      | Some (`Bool value) -> Some value
      | _ -> None)

let int_field name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Some value
  | Some (`Intlit value) -> int_of_string_opt value
  | _ -> None

let benchmark_query fixture =
  base_settings (Filename.dirname fixture)
  ^ "SELECT version() AS duckdb_version, count(*) AS benchmark_row_count, "
  ^ "count(DISTINCT tenant_id) AS tenant_count, "
  ^ "count(DISTINCT window_month) AS month_count, "
  ^ "count(DISTINCT auction_id) AS auction_count, "
  ^ "count(DISTINCT load_id) AS load_count, "
  ^ "count(DISTINCT bid_id) AS bid_count, "
  ^ "CAST(sum(CASE WHEN baseline_eligible THEN 1 ELSE 0 END) AS BIGINT) AS \
     baseline_eligible_count, "
  ^ "CAST(CAST(coalesce(sum(actual_landed_cost), 0) AS DECIMAL(38,2)) AS \
     VARCHAR) AS landed_cost_sum " ^ "FROM read_parquet('" ^ sql_literal fixture
  ^ "');\n"

let parse_benchmark output =
  match first_object output with
  | None -> None
  | Some fields -> (
      match
        ( List.assoc_opt "duckdb_version" fields,
          int_field "benchmark_row_count" fields,
          int_field "tenant_count" fields,
          int_field "month_count" fields,
          int_field "auction_count" fields,
          int_field "load_count" fields,
          int_field "bid_count" fields,
          int_field "baseline_eligible_count" fields,
          List.assoc_opt "landed_cost_sum" fields )
      with
      | ( Some (`String duckdb_version),
          Some row_count,
          Some tenant_count,
          Some month_count,
          Some auction_count,
          Some load_count,
          Some bid_count,
          Some baseline_eligible_count,
          Some (`String landed_cost_sum) ) ->
          Some
            {
              duckdb_version;
              row_count;
              tenant_count;
              month_count;
              auction_count;
              load_count;
              bid_count;
              baseline_eligible_count;
              landed_cost_sum;
            }
      | _ -> None)

let health store =
  invoke store (health_query store.replay_root) >|= function
  | Error error -> Error error
  | Ok output -> (
      match string_field "duckdb_version" output with
      | Some version when version <> "" -> Ok { version }
      | _ -> Error Malformed_output)

let capability store query field =
  invoke store query >|= function
  | Error error -> Error error
  | Ok output -> (
      match bool_field field output with
      | Some value -> Ok value
      | None -> Error Malformed_output)

let csv_capability store =
  capability store (csv_query store.replay_root) "csv_supported"

let parquet_capability store =
  capability store (parquet_query store.replay_root) "parquet_supported"

let read_parquet_rows store ~fixture_path =
  match
    regular_file_beneath ~root:store.replay_root ~extension:".parquet"
      fixture_path
  with
  | None -> Lwt.return (Error Path_invalid)
  | Some fixture ->
      let query =
        base_settings (Filename.dirname fixture)
        ^ "SELECT * FROM read_parquet('"
        ^ sql_literal fixture ^ "');\n"
      in
      invoke_memory store query >|= function
      | Error error -> Error error
      | Ok output -> (
          match Yojson.Safe.from_string output with
          | `List rows when List.for_all (function `Assoc _ -> true | _ -> false) rows ->
              (match check_row_count store (List.length rows) with
               | Ok () -> Ok rows
               | Error error -> Error error)
          | _ -> Error Malformed_output)

let benchmark_parquet store ~fixture_path =
  match
    regular_file_beneath ~root:store.replay_root ~extension:".parquet"
      fixture_path
  with
  | None -> Lwt.return (Error Path_invalid)
  | Some fixture -> (
      invoke_memory store (benchmark_query fixture) >|= function
      | Error error -> Error error
      | Ok output -> (
          match parse_benchmark output with
          | None -> Error Malformed_output
          | Some result -> (
              match check_row_count store result.row_count with
              | Error error -> Error error
              | Ok () ->
                  if
                    result.row_count < 1 || result.tenant_count < 1
                    || result.month_count < 1 || result.auction_count < 1
                    || result.load_count < 1
                    || result.bid_count <> result.row_count
                    || result.baseline_eligible_count < 0
                    || result.baseline_eligible_count > result.row_count
                  then Error Malformed_output
                  else Ok result)))

let benchmark_csv_query fixture =
  base_settings (Filename.dirname fixture)
  ^ "SELECT version() AS duckdb_version, count(*) AS benchmark_row_count, "
  ^ "count(DISTINCT tenant_id) AS tenant_count, "
  ^ "count(DISTINCT window_month) AS month_count, "
  ^ "count(DISTINCT auction_id) AS auction_count, "
  ^ "count(DISTINCT load_id) AS load_count, "
  ^ "count(DISTINCT bid_id) AS bid_count, "
  ^ "CAST(sum(CASE WHEN baseline_eligible THEN 1 ELSE 0 END) AS BIGINT) AS "
  ^ "baseline_eligible_count, "
  ^ "CAST(CAST(coalesce(sum(actual_landed_cost), 0) AS DECIMAL(38,2)) AS "
  ^ "VARCHAR) AS landed_cost_sum FROM read_csv_auto('"
  ^ sql_literal fixture ^ "', header=true);\n"

let benchmark_dataset store ~dataset_path =
  let extension = String.lowercase_ascii (Filename.extension dataset_path) in
  match extension with
  | ".parquet" -> benchmark_parquet store ~fixture_path:dataset_path
  | ".csv" ->
      (match regular_file_beneath ~root:store.replay_root ~extension dataset_path with
       | None -> Lwt.return (Error Path_invalid)
       | Some fixture ->
           invoke_memory store (benchmark_csv_query fixture) >|= function
           | Error error -> Error error
           | Ok output ->
               (match parse_benchmark output with
                | None -> Error Malformed_output
                | Some result ->
                    (match check_row_count store result.row_count with
                     | Ok () -> Ok result
                     | Error error -> Error error)))
  | _ -> Lwt.return (Error Path_invalid)
