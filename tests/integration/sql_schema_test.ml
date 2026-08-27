open Lwt.Infix

let ( let* ) = Lwt.bind

let required_env name =
  match Sys.getenv_opt name with
  | Some value when String.trim value <> "" -> value
  | _ -> Alcotest.fail (name ^ " is required by the PostgreSQL harness")

let ok label = function
  | Ok value -> value
  | Error `Database_operation_failed ->
      Alcotest.fail (label ^ " failed with a safe database error")

let create_probe_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->. Caqti_type.unit)
    "CREATE TABLE schema_probe_rows (tenant_id UUID NOT NULL, logical_key TEXT \
     NOT NULL, probe_value TEXT NOT NULL, PRIMARY KEY (tenant_id, \
     logical_key))"

let insert_probe_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t3 string string string) ->. Caqti_type.unit)
    "INSERT INTO schema_probe_rows (tenant_id, logical_key, probe_value) \
     VALUES (?::uuid, ?, ?)"

let find_probe_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 string string) ->! Caqti_type.string)
    "SELECT probe_value FROM schema_probe_rows WHERE tenant_id = ?::uuid AND \
     logical_key = ?"

let create_rollback_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->. Caqti_type.unit)
    "CREATE TABLE rollback_probe (probe_value TEXT NOT NULL)"

let insert_rollback_request =
  let open Caqti_request.Infix in
  (Caqti_type.string ->. Caqti_type.unit)
    "INSERT INTO rollback_probe (probe_value) VALUES (?)"

let relation_absent_request =
  let open Caqti_request.Infix in
  (Caqti_type.string ->! Caqti_type.bool) "SELECT to_regclass(?) IS NULL"

let local_search_path_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->! Caqti_type.bool)
    "SELECT current_setting('search_path') NOT LIKE '%public%' AND \
     current_setting('search_path') LIKE '\"fca_it_%\",pg_catalog'"

let pooled_search_path_clean_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->! Caqti_type.bool)
    "SELECT current_setting('search_path') NOT LIKE '%fca_it_%'"

let tenant_a, tenant_b =
  let path =
    Option.value
      (Sys.getenv_opt "FCA_TENANT_FIXTURE")
      ~default:"tests/fixtures/tenants.json"
  in
  match Tenant_fixture.load_file path with
  | Ok { tenants = [ first; second ]; _ } ->
      (first.Tenant_fixture.id, second.Tenant_fixture.id)
  | Ok _ | Error _ -> Alcotest.fail "canonical tenant fixture is invalid"

let logical_key = "shared-logical-key"

let with_transaction harness callback =
  let* result = Postgres_schema_harness.with_transaction harness callback in
  Lwt.return (ok "schema transaction" result)

let create_tenant_probe harness =
  with_transaction harness (fun (module Connection : Caqti_lwt.CONNECTION) ->
      let* local_path = Connection.find local_search_path_request () in
      match local_path with
      | Error _ as error -> Lwt.return error
      | Ok false -> Alcotest.fail "transaction search_path was not isolated"
      | Ok true -> (
          let* created = Connection.exec create_probe_request () in
          match created with
          | Error _ as error -> Lwt.return error
          | Ok () -> (
              let* first =
                Connection.exec insert_probe_request
                  (tenant_a, logical_key, "tenant-a-value")
              in
              match first with
              | Error _ as error -> Lwt.return error
              | Ok () ->
                  Connection.exec insert_probe_request
                    (tenant_b, logical_key, "tenant-b-value"))))

let assert_pooled_path_clean () =
  let* result =
    Db_pool.with_connection (fun (module Connection : Caqti_lwt.CONNECTION) ->
        Connection.find pooled_search_path_clean_request ())
  in
  match result with
  | Ok clean ->
      Alcotest.(check bool)
        "transaction-local search_path did not leak" true clean;
      Lwt.return_unit
  | Error error ->
      Alcotest.failf "pooled search_path probe failed with safe code %s"
        (Errors.Code.to_string (Db_pool.error_code error))

let read_tenant_values harness =
  with_transaction harness (fun (module Connection : Caqti_lwt.CONNECTION) ->
      let* first = Connection.find find_probe_request (tenant_a, logical_key) in
      match first with
      | Error _ as error -> Lwt.return error
      | Ok first ->
          let* second =
            Connection.find find_probe_request (tenant_b, logical_key)
          in
          Lwt.return (Result.map (fun second -> (first, second)) second))

let assert_rollback harness =
  let* rollback_result =
    Postgres_schema_harness.with_rollback harness
      (fun (module Connection : Caqti_lwt.CONNECTION) ->
        let* created = Connection.exec create_rollback_request () in
        match created with
        | Error _ as error -> Lwt.return error
        | Ok () -> Connection.exec insert_rollback_request "transient")
  in
  ignore (ok "intentional rollback" rollback_result);
  let* absent =
    with_transaction harness (fun (module Connection : Caqti_lwt.CONNECTION) ->
        Connection.find relation_absent_request "rollback_probe")
  in
  Alcotest.(check bool) "rolled-back DDL/data is absent" true absent;
  Lwt.return_unit

let primary_schema_cases harness =
  let* () = create_tenant_probe harness in
  let* () = assert_pooled_path_clean () in
  let* values = read_tenant_values harness in
  Alcotest.(check (pair string string))
    "committed tenant-scoped values survive"
    ("tenant-a-value", "tenant-b-value")
    values;
  assert_rollback harness

let create_harness_pair () =
  let* created =
    Lwt.both
      (Postgres_schema_harness.create ())
      (Postgres_schema_harness.create ())
  in
  match created with
  | Ok left, Ok right -> Lwt.return (left, right)
  | _ -> Alcotest.fail "concurrent harness creation failed"

let setup_schema harness value =
  with_transaction harness (fun (module Connection : Caqti_lwt.CONNECTION) ->
      let* created = Connection.exec create_probe_request () in
      match created with
      | Error _ as error -> Lwt.return error
      | Ok () ->
          Connection.exec insert_probe_request (tenant_a, logical_key, value))

let read_schema harness =
  with_transaction harness (fun (module Connection : Caqti_lwt.CONNECTION) ->
      Connection.find find_probe_request (tenant_a, logical_key))

let cleanup_schema_pair left right =
  let left_name = Postgres_schema_harness.schema_name left in
  let right_name = Postgres_schema_harness.schema_name right in
  let* closed =
    Lwt.both
      (Postgres_schema_harness.close left)
      (Postgres_schema_harness.close right)
  in
  ignore (ok "left concurrent cleanup" (fst closed));
  ignore (ok "right concurrent cleanup" (snd closed));
  let* absent =
    Lwt.both
      (Postgres_schema_harness.schema_exists left_name)
      (Postgres_schema_harness.schema_exists right_name)
  in
  Alcotest.(check (pair bool bool))
    "concurrent schemas cleaned" (false, false)
    ( ok "left concurrent absence" (fst absent),
      ok "right concurrent absence" (snd absent) );
  Lwt.return_unit

let concurrent_schema_isolation () =
  let* left, right = create_harness_pair () in
  Lwt.finalize
    (fun () ->
      Alcotest.(check bool)
        "concurrent schema names differ" true
        (Postgres_schema_harness.Schema_name.compare
           (Postgres_schema_harness.schema_name left)
           (Postgres_schema_harness.schema_name right)
        <> 0);
      let* () =
        Lwt.both (setup_schema left "left") (setup_schema right "right")
        >|= ignore
      in
      let* values = Lwt.both (read_schema left) (read_schema right) in
      Alcotest.(check (pair string string))
        "same table/key does not leak" ("left", "right") values;
      cleanup_schema_pair left right)
    (fun () ->
      let* _ =
        Lwt.both
          (Postgres_schema_harness.close left)
          (Postgres_schema_harness.close right)
      in
      Lwt.return_unit)

exception Forced_failure

let cleanup_finalizers () =
  let success_name = ref None in
  let* () =
    Postgres_schema_harness.with_harness (fun harness ->
        success_name := Some (Postgres_schema_harness.schema_name harness);
        Lwt.return_unit)
  in
  let success_name = Option.get !success_name in
  let* success_exists = Postgres_schema_harness.schema_exists success_name in
  Alcotest.(check bool)
    "success finalizer removed schema" false
    (ok "success cleanup probe" success_exists);
  let failure_name = ref None in
  let* () =
    Lwt.catch
      (fun () ->
        Postgres_schema_harness.with_harness (fun harness ->
            failure_name := Some (Postgres_schema_harness.schema_name harness);
            Lwt.fail Forced_failure))
      (function
        | Forced_failure -> Lwt.return_unit | exception_ -> Lwt.fail exception_)
  in
  let failure_name = Option.get !failure_name in
  let* failure_exists = Postgres_schema_harness.schema_exists failure_name in
  Alcotest.(check bool)
    "failure finalizer removed schema" false
    (ok "failure cleanup probe" failure_exists);
  Lwt.return_unit

let schema_name_cases () =
  let names = Postgres_schema_harness.sample_generated_names_for_test 256 in
  Alcotest.(check int) "generated name count" 256 (List.length names);
  List.iter
    (fun name ->
      Alcotest.(check bool)
        "generated schema grammar" true
        (Postgres_schema_harness.Schema_name.is_valid name);
      Alcotest.(check bool)
        "generated schema length" true
        (Postgres_schema_harness.Schema_name.length name <= 63))
    names;
  let sorted =
    List.sort_uniq Postgres_schema_harness.Schema_name.compare names
  in
  Alcotest.(check int) "256 generated names are unique" 256 (List.length sorted)

let test_schema_mechanics () =
  schema_name_cases ();
  let database_uri = Uri.of_string (required_env "DATABASE_URL") in
  Lwt_main.run
    (let* started = Db_pool.start ~max_size:8 database_uri in
     (match started with
     | Ok _ -> ()
     | Error error ->
         Alcotest.failf "database pool startup failed with safe code %s"
           (Errors.Code.to_string (Db_pool.error_code error)));
     let* () = Postgres_schema_harness.with_harness primary_schema_cases in
     let* () = concurrent_schema_isolation () in
     let* () = cleanup_finalizers () in
     Db_pool.shutdown ())

let run () =
  Alcotest.run "PostgreSQL isolated schema mechanics"
    [
      ( "real PostgreSQL 16",
        [
          Alcotest.test_case
            "generated names, transactions, tenants, isolation, cleanup" `Quick
            test_schema_mechanics;
        ] );
    ]
