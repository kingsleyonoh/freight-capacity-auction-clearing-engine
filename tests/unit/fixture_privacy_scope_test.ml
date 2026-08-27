let json_suffix path = Filename.check_suffix path ".json"

let validate_recording_file file =
  let open Fixture_contract in
  let json = load_json file in
  let invalid_signature =
    Filename.basename file = "signature_shaped_invalid.json"
  in
  reject_private_data
    ?allowed_signature_path:
      (if invalid_signature then Some "$.request.body.signature_descriptor"
       else None)
    json;
  let text = read_text file in
  if contains ~substring:"Bearer " text || contains ~substring:"Cookie:" text
  then Alcotest.failf "credential-shaped value in %s" file

let validate_public_fixture_file file =
  let open Fixture_contract in
  if json_suffix file && not (Filename.check_suffix file ".schema.json") then
    let basename = Filename.basename file in
    if
      basename <> "manifest.internal.json"
      && basename <> "toolchain.json"
      && basename <> "privacy-policy.json"
    then reject_private_data (load_json file)

let validate_scopes_and_tenants () =
  let open Fixture_contract in
  let import_manifest = load_json (path "imports/manifest.json") |> assoc in
  expect_string "fixture_contract_only" "evidence_scope" import_manifest;
  let solver_manifest = load_json (path "solver/manifest.json") |> assoc in
  expect_string "fixture_contract_only" "evidence_scope" solver_manifest;
  let integrations = load_json (path "integrations/manifest.json") |> assoc in
  expect_string "recorded_contract_only" "evidence_scope" integrations;
  let replay = load_json (path "replay/manifest.internal.json") |> assoc in
  let months = member "monthly_counts" replay |> list in
  List.iter
    (fun id ->
      let belongs row = string "tenant_id" (assoc row) = id in
      Alcotest.(check int)
        "twelve months per tenant" 12
        (List.length (List.filter belongs months)))
    (tenant_ids ())

let expect_private_rejection label ?allowed_signature_path json =
  match Fixture_contract.reject_private_data ?allowed_signature_path json with
  | () -> Alcotest.fail (label ^ " mutation was accepted")
  | exception Fixture_contract.Invalid _ -> ()

let test_adversarial_nested_mutations () =
  let mutations =
    [
      ( "nested secret",
        `Assoc [ ("outer", `Assoc [ ("client_secret", `String "x") ]) ] );
      ( "nested hash",
        `Assoc [ ("outer", `Assoc [ ("payload_hash", `String "abc") ]) ] );
      ( "nested host",
        `Assoc [ ("transport", `Assoc [ ("host", `String "example") ]) ] );
      ( "nested base URL",
        `Assoc [ ("transport", `Assoc [ ("base_url", `String "/") ]) ] );
      ( "full URI value",
        `Assoc [ ("route", `String "https://example.invalid/api") ] );
      ("cookie", `Assoc [ ("headers", `Assoc [ ("cookie", `String "x") ]) ]);
      ("auth", `Assoc [ ("metadata", `Assoc [ ("auth", `String "x") ]) ]);
      ("JWT", `Assoc [ ("metadata", `Assoc [ ("jwt", `String "eyJ.fake") ]) ]);
      ("password", `Assoc [ ("nested", `Assoc [ ("password", `String "x") ]) ]);
      ( "signature",
        `Assoc [ ("nested", `Assoc [ ("signature", `String "00") ]) ] );
      ( "raw error",
        `Assoc [ ("failure", `Assoc [ ("raw_error", `String "boom") ]) ] );
    ]
  in
  List.iter (fun (label, json) -> expect_private_rejection label json) mutations

let descriptor algorithm value =
  `Assoc
    [
      ("algorithm", `String algorithm);
      ("encoding", `String "hex");
      ("length", `Int 64);
      ("value", `String value);
    ]

let recording_with_descriptor descriptor =
  `Assoc
    [
      ( "request",
        `Assoc [ ("body", `Assoc [ ("signature_descriptor", descriptor) ]) ] );
    ]

let test_signature_descriptor_exact_path_and_shape () =
  let allowed = "$.request.body.signature_descriptor" in
  let valid = descriptor "sha256" "[REDACTED_FIXTURE]" in
  Fixture_contract.reject_private_data ~allowed_signature_path:allowed
    (recording_with_descriptor valid);
  expect_private_rejection "signature descriptor wrong path"
    ~allowed_signature_path:allowed
    (`Assoc [ ("response", `Assoc [ ("signature_descriptor", valid) ]) ]);
  expect_private_rejection "signature descriptor wrong algorithm"
    ~allowed_signature_path:allowed
    (recording_with_descriptor (descriptor "sha1" "[REDACTED_FIXTURE]"));
  expect_private_rejection "signature descriptor not redacted"
    ~allowed_signature_path:allowed
    (recording_with_descriptor (descriptor "sha256" "deadbeef"))

let test_privacy_scope () =
  let open Fixture_contract in
  let public_roots = [ "imports"; "solver"; "replay/edges" ] in
  List.concat_map (fun relative -> files_under (path relative)) public_roots
  |> List.iter validate_public_fixture_file;
  let recording_roots =
    [ "notification_hub"; "workflow_engine"; "webhook_engine" ]
  in
  List.concat_map (fun relative -> files_under (path relative)) recording_roots
  |> List.filter json_suffix
  |> List.iter validate_recording_file;
  validate_scopes_and_tenants ()

let test_unknown_field_fails_closed () =
  let open Fixture_contract in
  let fields = [ ("schema_version", `Int 1); ("unknown", `Bool true) ] in
  match exact_fields [ "schema_version" ] fields with
  | () -> Alcotest.fail "unknown field accepted"
  | exception Invalid "FIXTURE_FIELDS_NOT_EXACT" -> ()
  | exception Invalid code -> Alcotest.failf "unexpected code %s" code

let () =
  Alcotest.run "fixture privacy and scope"
    [
      ( "corpus",
        [
          Alcotest.test_case "privacy and scope" `Quick test_privacy_scope;
          Alcotest.test_case "unknown fields fail closed" `Quick
            test_unknown_field_fails_closed;
          Alcotest.test_case "nested privacy mutations fail closed" `Quick
            test_adversarial_nested_mutations;
          Alcotest.test_case "signature descriptor exact path/shape" `Quick
            test_signature_descriptor_exact_path_and_shape;
        ] );
    ]
