let fixture_path =
  match Sys.getenv_opt "FCA_TENANT_FIXTURE" with
  | Some path -> path
  | None -> Filename.concat (Filename.dirname __FILE__) "../fixtures/tenants.json"

let tenant_ids =
  let json = Yojson.Safe.from_file fixture_path in
  match Yojson.Safe.Util.(json |> member "tenants" |> to_list) with
  | [ tenant_a; tenant_b ] ->
      ( Yojson.Safe.Util.(tenant_a |> member "id" |> to_string),
        Yojson.Safe.Util.(tenant_b |> member "id" |> to_string) )
  | _ -> Alcotest.fail "canonical tenant fixture must contain exactly two tenants"

let uuid_a, uuid_b = tenant_ids
let carrier_uuid = "33333333-3333-4333-8333-333333333333"

let ok = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "expected valid value"

let is_error = function Error _ -> true | Ok _ -> false

let test_ids_and_tenants () =
  let tenant_a = ok (Tenant_context.Tenant_id.of_string uuid_a) in
  let tenant_b = ok (Tenant_context.Tenant_id.of_string uuid_b) in
  Alcotest.(check string)
    "tenant A immutable UUID" uuid_a
    (Tenant_context.Tenant_id.to_string tenant_a);
  Alcotest.(check string)
    "tenant B immutable UUID" uuid_b
    (Tenant_context.Tenant_id.to_string tenant_b);
  Alcotest.(check bool) "tenant A differs from B" true (uuid_a <> uuid_b);
  Alcotest.(check bool) "tenant B differs from A" true (uuid_b <> uuid_a);
  Alcotest.(check bool)
    "reject malformed" true
    (is_error (Tenant_context.Tenant_id.of_string "not-a-uuid"));
  Alcotest.(check bool)
    "reject non-RFC variant" true
    (is_error
       (Tenant_context.User_id.of_string "11111111-1111-4111-1111-111111111111"))

let test_user_scope () =
  let tenant_id = ok (Tenant_context.Tenant_id.of_string uuid_a) in
  let other_tenant_id = ok (Tenant_context.Tenant_id.of_string uuid_b) in
  let user_id = ok (Tenant_context.User_id.of_string uuid_b) in
  let carrier_id = ok (Tenant_context.Carrier_id.of_string carrier_uuid) in
  let viewer =
    ok
      (Tenant_context.user ~tenant_id ~user_id
         ~role:Tenant_context.Carrier_viewer ~carrier_id ~request_id:"req-123"
         ())
  in
  Alcotest.(check string)
    "exactly one tenant" uuid_a
    (Tenant_context.Tenant_id.to_string (Tenant_context.tenant_id viewer));
  let other_viewer =
    ok
      (Tenant_context.user ~tenant_id:other_tenant_id ~user_id
         ~role:Tenant_context.Carrier_viewer ~carrier_id
         ~request_id:"req-other-tenant" ())
  in
  let viewer_tenant =
    Tenant_context.tenant_id viewer |> Tenant_context.Tenant_id.to_string
  in
  let other_viewer_tenant =
    Tenant_context.tenant_id other_viewer
    |> Tenant_context.Tenant_id.to_string
  in
  Alcotest.(check bool)
    "A context is not tenant B" true (viewer_tenant <> uuid_b);
  Alcotest.(check bool)
    "B context is not tenant A" true (other_viewer_tenant <> uuid_a);
  Alcotest.(check bool)
    "viewer has carrier" true
    (Option.is_some (Tenant_context.carrier_id viewer));
  Alcotest.(check bool)
    "viewer requires carrier" true
    (is_error
       (Tenant_context.user ~tenant_id ~user_id
          ~role:Tenant_context.Carrier_viewer ~request_id:"req-124" ()));
  Alcotest.(check bool)
    "manager rejects carrier scope" true
    (is_error
       (Tenant_context.user ~tenant_id ~user_id
          ~role:Tenant_context.Auction_manager ~carrier_id ~request_id:"req-125"
          ()))

let test_non_user_actors () =
  let tenant_id = ok (Tenant_context.Tenant_id.of_string uuid_a) in
  let system =
    ok
      (Tenant_context.system ~tenant_id ~name:"clearing-worker"
         ~request_id:"job-1" ())
  in
  let integration =
    ok
      (Tenant_context.integration ~tenant_id ~name:"notification-hub"
         ~request_id:"event-1" ())
  in
  Alcotest.(check bool)
    "system has no role" true
    (Option.is_none (Tenant_context.role system));
  Alcotest.(check bool)
    "integration has no carrier" true
    (Option.is_none (Tenant_context.carrier_id integration));
  Alcotest.(check bool)
    "blank actor rejected" true
    (is_error
       (Tenant_context.system ~tenant_id ~name:" " ~request_id:"job-2" ()))

let () =
  Alcotest.run "Tenant context"
    [
      ( "identity",
        [
          Alcotest.test_case "validated UUIDs and tenants" `Quick
            test_ids_and_tenants;
        ] );
      ( "scope",
        [ Alcotest.test_case "carrier viewer invariant" `Quick test_user_scope ]
      );
      ( "actors",
        [ Alcotest.test_case "pure actor contexts" `Quick test_non_user_actors ]
      );
    ]
