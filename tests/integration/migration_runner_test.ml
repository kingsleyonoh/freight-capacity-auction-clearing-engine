let ( let* ) = Lwt.bind

let required_env name =
  match Sys.getenv_opt name with
  | Some value when String.trim value <> "" -> value
  | _ -> Alcotest.fail (name ^ " is required by the migration integration suite")

let fail_runner label error =
  Alcotest.failf "%s: %s" label (Migration_runner.error_code error)

let runner_ok label = function
  | Ok value -> value
  | Error error -> fail_runner label error

let db_ok label = function
  | Ok value -> value
  | Error `Database_operation_failed ->
      Alcotest.fail (label ^ ": safe database failure")

let source filename sql : Migration_catalog.source = { filename; sql }

let catalog_ok = function
  | Ok value -> value
  | Error error ->
      Alcotest.failf "catalog: %s" (Migration_catalog.error_code error)

let baseline_source () =
  match
    List.find_opt
      (fun entry -> Migration_catalog.entry_version entry = 1L)
      (Migration_catalog.entries Migration_catalog.production)
  with
  | Some entry ->
      source
        (Migration_catalog.entry_filename entry)
        (Migration_catalog.entry_sql entry)
  | None -> Alcotest.fail "production catalog must contain the baseline"

let runner_schema harness =
  Postgres_schema_harness.schema_name harness
  |> Postgres_schema_harness.Schema_name.to_string
  |> Migration_runner.Schema.of_string
  |> function
  | Ok schema -> schema
  | Error error -> fail_runner "generated schema validation" error

let run ?(catalog = Migration_catalog.production) harness =
  Migration_runner.run ~schema:(runner_schema harness) catalog

let status ?(catalog = Migration_catalog.production) harness =
  Migration_runner.status ~schema:(runner_schema harness) catalog

let with_query harness callback =
  let* result = Postgres_schema_harness.with_transaction harness callback in
  Lwt.return (db_ok "migration query" result)

let ledger_count_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->! Caqti_type.int)
    "SELECT count(*)::int FROM schema_migrations"

let relation_count_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->! Caqti_type.int)
    "SELECT count(*)::int FROM pg_catalog.pg_class c JOIN \
     pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = \
     current_schema() AND c.relkind IN ('r','p')"

let custom_type_count_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->! Caqti_type.int)
    "SELECT count(*)::int FROM pg_catalog.pg_type t JOIN \
     pg_catalog.pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = \
     current_schema() AND t.typtype IN ('d','e','r')"

let ledger_shape_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->! Caqti_type.(t4 int64 string string float))
    "SELECT version, filename, checksum_sha256, extract(epoch FROM \
     applied_at)::float8 FROM schema_migrations WHERE version = 1"

let relation_absent_request =
  let open Caqti_request.Infix in
  (Caqti_type.string ->! Caqti_type.bool) "SELECT to_regclass(?) IS NULL"

let search_path_clean_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->! Caqti_type.bool)
    "SELECT current_setting('search_path') NOT LIKE '%fca_it_%'"

let timezone_epoch_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->! Caqti_type.float)
    "SELECT extract(epoch FROM applied_at)::float8 FROM schema_migrations WHERE \
     version = 1"

let set_timezone_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->. Caqti_type.unit) "SET LOCAL TIME ZONE 'Pacific/Auckland'"

let check_status expected_applied expected_pending expected_current actual =
  Alcotest.(check int)
    "applied" expected_applied actual.Migration_runner.applied_count;
  Alcotest.(check int) "pending" expected_pending actual.pending_count;
  Alcotest.(check (option int64))
    "current" expected_current actual.current_version

let fresh_apply_and_idempotency harness =
  let* before = status harness in
  check_status 0 4 None (runner_ok "read-only status before apply" before);
  let* current_before =
    Migration_runner.current ~schema:(runner_schema harness)
      Migration_catalog.production
  in
  Alcotest.(check (option int64))
    "read-only current before apply" None
    (runner_ok "read-only current" current_before);
  let* absent_before =
    with_query harness (fun (module C : Caqti_lwt.CONNECTION) ->
        C.find relation_absent_request "schema_migrations")
  in
  Alcotest.(check bool) "status/current perform no DDL" true absent_before;
  let* first = run harness in
  check_status 4 0 (Some 4L) (runner_ok "fresh apply" first);
  let* row =
    with_query harness (fun (module C : Caqti_lwt.CONNECTION) ->
        C.find ledger_shape_request ())
  in
  let version, filename, checksum, applied_at = row in
  Alcotest.(check int64) "baseline version" 1L version;
  Alcotest.(check string)
    "baseline filename" "000001_create_schema_migrations.sql" filename;
  Alcotest.(check bool)
    "lowercase SHA-256" true
    (String.length checksum = 64
    && String.for_all
         (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
         checksum);
  let* counts =
    with_query harness (fun (module C : Caqti_lwt.CONNECTION) ->
        let* ledger = C.find ledger_count_request () in
        match ledger with
        | Error _ as error -> Lwt.return error
        | Ok ledger -> (
            let* relations = C.find relation_count_request () in
            match relations with
            | Error _ as error -> Lwt.return error
            | Ok relations ->
                let* custom_types = C.find custom_type_count_request () in
                Lwt.return
                  (Result.map
                     (fun custom_types -> (ledger, relations, custom_types))
                     custom_types)))
  in
  let ledger, relations, custom_types = counts in
  Alcotest.(check int) "all production migrations recorded" 4 ledger;
  Alcotest.(check bool) "production relations created" true (relations > 1);
  Alcotest.(check int) "production does not require custom types" 0 custom_types;
  let* second = run harness in
  check_status 4 0 (Some 4L) (runner_ok "idempotent rerun" second);
  let* rerun_epoch =
    with_query harness (fun (module C : Caqti_lwt.CONNECTION) ->
        C.find timezone_epoch_request ())
  in
  Alcotest.(check (float 0.000001)) "applied_at stable" applied_at rerun_epoch;
  let* zoned_epoch =
    with_query harness (fun (module C : Caqti_lwt.CONNECTION) ->
        let* changed = C.exec set_timezone_request () in
        match changed with
        | Error _ as error -> Lwt.return error
        | Ok () -> C.find timezone_epoch_request ())
  in
  Alcotest.(check (float 0.000001))
    "TIMESTAMPTZ is the same instant" applied_at zoned_epoch;
  let* clean =
    Db_pool.with_connection (fun (module C : Caqti_lwt.CONNECTION) ->
        C.find search_path_clean_request ())
  in
  Alcotest.(check bool)
    "transaction-local search_path cleaned" true
    (match clean with Ok value -> value | Error _ -> false);
  Lwt.return_unit

let same_schema_concurrency harness =
  let schema = runner_schema harness in
  let* left, right =
    Lwt.both
      (Migration_runner.run ~schema Migration_catalog.production)
      (Migration_runner.run ~schema Migration_catalog.production)
  in
  check_status 4 0 (Some 4L) (runner_ok "same-schema left" left);
  check_status 4 0 (Some 4L) (runner_ok "same-schema right" right);
  let* count =
    with_query harness (fun (module C : Caqti_lwt.CONNECTION) ->
        C.find ledger_count_request ())
  in
  Alcotest.(check int) "serialized production ledger rows" 4 count;
  Lwt.return_unit

let cross_schema_isolation () =
  Postgres_schema_harness.with_harness (fun left ->
      Postgres_schema_harness.with_harness (fun right ->
          let* left_result, right_result = Lwt.both (run left) (run right) in
          ignore (runner_ok "cross-schema left" left_result);
          ignore (runner_ok "cross-schema right" right_result);
          let* left_count, right_count =
            Lwt.both
              (with_query left (fun (module C : Caqti_lwt.CONNECTION) ->
                   C.find ledger_count_request ()))
              (with_query right (fun (module C : Caqti_lwt.CONNECTION) ->
                   C.find ledger_count_request ()))
          in
          Alcotest.(check (pair int int))
            "isolated ledgers" (4, 4) (left_count, right_count);
          Lwt.return_unit))

let invalid_schema_and_catalog_pre_mutation harness =
  List.iter
    (fun value ->
      match Migration_runner.Schema.of_string value with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail ("unsafe schema accepted: " ^ value))
    [ ""; "Public"; "public;drop_schema"; "a-b"; String.make 64 'a' ];
  List.iter
    (fun invalid_sql ->
      match
        Migration_catalog.of_sources [ source "900001_invalid.sql" invalid_sql ]
      with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "unsafe catalog accepted")
    [
      "/* no */ SELECT 1;";
      "BEGIN;";
      "SELECT ?;";
      "SELECT $(unsafe);";
      "SELECT 1";
    ];
  let* absent =
    with_query harness (fun (module C : Caqti_lwt.CONNECTION) ->
        C.find relation_absent_request "schema_migrations")
  in
  Alcotest.(check bool) "invalid input did not mutate" true absent;
  Lwt.return_unit

let parser_execution harness =
  let sql =
    "CREATE TABLE parser_probe (tenant_id uuid NOT NULL, value text NOT NULL, \
     PRIMARY KEY (tenant_id, value));\n\
     INSERT INTO parser_probe VALUES ('11111111-1111-4111-8111-111111111111', \
     'quoted;value');\n\
     DO $body$ BEGIN PERFORM 'dollar;value'; END $body$;\n"
  in
  let catalog =
    catalog_ok
      (Migration_catalog.of_sources
         [ baseline_source (); source "900001_parser_probe.sql" sql ])
  in
  let* result = run ~catalog harness in
  check_status 2 0 (Some 900001L) (runner_ok "parser execution" result);
  Lwt.return_unit

let execute_request sql =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true sql

let drift_case mutation =
  Postgres_schema_harness.with_harness (fun harness ->
      let* applied = run harness in
      ignore (runner_ok "drift setup" applied);
      let* () =
        with_query harness (fun (module C : Caqti_lwt.CONNECTION) ->
            C.exec (execute_request mutation) ())
      in
      let* result = run harness in
      (match result with
      | Error error ->
          Alcotest.(check string)
            "drift code" "MIGRATION_DRIFT"
            (Migration_runner.error_code error)
      | Ok _ -> Alcotest.fail "drift unexpectedly accepted");
      Lwt.return_unit)

let drift_checks () =
  let* () =
    drift_case "UPDATE schema_migrations SET checksum_sha256 = repeat('0', 64)"
  in
  let* () =
    drift_case
      "UPDATE schema_migrations SET filename = '000001_filename_drift.sql' WHERE version = 1"
  in
  drift_case "UPDATE schema_migrations SET version = 999999 WHERE version = 1"

let non_prefix_drift () =
  Postgres_schema_harness.with_harness (fun harness ->
      let catalog =
        catalog_ok
          (Migration_catalog.of_sources
             [
               baseline_source ();
               source "900001_second.sql"
                 "CREATE TABLE second_probe (value int);";
             ])
      in
      let* applied = run ~catalog harness in
      ignore (runner_ok "prefix setup" applied);
      let* () =
        with_query harness (fun (module C : Caqti_lwt.CONNECTION) ->
            C.exec
              (execute_request "DELETE FROM schema_migrations WHERE version = 1")
              ())
      in
      let* result = run ~catalog harness in
      (match result with
      | Error error ->
          Alcotest.(check string)
            "non-prefix" "MIGRATION_DRIFT"
            (Migration_runner.error_code error)
      | Ok _ -> Alcotest.fail "non-prefix accepted");
      Lwt.return_unit)

let forced_rollback harness =
  let failing_sql =
    "CREATE TABLE rollback_created (value int); INSERT INTO missing_relation \
     VALUES (1);"
  in
  let catalog =
    catalog_ok
      (Migration_catalog.of_sources
         [ baseline_source (); source "900002_forced_failure.sql" failing_sql ])
  in
  let* result = run ~catalog harness in
  (match result with
  | Error error ->
      Alcotest.(check string)
        "apply failure" "MIGRATION_APPLY_FAILED"
        (Migration_runner.error_code error)
  | Ok _ -> Alcotest.fail "forced failure succeeded");
  let* count, absent =
    Lwt.both
      (with_query harness (fun (module C : Caqti_lwt.CONNECTION) ->
           C.find ledger_count_request ()))
      (with_query harness (fun (module C : Caqti_lwt.CONNECTION) ->
           C.find relation_absent_request "rollback_created"))
  in
  Alcotest.(check int) "committed prefix retained" 1 count;
  Alcotest.(check bool) "failed migration rolled back" true absent;
  Lwt.return_unit

let tenant_fixture_mechanics harness =
  let tenant_a = "11111111-1111-4111-8111-111111111111" in
  let tenant_b = "22222222-2222-4222-8222-222222222222" in
  let sql =
    "CREATE TABLE fixture_tenants (tenant_id uuid PRIMARY KEY);\n\
     CREATE TABLE fixture_rows (tenant_id uuid NOT NULL REFERENCES \
     fixture_tenants(tenant_id), logical_key text NOT NULL, value text NOT \
     NULL, PRIMARY KEY (tenant_id, logical_key));\n\
     CREATE INDEX fixture_rows_tenant_value_idx ON fixture_rows (tenant_id, \
     value);\n\
     INSERT INTO fixture_tenants VALUES \
     ('11111111-1111-4111-8111-111111111111'), \
     ('22222222-2222-4222-8222-222222222222');\n\
     INSERT INTO fixture_rows VALUES ('11111111-1111-4111-8111-111111111111', \
     'overlap', 'left'), ('22222222-2222-4222-8222-222222222222', 'overlap', \
     'right');"
  in
  let catalog =
    catalog_ok
      (Migration_catalog.of_sources
         [ baseline_source (); source "900003_tenant_fixture.sql" sql ])
  in
  let* result = run ~catalog harness in
  ignore (runner_ok "tenant fixture" result);
  let request =
    let open Caqti_request.Infix in
    (Caqti_type.(t2 string string) ->! Caqti_type.string)
      "SELECT value FROM fixture_rows WHERE tenant_id = ?::uuid AND \
       logical_key = ?"
  in
  let* left, right =
    Lwt.both
      (with_query harness (fun (module C : Caqti_lwt.CONNECTION) ->
           C.find request (tenant_a, "overlap")))
      (with_query harness (fun (module C : Caqti_lwt.CONNECTION) ->
           C.find request (tenant_b, "overlap")))
  in
  Alcotest.(check (pair string string))
    "bidirectional tenant-leading reads" ("left", "right") (left, right);
  Lwt.return_unit

let quote_identifier value = "\"" ^ value ^ "\""

let database_request verb database =
  execute_request (verb ^ " DATABASE " ^ quote_identifier database)

let replace_database uri database =
  Uri.with_path uri ("/" ^ database) |> Uri.to_string

let run_process executable environment =
  let output = Filename.temp_file "fca-migrate-cli" ".txt" in
  let descriptor = Unix.openfile output [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let pid =
    Unix.create_process_env executable [| executable |] environment Unix.stdin
      descriptor descriptor
  in
  let status = snd (Unix.waitpid [] pid) in
  Unix.close descriptor;
  let channel = open_in_bin output in
  let text = really_input_string channel (in_channel_length channel) in
  close_in channel;
  Sys.remove output;
  (status, text)

let cli_twice database_uri =
  let database =
    Printf.sprintf "fca_cli_%x"
      (Hashtbl.hash (Unix.gettimeofday (), Unix.getpid ()))
  in
  let* created =
    Db_pool.with_connection (fun (module C : Caqti_lwt.CONNECTION) ->
        C.exec (database_request "CREATE" database) ())
  in
  (match created with
  | Ok () -> ()
  | Error error ->
      Alcotest.failf "CLI database create: %s"
        (Errors.Code.to_string (Db_pool.error_code error)));
  Lwt.finalize
    (fun () ->
      let target = replace_database database_uri database in
      let base = Array.to_list (Unix.environment ()) in
      let replace name value entries =
        let prefix = name ^ "=" in
        (prefix ^ value)
        :: List.filter
             (fun entry -> not (String.starts_with ~prefix entry))
             entries
      in
      let environment =
        base
        |> replace "DATABASE_URL" target
        |> replace "REDIS_URL" "redis://localhost:6379/0"
        |> replace "SECRET_KEY_BASE"
             "test-only-secret-key-base-32-bytes-minimum"
        |> replace "APP_ENV" "test" |> Array.of_list
      in
      let executable = "tests/integration/run_migrate_cli.sh" in
      let process_status, output = run_process executable environment in
      let expected_line =
        "{\"status\":\"current\",\"applied\":4,\"pending\":0,\"current_version\":4}"
      in
      let lines =
        String.split_on_char '\n' output
        |> List.filter (fun line -> String.trim line <> "")
      in
      Alcotest.(check bool)
        "compiled CLI exits cleanly" true
        (process_status = Unix.WEXITED 0);
      Alcotest.(check (list string))
        "compiled CLI runs exactly twice"
        [ expected_line; expected_line ]
        lines;
      Lwt.return_unit)
    (fun () ->
      let* dropped =
        Db_pool.with_connection (fun (module C : Caqti_lwt.CONNECTION) ->
            C.exec (database_request "DROP" database) ())
      in
      (match dropped with
      | Ok () -> ()
      | Error _ -> Alcotest.fail "CLI disposable database cleanup failed");
      Lwt.return_unit)

let test_runner_matrix () =
  let database_uri = Uri.of_string (required_env "DATABASE_URL") in
  Lwt_main.run
    (let* started = Db_pool.start ~max_size:10 database_uri in
     (match started with
     | Ok _ -> ()
     | Error error ->
         Alcotest.failf "pool start: %s"
           (Errors.Code.to_string (Db_pool.error_code error)));
     Lwt.finalize
       (fun () ->
         let* () =
           Postgres_schema_harness.with_harness fresh_apply_and_idempotency
         in
         let* () =
           Postgres_schema_harness.with_harness same_schema_concurrency
         in
         let* () = cross_schema_isolation () in
         let* () =
           Postgres_schema_harness.with_harness
             invalid_schema_and_catalog_pre_mutation
         in
         let* () = Postgres_schema_harness.with_harness parser_execution in
         let* () = drift_checks () in
         let* () = non_prefix_drift () in
         let* () = Postgres_schema_harness.with_harness forced_rollback in
         let* () =
           Postgres_schema_harness.with_harness tenant_fixture_mechanics
         in
         cli_twice database_uri)
       Db_pool.shutdown)

let run () =
  Alcotest.run "Production migration runner"
    [
      ( "PostgreSQL 16",
        [
          Alcotest.test_case "catalog runner ledger drift rollback CLI" `Quick
            test_runner_matrix;
        ] );
    ]
