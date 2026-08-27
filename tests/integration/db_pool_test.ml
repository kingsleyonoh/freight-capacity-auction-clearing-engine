let ( let* ) = Lwt.bind

let echo_query =
  let open Caqti_request.Infix in
  (Caqti_type.int -->! Caqti_type.int) @:- "SELECT ?"

let required_env name =
  match Sys.getenv_opt name with
  | Some value when String.trim value <> "" -> value
  | _ -> Alcotest.fail (name ^ " is required by the PostgreSQL harness")

let contains ~needle haystack =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  let rec loop index =
    if needle_length = 0 then true
    else if index + needle_length > haystack_length then false
    else if String.sub haystack index needle_length = needle then true
    else loop (index + 1)
  in
  loop 0

let password_from_uri uri =
  match Uri.userinfo uri with
  | None -> Alcotest.fail "test URI has no userinfo"
  | Some userinfo ->
      (match String.index_opt userinfo ':' with
       | None -> Alcotest.fail "test URI has no password"
       | Some index ->
           String.sub userinfo (index + 1) (String.length userinfo - index - 1))

let check_error_code expected error =
  Alcotest.(check string) "stable safe error code" expected
    (Errors.Code.to_string (Db_pool.error_code error))

let expect_error expected = function
  | Error error -> check_error_code expected error
  | Ok _ -> Alcotest.fail ("expected typed error " ^ expected)

let query value =
  Db_pool.with_connection (fun (module Connection : Caqti_lwt.CONNECTION) ->
      Connection.find echo_query value)

let check_query_result expected = function
  | Ok actual -> Alcotest.(check int) "parameterized SELECT result" expected actual
  | Error error ->
      Alcotest.failf "query failed with safe code %s"
        (Errors.Code.to_string (Db_pool.error_code error))

let check_identity first = function
  | Ok current -> Alcotest.(check bool) "same cached handle" true (first == current)
  | Error error ->
      Alcotest.failf "cached start failed with safe code %s"
        (Errors.Code.to_string (Db_pool.error_code error))

let assert_not_leaked ~wrong_uri ~captured_logs startup_error =
  let uri_text = Uri.to_string wrong_uri in
  let password = password_from_uri wrong_uri in
  let safe_message = Db_pool.error_message startup_error in
  Alcotest.(check bool) "wrong URI absent from error" false
    (contains ~needle:uri_text safe_message);
  Alcotest.(check bool) "wrong password absent from error" false
    (contains ~needle:password safe_message);
  Alcotest.(check bool) "wrong URI absent from captured logs" false
    (List.exists (contains ~needle:uri_text) !captured_logs);
  Alcotest.(check bool) "wrong password absent from captured logs" false
    (List.exists (contains ~needle:password) !captured_logs)

let prestart_and_failed_start database_uri wrong_uri captured_logs =
  let callback_called = ref false in
  let* before_start =
    Db_pool.with_connection (fun _ ->
        callback_called := true;
        Lwt.return (Ok ()))
  in
  expect_error "DATABASE_POOL_NOT_STARTED" before_start;
  Alcotest.(check bool) "pre-start callback not entered" false !callback_called;
  expect_error "DATABASE_POOL_NOT_STARTED" (Db_pool.get ());
  let* invalid_size = Db_pool.start ~max_size:0 database_uri in
  expect_error "DATABASE_POOL_INVALID_SIZE" invalid_size;
  let* failed_start = Db_pool.start ~max_size:4 wrong_uri in
  let startup_error =
    match failed_start with
    | Error error -> check_error_code "DATABASE_STARTUP_FAILED" error; error
    | Ok _ -> Alcotest.fail "wrong-password startup unexpectedly succeeded"
  in
  expect_error "DATABASE_POOL_NOT_STARTED" (Db_pool.get ());
  assert_not_leaked ~wrong_uri ~captured_logs startup_error;
  Lwt.return_unit

let cached_start_and_queries database_uri =
  let starts = List.init 8 (fun _ -> Db_pool.start ~max_size:4 database_uri) in
  let* concurrent_results = Lwt.all starts in
  let first =
    match concurrent_results with
    | Ok handle :: rest -> List.iter (check_identity handle) rest; handle
    | Error error :: _ ->
        Alcotest.failf "retry failed with safe code %s"
          (Errors.Code.to_string (Db_pool.error_code error))
    | [] -> Alcotest.fail "no concurrent startup results"
  in
  let* sequential = Db_pool.start ~max_size:4 database_uri in
  check_identity first sequential;
  (match Db_pool.get () with
   | Ok cached -> Alcotest.(check bool) "get returns cached handle" true (first == cached)
   | Error error ->
       Alcotest.failf "get failed with safe code %s"
         (Errors.Code.to_string (Db_pool.error_code error)));
  let* startup_query = query 1 in
  check_query_result 1 startup_query;
  let values = List.init 32 Fun.id in
  let* query_results = Lwt.all (List.map query values) in
  List.iter2 check_query_result values query_results;
  Lwt.return_unit

let draining_shutdown () =
  let entered, signal_entered = Lwt.wait () in
  let release, signal_release = Lwt.wait () in
  let active_use =
    Db_pool.with_connection (fun (module Connection : Caqti_lwt.CONNECTION) ->
        if Lwt.is_sleeping entered then Lwt.wakeup_later signal_entered ();
        let* () = release in
        Connection.find echo_query 99)
  in
  let* () = entered in
  let shutdown_one = Db_pool.shutdown () in
  let shutdown_two = Db_pool.shutdown () in
  let* () = Lwt.pause () in
  expect_error "DATABASE_POOL_STOPPING" (Db_pool.get ());
  let stopped_callback_called = ref false in
  let* rejected =
    Db_pool.with_connection (fun _ ->
        stopped_callback_called := true;
        Lwt.return (Ok ()))
  in
  expect_error "DATABASE_POOL_STOPPING" rejected;
  Alcotest.(check bool) "no callback admitted after stopping" false
    !stopped_callback_called;
  Lwt.wakeup_later signal_release ();
  let* active_result = active_use in
  check_query_result 99 active_result;
  let* () = Lwt.join [ shutdown_one; shutdown_two; Db_pool.shutdown () ] in
  let* () = Db_pool.shutdown () in
  expect_error "DATABASE_POOL_STOPPED" (Db_pool.get ());
  let* after_stop = query 3 in
  expect_error "DATABASE_POOL_STOPPED" after_stop;
  Lwt.return_unit

let test_lifecycle_matrix () =
  let database_uri = Uri.of_string (required_env "DATABASE_URL") in
  let wrong_uri = Uri.of_string (required_env "DATABASE_URL_WRONG") in
  let captured_logs = ref [] in
  Logging.configure ~level:(Some Logs.Debug)
    ~write:(fun line -> captured_logs := line :: !captured_logs) ();
  Lwt_main.run
    (let* () = prestart_and_failed_start database_uri wrong_uri captured_logs in
     let* () = cached_start_and_queries database_uri in
     draining_shutdown ())

let run () =
  Alcotest.run "PostgreSQL pool integration"
    [ ( "real PostgreSQL 16",
        [ Alcotest.test_case "startup, cache, failure, concurrency, shutdown"
            `Quick test_lifecycle_matrix ] ) ]
