let ( let* ) = Lwt.bind
let counters : (string, int ref) Hashtbl.t = Hashtbl.create 32
let chunked_finalized = ref false
let server_exceptions = ref []
let raw_exception_marker = "synthetic-raw-exception-marker"

let bump path =
  let counter =
    match Hashtbl.find_opt counters path with
    | Some value -> value
    | None ->
        let value = ref 0 in
        Hashtbl.add counters path value;
        value
  in
  incr counter;
  !counter

let count path =
  Option.value ~default:0
    (Option.map (fun value -> !value) (Hashtbl.find_opt counters path))

let reset path = Hashtbl.replace counters path (ref 0)

let contains ~needle value =
  let needle_length = String.length needle in
  let rec loop index =
    if index + needle_length > String.length value then false
    else if String.sub value index needle_length = needle then true
    else loop (index + 1)
  in
  needle_length = 0 || loop 0

let respond ?(headers = Cohttp.Header.init ()) ?(status = `OK) body =
  Cohttp_lwt_unix.Server.respond_string ~headers ~status ~body ()

let chunked_response () =
  chunked_finalized := false;
  let chunks = ref [ String.make 700 'a'; String.make 700 'b'; String.make 700 'c' ] in
  let stream =
    Lwt_stream.from (fun () ->
        match !chunks with
        | chunk :: rest ->
            chunks := rest;
            Lwt.return_some chunk
        | [] ->
            chunked_finalized := true;
            Lwt.return_none)
  in
  Cohttp_lwt_unix.Server.respond ~status:`OK
    ~body:(Cohttp_lwt.Body.of_stream stream) ()

let retry_after_value = function
  | "/retry-clamp" | "/retry-deadline" -> Some "10"
  | "/retry-fallback" -> Some "malformed"
  | "/retry-delta" -> Some "0"
  | "/retry-date" -> Some "Sat, 06 Nov 2094 08:49:37 GMT"
  | "/retry-past" -> Some "Sun, 06 Nov 1994 08:49:37 GMT"
  | "/retry-malformed" -> Some "not-a-delay"
  | "/retry-negative" -> Some "-1"
  | "/retry-overflow" -> Some "999999999999999999999"
  | _ -> None

let retry_after_response path attempt =
  if attempt >= 2 && path <> "/retry-deadline" then respond "recovered"
  else
    match retry_after_value path with
    | Some value ->
        respond ~status:`Service_unavailable
          ~headers:(Cohttp.Header.init_with "retry-after" value) "retry"
    | None -> respond ~status:`Not_found "missing"

let callback _connection request body =
  let path = Uri.path (Cohttp.Request.uri request) in
  let attempt = bump path in
  let* _ = Cohttp_lwt.Body.to_string body in
  match path with
  | "/success" | "/success-concurrent" -> respond "ok"
  | "/json" -> respond "{\"ok\":true}"
  | "/malformed-json" -> respond "{broken"
  | "/oversize-chunked" -> chunked_response ()
  | "/slow" ->
      let* () = Lwt_unix.sleep 0.2 in
      respond "late"
  | ("/timeout-post" | "/timeout-patch") when attempt < 2 ->
      let* () = Lwt_unix.sleep 0.06 in
      respond "late"
  | "/timeout-post" | "/timeout-patch" -> respond "recovered"
  | "/retry" when attempt < 3 -> respond ~status:`Service_unavailable "retry"
  | "/retry" -> respond "recovered"
  | path when String.starts_with ~prefix:"/status-" path && attempt < 2 ->
      let code = int_of_string (String.sub path 8 (String.length path - 8)) in
      respond ~status:(Cohttp.Code.status_of_code code) "retry"
  | path when String.starts_with ~prefix:"/status-" path -> respond "recovered"
  | "/post" when attempt < 2 -> respond ~status:`Service_unavailable "retry"
  | "/post" -> respond "posted"
  | "/bad-request" -> respond ~status:`Bad_request "no retry"
  | "/backoff-release" when attempt < 2 ->
      respond ~status:`Service_unavailable
        ~headers:(Cohttp.Header.init_with "retry-after" "10") "retry"
  | "/backoff-release" -> respond "recovered"
  | path when String.starts_with ~prefix:"/retry-" path ->
      retry_after_response path attempt
  | path when String.starts_with ~prefix:"/raw-exception/" path ->
      Lwt.fail (Failure raw_exception_marker)
  | _ -> respond ~status:`Not_found "missing"

let with_fixture test =
  let fd = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt fd Unix.SO_REUSEADDR true;
  let* () = Lwt_unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) in
  Lwt_unix.listen fd 32;
  let port =
    match Lwt_unix.getsockname fd with
    | Unix.ADDR_INET (_, value) -> value
    | _ -> Alcotest.fail "fixture did not bind TCP"
  in
  let stop, signal_stop = Lwt.wait () in
  let server =
    Cohttp_lwt_unix.Server.create ~stop
      ~on_exn:(fun error -> server_exceptions := Printexc.to_string error :: !server_exceptions)
      ~mode:(`TCP (`Socket fd))
      (Cohttp_lwt_unix.Server.make ~callback ())
  in
  Lwt.finalize
    (fun () ->
      let* () = Lwt.pause () in
      test port)
    (fun () ->
      if Lwt.is_sleeping stop then Lwt.wakeup_later signal_stop ();
      let* () = server in
      let closed =
        try
          ignore (Lwt_unix.getsockname fd);
          false
        with Unix.Unix_error (Unix.EBADF, _, _) -> true
      in
      Alcotest.(check bool) "fixture socket closed" true closed;
      Lwt.return_unit)

let make_policy ~total ~attempt ~attempts ~initial ~max_backoff ~retry_after
    ~response =
  match
    Http_client.policy ~total_timeout_s:total ~attempt_timeout_s:attempt
      ~max_attempts:attempts ~initial_backoff_s:initial
      ~max_backoff_s:max_backoff ~max_retry_after_s:retry_after
      ~max_request_bytes:1024 ~max_response_bytes:response
  with
  | Ok value -> value
  | Error _ -> Alcotest.fail "valid policy rejected"

let default_policy () =
  make_policy ~total:0.2 ~attempt:0.08 ~attempts:3 ~initial:0.005
    ~max_backoff:0.01 ~retry_after:0.01 ~response:1024

let make_client ?(concurrency = 2) policy =
  match Http_client.create ~max_concurrency:concurrency policy with
  | Ok value -> value
  | Error _ -> Alcotest.fail "valid client rejected"

let client () = make_client (default_policy ())

let request ?(meth = `GET) ?headers ?body ?idempotency_key port path =
  Http_client.request ~meth
    ~uri:(Uri.of_string (Printf.sprintf "http://127.0.0.1:%d%s" port path))
    ?headers ?body ?idempotency_key ()

let ok = function
  | Ok value -> value
  | Error error ->
      Alcotest.failf "unexpected HTTP error %s"
        (Errors.Code.to_string (Http_client.error_code error))

let error = function
  | Error error -> error
  | Ok _ -> Alcotest.fail "expected HTTP error"

let error_code result =
  Errors.Code.to_string (Http_client.error_code (error result))

let test_success_validation port =
  let http = client () in
  let req = ok (request port "/success") in
  let* result = Http_client.call http ~decoder:Http_client.bytes req in
  let response = ok result in
  Alcotest.(check int) "status" 200 (Http_client.status response);
  Alcotest.(check string) "body" "ok" (Bytes.to_string (Http_client.body response));
  Alcotest.(check int) "one attempt" 1 (Http_client.attempts response);
  Alcotest.(check bool) "userinfo rejected" true
    (Result.is_error
       (Http_client.request ~meth:`GET
          ~uri:(Uri.of_string "http://user@127.0.0.1/path") ()));
  Alcotest.(check bool) "relative rejected" true
    (Result.is_error (Http_client.request ~meth:`GET ~uri:(Uri.of_string "/path") ()));
  Alcotest.(check bool) "CRLF header rejected" true
    (Result.is_error
       (Http_client.request ~meth:`GET
          ~uri:(Uri.of_string "http://127.0.0.1/path")
          ~headers:[ ("X-Test", "ok\r\ninjected") ] ()));
  Lwt.return_unit

let rec check_exact_statuses http port = function
  | [] -> Lwt.return_unit
  | code :: rest ->
      let path = Printf.sprintf "/status-%d" code in
      let* result = Http_client.call http ~decoder:Http_client.bytes (ok (request port path)) in
      Alcotest.(check int) path 2 (Http_client.attempts (ok result));
      check_exact_statuses http port rest

let rec check_retry_after http port = function
  | [] -> Lwt.return_unit
  | path :: rest ->
      let* result = Http_client.call http ~decoder:Http_client.bytes (ok (request port path)) in
      Alcotest.(check int) ("Retry-After " ^ path) 2 (Http_client.attempts (ok result));
      check_retry_after http port rest

let test_retry_matrix port =
  let http = client () in
  let* retried = Http_client.call http ~decoder:Http_client.bytes (ok (request port "/retry")) in
  Alcotest.(check int) "retryable status attempts" 3 (Http_client.attempts (ok retried));
  let* () = check_exact_statuses http port [ 408; 425; 429; 500; 502; 503; 504 ] in
  let* no_retry = Http_client.call http ~decoder:Http_client.bytes (ok (request port "/bad-request")) in
  Alcotest.(check int) "nonretryable status" 1 (Http_client.attempts (ok no_retry));
  let* post_no_key = Http_client.call http ~decoder:Http_client.bytes (ok (request ~meth:`POST port "/post")) in
  Alcotest.(check int) "unkeyed POST no retry" 1 (Http_client.attempts (ok post_no_key));
  reset "/post";
  let* keyed = Http_client.call http ~decoder:Http_client.bytes
      (ok (request ~meth:`POST ~idempotency_key:"event-123456" port "/post")) in
  Alcotest.(check int) "keyed POST retries" 2 (Http_client.attempts (ok keyed));
  check_retry_after http port
    [ "/retry-delta"; "/retry-date"; "/retry-past"; "/retry-malformed";
      "/retry-negative"; "/retry-overflow" ]

let test_keyed_timeout_retries port =
  let policy = make_policy ~total:0.25 ~attempt:0.03 ~attempts:3 ~initial:0.005
      ~max_backoff:0.01 ~retry_after:0.01 ~response:1024 in
  let http = make_client policy in
  let check meth path key =
    reset path;
    let* result = Http_client.call http ~decoder:Http_client.bytes
        (ok (request ~meth ~idempotency_key:key port path)) in
    Alcotest.(check int) (path ^ " keyed timeout retries") 2
      (Http_client.attempts (ok result));
    Lwt.return_unit
  in
  let* () = check `POST "/timeout-post" "post-timeout-123" in
  check `PATCH "/timeout-patch" "patch-timeout-123"

let rec wait_for_count path expected deadline =
  if count path >= expected then Lwt.return_unit
  else if Unix.gettimeofday () >= deadline then
    Alcotest.fail (path ^ " was not observed")
  else
    let* () = Lwt_unix.sleep 0.002 in
    wait_for_count path expected deadline

let test_pool_token_released_before_backoff port =
  reset "/backoff-release";
  let policy = make_policy ~total:1.0 ~attempt:0.2 ~attempts:2 ~initial:0.25
      ~max_backoff:0.25 ~retry_after:0.25 ~response:1024 in
  let http = make_client ~concurrency:1 policy in
  let backing_off = Http_client.call http ~decoder:Http_client.bytes
      (ok (request port "/backoff-release")) in
  let* () = wait_for_count "/backoff-release" 1 (Unix.gettimeofday () +. 1.0) in
  let started = Unix.gettimeofday () in
  let* concurrent = Http_client.call http ~decoder:Http_client.bytes
      (ok (request port "/success-concurrent")) in
  let elapsed = Unix.gettimeofday () -. started in
  Alcotest.(check int) "concurrent request succeeds" 200
    (Http_client.status (ok concurrent));
  Alcotest.(check bool) "token released while first request backs off" true
    (elapsed < 0.15);
  let* recovered = backing_off in
  Alcotest.(check int) "backing-off request retries" 2
    (Http_client.attempts (ok recovered));
  Lwt.return_unit

let test_retry_after_bounds port =
  let timed path policy =
    reset path;
    let http = make_client policy in
    let started = Unix.gettimeofday () in
    let* result = Http_client.call http ~decoder:Http_client.bytes
        (ok (request port path)) in
    Lwt.return (result, Unix.gettimeofday () -. started)
  in
  let clamp = make_policy ~total:0.4 ~attempt:0.1 ~attempts:2 ~initial:0.005
      ~max_backoff:0.01 ~retry_after:0.06 ~response:1024 in
  let* clamped, clamp_elapsed = timed "/retry-clamp" clamp in
  ignore (ok clamped);
  Alcotest.(check bool) "Retry-After is clamped" true
    (clamp_elapsed >= 0.045 && clamp_elapsed < 0.2);
  let fallback = make_policy ~total:0.4 ~attempt:0.1 ~attempts:2 ~initial:0.04
      ~max_backoff:0.04 ~retry_after:0.2 ~response:1024 in
  let* fallback_result, fallback_elapsed = timed "/retry-fallback" fallback in
  ignore (ok fallback_result);
  Alcotest.(check bool) "malformed Retry-After uses local fallback" true
    (fallback_elapsed >= 0.025 && fallback_elapsed < 0.18);
  let deadline = make_policy ~total:0.05 ~attempt:0.04 ~attempts:3 ~initial:0.01
      ~max_backoff:0.02 ~retry_after:0.2 ~response:1024 in
  let* deadline_result, deadline_elapsed = timed "/retry-deadline" deadline in
  Alcotest.(check string) "Retry-After cannot exceed deadline" "HTTP_TOTAL_TIMEOUT"
    (error_code deadline_result);
  Alcotest.(check int) "deadline blocks another attempt" 1 (count "/retry-deadline");
  Alcotest.(check bool) "deadline failure is bounded" true (deadline_elapsed < 0.12);
  Lwt.return_unit

let test_body_decode_timeout port =
  let http = client () in
  reset "/slow";
  let* unkeyed_timeout = Http_client.call http ~decoder:Http_client.bytes
      (ok (request ~meth:`POST port "/slow")) in
  Alcotest.(check string) "unkeyed POST timeout is not retried" "HTTP_ATTEMPT_TIMEOUT"
    (error_code unkeyed_timeout);
  Alcotest.(check int) "unkeyed POST attempted once" 1 (count "/slow");
  let* malformed = Http_client.call http ~decoder:Http_client.json
      (ok (request port "/malformed-json")) in
  Alcotest.(check string) "decode not retried" "HTTP_DECODE_FAILED" (error_code malformed);
  let* oversized = Http_client.call http ~decoder:Http_client.bytes
      (ok (request port "/oversize-chunked")) in
  Alcotest.(check string) "chunked incremental cap" "HTTP_RESPONSE_TOO_LARGE"
    (error_code oversized);
  Alcotest.(check bool) "oversize stream drained to finalization" true !chunked_finalized;
  let* after_drain = Http_client.call http ~decoder:Http_client.bytes
      (ok (request port "/success")) in
  Alcotest.(check int) "client remains usable after drain" 200
    (Http_client.status (ok after_drain));
  let oversized_request = ok (request ~meth:`POST ~body:(Bytes.make 1025 'x') port "/post") in
  let* rejected_request = Http_client.call http ~decoder:Http_client.bytes oversized_request in
  Alcotest.(check string) "request policy cap" "HTTP_REQUEST_TOO_LARGE"
    (error_code rejected_request);
  let started = Unix.gettimeofday () in
  let* timed = Http_client.call http ~decoder:Http_client.bytes (ok (request port "/slow")) in
  Alcotest.(check string) "timeout retries to budget" "HTTP_TOTAL_TIMEOUT" (error_code timed);
  Alcotest.(check bool) "single total budget" true (Unix.gettimeofday () -. started < 0.35);
  Lwt.return_unit

let assert_markers_absent label markers result =
  let message = Http_client.error_message (error result) in
  List.iter (fun marker ->
      Alcotest.(check bool) (label ^ " marker absent") false
        (contains ~needle:marker message)) markers

let test_cancellation_and_nonleakage port =
  let http = client () in
  reset "/slow";
  let call = Http_client.call http ~decoder:Http_client.bytes (ok (request port "/slow")) in
  let* () = Lwt_unix.sleep 0.01 in
  Lwt.cancel call;
  let* cancelled = call in
  Alcotest.(check string) "typed cancellation without retry" "HTTP_CANCELLED"
    (error_code cancelled);
  Alcotest.(check int) "cancelled endpoint attempted once" 1 (count "/slow");
  let query_marker = "synthetic-query-marker" in
  let query_request = ok (Http_client.request ~meth:`GET
      ~uri:(Uri.of_string (Printf.sprintf "http://127.0.0.1:1/fail?token=%s" query_marker)) ()) in
  let* query_failed = Http_client.call http ~decoder:Http_client.bytes query_request in
  assert_markers_absent "query" [ query_marker; Uri.to_string (Uri.of_string (Printf.sprintf "http://127.0.0.1:1/fail?token=%s" query_marker)) ] query_failed;
  let header_marker = "synthetic-authorization-marker" in
  let cookie_marker = "synthetic-cookie-marker" in
  let body_marker = "synthetic-body-marker" in
  let sensitive_request = ok (request ~meth:`POST
      ~headers:[ ("Authorization", header_marker); ("Cookie", cookie_marker) ]
      ~body:(Bytes.of_string body_marker) port "/slow") in
  let* sensitive_failed = Http_client.call http ~decoder:Http_client.bytes sensitive_request in
  assert_markers_absent "request" [ header_marker; cookie_marker; body_marker ] sensitive_failed;
  server_exceptions := [];
  let raw_path = "/raw-exception/" ^ raw_exception_marker in
  let* raw_failed =
    Http_client.call http ~decoder:Http_client.bytes
      (ok (request port raw_path))
  in
  Alcotest.(check string)
    "raw callback failure is typed" "HTTP_ATTEMPT_TIMEOUT"
    (error_code raw_failed);
  assert_markers_absent "raw exception path" [ raw_exception_marker ] raw_failed;
  Lwt.return_unit

let lifecycle () =
  Hashtbl.reset counters;
  server_exceptions := [];
  Lwt_main.run
    (with_fixture (fun port ->
         let* () = test_success_validation port in
         let* () = test_retry_matrix port in
         let* () = test_keyed_timeout_retries port in
         let* () = test_pool_token_released_before_backoff port in
         let* () = test_retry_after_bounds port in
         let* () = test_body_decode_timeout port in
         test_cancellation_and_nonleakage port))

let run () =
  Alcotest.run "Outbound HTTP integration"
    [ ("loopback fixture",
       [ Alcotest.test_case "retries, concurrency, deadlines, drain, redaction"
           `Quick lifecycle ]) ]
