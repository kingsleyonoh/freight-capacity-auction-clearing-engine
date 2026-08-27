type award = { load_id : string; bid_id : string; carrier_id : string; amount_cents : int; total_score : int }
type rejection = { bid_id : string; reason : string }
type relaxation = { rank : int; constraint_name : string; proposal : string; expected_tradeoff : string }
type outcome = Feasible of { awards : award list; rejections : rejection list; objective : int; evidence : Capability_registry.capability } | Infeasible of { unassigned_loads : string list; reasons : string list; relaxations : relaxation list }

let rank_relaxations ~reasons =
  let proposals =
    [ ("SERVICE_RISK", "increase_service_risk_cap", "Allow a small reliability concession while retaining an explicit service floor.");
      ("CARRIER_SHARE", "increase_max_carrier_share", "Allow additional concentration for this auction while retaining an auditable cap.");
      ("BELOW_RESERVE", "allow_with_reason", "Permit a below-reserve award only after an explicit operator approval.");
      ("NO_FEASIBLE_ASSIGNMENT", "review_constraint_order", "Compare the declared relaxation order against the captured infeasible set.") ]
  in
  proposals
  |> List.filter (fun (reason, _, _) -> List.mem reason reasons || List.mem "NO_FEASIBLE_ASSIGNMENT" reasons)
  |> List.mapi (fun index (_, constraint_name, expected_tradeoff) -> { rank = index + 1; constraint_name; proposal = constraint_name; expected_tradeoff })

let bids_for_load (bids : Model_builder.bid list) load_id = List.filter (fun bid -> bid.Model_builder.load_id = load_id) bids

let carrier_units carrier counts = Option.value ~default:0 (List.assoc_opt carrier counts)

let increment_carrier carrier units counts =
  let existing = carrier_units carrier counts in
  (carrier, existing + units) :: List.remove_assoc carrier counts

let clear (model : Model_builder.t) ~evidence =
  match evidence with
  | None -> Infeasible { unassigned_loads = List.map (fun (load : Model_builder.load) -> load.Model_builder.id) model.loads; reasons = [ "SOLVER_EVIDENCE_REQUIRED" ]; relaxations = [] }
  | Some evidence ->
      let max_carrier_units = max 1 ((List.length model.loads * model.policy.max_carrier_share_milli + 999) / 1_000) in
      let awards, rejections, unassigned, _carrier_counts =
        List.fold_left
          (fun (awards, rejections, unassigned, carrier_counts) (load : Model_builder.load) ->
            let candidates = bids_for_load model.bids load.Model_builder.id |> List.sort Scoring.compare_bid in
            let eligible (bid : Model_builder.bid) =
              bid.amount_cents >= load.Model_builder.reserve_cents
              && bid.service_score_milli >= (1_000 - model.policy.max_service_risk_milli)
              && carrier_units bid.carrier_id carrier_counts + bid.capacity_units <= max_carrier_units
            in
            match List.find_opt eligible candidates with
            | Some bid ->
                ({ load_id = load.id; bid_id = bid.id; carrier_id = bid.carrier_id; amount_cents = bid.amount_cents; total_score = Scoring.total_score ~amount_cents:bid.amount_cents ~service_score_milli:bid.service_score_milli } :: awards,
                 rejections @ List.map (fun (other : Model_builder.bid) -> { bid_id = other.id; reason = if other.amount_cents < load.Model_builder.reserve_cents then "BELOW_RESERVE" else if other.service_score_milli < (1_000 - model.policy.max_service_risk_milli) then "SERVICE_RISK" else if carrier_units other.carrier_id carrier_counts + other.capacity_units > max_carrier_units then "CARRIER_SHARE" else "NOT_SELECTED" }) (List.filter (fun (other : Model_builder.bid) -> other.id <> bid.id) candidates), unassigned, increment_carrier bid.carrier_id bid.capacity_units carrier_counts)
            | None ->
                (awards, rejections @ List.map (fun (bid : Model_builder.bid) -> { bid_id = bid.id; reason = if bid.amount_cents < load.Model_builder.reserve_cents then "BELOW_RESERVE" else if bid.service_score_milli < (1_000 - model.policy.max_service_risk_milli) then "SERVICE_RISK" else if carrier_units bid.carrier_id carrier_counts + bid.capacity_units > max_carrier_units then "CARRIER_SHARE" else "NO_FEASIBLE_ASSIGNMENT" }) candidates, load.Model_builder.id :: unassigned, carrier_counts))
          ([], [], [], []) model.loads
      in
      if unassigned <> [] then
        let reasons = [ "NO_FEASIBLE_ASSIGNMENT" ] in
        Infeasible { unassigned_loads = List.rev unassigned; reasons; relaxations = rank_relaxations ~reasons }
      else
        let awards = List.rev awards in
        Feasible { awards; rejections; objective = List.fold_left (fun total award -> total + award.total_score) 0 awards; evidence }
