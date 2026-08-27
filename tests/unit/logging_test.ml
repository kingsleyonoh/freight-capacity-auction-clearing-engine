let get_context result =
  match result with
  | Ok context -> context
  | Error _ -> Alcotest.fail "expected valid logging context"

let get_event result =
  match result with
  | Ok event -> event
  | Error _ -> Alcotest.fail "expected valid logging event"

let valid_event ?(message = "auction accepted") () =
  let context =
    get_context
      (Logging.context ~tenant_id:"tenant-1" ~user_id:"user-1"
         ~role:"auction_manager" ~request_id:"request-1" ~job_id:"job-1"
         ~entity_id:"auction-1" ())
  in
  let error_code =
    match Errors.Code.of_string "CLEARING_SUCCEEDED" with
    | Ok code -> code
    | Error _ -> Alcotest.fail "valid test error code rejected"
  in
  get_event
    (Logging.event ~context ~status:"succeeded" ~duration_ms:17 ~error_code
       ~message ())

let assoc_keys = function
  | `Assoc fields -> List.map fst fields
  | _ -> Alcotest.fail "expected a JSON object"

let test_exact_allow_list_and_time () =
  let json =
    Logging.to_yojson ~now:(fun () -> 1_725_000_000.125)
      ~source:"Clearing.worker" Logs.Info (valid_event ())
  in
  let expected =
    `Assoc
      [ ("timestamp_unix_ms", `Int 1_725_000_000_125);
        ("level", `String "info");
        ("module", `String "Clearing.worker");
        ("message", `String "auction accepted");
        ("tenant_id", `String "tenant-1");
        ("user_id", `String "user-1");
        ("role", `String "auction_manager");
        ("request_id", `String "request-1");
        ("job_id", `String "job-1");
        ("entity_id", `String "auction-1");
        ("status", `String "succeeded");
        ("duration_ms", `Int 17);
        ("error_code", `String "CLEARING_SUCCEEDED") ]
  in
  Alcotest.(check bool) "exact structured event" true
    (Yojson.Safe.equal expected json);
  Alcotest.(check (list string)) "only allow-listed keys"
    (assoc_keys expected) (assoc_keys json)

let test_single_line_escaped_and_filtered () =
  let writes = ref [] in
  let write line = writes := line :: !writes in
  Logging.configure ~level:(Some Logs.Info) ~now:(fun () -> 42.5) ~write ();
  Logging.configure ~level:(Some Logs.Info) ~now:(fun () -> 42.5) ~write ();
  let source = Logs.Src.create "Shared.test" in
  Logging.emit ~src:source Logs.Debug (valid_event ~message:"filtered" ());
  Logging.emit ~src:source Logs.Info
    (valid_event ~message:"quote=\"ok\" newline=\nend" ());
  match List.rev !writes with
  | [ line ] ->
      Alcotest.(check bool) "newline terminated" true
        (String.ends_with ~suffix:"\n" line);
      let without_final = String.sub line 0 (String.length line - 1) in
      Alcotest.(check bool) "one physical line" false
        (String.contains without_final '\n');
      let json = Yojson.Safe.from_string without_final in
      Alcotest.(check string) "escaped message round-trips"
        "quote=\"ok\" newline=\nend"
        Yojson.Safe.Util.(json |> member "message" |> to_string)
  | lines ->
      Alcotest.failf "expected one accepted event write, got %d" (List.length lines)

let test_third_party_logs_are_not_forwarded () =
  let writes = ref [] in
  Logging.configure ~level:(Some Logs.Debug) ~write:(fun line -> writes := line :: !writes) ();
  Logs.err (fun message -> message "raw adapter text must not be forwarded");
  Alcotest.(check int) "untyped Logs message ignored" 0 (List.length !writes)

let test_typed_validation () =
  (match Logging.context ~tenant_id:"  " () with
   | Error (Logging.Empty_field "tenant_id") -> ()
   | _ -> Alcotest.fail "empty tenant_id was not rejected with typed result");
  (match Logging.event ~duration_ms:(-1) ~message:"safe" () with
   | Error Logging.Negative_duration -> ()
   | _ -> Alcotest.fail "negative duration was not rejected with typed result");
  match Logging.event ~message:"\n\t " () with
  | Error Logging.Empty_message -> ()
  | _ -> Alcotest.fail "empty event message was not rejected with typed result"

let () =
  Alcotest.run "Structured JSON logging"
    [ ( "serialization",
        [ Alcotest.test_case "exact allow list and time" `Quick
            test_exact_allow_list_and_time;
          Alcotest.test_case "single line, escaping, filtering, idempotence" `Quick
            test_single_line_escaped_and_filtered;
          Alcotest.test_case "third-party text suppressed" `Quick
            test_third_party_logs_are_not_forwarded ] );
      ( "validation",
        [ Alcotest.test_case "typed construction errors" `Quick
            test_typed_validation ] ) ]
