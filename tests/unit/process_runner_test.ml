open Lwt.Infix

let fixture = Sys.getenv "FCA_PROCESS_FIXTURE" |> Unix.realpath

let contains haystack needle =
  let length = String.length needle in
  let rec loop index =
    index + length <= String.length haystack
    && (String.sub haystack index length = needle || loop (index + 1))
  in
  length = 0 || loop 0

let run_lwt value = Lwt_main.run value
let runner ?(allowed_env = []) () = Process_runner.create ~allowed_env

let request ?(argv = []) ?(env = []) ?(stdin = "") ?(stdin_limit = 1024)
    ?(stdout_limit = 4096) ?(stderr_limit = 4096) ?(timeout = 2.)
    ?(term_grace = 0.1) ?capture () =
  Process_runner.request ~executable:fixture ~argv ~env ~stdin ~stdin_limit
    ~stdout_limit ~stderr_limit ~timeout ~term_grace ?capture ()

let expect_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Process_runner.error_to_string error)

let expect_error_code expected = function
  | Ok _ -> Alcotest.fail "expected process error"
  | Error error ->
      Alcotest.(check string)
        "stable error code" expected
        (Process_runner.error_code error)

let test_literal_argv () =
  let argv =
    [ "argv"; "; touch /tmp/never"; "$(echo nope)"; "a b"; "quote\"'" ]
  in
  let output =
    run_lwt (Process_runner.run (runner ()) (request ~argv ())) |> expect_ok
  in
  let parsed = Yojson.Safe.from_string output.stdout in
  let expected =
    `List (List.tl argv |> List.map (fun value -> `String value))
  in
  Alcotest.(check string)
    "literal argv"
    (Yojson.Safe.to_string expected)
    (Yojson.Safe.to_string parsed)

let test_nul_rejected () =
  run_lwt (Process_runner.run (runner ()) (request ~argv:[ "\000leading" ] ()))
  |> expect_error_code "PROCESS_INVALID_REQUEST";
  run_lwt
    (Process_runner.run (runner ()) (request ~argv:[ "embedded\000nul" ] ()))
  |> expect_error_code "PROCESS_INVALID_REQUEST"

let test_environment_allowlist () =
  run_lwt
    (Process_runner.run
       (runner ~allowed_env:[ "SAFE_FLAG" ] ())
       (request ~argv:[ "stdin" ] ~env:[ ("NOT_ALLOWED", "x") ] ()))
  |> expect_error_code "PROCESS_INVALID_ENV";
  run_lwt
    (Process_runner.run
       (runner ~allowed_env:[ "SAFE_FLAG" ] ())
       (request ~argv:[ "stdin" ] ~env:[ ("SAFE_FLAG", "bad\000value") ] ()))
  |> expect_error_code "PROCESS_INVALID_ENV"

let test_bounded_stdin_and_output () =
  let body = String.make 512 'x' in
  let output =
    run_lwt
      (Process_runner.run (runner ())
         (request ~argv:[ "stdin" ] ~stdin:body ~stdin_limit:512
            ~stdout_limit:512 ()))
    |> expect_ok
  in
  Alcotest.(check string) "stdin roundtrip" body output.stdout;
  run_lwt
    (Process_runner.run (runner ())
       (request ~argv:[ "stdin" ] ~stdin:body ~stdin_limit:511 ()))
  |> expect_error_code "PROCESS_STDIN_LIMIT";
  run_lwt
    (Process_runner.run (runner ())
       (request ~argv:[ "flood"; "8192"; "1" ] ~stdout_limit:1024 ()))
  |> expect_error_code "PROCESS_STDOUT_LIMIT";
  run_lwt
    (Process_runner.run (runner ())
       (request ~argv:[ "flood"; "1"; "8192" ] ~stderr_limit:1024 ()))
  |> expect_error_code "PROCESS_STDERR_LIMIT"

let test_exact_exit_outcomes_redacted () =
  let nonzero =
    run_lwt
      (Process_runner.run (runner ()) (request ~argv:[ "nonzero"; "23" ] ()))
  in
  (match nonzero with
  | Error (Process_runner.Nonzero_exit (`Exited 23)) -> ()
  | _ -> Alcotest.fail "expected exact exit 23");
  let signal =
    run_lwt (Process_runner.run (runner ()) (request ~argv:[ "signal" ] ()))
  in
  (match signal with
  | Error (Process_runner.Nonzero_exit (`Signaled value)) ->
      Alcotest.(check int) "SIGTERM" Sys.sigterm value
  | _ -> Alcotest.fail "expected exact signal");
  let rendered =
    match nonzero with
    | Error error -> Process_runner.error_to_string error
    | Ok _ -> ""
  in
  Alcotest.(check bool)
    "child stderr redacted" false
    (contains rendered "sensitive")

let test_timeout_and_cancel () =
  run_lwt
    (Process_runner.run (runner ())
       (request ~argv:[ "sleep"; "5" ] ~timeout:0.1 ()))
  |> expect_error_code "PROCESS_TIMEOUT";
  let cancel, wake = Lwt.wait () in
  let pending =
    Process_runner.run ~cancel (runner ())
      (request ~argv:[ "sleep"; "5" ] ~timeout:5. ())
  in
  Lwt.async (fun () ->
      Lwt_unix.sleep 0.05 >|= fun () -> Lwt.wakeup_later wake ());
  run_lwt pending |> expect_error_code "PROCESS_CANCELLED"

let temporary_directory prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path

let test_descendant_tree_termination () =
  let root = temporary_directory "fca-process-tree" in
  let marker = Filename.concat root "survivor" in
  run_lwt
    (Process_runner.run (runner ())
       (request ~argv:[ "descendant"; marker; "0.4" ] ~timeout:0.1 ()))
  |> expect_error_code "PROCESS_TIMEOUT";
  Unix.sleepf 0.6;
  Alcotest.(check bool)
    "descendant did not survive" false (Sys.file_exists marker);
  Unix.rmdir root

let test_term_resistant_descendant_termination () =
  let root = temporary_directory "fca-resistant-tree" in
  let marker = Filename.concat root "delayed-survivor" in
  run_lwt
    (Process_runner.run (runner ())
       (request
          ~argv:[ "term-resistant-descendant"; marker; "2.0" ]
          ~timeout:0.1 ~term_grace:1.5 ()))
  |> expect_error_code "PROCESS_TIMEOUT";
  Unix.sleepf 2.2;
  let survived = Sys.file_exists marker in
  if survived then Sys.remove marker;
  Unix.rmdir root;
  Alcotest.(check bool)
    "TERM-resistant descendant did not survive leader exit" false survived

let test_safe_capture () =
  let root = temporary_directory "fca-capture" in
  let capture = Process_runner.capture ~root ~namespace:"solver-job" in
  let output =
    run_lwt
      (Process_runner.run (runner ())
         (request ~argv:[ "stdin" ] ~stdin:"bounded" ~capture ()))
    |> expect_ok
  in
  let directory = Option.get output.capture_directory in
  Alcotest.(check bool)
    "capture below root" true
    (String.starts_with
       ~prefix:(Unix.realpath root ^ Filename.dir_sep)
       (Unix.realpath directory));
  Alcotest.(check string)
    "stdout artifact" "bounded"
    (let channel = open_in_bin (Filename.concat directory "stdout.bin") in
     Fun.protect
       ~finally:(fun () -> close_in channel)
       (fun () -> really_input_string channel 7));
  run_lwt
    (Process_runner.run (runner ())
       (request ~argv:[ "stdin" ]
          ~capture:(Process_runner.capture ~root ~namespace:"../escape")
          ()))
  |> expect_error_code "PROCESS_ARTIFACT_INVALID";
  Sys.remove (Filename.concat directory "stdout.bin");
  Sys.remove (Filename.concat directory "stderr.bin");
  Sys.remove (Filename.concat directory "metadata.json");
  Unix.rmdir directory;
  Unix.rmdir root

let test_symlink_capture_rejected () =
  let base = temporary_directory "fca-capture-base" in
  let target = temporary_directory "fca-capture-target" in
  let child = Filename.concat target "child" in
  Unix.mkdir child 0o700;
  let link = Filename.concat base "linked-parent" in
  Unix.symlink target link;
  let root = Filename.concat link "child" in
  run_lwt
    (Process_runner.run (runner ())
       (request ~argv:[ "stdin" ]
          ~capture:(Process_runner.capture ~root ~namespace:"safe")
          ()))
  |> expect_error_code "PROCESS_ARTIFACT_INVALID";
  Sys.remove link;
  Unix.rmdir base;
  Unix.rmdir child;
  Unix.rmdir target

let () =
  Alcotest.run "bounded process runner"
    [
      ( "literal and validation",
        [
          Alcotest.test_case "literal argv metacharacters" `Quick
            test_literal_argv;
          Alcotest.test_case "leading and embedded NUL" `Quick test_nul_rejected;
          Alcotest.test_case "allowlisted environment" `Quick
            test_environment_allowlist;
        ] );
      ( "bounds and lifecycle",
        [
          Alcotest.test_case "stdin/stdout/stderr caps" `Quick
            test_bounded_stdin_and_output;
          Alcotest.test_case "nonzero and signal" `Quick
            test_exact_exit_outcomes_redacted;
          Alcotest.test_case "timeout and cancellation" `Quick
            test_timeout_and_cancel;
          Alcotest.test_case "process-group descendant termination" `Slow
            test_descendant_tree_termination;
          Alcotest.test_case "TERM-resistant descendant after leader exit" `Slow
            test_term_resistant_descendant_termination;
        ] );
      ( "artifacts",
        [
          Alcotest.test_case "atomic bounded capture" `Quick test_safe_capture;
          Alcotest.test_case "symlink root rejected" `Quick
            test_symlink_capture_rejected;
        ] );
    ]
