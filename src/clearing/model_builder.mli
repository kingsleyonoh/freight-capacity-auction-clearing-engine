type load = { id : string; reserve_cents : int; equipment : string }
type bid = { id : string; load_id : string; carrier_id : string; amount_cents : int; service_score_milli : int; capacity_units : int }
type policy = { max_service_risk_milli : int; max_carrier_share_milli : int; reserve_behavior : string }
type t = { loads : load list; bids : bid list; policy : policy; canonical_input : string; input_hash : string }

val make : loads:load list -> bids:bid list -> policy:policy -> t
