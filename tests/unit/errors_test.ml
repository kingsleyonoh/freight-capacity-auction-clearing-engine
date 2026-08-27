let get_code value =
  match Errors.Code.of_string value with
  | Ok code -> code
  | Error _ -> Alcotest.fail ("expected valid error code: " ^ value)

let get_detail result =
  match result with
  | Ok detail -> detail
  | Error _ -> Alcotest.fail "expected valid error detail"

let get_error result =
  match result with
  | Ok error -> error
  | Error _ -> Alcotest.fail "expected valid error envelope"

let test_empty_details_envelope () =
  let code = get_code "AUCTION_NOT_FOUND" in
  let error = get_error (Errors.make ~code ~message:"Auction not found" ()) in
  let expected =
    `Assoc
      [ ( "error",
          `Assoc
            [ ("code", `String "AUCTION_NOT_FOUND");
              ("message", `String "Auction not found");
              ("details", `List []) ] ) ]
  in
  Alcotest.(check bool) "exact nested envelope" true
    (Yojson.Safe.equal expected (Errors.to_yojson error))

let test_ordered_details_and_escaping () =
  let invalid = get_code "INVALID_FIELD" in
  let required = get_code "REQUIRED" in
  let details =
    [ get_detail
        (Errors.detail ~field:"lane\"name" ~code:required
           ~message:"A lane\nname is required" ());
      get_detail
        (Errors.detail ~code:invalid ~message:"Unsupported value" ()) ]
  in
  let error =
    get_error
      (Errors.make ~code:invalid ~message:"Validation failed \"safely\""
         ~details ())
  in
  let encoded = Yojson.Safe.to_string (Errors.to_yojson error) in
  let decoded = Yojson.Safe.from_string encoded in
  let expected_details =
    `List
      [ `Assoc
          [ ("field", `String "lane\"name");
            ("code", `String "REQUIRED");
            ("message", `String "A lane\nname is required") ];
        `Assoc
          [ ("code", `String "INVALID_FIELD");
            ("message", `String "Unsupported value") ] ]
  in
  let actual_details =
    Yojson.Safe.Util.member "error" decoded
    |> Yojson.Safe.Util.member "details"
  in
  Alcotest.(check bool) "detail order and fields" true
    (Yojson.Safe.equal expected_details actual_details);
  Alcotest.(check bool) "newline escaped in serialized JSON" false
    (String.contains encoded '\n')

let test_code_validation_is_typed () =
  let invalid_values = [ ""; "lower_case"; "1STARTS_WITH_DIGIT"; "HAS-DASH"; "HAS SPACE" ] in
  List.iter
    (fun value ->
      match Errors.Code.of_string value with
      | Error Errors.Code.Invalid_format -> ()
      | Ok _ -> Alcotest.fail ("accepted invalid code: " ^ value))
    invalid_values;
  match Errors.Code.of_string "DATABASE_POOL_STOPPED" with
  | Ok _ -> ()
  | Error _ -> Alcotest.fail "rejected valid upper snake case code"

let test_message_validation_is_typed () =
  let code = get_code "INVALID_REQUEST" in
  (match Errors.make ~code ~message:"  \n\t" () with
   | Error Errors.Empty_message -> ()
   | _ -> Alcotest.fail "empty envelope message did not return Empty_message");
  match Errors.detail ~code ~message:"" () with
  | Error Errors.Empty_detail_message -> ()
  | _ -> Alcotest.fail "empty detail message did not return Empty_detail_message"

let () =
  Alcotest.run "Canonical errors"
    [ ( "serialization",
        [ Alcotest.test_case "empty details envelope" `Quick
            test_empty_details_envelope;
          Alcotest.test_case "ordered details and escaping" `Quick
            test_ordered_details_and_escaping ] );
      ( "validation",
        [ Alcotest.test_case "typed code validation" `Quick
            test_code_validation_is_typed;
          Alcotest.test_case "typed message validation" `Quick
            test_message_validation_is_typed ] ) ]
