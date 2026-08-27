let ( let* ) = Lwt.bind

module Queue_suite = Queue_conformance.Make (Redis_queue_conformance_adapter)

let required_env name =
  match Sys.getenv_opt name with
  | Some value when String.trim value <> "" -> value
  | _ -> Alcotest.fail (name ^ " is required by the Redis harness")

let code error = Errors.Code.to_string (Redis_queue.error_code error)

let expect_error expected = function
  | Error error -> Alcotest.(check string) "stable error" expected (code error)
  | Ok _ -> Alcotest.fail ("expected " ^ expected)

let ok label = function
  | Ok value -> value
  | Error error -> Alcotest.failf "%s: %s" label (code error)

let contains ~needle value =
  let needle_length = String.length needle in
  let rec loop index =
    if index + needle_length > String.length value then false
    else if String.sub value index needle_length = needle then true
    else loop (index + 1)
  in
  needle_length = 0 || loop 0

let credential_markers uri =
  match Uri.userinfo uri with
  | None -> []
  | Some userinfo -> [ userinfo; Uri.pct_decode userinfo; Uri.to_string uri ]

let assert_redacted label markers logs error =
  let message = Redis_queue.error_message error in
  List.iter
    (fun marker ->
      Alcotest.(check bool)
        (label ^ " absent from error")
        false
        (contains ~needle:marker message);
      Alcotest.(check bool)
        (label ^ " absent from logs")
        false
        (List.exists (contains ~needle:marker) !logs))
    markers

let payload_string payload =
  match Redis_queue.Payload.bytes_value payload with
  | Some value -> Bytes.to_string value
  | None -> Alcotest.fail "expected bytes payload"

let malformed_uris base =
  let suffix =
    let raw = Uri.to_string base in
    String.sub raw 8 (String.length raw - 8)
  in
  List.map Uri.of_string
    [
      "redis://@" ^ suffix;
      "redis://:@" ^ suffix;
      "redis://user:@" ^ suffix;
      "redis://password@" ^ suffix;
      "redis://%40@" ^ suffix;
    ]

let startup uri wrong_uri denied_uri base_uri logs =
  expect_error "REDIS_NOT_STARTED" (Redis_queue.get ());
  let* invalid_timeout = Redis_queue.start ~timeout_s:nan uri in
  expect_error "REDIS_INVALID_CONFIG" invalid_timeout;
  let* rejected_tls =
    Redis_queue.start ~timeout_s:0.15
      (Uri.of_string "rediss://127.0.0.1:6379/15")
  in
  expect_error "REDIS_INVALID_CONFIG" rejected_tls;
  let* () =
    Lwt_list.iter_s
      (fun malformed ->
        let* result = Redis_queue.start ~timeout_s:0.15 malformed in
        expect_error "REDIS_INVALID_CONFIG" result;
        Lwt.return_unit)
      (malformed_uris base_uri)
  in
  let* failed = Redis_queue.start ~timeout_s:0.5 wrong_uri in
  let failed_error =
    match failed with
    | Error error -> error
    | Ok _ -> Alcotest.fail "wrong Redis credentials unexpectedly succeeded"
  in
  Alcotest.(check string)
    "wrong credentials fail eagerly" "REDIS_STARTUP_FAILED" (code failed_error);
  assert_redacted "wrong credentials"
    (credential_markers wrong_uri)
    logs failed_error;
  expect_error "REDIS_NOT_STARTED" (Redis_queue.get ());
  let* denied = Redis_queue.start ~timeout_s:0.5 denied_uri in
  expect_error "REDIS_STARTUP_FAILED" denied;
  expect_error "REDIS_NOT_STARTED" (Redis_queue.get ());
  let* results =
    Lwt.all (List.init 8 (fun _ -> Redis_queue.start ~timeout_s:2.0 uri))
  in
  let handles = List.map (ok "start") results in
  let first = List.hd handles in
  List.iter
    (fun current ->
      Alcotest.(check bool) "one cached handle" true (first == current))
    handles;
  Lwt.return first

let queue_cases redis =
  let queue =
    ok "queue"
      (Redis_queue.Queue.make ~name:"jobs" ~max_depth:2 ~max_payload_bytes:128)
  in
  Alcotest.(check bool)
    "strict queue name" true
    (Result.is_error
       (Redis_queue.Queue.make ~name:"BAD NAME" ~max_depth:2
          ~max_payload_bytes:128));
  let too_large = Redis_queue.Payload.bytes (Bytes.make 129 'x') in
  let* rejected = Redis_queue.enqueue redis queue too_large in
  expect_error "REDIS_PAYLOAD_TOO_LARGE" rejected;
  let* first =
    Redis_queue.enqueue redis queue
      (Redis_queue.Payload.bytes (Bytes.of_string "one"))
  in
  ignore (ok "enqueue one" first);
  let json = Redis_queue.Payload.json (`Assoc [ ("job", `String "two") ]) in
  let* second = Redis_queue.enqueue redis queue json in
  ignore (ok "enqueue two" second);
  let* full =
    Redis_queue.enqueue redis queue
      (Redis_queue.Payload.bytes (Bytes.of_string "three"))
  in
  expect_error "REDIS_QUEUE_FULL" full;
  let* popped = Redis_queue.dequeue redis queue in
  let popped = ok "dequeue one" popped |> Option.get in
  Alcotest.(check string) "FIFO no drop" "one" (payload_string popped);
  let* popped_json = Redis_queue.dequeue redis queue in
  let popped_json = ok "dequeue JSON" popped_json |> Option.get in
  Alcotest.(check bool)
    "JSON typed" true
    (Option.is_some (Redis_queue.Payload.json_value popped_json));
  let* empty = Redis_queue.dequeue redis queue in
  Alcotest.(check bool)
    "nonblocking empty" true
    (Option.is_none (ok "empty" empty));
  let poison =
    ok "poison queue"
      (Redis_queue.Queue.make ~name:"poison" ~max_depth:2 ~max_payload_bytes:128)
  in
  let* poison_result = Redis_queue.dequeue redis poison in
  expect_error "REDIS_POISON_PAYLOAD" poison_result;
  Lwt.return_unit

let lock_cases redis tenant_id =
  let lock =
    ok "lock" (Redis_queue.Lock.make ~tenant_id ~resource:"auction:close")
  in
  let owner_a =
    ok "owner A" (Redis_queue.Owner_token.of_string "worker-a-123456")
  in
  let owner_b =
    ok "owner B" (Redis_queue.Owner_token.of_string "worker-b-123456")
  in
  let* acquired = Redis_queue.acquire redis lock ~owner:owner_a ~ttl_ms:150 in
  Alcotest.(check bool) "acquired" true (ok "acquire" acquired);
  let* duplicate = Redis_queue.acquire redis lock ~owner:owner_b ~ttl_ms:150 in
  Alcotest.(check bool) "NX blocks other owner" false (ok "duplicate" duplicate);
  let* wrong_renew = Redis_queue.renew redis lock ~owner:owner_b ~ttl_ms:300 in
  Alcotest.(check bool)
    "wrong owner cannot renew" true
    (ok "renew" wrong_renew = `Not_owner);
  let* renewed = Redis_queue.renew redis lock ~owner:owner_a ~ttl_ms:300 in
  Alcotest.(check bool) "owner renews" true (ok "renew" renewed = `Renewed);
  let* wrong_release = Redis_queue.release redis lock ~owner:owner_b in
  Alcotest.(check bool)
    "wrong owner cannot release" true
    (ok "release" wrong_release = `Not_owner);
  let* released = Redis_queue.release redis lock ~owner:owner_a in
  Alcotest.(check bool) "owner releases" true (ok "release" released = `Released);
  let* reacquired = Redis_queue.acquire redis lock ~owner:owner_b ~ttl_ms:50 in
  Alcotest.(check bool)
    "released lock reusable" true
    (ok "reacquire" reacquired);
  let* () = Lwt_unix.sleep 0.08 in
  let* after_expiry =
    Redis_queue.acquire redis lock ~owner:owner_a ~ttl_ms:100
  in
  Alcotest.(check bool) "expired lock reusable" true (ok "expiry" after_expiry);
  Lwt.return_unit

let progress_cases redis tenant_id =
  let stream =
    ok "stream"
      (Redis_queue.Progress_stream.make ~tenant_id ~job_id:"job-123"
         ~max_length:10)
  in
  let rec append index last_id =
    if index = 250 then Lwt.return last_id
    else
      let progress =
        ok "progress"
          (Redis_queue.Progress.make ~state:"running" ~completed:index
             ~total:249 ())
      in
      let* result = Redis_queue.append_progress redis stream progress in
      append (index + 1) (Some (ok "append" result))
  in
  let* last_id = append 0 None in
  let* entries = Redis_queue.read_progress redis stream ~after:None ~limit:5 in
  let entries = ok "read" entries in
  Alcotest.(check int) "typed bounded XREAD" 5 (List.length entries);
  let first_id = fst (List.hd entries) in
  let* later =
    Redis_queue.read_progress redis stream ~after:(Some first_id) ~limit:3
  in
  Alcotest.(check int)
    "after excludes cursor" 3
    (List.length (ok "read later" later));
  Alcotest.(check bool)
    "append returned stream id" true (Option.is_some last_id);
  Lwt.return_unit

let tenant_id () =
  let fixture_path =
    Option.value
      (Sys.getenv_opt "FCA_TENANT_FIXTURE")
      ~default:"tests/fixtures/tenants.json"
  in
  let raw_id =
    match Tenant_fixture.load_file fixture_path with
    | Ok { tenants = first :: _; _ } -> first.Tenant_fixture.id
    | Ok _ | Error _ -> Alcotest.fail "canonical tenant fixture is invalid"
  in
  match Tenant_context.Tenant_id.of_string raw_id with
  | Ok value -> value
  | Error _ -> Alcotest.fail "canonical tenant UUID invalid"

let core_lifecycle () =
  let uri = Uri.of_string (required_env "REDIS_URL") in
  let wrong_uri = Uri.of_string (required_env "REDIS_URL_WRONG") in
  let denied_uri = Uri.of_string (required_env "REDIS_URL_DENIED") in
  let base_uri = Uri.of_string (required_env "REDIS_BASE_URL") in
  let captured_logs = ref [] in
  Logging.configure ~level:(Some Logs.Debug)
    ~write:(fun line -> captured_logs := line :: !captured_logs)
    ();
  Lwt_main.run
    (let* redis = startup uri wrong_uri denied_uri base_uri captured_logs in
     let* () = queue_cases redis in
     let* () = lock_cases redis (tenant_id ()) in
     let* () = progress_cases redis (tenant_id ()) in
     let* () =
       Lwt_list.iter_s
         (fun case -> case.Queue_conformance.run redis)
         Queue_suite.cases
     in
     expect_error "REDIS_STOPPED" (Redis_queue.get ());
     Lwt.return_unit)

let acl_lifecycle () =
  let uri = Uri.of_string (required_env "REDIS_URL_ACL") in
  let wrong_uri = Uri.of_string (required_env "REDIS_URL_ACL_WRONG") in
  let logs = ref [] in
  Logging.configure ~level:(Some Logs.Debug)
    ~write:(fun line -> logs := line :: !logs)
    ();
  Lwt_main.run
    (let* failed = Redis_queue.start ~timeout_s:0.5 wrong_uri in
     let error =
       match failed with
       | Error error -> error
       | Ok _ -> Alcotest.fail "wrong ACL credentials unexpectedly succeeded"
     in
     Alcotest.(check string)
       "wrong ACL AUTH" "REDIS_STARTUP_FAILED" (code error);
     assert_redacted "ACL credentials" (credential_markers wrong_uri) logs error;
     let* redis = Redis_queue.start ~timeout_s:2.0 uri in
     ignore (ok "ACL startup retry" redis);
     let* () = Redis_queue.shutdown () in
     Lwt.return_unit)

let marker name = Filename.concat (required_env "FCA_REDIS_CONTROL_DIR") name

let write_marker name =
  let channel = open_out_bin (marker name) in
  output_string channel "ok\n";
  close_out channel

let rec wait_marker name deadline =
  if Sys.file_exists (marker name) then Lwt.return_unit
  else if Unix.gettimeofday () >= deadline then
    Alcotest.fail ("timed out waiting for Redis harness marker " ^ name)
  else
    let* () = Lwt_unix.sleep 0.01 in
    wait_marker name deadline

let running_failure () =
  let uri = Uri.of_string (required_env "REDIS_URL") in
  Lwt_main.run
    (let* redis = Redis_queue.start ~timeout_s:2.0 uri in
     let redis = ok "running failure startup" redis in
     write_marker "failure-ready";
     let* () = wait_marker "failure-broken" (Unix.gettimeofday () +. 10.0) in
     let queue =
       ok "failure queue"
         (Redis_queue.Queue.make ~name:"failure" ~max_depth:2
            ~max_payload_bytes:32)
     in
     let* failed =
       Redis_queue.enqueue redis queue
         (Redis_queue.Payload.bytes (Bytes.of_string "x"))
     in
     expect_error "REDIS_UNAVAILABLE" failed;
     expect_error "REDIS_UNAVAILABLE" (Redis_queue.get ());
     let* () = Redis_queue.shutdown () in
     Lwt.return_unit)

let draining_shutdown () =
  let uri = Uri.of_string (required_env "REDIS_URL") in
  Lwt_main.run
    (let* redis = Redis_queue.start ~timeout_s:2.0 uri in
     let redis = ok "drain startup" redis in
     let queue =
       ok "drain queue"
         (Redis_queue.Queue.make ~name:"drain" ~max_depth:4
            ~max_payload_bytes:32)
     in
     write_marker "drain-ready";
     let* () = wait_marker "drain-paused" (Unix.gettimeofday () +. 10.0) in
     let active =
       Redis_queue.enqueue redis queue
         (Redis_queue.Payload.bytes (Bytes.of_string "admitted"))
     in
     let* () = Lwt.pause () in
     Alcotest.(check bool)
       "admitted operation is in flight" true (Lwt.is_sleeping active);
     let shutdown_one = Redis_queue.shutdown () in
     let shutdown_two = Redis_queue.shutdown () in
     let* () = Lwt.pause () in
     expect_error "REDIS_STOPPING" (Redis_queue.get ());
     let* rejected =
       Redis_queue.enqueue redis queue
         (Redis_queue.Payload.bytes (Bytes.of_string "late"))
     in
     expect_error "REDIS_STOPPING" rejected;
     Alcotest.(check bool)
       "shutdown waits for in-flight operation" true
       (Lwt.is_sleeping shutdown_one);
     write_marker "drain-release";
     let* () = wait_marker "drain-unpaused" (Unix.gettimeofday () +. 10.0) in
     let* active_result = active in
     ignore (ok "admitted operation drains" active_result);
     let* () =
       Lwt.join [ shutdown_one; shutdown_two; Redis_queue.shutdown () ]
     in
     expect_error "REDIS_STOPPED" (Redis_queue.get ());
     Lwt.return_unit)

let run_case name case =
  Alcotest.run "Redis queue integration"
    [ ("real authenticated Redis 7", [ Alcotest.test_case name `Quick case ]) ]

let run () =
  match Sys.getenv_opt "FCA_REDIS_SCENARIO" with
  | Some "acl" -> run_case "explicit ACL AUTH and retry" acl_lifecycle
  | Some "failure" -> run_case "running failure fails closed" running_failure
  | Some "drain" -> run_case "shutdown admission race drains" draining_shutdown
  | None | Some "core" ->
      run_case "password AUTH, queues, locks, streams" core_lifecycle
  | Some _ -> Alcotest.fail "unknown FCA_REDIS_SCENARIO"
