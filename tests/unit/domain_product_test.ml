let expect condition message = if not condition then Alcotest.fail message

let test_permissions () =
  expect (Permission_matrix.can ~role:"carrier_viewer" ~action:Permission_matrix.Submit_bid Permission_matrix.Own_carrier) "carrier can submit";
  expect (not (Permission_matrix.can ~role:"carrier_viewer" ~action:Permission_matrix.Read_competitor_bid Permission_matrix.Any_carrier)) "carrier cannot inspect competitors";
  expect (Permission_matrix.can ~role:"auction_manager" ~action:Permission_matrix.Close_auction Permission_matrix.Tenant) "manager can close";
  expect (not (Permission_matrix.can ~role:"unknown" ~action:Permission_matrix.Read_tenant Permission_matrix.Tenant)) "unknown role fails closed"

let test_import_validation () =
  let csv = "external_id,origin,destination,equipment,pickup_at,delivery_at,quantity\nload-1,NG,US,dry_van,2026-08-27T10:00,2026-08-28T10:00,2\nload-1,NG,US,dry_van,2026-08-27T10:00,2026-08-28T10:00,2\nload-2,NG,XX,dry_van,2026-08-27T10:00,2026-08-28T10:00,1" in
  match Validator.parse_csv ~unknown_carrier_policy:Validator.Quarantine ~known_carriers:[ "US" ] ~suspended_carriers:[] ~supported_equipment:[ "dry_van" ] csv with
  | [ Validator.Accepted _; Validator.Rejected Validator.Duplicate_external_id; Validator.Quarantined Validator.Unknown_carrier ] -> ()
  | _ -> Alcotest.fail "import validator did not preserve row outcomes"

let test_clearing_is_deterministic_and_closed () =
  let load = { Model_builder.id = "load-1"; reserve_cents = 100; equipment = "dry_van" } in
  let bids = [ { Model_builder.id = "bid-b"; load_id = "load-1"; carrier_id = "carrier-b"; amount_cents = 120; service_score_milli = 900; capacity_units = 1 }; { id = "bid-a"; load_id = "load-1"; carrier_id = "carrier-a"; amount_cents = 120; service_score_milli = 900; capacity_units = 1 } ] in
  let policy = { Model_builder.max_service_risk_milli = 200; max_carrier_share_milli = 1_000; reserve_behavior = "hard_reject" } in
  let model = Model_builder.make ~loads:[ load ] ~bids ~policy in
  (match Clearing_service.clear model ~evidence:None with Clearing_service.Infeasible { reasons = [ "SOLVER_EVIDENCE_REQUIRED" ]; _ } -> () | _ -> Alcotest.fail "clearing must fail closed");
  let evidence = Capability_registry.production ~backend:"minizinc" ~version:"2.8.7" ~terminal_status:"OPTIMAL_SOLUTION" ~input_hash:model.input_hash ~output_hash:"output-hash" |> Result.get_ok in
  match Clearing_service.clear model ~evidence:(Some evidence) with
  | Clearing_service.Feasible { awards = [ award ]; _ } -> Alcotest.(check string) "stable tie break" "bid-a" award.bid_id
  | _ -> Alcotest.fail "feasible model did not clear"

let test_ranked_relaxations () =
  match Clearing_service.rank_relaxations ~reasons:[ "NO_FEASIBLE_ASSIGNMENT" ] with
  | first :: second :: _ ->
      Alcotest.(check int) "first relaxation rank" 1 first.rank;
      Alcotest.(check int) "second relaxation rank" 2 second.rank;
      Alcotest.(check bool) "relaxation proposal is non-empty" true (first.proposal <> "")
  | _ -> Alcotest.fail "infeasible clearing did not produce ranked relaxations"

let test_approval_and_privacy () =
  let open Approval_state in
  (match transition ~current:Pending ~next:Approved ~decider:None with Error Missing_decider -> () | _ -> Alcotest.fail "approval needs a decider");
  let report = { Report_renderer.auction_id = "auction-1"; tenant_id = "tenant-a"; awards = [ ("load-1", "carrier-a", 100); ("load-2", "carrier-b", 200) ]; generated_at = "now" } in
  let json = Report_renderer.render_json ~viewer:(Report_renderer.Carrier "carrier-a") report |> Result.get_ok in
  let awards = Yojson.Safe.Util.(json |> member "awards" |> to_list) in
  Alcotest.(check int) "carrier sees only own awards" 1 (List.length awards)

let test_replay_and_notifications () =
  let metrics = Replay_runner.run [ Replay_runner.Lowest_cost; Replay_runner.First_acceptable; Replay_runner.Incumbent_preference; Replay_runner.Historical_awards ] [ (200, 700, 2); (100, 900, 1) ] in
  Alcotest.(check int) "replay metric" 1 (List.hd metrics).assigned;
  Alcotest.(check int) "lowest-cost replay" 100 (List.hd metrics).total_cost_cents;
  Alcotest.(check int) "first acceptable replay" 200 (List.nth metrics 1).total_cost_cents;
  Alcotest.(check int) "incumbent replay" 100 (List.nth metrics 2).total_cost_cents;
  Alcotest.(check int) "historical replay" 100 (List.nth metrics 3).total_cost_cents;
  match Notification_service.decide ~urgency:Notification_service.Critical ~preferences:[ { event_type = "award"; channel = "email"; enabled = false } ] ~event_type:"award" ~channels:[ "email" ] with
  | Notification_service.Deliver [ "in_app" ] -> ()
  | _ -> Alcotest.fail "critical notifications require in-app delivery"

let test_signed_sessions_and_webhooks () =
  let token = Jwt_session.issue ~secret:"local-secret" ~tenant_id:"tenant-a" ~user_id:"user-a" ~role:"tenant_admin" ~ttl_seconds:60 in
  (match Jwt_session.verify ~secret:"local-secret" ~token with Ok claims -> Alcotest.(check string) "jwt tenant claim" "tenant-a" claims.tenant_id | Error _ -> Alcotest.fail "valid jwt rejected");
  Alcotest.(check bool) "wrong jwt secret rejected" false (Result.is_ok (Jwt_session.verify ~secret:"other" ~token));
  let body = "{\"event\":\"bid.updated\"}" in
  let signature = Integration_protocol.webhook_signature ~secret:"receiver-secret" ~body in
  Alcotest.(check bool) "webhook HMAC" true (Integration_protocol.verify_webhook ~secret:"receiver-secret" ~body ~signature);
  Alcotest.(check bool) "webhook tampering" false (Integration_protocol.verify_webhook ~secret:"receiver-secret" ~body:"tampered" ~signature)

let () =
  Alcotest.run "Product domain" [ ("contracts", [ Alcotest.test_case "permissions" `Quick test_permissions; Alcotest.test_case "imports" `Quick test_import_validation; Alcotest.test_case "clearing" `Quick test_clearing_is_deterministic_and_closed; Alcotest.test_case "ranked relaxations" `Quick test_ranked_relaxations; Alcotest.test_case "approval and privacy" `Quick test_approval_and_privacy; Alcotest.test_case "replay and notifications" `Quick test_replay_and_notifications; Alcotest.test_case "signed sessions and webhooks" `Quick test_signed_sessions_and_webhooks ]) ]
