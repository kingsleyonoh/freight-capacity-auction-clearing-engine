let required_case_fields =
  [
    "case_id";
    "allowed_uses";
    "production_clearing_success_eligible";
    "evidence_scope";
    "input";
    "expected";
    "stdout";
    "normalized_output";
  ]

let check_invalid label thunk =
  match thunk () with
  | () -> Alcotest.fail (label ^ " unexpectedly accepted")
  | exception Fixture_contract.Invalid _ -> ()

let validate_manifest () =
  let open Fixture_contract in
  let schema = load_json (path "solver/manifest.schema.json") in
  let instance = load_json (path "solver/manifest.json") in
  validate_schema schema instance;
  let manifest = assoc instance in
  exact_fields
    [ "schema_version"; "corpus_id"; "evidence_scope"; "cases" ]
    manifest;
  expect_int 1 "schema_version" manifest;
  expect_string "solver_contract_v1" "corpus_id" manifest;
  expect_string "fixture_contract_only" "evidence_scope" manifest;
  let cases = member "cases" manifest |> list in
  Alcotest.(check int) "five solver cases" 5 (List.length cases);
  List.iter
    (fun case ->
      let fields = assoc case in
      exact_fields required_case_fields fields;
      Alcotest.(check (list string))
        "closed allowed uses"
        [ "unit_contract"; "replay"; "local_diagnostic" ]
        (string_list "allowed_uses" fields);
      expect_bool false "production_clearing_success_eligible" fields;
      expect_string "fixture_contract_only" "evidence_scope" fields)
    cases;
  check_invalid "solver manifest unknown field" (fun () ->
      validate_schema schema
        (`Assoc (("unexpected", `Bool true) :: assoc instance)));
  check_invalid "solver manifest version" (fun () ->
      validate_schema schema
        (`Assoc
           (("schema_version", `Int 2)
           :: List.remove_assoc "schema_version" (assoc instance))))

let model_input () =
  Fixture_contract.load_json
    (Fixture_contract.path "solver/golden_single_round/input.json")
  |> Fixture_contract.assoc

let expected_decisions () =
  Fixture_contract.load_json
    (Fixture_contract.path "solver/golden_single_round/expected_decisions.json")
  |> Fixture_contract.assoc

let find_by name id values =
  List.find (fun value -> Fixture_contract.string name value = id) values

let int_of_decimal_micros value =
  match String.split_on_char '.' value with
  | [ whole; fraction ] ->
      let padded = fraction ^ "000000" in
      (int_of_string whole * 1_000_000) + int_of_string (String.sub padded 0 6)
  | _ -> Alcotest.failf "invalid decimal %s" value

let validate_input_schema () =
  let open Fixture_contract in
  let schema = load_json (path "solver/contracts/v1/model_input.schema.json") in
  let instance = `Assoc (model_input ()) in
  validate_schema schema instance;
  validate_schema_file ~schema_path:(path "solver/contracts/v1/model_input.schema.json")
    ~instance_path:(path "solver/infeasible_hard_constraints/input.json");
  let input = assoc instance in
  let policy = member "policy" input |> assoc in
  Alcotest.(check (list string))
    "declared total tie order"
    [ "total_score_micros"; "bid_amount"; "submitted_at"; "bid_id" ]
    (string_list "tie_break" policy);
  Alcotest.(check int)
    "four loads" 4
    (member "loads" input |> list |> List.length);
  Alcotest.(check int)
    "four carriers" 4
    (member "carriers" input |> list |> List.length);
  Alcotest.(check int)
    "eight eligible bids" 8
    (member "eligible_bids" input |> list |> List.length);
  Alcotest.(check int)
    "three excluded bids" 3
    (member "excluded_bids" input |> list |> List.length);
  check_invalid "model input enum" (fun () ->
      let auction = member "auction" input |> assoc in
      let bad_auction =
        `Assoc
          (("mode", `String "heuristic") :: List.remove_assoc "mode" auction)
      in
      validate_schema schema
        (`Assoc (("auction", bad_auction) :: List.remove_assoc "auction" input)))

let award_ids expected =
  Fixture_contract.member "awards" expected
  |> Fixture_contract.list
  |> List.map (fun award ->
      Fixture_contract.string "bid_id" (Fixture_contract.assoc award))

let stable_constraints =
  [
    "one_award_per_load";
    "carrier_capacity";
    "compatible_equipment";
    "reserve_price";
    "service_risk_cap";
    "max_carrier_share";
    "deterministic_tiebreak";
  ]

let validate_constraint_names label names =
  List.iter
    (fun name ->
      if not (List.mem name stable_constraints) then
        Alcotest.failf "unsupported %s constraint %s" label name)
    names

let validate_expected_entities expected =
  let open Fixture_contract in
  member "awards" expected |> list
  |> List.iter (fun value ->
      let award = assoc value in
      exact_fields
        [ "bid_id"; "load_id"; "carrier_id"; "binding_constraints" ]
        award;
      validate_constraint_names "award"
        (string_list "binding_constraints" award));
  member "decisions" expected
  |> list
  |> List.iter (fun value ->
      let decision = assoc value in
      exact_fields
        [
          "bid_id";
          "load_id";
          "decision_type";
          "binding_constraints";
          "rejected_reason";
          "score_micros";
        ]
        decision;
      if
        not
          (List.mem
             (string "decision_type" decision)
             [ "awarded"; "rejected"; "excluded" ])
      then Alcotest.fail "decision enum";
      validate_constraint_names "decision"
        (string_list "binding_constraints" decision))

let validate_decision_coverage input expected =
  let open Fixture_contract in
  let bid_ids name =
    member name input |> list
    |> List.map (fun value -> string "bid_id" (assoc value))
  in
  let input_ids =
    bid_ids "eligible_bids" @ bid_ids "excluded_bids"
    |> List.sort String.compare
  in
  let decisions = member "decisions" expected |> list |> List.map assoc in
  let decision_ids =
    List.map (string "bid_id") decisions |> List.sort String.compare
  in
  Alcotest.(check int) "all eleven decisions" 11 (List.length decisions);
  Alcotest.(check (list string))
    "exactly one decision per bid" input_ids decision_ids;
  Alcotest.(check int)
    "decision IDs unique" (List.length decision_ids)
    (List.sort_uniq String.compare decision_ids |> List.length)

let test_objective_and_decisions () =
  let open Fixture_contract in
  let input = model_input () and expected = expected_decisions () in
  validate_schema_file
    ~schema_path:(path "solver/contracts/v1/expected_decisions.schema.json")
    ~instance_path:(path "solver/golden_single_round/expected_decisions.json");
  let eligible = member "eligible_bids" input |> list |> List.map assoc in
  let objective =
    eligible
    |> List.filter (fun bid ->
        List.mem (string "bid_id" bid) (award_ids expected))
    |> List.fold_left (fun total bid -> total + int "total_score_micros" bid) 0
  in
  Alcotest.(check int)
    "objective equals awarded score sum" objective
    (int "objective_micros" expected);
  validate_expected_entities expected;
  validate_decision_coverage input expected

let award_count bids awards carrier_id =
  let open Fixture_contract in
  List.fold_left
    (fun count award ->
      let bid = find_by "bid_id" (string "bid_id" award) bids in
      if string "carrier_id" bid = carrier_id then count + 1 else count)
    0 awards

let validate_award_feasibility loads carriers bids awards risk_cap share_cap
    award =
  let open Fixture_contract in
  let bid = find_by "bid_id" (string "bid_id" award) bids in
  let load = find_by "load_id" (string "load_id" award) loads in
  let carrier = find_by "carrier_id" (string "carrier_id" award) carriers in
  Alcotest.(check string)
    "award load matches bid" (string "load_id" load) (string "load_id" bid);
  if
    float_of_string (string "bid_amount" bid)
    > float_of_string (string "reserve_price" load)
  then Alcotest.fail "awarded bid exceeds reserve";
  if
    not
      (List.mem
         (string "equipment_type" load)
         (string_list "equipment_types" carrier))
  then Alcotest.fail "awarded carrier equipment incompatible";
  if
    string "service_priority" load = "priority"
    && int "service_risk_micros" carrier > risk_cap
  then Alcotest.fail "priority award violates service risk";
  let count = award_count bids awards (string "carrier_id" carrier) in
  if count > int "capacity_units" carrier then
    Alcotest.fail "awards exceed carrier capacity";
  if count * 1_000_000 > share_cap * List.length loads then
    Alcotest.fail "awards exceed carrier share"

let test_feasibility_and_binding_reasons () =
  let open Fixture_contract in
  let input = model_input () and expected = expected_decisions () in
  let loads = member "loads" input |> list |> List.map assoc in
  let carriers = member "carriers" input |> list |> List.map assoc in
  let bids = member "eligible_bids" input |> list |> List.map assoc in
  let awards = member "awards" expected |> list |> List.map assoc in
  let policy = member "policy" input |> assoc in
  let risk_cap = int_of_decimal_micros (string "service_risk_cap" policy) in
  let share_cap = int_of_decimal_micros (string "max_carrier_share" policy) in
  List.iter
    (validate_award_feasibility loads carriers bids awards risk_cap share_cap)
    awards;
  let risk_bid = find_by "bid_id" "00000303-0000-4000-8000-000000000303" bids in
  let risk_load = find_by "load_id" (string "load_id" risk_bid) loads in
  let risk_carrier =
    find_by "carrier_id" (string "carrier_id" risk_bid) carriers
  in
  Alcotest.(check string)
    "risk rejection applies to priority load" "priority"
    (string "service_priority" risk_load);
  if int "service_risk_micros" risk_carrier <= risk_cap then
    Alcotest.fail "service-risk rejection does not bind";
  let lower = find_by "bid_id" "00000305-0000-4000-8000-000000000305" bids in
  let carrier = find_by "carrier_id" (string "carrier_id" lower) carriers in
  let proposed = award_count bids awards (string "carrier_id" lower) + 1 in
  if proposed <= int "capacity_units" carrier then
    Alcotest.fail "capacity does not bind";
  if proposed * 1_000_000 <= share_cap * List.length loads then
    Alcotest.fail "share does not bind"

let test_final_uuid_tie_branch () =
  let open Fixture_contract in
  let input = model_input () in
  let expected = expected_decisions () in
  let bids = member "eligible_bids" input |> list |> List.map assoc in
  let first = find_by "bid_id" "00000307-0000-4000-8000-000000000307" bids in
  let second = find_by "bid_id" "00000308-0000-4000-8000-000000000308" bids in
  Alcotest.(check int)
    "tie score"
    (int "total_score_micros" first)
    (int "total_score_micros" second);
  Alcotest.(check string)
    "tie amount"
    (string "bid_amount" first)
    (string "bid_amount" second);
  Alcotest.(check string)
    "tie submitted time"
    (string "submitted_at" first)
    (string "submitted_at" second);
  let expected_winner = min (string "bid_id" first) (string "bid_id" second) in
  if not (List.mem expected_winner (award_ids expected)) then
    Alcotest.fail "exact tie did not resolve on lowest bid UUID"

let terminal_records records =
  List.filter
    (fun record ->
      match List.assoc_opt "type" (Fixture_contract.assoc record) with
      | Some (`String "status") -> true
      | _ -> false)
    records

let validate_stream relative expected_status =
  let open Fixture_contract in
  let records = read_text (path relative) |> ndjson in
  let terminals = terminal_records records in
  Alcotest.(check int) "exactly one terminal" 1 (List.length terminals);
  if List.hd (List.rev records) <> List.hd terminals then
    Alcotest.fail "terminal must be final record";
  let terminal = List.hd terminals |> assoc in
  exact_fields [ "type"; "status" ] terminal;
  expect_string expected_status "status" terminal;
  records

let validate_raw_solution records =
  let open Fixture_contract in
  let solutions =
    List.filter
      (fun record ->
        List.assoc_opt "type" (assoc record) = Some (`String "solution"))
      records
  in
  Alcotest.(check int) "one solution" 1 (List.length solutions);
  let solution = List.hd solutions |> assoc in
  exact_fields
    [
      "type";
      "protocol_version";
      "objective_micros";
      "assignments";
      "binding_constraints";
      "statistics";
    ]
    solution;
  expect_string "solution" "type" solution;
  expect_int 1 "protocol_version" solution;
  member "assignments" solution
  |> list
  |> List.iter (fun assignment ->
      exact_fields [ "load_id"; "bid_id" ] (assoc assignment));
  let statistics = member "statistics" solution |> assoc in
  exact_fields [ "solutions"; "nodes_bucket" ] statistics;
  expect_int 1 "solutions" statistics;
  expect_string "under_100" "nodes_bucket" statistics;
  solution

let test_normalized_output_and_ndjson () =
  let open Fixture_contract in
  let records =
    validate_stream "solver/golden_single_round/minizinc.stdout.ndjson"
      "SATISFIED"
  in
  let solution = validate_raw_solution records in
  let output_path = path "solver/golden_single_round/normalized_output.json" in
  validate_schema_file
    ~schema_path:(path "solver/contracts/v1/normalized_output.schema.json")
    ~instance_path:output_path;
  let output = load_json output_path |> assoc in
  expect_string "SATISFIED" "terminal_status" output;
  Alcotest.(check int)
    "normalized objective"
    (int "objective_micros" (expected_decisions ()))
    (int "objective_micros" output);
  Alcotest.(check int)
    "four assignments" 4
    (member "assignments" output |> list |> List.length);
  Alcotest.(check string)
    "raw/normalized objective"
    (Yojson.Safe.to_string (member "objective_micros" solution))
    (Yojson.Safe.to_string (member "objective_micros" output));
  Alcotest.(check string)
    "raw/normalized assignments"
    (Yojson.Safe.to_string (member "assignments" solution))
    (Yojson.Safe.to_string (member "assignments" output))

let validate_infeasible_oracle () =
  let open Fixture_contract in
  validate_schema_file
    ~schema_path:(path "solver/contracts/v1/infeasible_expected.schema.json")
    ~instance_path:(path "solver/infeasible_hard_constraints/expected.json");
  let expected =
    load_json (path "solver/infeasible_hard_constraints/expected.json") |> assoc
  in
  expect_string "UNSATISFIABLE" "terminal_status" expected;
  Alcotest.(check int)
    "unsat awards" 0
    (member "awards" expected |> list |> List.length);
  expect_bool false "auto_relaxed" expected;
  expect_bool false "published" expected;
  let relaxations =
    member "ranked_relaxations" expected |> list |> List.map assoc
  in
  Alcotest.(check (list int))
    "ranked relaxations" [ 1; 2 ]
    (List.map (int "rank") relaxations);
  ignore
    (validate_stream "solver/infeasible_hard_constraints/minizinc.stdout.ndjson"
       "UNSATISFIABLE")

let validate_failure_case_schemas () =
  let open Fixture_contract in
  let schema = path "solver/contracts/v1/failure_case.schema.json" in
  [
    "solver/timeout/case.json";
    "solver/malformed/case.json";
    "solver/nonzero/case.json";
  ]
  |> List.iter (fun relative ->
      validate_schema_file ~schema_path:schema ~instance_path:(path relative))

let validate_malformed_oracle () =
  let open Fixture_contract in
  let malformed = load_json (path "solver/malformed/case.json") |> assoc in
  expect_string "SOLVER_MALFORMED_OUTPUT" "error_code" malformed;
  let records =
    read_text (path "solver/malformed/minizinc.stdout.ndjson") |> ndjson
  in
  Alcotest.(check int)
    "malformed stream has no terminal" 0
    (terminal_records records |> List.length);
  match member "assignments" (List.hd records |> assoc) with
  | `List _ -> Alcotest.fail "malformed assignment unexpectedly valid"
  | _ -> ()

let validate_timeout_nonzero_oracles () =
  let open Fixture_contract in
  let timeout = load_json (path "solver/timeout/case.json") |> assoc in
  expect_string "timeout" "process_outcome" timeout;
  expect_string "SOLVER_TIMEOUT" "error_code" timeout;
  Alcotest.(check int)
    "timeout awards" 0
    (member "awards" timeout |> list |> List.length);
  let nonzero = load_json (path "solver/nonzero/case.json") |> assoc in
  expect_int 17 "exit_code" nonzero;
  expect_string "omitted" "stderr_policy" nonzero;
  Alcotest.(check int)
    "nonzero awards" 0
    (member "awards" nonzero |> list |> List.length)

let test_failure_oracles () =
  validate_infeasible_oracle ();
  validate_failure_case_schemas ();
  validate_malformed_oracle ();
  validate_timeout_nonzero_oracles ()

let () =
  Alcotest.run "solver fixture contract"
    [
      ( "schemas",
        [
          Alcotest.test_case "manifest exact schema" `Quick validate_manifest;
          Alcotest.test_case "model input exact schema" `Quick
            validate_input_schema;
        ] );
      ( "golden oracle",
        [
          Alcotest.test_case "objective and one decision per bid" `Quick
            test_objective_and_decisions;
          Alcotest.test_case "feasibility and binding reasons" `Quick
            test_feasibility_and_binding_reasons;
          Alcotest.test_case "final UUID tie branch" `Quick
            test_final_uuid_tie_branch;
          Alcotest.test_case "normalized output and NDJSON" `Quick
            test_normalized_output_and_ndjson;
        ] );
      ( "failure oracle",
        [
          Alcotest.test_case "fail closed semantics" `Quick test_failure_oracles;
        ] );
    ]
