let fail message =
  prerr_endline ("freight-auction: " ^ message);
  exit 2

let option_after flag values =
  let rec loop = function
    | [] -> None
    | current :: next when current = flag -> (match next with value :: _ -> Some value | [] -> None)
    | _ :: next -> loop next
  in
  loop values

let has_flag flag values = List.exists (( = ) flag) values

let read_file path =
  try
    let channel = open_in_bin path in
    Fun.protect ~finally:(fun () -> close_in_noerr channel)
      (fun () -> really_input_string channel (in_channel_length channel))
  with Sys_error message -> fail ("cannot read " ^ path ^ ": " ^ message)

let extension path = String.lowercase_ascii (Filename.extension path)

let list_strings name json =
  match Yojson.Safe.Util.member name json with
  | `List values -> List.filter_map (function `String value -> Some value | _ -> None) values
  | _ -> []

let import_context json : Import_validation.context =
  { carrier_ids = list_strings "carrier_ids" json;
    suspended_carrier_ids = list_strings "suspended_carrier_ids" json;
    lane_ids = list_strings "lane_ids" json;
    load_ids = list_strings "load_ids" json }

let cleanup_duckdb database =
  List.iter
    (fun path -> if Sys.file_exists path then try Sys.remove path with _ -> ())
    [ database; database ^ ".wal" ]

let parquet_rows config path =
  let fixture =
    try Unix.realpath path with _ -> fail "Parquet file cannot be resolved"
  in
  let root = Filename.dirname fixture in
  let database, channel = Filename.open_temp_file ~temp_dir:root ".fca-cli-" ".duckdb" in
  close_out channel;
  Sys.remove database;
  Fun.protect
    ~finally:(fun () -> cleanup_duckdb database)
    (fun () ->
      let runner = Process_runner.create ~allowed_env:[] in
      let executable =
        match Sys.getenv_opt "FCA_DUCKDB_BINARY" with
        | Some value when value <> "" -> value
        | _ -> if Sys.file_exists "/usr/local/bin/duckdb" then "/usr/local/bin/duckdb" else "duckdb"
      in
      let max_rows = (Runtime_config.solver config).replay_max_rows in
      match
        Duckdb_store.create ~runner ~executable ~replay_root:root
          ~database_path:database ~timeout:30. ~output_limit:(32 * 1024 * 1024)
          ~max_rows
      with
      | Error error -> fail ("Parquet reader unavailable: " ^ Duckdb_store.error_to_string error)
      | Ok store ->
          (match Lwt_main.run (Duckdb_store.read_parquet_rows store ~fixture_path:fixture) with
           | Ok rows -> rows
           | Error error -> fail ("Parquet read failed: " ^ Duckdb_store.error_to_string error)))

let () =
  match Array.to_list Sys.argv with
  | _ :: "import" :: rest ->
      let resource_type = Option.value ~default:"" (option_after "--type" rest) in
      let path = Option.value ~default:"" (option_after "--file" rest) in
      let auction_id = option_after "--auction-id" rest in
      let commit = has_flag "--commit" rest in
      if not (List.mem resource_type [ "carriers"; "lanes"; "loads"; "bids"; "replay_dataset" ]) then fail "--type must be carriers, lanes, loads, bids, or replay_dataset";
      if path = "" then fail "--file is required";
      let source_format =
        match extension path with
        | ".csv" -> "csv"
        | ".parquet" -> "parquet"
        | _ -> fail "--file must have a .csv or .parquet extension"
      in
      let config =
        match Runtime_config.from_process_env () with
        | Ok value -> value
        | Error _ -> fail "runtime configuration is invalid"
      in
      let api_key = Option.value ~default:"" (Sys.getenv_opt "FCA_CLI_API_KEY") in
      if api_key = "" then fail "FCA_CLI_API_KEY is required";
      Runtime_config.Secret.with_value (Runtime_config.data config).database_url
        (fun database_url ->
          match Lwt_main.run (Db_pool.start (Uri.of_string database_url)) with
          | Error _ -> fail "database is unavailable"
          | Ok _ ->
              let data = Runtime_config.data config in
              if data.migrations_auto_run then
                (match Lwt_main.run (Migration_runner.run Migration_catalog.production) with
                 | Error _ -> fail "database migrations failed"
                 | Ok _ -> ());
              match Lwt_main.run (Store.authenticate ~api_key) with
              | Error _ -> fail "API key is invalid"
              | Ok actor ->
                  let rows =
                    match source_format with
                    | "csv" -> []
                    | "parquet" -> parquet_rows config path
                    | _ -> []
                  in
                  let validation =
                    match source_format with
                    | "csv" ->
                        (match Lwt_main.run (Store.import_context ~tenant_id:actor.tenant_id) with
                         | Ok context -> Import_validation.validate_csv ~resource_type ~context:(import_context context) (read_file path)
                         | Error _ -> fail "database reference data is unavailable")
                    | "parquet" ->
                        (match Lwt_main.run (Store.import_context ~tenant_id:actor.tenant_id) with
                         | Ok context -> Import_validation.validate_json_rows ~resource_type ~context:(import_context context) rows
                         | Error _ -> fail "database reference data is unavailable")
                    | _ -> fail "unsupported source format"
                  in
                  let summary = Yojson.Safe.to_string (`Assoc [ ("status", `String validation.status); ("row_count", `Int validation.row_count); ("valid_row_count", `Int validation.valid_row_count); ("invalid_row_count", `Int validation.invalid_row_count); ("error_count", `Int (List.length validation.errors)); ("source_format", `String source_format) ]) in
                  let result = Lwt_main.run (Store.create_import ~tenant_id:actor.tenant_id ~user_id:actor.user_id ~resource_type ~source_filename:(Filename.basename path) ~source_format ~auction_id ~mapping:"{}" ~staging_rows:(Yojson.Safe.to_string (`List validation.rows)) ~validation_summary:summary ~row_errors:(Yojson.Safe.to_string (`List validation.errors)) ~row_count:validation.row_count ~valid_row_count:validation.valid_row_count ~invalid_row_count:validation.invalid_row_count) in
                  (match result with
                   | Error _ -> fail "import preview could not be persisted"
                   | Ok import_id ->
                       let result = if commit then Lwt_main.run (Store.commit_import ~tenant_id:actor.tenant_id ~import_id ~confirm:true) else Ok (`Assoc [ ("id", `String import_id); ("status", `String validation.status) ]) in
                       (match result with
                        | Error _ -> fail "import commit failed"
                        | Ok json -> print_endline (Yojson.Safe.pretty_to_string json))))
  | _ ->
      print_endline "Usage: freight-auction import --type {carriers|lanes|loads|bids|replay_dataset} --file PATH [--auction-id UUID] [--commit]"
