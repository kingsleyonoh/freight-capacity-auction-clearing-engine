let header =
  [
    "case_id";
    "auction_ref";
    "load_ref";
    "carrier_ref";
    "idempotency_key";
    "bid_amount";
    "currency";
    "capacity_units";
    "equipment_type";
    "submitted_at";
    "valid_until";
  ]

let check_invalid label thunk =
  match thunk () with
  | () -> Alcotest.fail (label ^ " unexpectedly accepted")
  | exception Fixture_contract.Invalid _ -> ()

let row_assoc header row = List.combine header row
let field name row = List.assoc name row

let manifest () =
  Fixture_contract.load_json (Fixture_contract.path "imports/manifest.json")
  |> Fixture_contract.assoc

let validate_manifest_schema () =
  let open Fixture_contract in
  let schema = load_json (path "imports/manifest.schema.json") in
  let instance = `Assoc (manifest ()) in
  validate_schema schema instance;
  check_invalid "import unknown field" (fun () ->
      validate_schema schema (`Assoc (("unexpected", `Null) :: assoc instance)));
  check_invalid "import unsupported version" (fun () ->
      validate_schema schema
        (`Assoc
           (("schema_version", `Int 9)
           :: List.remove_assoc "schema_version" (assoc instance))))

let validate_reference_data () =
  let open Fixture_contract in
  let reference = load_json (path "imports/reference_data.json") |> assoc in
  exact_fields
    [ "schema_version"; "evidence_scope"; "tenant_fixture"; "tenants" ]
    reference;
  expect_int 1 "schema_version" reference;
  expect_string "fixture_contract_only" "evidence_scope" reference;
  expect_string "../tenants.json" "tenant_fixture" reference;
  let canonical = tenant_ids () |> List.sort String.compare in
  let tenants = member "tenants" reference |> list |> List.map assoc in
  Alcotest.(check int) "two reference tenants" 2 (List.length tenants);
  Alcotest.(check (list string))
    "canonical tenant IDs" canonical
    (List.map (string "tenant_id") tenants |> List.sort String.compare);
  List.iter
    (fun tenant ->
      exact_fields
        [
          "tenant_id";
          "auction_ref";
          "lane_ref";
          "load_ref";
          "carriers";
          "existing_bid";
        ]
        tenant;
      member "carriers" tenant |> list
      |> List.iter (fun carrier ->
          let carrier = assoc carrier in
          exact_fields [ "carrier_ref"; "status"; "equipment_types" ] carrier;
          if not (List.mem (string "status" carrier) [ "active"; "suspended" ])
          then Alcotest.fail "carrier status enum";
          string_list "equipment_types" carrier
          |> List.iter (fun equipment ->
              if not (List.mem equipment [ "REEFER"; "DRY_VAN" ]) then
                Alcotest.fail "equipment enum"));
      match member "existing_bid" tenant with
      | `Null -> ()
      | `Assoc existing ->
          exact_fields [ "idempotency_key"; "status" ] existing;
          expect_string "eligible" "status" existing
      | _ -> Alcotest.fail "existing bid shape")
    tenants

let validate_csv_case rows index case =
  let open Fixture_contract in
  exact_fields [ "case_id"; "file"; "row_number"; "expected" ] case;
  let row = List.nth rows index in
  Alcotest.(check int) "physical row number" (index + 2) (int "row_number" case);
  Alcotest.(check string)
    "case ID matches CSV row" (string "case_id" case) (field "case_id" row);
  expect_string "freight_import_bids_v1.csv" "file" case;
  let expected = member "expected" case |> assoc in
  exact_fields
    [
      "normalized_payload";
      "row_status";
      "domain_status";
      "error_codes";
      "error_severity";
      "quarantine_reason";
      "commit_action";
      "enters_solver";
    ]
    expected;
  let normalized = member "normalized_payload" expected |> assoc in
  exact_fields
    [ "bid_amount"; "currency"; "capacity_units"; "equipment_type" ]
    normalized;
  Alcotest.(check string)
    "normalized amount" (field "bid_amount" row)
    (string "bid_amount" normalized);
  Alcotest.(check string)
    "normalized currency" (field "currency" row)
    (string "currency" normalized);
  Alcotest.(check int)
    "normalized capacity"
    (int_of_string (field "capacity_units" row))
    (int "capacity_units" normalized);
  Alcotest.(check string)
    "normalized equipment"
    (field "equipment_type" row)
    (string "equipment_type" normalized);
  if
    (not (String.ends_with ~suffix:"Z" (field "submitted_at" row)))
    || not (String.ends_with ~suffix:"Z" (field "valid_until" row))
  then Alcotest.fail "timestamps must be normalized UTC"

let validate_csv_rows_against_oracle () =
  let open Fixture_contract in
  let actual_header, raw_rows =
    read_text (path "imports/freight_import_bids_v1.csv") |> csv_rows
  in
  Alcotest.(check (list string)) "exact CSV header" header actual_header;
  Alcotest.(check int) "six CSV rows" 6 (List.length raw_rows);
  let rows = List.map (row_assoc header) raw_rows in
  let cases = member "cases" (manifest ()) |> list |> List.map assoc in
  Alcotest.(check int) "six manifest cases" 6 (List.length cases);
  List.iteri (validate_csv_case rows) cases

let validate_schema_drift_oracle () =
  let open Fixture_contract in
  let drift = member "schema_drift" (manifest ()) |> assoc in
  exact_fields [ "file"; "expected" ] drift;
  expect_string "freight_import_bids_schema_drift_v2.csv" "file" drift;
  let drift_header, rows =
    read_text (path ("imports/" ^ string "file" drift)) |> csv_rows
  in
  Alcotest.(check int) "one physical drift row" 1 (List.length rows);
  let missing =
    List.filter (fun name -> not (List.mem name drift_header)) header
  in
  let unknown =
    List.filter (fun name -> not (List.mem name header)) drift_header
  in
  let expected = member "expected" drift |> assoc in
  exact_fields
    [
      "run_status";
      "row_count";
      "valid_row_count";
      "invalid_row_count";
      "error_codes";
      "missing_columns";
      "unknown_columns";
      "commit_allowed";
    ]
    expected;
  expect_string "quarantined" "run_status" expected;
  expect_int 0 "row_count" expected;
  expect_int 0 "valid_row_count" expected;
  expect_int 0 "invalid_row_count" expected;
  expect_bool false "commit_allowed" expected;
  Alcotest.(check (list string))
    "computed missing columns" missing
    (string_list "missing_columns" expected);
  Alcotest.(check (list string))
    "computed unknown columns" unknown
    (string_list "unknown_columns" expected);
  Alcotest.(check (list string))
    "schema drift code" [ "IMPORT_SCHEMA_DRIFT" ]
    (string_list "error_codes" expected)

let () =
  Alcotest.run "import fixture corpus"
    [
      ( "schema",
        [
          Alcotest.test_case "manifest exact schema" `Quick
            validate_manifest_schema;
        ] );
      ( "oracle",
        [
          Alcotest.test_case "canonical reference data" `Quick
            validate_reference_data;
          Alcotest.test_case "CSV rows and normalized oracle" `Quick
            validate_csv_rows_against_oracle;
          Alcotest.test_case "schema drift is file-level" `Quick
            validate_schema_drift_oracle;
        ] );
    ]
