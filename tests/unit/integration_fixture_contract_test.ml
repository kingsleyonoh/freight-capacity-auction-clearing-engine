let recording_fields =
  [
    "schema_version";
    "adapter";
    "case_id";
    "direction";
    "evidence_scope";
    "network_policy";
    "tenant_scope";
    "request";
    "transport";
    "response";
    "expected";
  ]

let check_enum label allowed value =
  if not (List.mem value allowed) then
    Alcotest.failf "%s unsupported value %s" label value

let exact_body_fields fields expected =
  Fixture_contract.exact_fields expected fields

let validate_body_types fields =
  List.iter
    (fun (name, value) ->
      match (name, value) with
      | ("award_count" | "relaxation_count" | "retry_after_seconds"), `Int _ ->
          ()
      | "signature_descriptor", `Assoc descriptor ->
          Fixture_contract.exact_fields
            [ "algorithm"; "encoding"; "length"; "value" ]
            descriptor
      | _, `String _ -> ()
      | _ -> Alcotest.failf "integration body field %s has wrong type" name)
    fields

let expected_body_shape adapter case_id =
  match (adapter, case_id) with
  | "notification_hub", "success" ->
      ([ "event_type"; "auction_ref"; "award_count" ], Some [ "status" ])
  | "notification_hub", "timeout" ->
      ([ "event_type"; "auction_ref"; "relaxation_count" ], None)
  | "notification_hub", "rate_limited_429" ->
      ([ "event_type"; "award_ref" ], Some [ "code"; "retry_after_seconds" ])
  | "notification_hub", "duplicate" ->
      ([ "event_type"; "export_ref" ], Some [ "status"; "duplicate_of" ])
  | "workflow_engine", "execute_success" | "workflow_engine", "timeout" ->
      ( [ "workflow_ref"; "award_ref" ],
        if case_id = "timeout" then None else Some [ "execution_ref"; "status" ]
      )
  | "workflow_engine", "status_success" ->
      ([ "fixture_event_ref" ], Some [ "execution_ref"; "status"; "decision" ])
  | "workflow_engine", "rate_limited_429" ->
      ([ "fixture_event_ref" ], Some [ "code"; "retry_after_seconds" ])
  | "workflow_engine", "duplicate" ->
      ([ "fixture_event_ref" ], Some [ "execution_ref"; "status" ])
  | "webhook_engine", "accepted"
  | "webhook_engine", "duplicate"
  | "webhook_engine", "retriable_failure" ->
      ( [ "event_type"; "event_ref"; "tenant_id"; "bid_ref" ],
        if case_id = "retriable_failure" then Some [ "code" ]
        else Some [ "status" ] )
  | "webhook_engine", "signature_shaped_invalid" ->
      ([ "signature_descriptor"; "event_ref" ], Some [ "code" ])
  | "webhook_engine", "unknown_source" ->
      ([ "source_ref"; "event_ref" ], Some [ "status" ])
  | _ -> Alcotest.failf "unrecognized recording shape %s/%s" adapter case_id

let validate_tenant_scope adapter case_id fields =
  let open Fixture_contract in
  let scope = member "tenant_scope" fields |> assoc in
  exact_fields [ "tenant_fixture"; "resolution_stage"; "tenant_id" ] scope;
  expect_string "../tenants.json" "tenant_fixture" scope;
  let stage = string "resolution_stage" scope in
  let expected_stage =
    match (adapter, case_id) with
    | "webhook_engine", "signature_shaped_invalid" ->
        "pre_tenant_invalid_signature"
    | "webhook_engine", "unknown_source" -> "pre_tenant_unknown_source"
    | _ -> "tenant_known"
  in
  Alcotest.(check string) "tenant resolution stage" expected_stage stage;
  match (stage, member "tenant_id" scope) with
  | "tenant_known", `String tenant_id ->
      if not (List.mem tenant_id (tenant_ids ())) then
        Alcotest.fail "recording tenant not canonical"
  | ("pre_tenant_invalid_signature" | "pre_tenant_unknown_source"), `Null -> ()
  | _ -> Alcotest.fail "tenant scope ID/stage mismatch"

let validate_headers label headers =
  let open Fixture_contract in
  member "redacted_headers" headers
  |> list
  |> List.iter (fun header ->
      let header = assoc header in
      exact_fields [ "name"; "value" ] header;
      expect_string "[REDACTED_FIXTURE]" "value" header);
  member "header_names" headers
  |> list
  |> List.iter (function
    | `String _ -> ()
    | _ -> Alcotest.fail (label ^ " header name must be string"))

let validate_request adapter case_id fields =
  let open Fixture_contract in
  let request = member "request" fields |> assoc in
  exact_fields
    [ "method"; "route_template"; "header_names"; "redacted_headers"; "body" ]
    request;
  check_enum "method" [ "GET"; "POST" ] (string "method" request);
  let route = string "route_template" request in
  if
    (not (String.starts_with ~prefix:"/" route))
    || contains ~substring:"://" route
  then Alcotest.fail "route must be a template, never a full URI";
  validate_headers "request" request;
  let request_shape, response_shape = expected_body_shape adapter case_id in
  let body = member "body" request |> assoc in
  exact_body_fields body request_shape;
  validate_body_types body;
  response_shape

let validate_transport_response response_shape fields =
  let open Fixture_contract in
  let transport = member "transport" fields |> assoc in
  exact_fields [ "outcome"; "attempt"; "elapsed_ms_bucket" ] transport;
  check_enum "transport outcome" [ "response"; "timeout" ]
    (string "outcome" transport);
  if int "attempt" transport < 1 then Alcotest.fail "attempt must be positive";
  expect_string "under_5000" "elapsed_ms_bucket" transport;
  match
    (string "outcome" transport, member "response" fields, response_shape)
  with
  | "timeout", `Null, None -> ()
  | "response", `Assoc response, Some body_fields ->
      exact_fields
        [ "status"; "header_names"; "redacted_headers"; "body" ]
        response;
      validate_headers "response" response;
      let body = member "body" response |> assoc in
      exact_body_fields body body_fields;
      validate_body_types body
  | _ -> Alcotest.fail "transport/response contract mismatch"

let validate_expected fields =
  let open Fixture_contract in
  let expected = member "expected" fields |> assoc in
  exact_fields
    [
      "adapter_status";
      "outbox_status";
      "retry_scheduled";
      "duplicate_of";
      "canonical_state_mutated";
      "audit_code";
      "response_status";
    ]
    expected;
  check_enum "adapter status"
    [
      "accepted";
      "completed";
      "timeout";
      "rate_limited";
      "duplicate";
      "ignored";
      "rejected";
      "retriable_failure";
    ]
    (string "adapter_status" expected);
  check_enum "outbox status"
    [ "delivered"; "retry_scheduled"; "not_applicable" ]
    (string "outbox_status" expected);
  expect_bool false "canonical_state_mutated" expected

let validate_recording fields =
  let open Fixture_contract in
  exact_fields recording_fields fields;
  expect_int 1 "schema_version" fields;
  expect_string "recorded_contract_only" "evidence_scope" fields;
  expect_string "no_live_call" "network_policy" fields;
  let adapter = string "adapter" fields and case_id = string "case_id" fields in
  check_enum "adapter"
    [ "notification_hub"; "workflow_engine"; "webhook_engine" ]
    adapter;
  check_enum "direction" [ "outbound"; "inbound" ] (string "direction" fields);
  validate_tenant_scope adapter case_id fields;
  validate_transport_response (validate_request adapter case_id fields) fields;
  validate_expected fields;
  reject_private_data
    ?allowed_signature_path:
      (if adapter = "webhook_engine" && case_id = "signature_shaped_invalid"
       then Some "$.request.body.signature_descriptor"
       else None)
    (`Assoc fields)

let validate_privacy_policy () =
  let open Fixture_contract in
  let policy = load_json (path "integrations/privacy-policy.json") |> assoc in
  exact_fields
    [
      "schema_version";
      "evidence_scope";
      "network_policy";
      "forbidden_fields";
      "required_redaction";
      "signature_descriptor";
    ]
    policy;
  expect_int 1 "schema_version" policy;
  expect_string "[REDACTED_FIXTURE]" "required_redaction" policy

let validate_recording_entry schema adapters value =
  let open Fixture_contract in
  let entry = assoc value in
  exact_fields [ "adapter"; "case_id"; "file" ] entry;
  let instance = load_json (path (string "file" entry)) in
  validate_schema schema instance;
  let fields = assoc instance in
  Alcotest.(check string)
    "manifest adapter" (string "adapter" entry) (string "adapter" fields);
  Alcotest.(check string)
    "manifest case" (string "case_id" entry) (string "case_id" fields);
  validate_recording fields;
  let adapter = string "adapter" fields in
  Hashtbl.replace adapters adapter
    (1 + Option.value ~default:0 (Hashtbl.find_opt adapters adapter))

let test_recordings () =
  let open Fixture_contract in
  validate_privacy_policy ();
  let schema = load_json (path "integrations/recording.schema.json") in
  let manifest = load_json (path "integrations/manifest.json") |> assoc in
  exact_fields
    [ "schema_version"; "evidence_scope"; "network_policy"; "recordings" ]
    manifest;
  expect_int 1 "schema_version" manifest;
  expect_string "recorded_contract_only" "evidence_scope" manifest;
  expect_string "no_live_call" "network_policy" manifest;
  let recordings = member "recordings" manifest |> list in
  Alcotest.(check int) "fourteen recordings" 14 (List.length recordings);
  let adapters = Hashtbl.create 3 in
  List.iter (validate_recording_entry schema adapters) recordings;
  Alcotest.(check int) "hub cases" 4 (Hashtbl.find adapters "notification_hub");
  Alcotest.(check int)
    "workflow cases" 5
    (Hashtbl.find adapters "workflow_engine");
  Alcotest.(check int)
    "webhook cases" 5
    (Hashtbl.find adapters "webhook_engine")

let () =
  Alcotest.run "recorded integration fixture contract"
    [
      ( "contract",
        [
          Alcotest.test_case "strict schemas, shapes, and tenant scope" `Quick
            test_recordings;
        ] );
    ]
