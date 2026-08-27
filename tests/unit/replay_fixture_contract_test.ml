let expected_columns =
  [
    "schema_version";
    "tenant_id";
    "window_month";
    "auction_id";
    "auction_name";
    "auction_mode";
    "auction_closed_at";
    "policy_version";
    "load_id";
    "load_external_ref";
    "lane_id";
    "origin_region";
    "destination_region";
    "equipment_type";
    "service_priority";
    "reserve_price";
    "load_sequence";
    "bid_id";
    "carrier_id";
    "carrier_public_name";
    "idempotency_key";
    "bid_amount";
    "accessorial_cost";
    "submitted_at";
    "valid_until";
    "bid_status";
    "service_score_snapshot";
    "reliability_score";
    "historical_otd_rate";
    "withdrawal_rate";
    "incumbent";
    "first_acceptable_rank";
    "historical_awarded";
    "delivered_on_time";
    "withdrawn_after_award";
    "actual_landed_cost";
    "baseline_eligible";
  ]

let check_invalid label thunk =
  match thunk () with
  | () -> Alcotest.fail (label ^ " unexpectedly accepted")
  | exception Fixture_contract.Invalid _ -> ()

let validate_manifest () =
  let open Fixture_contract in
  let schema = load_json (path "replay/manifest.schema.json") in
  let instance = load_json (path "replay/manifest.internal.json") in
  validate_schema schema instance;
  let manifest = assoc instance in
  exact_fields
    [
      "schema_version";
      "evidence_scope";
      "dataset";
      "generator";
      "duckdb_version";
      "parquet_magic";
      "row_count";
      "row_group_count";
      "ordered_columns";
      "column_schema";
      "monthly_counts";
      "artifact_sha256";
    ]
    manifest;
  expect_int 1 "schema_version" manifest;
  expect_string "internal_fixture_evidence" "evidence_scope" manifest;
  expect_string "1.3.2" "duckdb_version" manifest;
  expect_int 432 "row_count" manifest;
  expect_int 1 "row_group_count" manifest;
  Alcotest.(check (list string))
    "ordered schema" expected_columns
    (string_list "ordered_columns" manifest);
  let columns = member "column_schema" manifest |> list |> List.map assoc in
  Alcotest.(check int) "37 typed columns" 37 (List.length columns);
  Alcotest.(check (list string))
    "column schema order" expected_columns
    (List.map (string "name") columns);
  List.iter
    (fun column ->
      exact_fields [ "name"; "logical_type"; "nullable" ] column;
      expect_bool false "nullable" column)
    columns;
  let months = member "monthly_counts" manifest |> list |> List.map assoc in
  Alcotest.(check int) "24 tenant-month counts" 24 (List.length months);
  List.iter
    (fun month ->
      exact_fields [ "tenant_id"; "window_month"; "row_count" ] month;
      expect_int 18 "row_count" month)
    months;
  check_invalid "replay manifest unknown field" (fun () ->
      validate_schema schema (`Assoc (("public_hash", `String "x") :: manifest)))

let validate_expected_facts () =
  let open Fixture_contract in
  let expected =
    load_json (path "replay/golden_12_month.expected.json") |> assoc
  in
  exact_fields
    [
      "schema_version";
      "evidence_scope";
      "row_count";
      "tenant_count";
      "month_count";
      "auction_count";
      "load_count";
      "bid_count";
      "rows_per_tenant_month";
      "baseline_outcome_claimed";
      "production_policy_promotion_eligible";
    ]
    expected;
  expect_int 1 "schema_version" expected;
  expect_string "fixture_contract_only" "evidence_scope" expected;
  [
    ("row_count", 432);
    ("tenant_count", 2);
    ("month_count", 12);
    ("auction_count", 48);
    ("load_count", 144);
    ("bid_count", 432);
    ("rows_per_tenant_month", 18);
  ]
  |> List.iter (fun (name, value) -> expect_int value name expected);
  expect_bool false "baseline_outcome_claimed" expected;
  expect_bool false "production_policy_promotion_eligible" expected

let validate_generator_contract () =
  let open Fixture_contract in
  let toolchain = load_json (path "replay/tooling/toolchain.json") |> assoc in
  exact_fields
    [
      "schema_version";
      "duckdb_version";
      "expected_version_string";
      "generator_schema_version";
      "official_release";
      "official_release_api";
      "official_assets";
      "acquisition_policy";
      "generation_command";
      "network_during_generation";
      "executable_vendored";
    ]
    toolchain;
  expect_int 1 "schema_version" toolchain;
  expect_string "1.3.2" "duckdb_version" toolchain;
  expect_bool false "network_during_generation" toolchain;
  expect_bool false "executable_vendored" toolchain;
  let generator =
    read_text (path "replay/tooling/generate_golden_12_month.sql")
    |> String.lowercase_ascii
  in
  [ "random("; "uuid("; "now("; "http://"; "https://"; "install "; "load " ]
  |> List.iter (fun forbidden ->
      if contains ~substring:forbidden generator then
        Alcotest.failf "generator contains forbidden %s" forbidden)

let validate_expected_and_generator () =
  validate_expected_facts ();
  validate_generator_contract ()

let validate_common_json exact_fields_for_case fields =
  let open Fixture_contract in
  exact_fields exact_fields_for_case fields;
  expect_int 1 "schema_version" fields;
  expect_string "fixture_contract_only" "evidence_scope" fields;
  if not (List.mem (string "tenant_id" fields) (tenant_ids ())) then
    Alcotest.fail "edge tenant must be canonical";
  if not (String.ends_with ~suffix:"Z" (string "observed_at" fields)) then
    Alcotest.fail "edge observed_at must be UTC"

let withdrawal_count fields =
  let open Fixture_contract in
  validate_common_json
    [
      "schema_version";
      "tenant_id";
      "observed_at";
      "evidence_scope";
      "proposed_awards";
      "events";
      "expected_transition";
      "live_state_mutated";
    ]
    fields;
  expect_bool false "live_state_mutated" fields;
  let awards = member "proposed_awards" fields |> list in
  List.iter (fun award -> exact_fields [ "award_ref" ] (assoc award)) awards;
  let events = member "events" fields |> list in
  List.iter
    (fun value ->
      let event = assoc value in
      exact_fields [ "event_ref"; "type" ] event;
      expect_string "award_withdrawn" "type" event)
    events;
  List.length awards + List.length events

let duplicate_count fields =
  let open Fixture_contract in
  validate_common_json
    [
      "schema_version";
      "tenant_id";
      "observed_at";
      "evidence_scope";
      "deliveries";
      "expected_canonical_mutations";
    ]
    fields;
  expect_int 1 "expected_canonical_mutations" fields;
  let deliveries = member "deliveries" fields |> list in
  List.iter
    (fun value -> exact_fields [ "event_ref"; "idempotency_key" ] (assoc value))
    deliveries;
  List.length deliveries

let multi_round_count fields =
  let open Fixture_contract in
  validate_common_json
    [
      "schema_version";
      "tenant_id";
      "observed_at";
      "evidence_scope";
      "load_ref";
      "rounds";
      "expected_snapshot_round";
    ]
    fields;
  expect_int 2 "expected_snapshot_round" fields;
  member "rounds" fields |> list
  |> List.fold_left
       (fun count value ->
         let round = assoc value in
         exact_fields [ "round"; "events" ] round;
         let events = member "events" round |> list in
         List.iter
           (function `String _ -> () | _ -> Alcotest.fail "round event type")
           events;
         count + List.length events)
       0

let nonmutating_edge_count case_id fields =
  let open Fixture_contract in
  match case_id with
  | "emergency_reclear" ->
      validate_common_json
        [
          "schema_version";
          "tenant_id";
          "observed_at";
          "evidence_scope";
          "withdrawn_award_ref";
          "remaining_bids";
          "silent_publication";
        ]
        fields;
      expect_bool false "silent_publication" fields;
      let bids = member "remaining_bids" fields |> list in
      List.iter
        (function `String _ -> () | _ -> Alcotest.fail "remaining bid type")
        bids;
      List.length bids
  | "scenario_replay" ->
      validate_common_json
        [
          "schema_version";
          "tenant_id";
          "observed_at";
          "evidence_scope";
          "replay_request_ref";
          "policy_ref";
          "baseline_ref";
          "live_awards_created";
          "notifications_emitted";
          "external_events_emitted";
        ]
        fields;
      List.iter
        (fun name -> expect_int 0 name fields)
        [
          "live_awards_created";
          "notifications_emitted";
          "external_events_emitted";
        ];
      1
  | _ -> Alcotest.failf "unexpected nonmutating edge %s" case_id

let json_record_count case_id fields =
  match case_id with
  | "withdrawal" -> withdrawal_count fields
  | "duplicate" -> duplicate_count fields
  | "multi_round" -> multi_round_count fields
  | "emergency_reclear" | "scenario_replay" ->
      nonmutating_edge_count case_id fields
  | _ -> Alcotest.failf "unexpected JSON edge %s" case_id

let edge_header = function
  | "thin_lane" ->
      [
        "schema_version";
        "tenant_id";
        "observed_at";
        "load_ref";
        "bid_ref";
        "eligible";
        "expected_decision";
      ]
  | "surge" ->
      [
        "schema_version";
        "tenant_id";
        "observed_at";
        "load_ref";
        "bid_ref";
        "carrier_ref";
        "expected_constraint";
      ]
  | "late_bid" ->
      [
        "schema_version";
        "tenant_id";
        "submitted_at";
        "load_ref";
        "bid_ref";
        "bid_amount";
        "expected_decision";
      ]
  | case_id -> Alcotest.failf "unexpected CSV edge %s" case_id

let validate_edge_csv_row case_id header row =
  let fields = List.combine header row in
  if List.assoc "schema_version" fields <> "1" then
    Alcotest.fail "edge CSV version";
  if
    not
      (List.mem
         (List.assoc "tenant_id" fields)
         (Fixture_contract.tenant_ids ()))
  then Alcotest.fail "edge CSV tenant";
  let timestamp =
    if case_id = "late_bid" then "submitted_at" else "observed_at"
  in
  if not (String.ends_with ~suffix:"Z" (List.assoc timestamp fields)) then
    Alcotest.fail "edge CSV timestamp";
  match case_id with
  | "thin_lane" ->
      if
        (not (List.mem (List.assoc "eligible" fields) [ "true"; "false" ]))
        || List.assoc "expected_decision" fields <> "award"
      then Alcotest.fail "thin lane enum"
  | "surge" ->
      if List.assoc "expected_constraint" fields <> "carrier_capacity" then
        Alcotest.fail "surge constraint enum"
  | "late_bid" ->
      ignore (float_of_string (List.assoc "bid_amount" fields));
      if
        not
          (List.mem
             (List.assoc "expected_decision" fields)
             [ "award"; "exclude_late" ])
      then Alcotest.fail "late bid decision enum"
  | _ -> ()

let edge_record_count case_id relative =
  let open Fixture_contract in
  if Filename.check_suffix relative ".csv" then (
    let header, rows = read_text (path relative) |> csv_rows in
    Alcotest.(check (list string))
      (case_id ^ " exact header")
      (edge_header case_id) header;
    List.iter (validate_edge_csv_row case_id header) rows;
    List.length rows)
  else load_json (path relative) |> assoc |> json_record_count case_id

let validate_edge_scenario scenario =
  let open Fixture_contract in
  exact_fields
    [
      "schema_version";
      "case_id";
      "file";
      "record_count";
      "evidence_scope";
      "production_clearing_success_eligible";
    ]
    scenario;
  expect_int 1 "schema_version" scenario;
  expect_string "fixture_contract_only" "evidence_scope" scenario;
  expect_bool false "production_clearing_success_eligible" scenario;
  let case_id = string "case_id" scenario in
  let actual =
    edge_record_count case_id ("replay/edges/" ^ string "file" scenario)
  in
  Alcotest.(check int)
    (case_id ^ " exact record count")
    (int "record_count" scenario)
    actual

let validate_edges () =
  let open Fixture_contract in
  let edges = load_json (path "replay/edges/manifest.json") |> assoc in
  exact_fields [ "schema_version"; "tenant_fixture"; "scenarios" ] edges;
  expect_int 1 "schema_version" edges;
  expect_string "../../tenants.json" "tenant_fixture" edges;
  let scenarios = member "scenarios" edges |> list |> List.map assoc in
  Alcotest.(check int) "eight edge scenarios" 8 (List.length scenarios);
  List.iter validate_edge_scenario scenarios

let () =
  Alcotest.run "replay fixture contract"
    [
      ( "contract",
        [
          Alcotest.test_case "internal manifest exact schema" `Quick
            validate_manifest;
          Alcotest.test_case "expected and generator" `Quick
            validate_expected_and_generator;
          Alcotest.test_case "edge structures/counts/nonmutation" `Quick
            validate_edges;
        ] );
    ]
