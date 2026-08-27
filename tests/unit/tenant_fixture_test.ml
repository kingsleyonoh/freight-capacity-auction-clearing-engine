let fixture_path () =
  match Sys.getenv_opt "FCA_TENANT_FIXTURE" with
  | Some path -> path
  | None -> Alcotest.fail "FCA_TENANT_FIXTURE is required"

let loaded () =
  match Tenant_fixture.load_file (fixture_path ()) with
  | Ok fixture -> fixture
  | Error errors ->
      Alcotest.failf "fixture rejected: %s"
        (String.concat "," (List.map Tenant_fixture.error_code errors))

let unique values =
  List.sort_uniq String.compare values |> List.length = List.length values

let contains_non_ascii value =
  String.exists (fun character -> Char.code character > 127) value

let test_schema_version_and_exact_two () =
  let fixture = loaded () in
  Alcotest.(check int) "schema version" 1 fixture.schema_version;
  Alcotest.(check int) "exactly two tenants" 2 (List.length fixture.tenants)

let test_distinct_identity_and_unicode () =
  let tenants = (loaded ()).tenants in
  let ids =
    List.map (fun (tenant : Tenant_fixture.tenant) -> tenant.id) tenants
  in
  let legal_names =
    List.map (fun (tenant : Tenant_fixture.tenant) -> tenant.legal_name) tenants
  in
  let registrations =
    List.map
      (fun (tenant : Tenant_fixture.tenant) ->
        tenant.registration.broker_registration)
      tenants
  in
  Alcotest.(check bool) "tenant IDs are distinct" true (unique ids);
  Alcotest.(check bool)
    "legal identities are distinct" true (unique legal_names);
  Alcotest.(check bool) "registrations are distinct" true (unique registrations);
  Alcotest.(check bool)
    "canonical fixture preserves Unicode" true
    (List.exists
       (fun (tenant : Tenant_fixture.tenant) ->
         contains_non_ascii tenant.name
         || contains_non_ascii tenant.legal_name
         || contains_non_ascii tenant.contact.operations_contact)
       tenants)

let test_overlap_public_labels_and_distinct_ids () =
  let tenants = (loaded ()).tenants in
  let first, second =
    match tenants with
    | [ first; second ] -> (first, second)
    | _ -> Alcotest.fail "fixture must have exactly two tenants"
  in
  Alcotest.(check string)
    "carrier public name overlaps" first.overlap.carrier.public_name
    second.overlap.carrier.public_name;
  Alcotest.(check string)
    "load public ref overlaps" first.overlap.load.public_ref
    second.overlap.load.public_ref;
  Alcotest.(check string)
    "auction public name overlaps" first.overlap.auction.public_name
    second.overlap.auction.public_name;
  Alcotest.(check bool)
    "carrier IDs differ" true
    (first.overlap.carrier.id <> second.overlap.carrier.id);
  Alcotest.(check bool)
    "load IDs differ" true
    (first.overlap.load.id <> second.overlap.load.id);
  Alcotest.(check bool)
    "auction IDs differ" true
    (first.overlap.auction.id <> second.overlap.auction.id)

let test_schema_contract_and_secret_rejection () =
  let fixture = loaded () in
  Alcotest.(check (result unit string))
    "normative schema is satisfied" (Ok ())
    (Tenant_fixture.validate_schema_file
       ~schema_path:(Sys.getenv "FCA_TENANT_FIXTURE_SCHEMA")
       ~fixture_path:(fixture_path ()));
  let json = Tenant_fixture.to_yojson fixture in
  let tainted =
    match json with
    | `Assoc fields -> `Assoc (("api_key", `String "synthetic") :: fields)
    | _ -> Alcotest.fail "fixture encoder must return an object"
  in
  match Tenant_fixture.of_yojson tainted with
  | Error errors ->
      Alcotest.(check bool)
        "secret-like key is rejected" true
        (List.exists
           (fun error ->
             Tenant_fixture.error_code error = "FIXTURE_SECRET_KEY_FORBIDDEN")
           errors)
  | Ok _ -> Alcotest.fail "secret-like key was accepted"

let () =
  Alcotest.run "tenant-fixture"
    [
      ( "canonical",
        [
          Alcotest.test_case "schema version and cardinality" `Quick
            test_schema_version_and_exact_two;
          Alcotest.test_case "distinct identity and Unicode" `Quick
            test_distinct_identity_and_unicode;
          Alcotest.test_case "overlap labels and distinct IDs" `Quick
            test_overlap_public_labels_and_distinct_ids;
          Alcotest.test_case "schema and no-secret semantics" `Quick
            test_schema_contract_and_secret_rejection;
        ] );
    ]
