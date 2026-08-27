let expect condition message = if not condition then Alcotest.fail message

let can_tenant_admin_manage_tenant_settings () =
  Permission_matrix.can ~role:"tenant_admin" ~action:Permission_matrix.Manage_users Permission_matrix.Tenant

let can_tenant_admin_manage_carriers () =
  Permission_matrix.can ~role:"tenant_admin" ~action:Permission_matrix.Manage_auctions Permission_matrix.Tenant

let can_tenant_admin_import_and_clear () =
  Permission_matrix.can ~role:"tenant_admin" ~action:Permission_matrix.Request_clear Permission_matrix.Tenant

let can_tenant_admin_approve_high_value_awards () =
  Permission_matrix.can ~role:"tenant_admin" ~action:Permission_matrix.Approve_award Permission_matrix.Tenant

let can_tenant_admin_view_audit_reports () =
  Permission_matrix.can ~role:"tenant_admin" ~action:Permission_matrix.Export_report Permission_matrix.Tenant

let can_auction_manager_manage_carriers () =
  Permission_matrix.can ~role:"auction_manager" ~action:Permission_matrix.Manage_auctions Permission_matrix.Tenant

let can_auction_manager_import_and_clear () =
  Permission_matrix.can ~role:"auction_manager" ~action:Permission_matrix.Request_clear Permission_matrix.Tenant

let can_auction_manager_view_audit_reports () =
  Permission_matrix.can ~role:"auction_manager" ~action:Permission_matrix.Export_report Permission_matrix.Tenant

let can_procurement_analyst_import_and_clear () =
  Permission_matrix.can ~role:"procurement_analyst" ~action:Permission_matrix.Request_clear Permission_matrix.Tenant

let can_procurement_analyst_view_audit_reports () =
  Permission_matrix.can ~role:"procurement_analyst" ~action:Permission_matrix.Export_report Permission_matrix.Tenant

let can_carrier_viewer_view_own_bid_audit () =
  Permission_matrix.can ~role:"carrier_viewer" ~action:Permission_matrix.Read_own_bid Permission_matrix.Own_carrier

let test_allowed_paths () =
  List.iter
    (fun (name, allowed) -> expect (allowed ()) (name ^ " should be allowed"))
    [ ("tenant admin settings", can_tenant_admin_manage_tenant_settings);
      ("tenant admin carriers", can_tenant_admin_manage_carriers);
      ("tenant admin clearing", can_tenant_admin_import_and_clear);
      ("tenant admin approval", can_tenant_admin_approve_high_value_awards);
      ("tenant admin reports", can_tenant_admin_view_audit_reports);
      ("manager carriers", can_auction_manager_manage_carriers);
      ("manager clearing", can_auction_manager_import_and_clear);
      ("manager reports", can_auction_manager_view_audit_reports);
      ("analyst clearing", can_procurement_analyst_import_and_clear);
      ("analyst reports", can_procurement_analyst_view_audit_reports);
      ("carrier own bids", can_carrier_viewer_view_own_bid_audit) ]

let test_denied_boundaries () =
  let denied role action scope name =
    expect
      (not (Permission_matrix.can ~role ~action scope))
      (name ^ " should be denied")
  in
  denied "auction_manager" Permission_matrix.Manage_users Permission_matrix.Tenant "manager tenant settings";
  denied "auction_manager" Permission_matrix.Manage_integration Permission_matrix.Tenant "manager integrations";
  denied "procurement_analyst" Permission_matrix.Manage_auctions Permission_matrix.Tenant "analyst carrier master data";
  denied "procurement_analyst" Permission_matrix.Approve_award Permission_matrix.Tenant "analyst approval";
  denied "carrier_viewer" Permission_matrix.Read_competitor_bid Permission_matrix.Any_carrier "carrier competitor bids";
  denied "carrier_viewer" Permission_matrix.Request_clear Permission_matrix.Tenant "carrier clearing";
  denied "carrier_viewer" Permission_matrix.Manage_integration Permission_matrix.Tenant "carrier integrations";
  denied "unknown" Permission_matrix.Read_tenant Permission_matrix.Tenant "unknown role"

let test_single_round_capabilities () =
  expect
    (Result.is_ok (Capability_registry.production_mode "single_round_spot"))
    "single-round production path should be registered";
  expect
    (Result.is_error (Capability_registry.production_mode "multi_round_spot"))
    "multi-round path must fail closed";
  let paths = Capability_registry.single_round_spot_capabilities () in
  expect (List.length paths = 6) "single-round capability registry is incomplete";
  expect
    (List.exists (fun (name, path) -> name = "reserve_price_enforcement" && path = Capability_registry.Registered) paths)
    "reserve capability is not registered";
  expect
    (List.exists (fun (name, path) -> name = "multi_load_bundle_awards" && match path with Capability_registry.Explicitly_excluded _ -> true | _ -> false) paths)
    "bundled awards exclusion is not explicit"

let () =
  Alcotest.run "Authorization matrix"
    [ ("matrix",
       [ Alcotest.test_case "allowed paths" `Quick test_allowed_paths;
         Alcotest.test_case "denied boundaries" `Quick test_denied_boundaries;
         Alcotest.test_case "single-round capability registry" `Quick test_single_round_capabilities ]) ]
