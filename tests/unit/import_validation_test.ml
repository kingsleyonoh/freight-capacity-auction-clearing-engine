let ctx =
  { Import_validation.carrier_ids = [ "carrier-1" ];
    suspended_carrier_ids = [ "carrier-suspended" ];
    lane_ids = [ "lane-1" ];
    load_ids = [ "load-1" ] }

let string_member name json =
  match Yojson.Safe.Util.member name json with
  | `String value -> Some value
  | _ -> None

let has_error code errors =
  List.exists (fun error -> string_member "error_code" error = Some code) errors

let test_valid_duplicate_and_quarantine () =
  let rows =
    [ `Assoc [ ("load_id", `String "load-1"); ("carrier_id", `String "carrier-1"); ("idempotency_key", `String "key-1"); ("bid_amount", `String "100.00"); ("submitted_at", `String "2026-08-27T10:00:00Z") ];
      `Assoc [ ("load_id", `String "load-1"); ("carrier_id", `String "carrier-1"); ("idempotency_key", `String "key-1"); ("bid_amount", `String "101.00"); ("submitted_at", `String "2026-08-27T10:00:00Z") ];
      `Assoc [ ("load_id", `String "load-1"); ("carrier_id", `String "carrier-unknown"); ("idempotency_key", `String "key-2"); ("bid_amount", `String "102.00"); ("submitted_at", `String "2026-08-27T10:00:00Z") ] ]
  in
  let result = Import_validation.validate_json_rows ~resource_type:"bids" ~context:ctx rows in
  Alcotest.(check int) "all rows counted" 3 result.row_count;
  Alcotest.(check int) "two non-error rows" 2 result.valid_row_count;
  Alcotest.(check int) "one quarantined row" 1 result.invalid_row_count;
  Alcotest.(check string) "run quarantined" "quarantined" result.status;
  Alcotest.(check bool) "duplicate recorded" true (has_error "BID_DUPLICATE" result.errors);
  Alcotest.(check bool) "unknown carrier recorded" true (has_error "UNKNOWN_CARRIER" result.errors)

let test_schema_drift_is_fail_closed () =
  let csv = "case_id,load_ref,carrier_ref,idempotency_key,amount,submitted_at\ncase-1,load-1,carrier-1,key-1,10.00,2026-08-27T10:00:00Z" in
  let result = Import_validation.validate_csv ~resource_type:"bids" ~context:ctx csv in
  Alcotest.(check string) "schema drift quarantines" "quarantined" result.status;
  Alcotest.(check int) "schema drift has no rows" 0 result.row_count;
  Alcotest.(check bool) "schema drift error" true (has_error "IMPORT_SCHEMA_DRIFT" result.errors)

let test_json_boolean_fields_are_required_values () =
  let result =
    Import_validation.validate_json_rows ~resource_type:"replay_dataset"
      ~context:ctx
      [ `Assoc
          [ ("tenant_id", `String "tenant-1");
            ("auction_id", `String "auction-1");
            ("load_id", `String "load-1");
            ("bid_id", `String "bid-1");
            ("actual_landed_cost", `Float 100.0);
            ("baseline_eligible", `Bool true) ] ]
  in
  Alcotest.(check string) "boolean field accepted" "validated" result.status;
  Alcotest.(check int) "one valid row" 1 result.valid_row_count

let () =
  Alcotest.run "Import validation" [ ("pipeline", [ Alcotest.test_case "row outcomes" `Quick test_valid_duplicate_and_quarantine; Alcotest.test_case "schema drift" `Quick test_schema_drift_is_fail_closed; Alcotest.test_case "JSON booleans" `Quick test_json_boolean_fields_are_required_values ]) ]
