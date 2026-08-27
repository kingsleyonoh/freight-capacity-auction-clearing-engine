type load = { id : string; reserve_cents : int; equipment : string }
type bid = { id : string; load_id : string; carrier_id : string; amount_cents : int; service_score_milli : int; capacity_units : int }
type policy = { max_service_risk_milli : int; max_carrier_share_milli : int; reserve_behavior : string }
type t = { loads : load list; bids : bid list; policy : policy; canonical_input : string; input_hash : string }

let canonical_load (load : load) = Printf.sprintf "%s|%d|%s" load.id load.reserve_cents load.equipment
let canonical_bid (bid : bid) = Printf.sprintf "%s|%s|%s|%d|%d|%d" bid.id bid.load_id bid.carrier_id bid.amount_cents bid.service_score_milli bid.capacity_units
let canonical_policy (policy : policy) = Printf.sprintf "%d|%d|%s" policy.max_service_risk_milli policy.max_carrier_share_milli policy.reserve_behavior

let make ~(loads : load list) ~(bids : bid list) ~(policy : policy) =
  let loads = List.sort (fun (left : load) (right : load) -> String.compare left.id right.id) loads in
  let bids = List.sort (fun (left : bid) (right : bid) -> String.compare left.id right.id) bids in
  let canonical_input =
    String.concat "\n"
      [ "policy:" ^ canonical_policy policy;
        "loads:" ^ String.concat ";" (List.map canonical_load loads);
        "bids:" ^ String.concat ";" (List.map canonical_bid bids) ]
  in
  let input_hash = Digestif.SHA256.digest_string canonical_input |> Digestif.SHA256.to_hex in
  { loads; bids; policy; canonical_input; input_hash }
