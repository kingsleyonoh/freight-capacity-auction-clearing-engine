let fixture_path () =
  Option.value
    (Sys.getenv_opt "FCA_TENANT_FIXTURE")
    ~default:"tests/fixtures/tenants.json"

let fixture () =
  match Tenant_fixture.load_file (fixture_path ()) with
  | Ok fixture -> fixture
  | Error errors ->
      Alcotest.failf "fixture rejected: %s"
        (String.concat "," (List.map Tenant_fixture.error_code errors))

let json_body response =
  Yojson.Safe.from_string response.Dream_request_harness.body

let tenant_id tenant = tenant.Tenant_fixture.id

let contains ~substring value =
  let substring_length = String.length substring in
  let rec loop index =
    index + substring_length <= String.length value
    && (String.sub value index substring_length = substring || loop (index + 1))
  in
  substring = "" || loop 0

let test_registered_tenant_probe () =
  let fixture = fixture () in
  let tenant = List.hd fixture.tenants in
  let app =
    Dream_tenant_probe_app.build ~fixture ~worker_check:(fun requested_tenant ->
        Lwt.return
          (Ok
             (`Assoc
                [
                  ("validated_tenant_id", `String requested_tenant);
                  ("tenant_count", `Int 2);
                ])))
  in
  let response =
    Dream_request_harness.call app
      ~headers:[ ("X-FCA-Test-Tenant", tenant_id tenant) ]
      ~target:("/__test/tenants/" ^ tenant_id tenant)
  in
  Alcotest.(check int) "status" 200 response.status;
  Alcotest.(check (option string))
    "request correlation" (Some "test-request-1")
    (Dream_request_harness.header "x-request-id" response);
  let body = json_body response |> Yojson.Safe.to_string in
  Alcotest.(check bool)
    "current tenant is present" true
    (contains body ~substring:tenant.display_name);
  let other = List.nth fixture.tenants 1 in
  List.iter
    (fun literal ->
      Alcotest.(check bool)
        "other-tenant identity is absent" false
        (contains body ~substring:literal))
    (Tenant_fixture.public_identity_literals other)

let error_code response =
  match json_body response with
  | `Assoc [ ("error", `Assoc fields) ] -> (
      match List.assoc_opt "code" fields with
      | Some (`String code) -> code
      | _ -> Alcotest.fail "missing canonical error code")
  | _ -> Alcotest.fail "non-canonical error envelope"

let test_middleware_and_canonical_errors () =
  let fixture = fixture () in
  let app =
    Dream_tenant_probe_app.build ~fixture ~worker_check:(fun _ ->
        Lwt.return (Error "WORKER_FIXTURE_REJECTED"))
  in
  let missing =
    Dream_request_harness.call app ~target:"/__test/tenants/not-a-uuid"
  in
  Alcotest.(check int) "missing header" 400 missing.status;
  Alcotest.(check string)
    "missing header code" "TEST_TENANT_REQUIRED" (error_code missing);
  let tenant = List.hd fixture.tenants in
  let failed =
    Dream_request_harness.call app ~method_:`POST
      ~headers:[ ("X-FCA-Test-Tenant", tenant_id tenant) ]
      ~target:("/__test/tenants/" ^ tenant_id tenant ^ "/validate")
  in
  Alcotest.(check int) "typed worker error" 503 failed.status;
  Alcotest.(check string)
    "typed worker code" "WORKER_FIXTURE_REJECTED" (error_code failed)

let test_cross_tenant_is_non_disclosing () =
  let fixture = fixture () in
  let current, other =
    match fixture.tenants with
    | [ current; other ] -> (current, other)
    | _ -> Alcotest.fail "expected two tenants"
  in
  let calls = ref 0 in
  let app =
    Dream_tenant_probe_app.build ~fixture ~worker_check:(fun _ ->
        incr calls;
        Lwt.return (Ok (`Assoc [])))
  in
  let response =
    Dream_request_harness.call app ~method_:`POST
      ~headers:[ ("X-FCA-Test-Tenant", tenant_id current) ]
      ~target:("/__test/tenants/" ^ tenant_id other ^ "/validate")
  in
  Alcotest.(check int) "cross-tenant status" 404 response.status;
  Alcotest.(check string)
    "non-disclosing code" "TEST_RESOURCE_NOT_FOUND" (error_code response);
  Alcotest.(check int) "worker callback was not invoked" 0 !calls;
  let body = Yojson.Safe.to_string (json_body response) in
  List.iter
    (fun literal ->
      Alcotest.(check bool)
        "other-tenant literal is absent" false
        (contains body ~substring:literal))
    (Tenant_fixture.public_identity_literals other)

let run () =
  Alcotest.run "dream-request-infrastructure"
    [
      ( "test-only-probe",
        [
          Alcotest.test_case "registered tenant probe" `Quick
            test_registered_tenant_probe;
          Alcotest.test_case "middleware and canonical errors" `Quick
            test_middleware_and_canonical_errors;
          Alcotest.test_case "cross tenant non-disclosure" `Quick
            test_cross_tenant_is_non_disclosing;
        ] );
    ]
