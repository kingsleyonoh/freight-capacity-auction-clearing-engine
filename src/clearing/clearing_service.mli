type award = { load_id : string; bid_id : string; carrier_id : string; amount_cents : int; total_score : int }
type rejection = { bid_id : string; reason : string }
type relaxation = { rank : int; constraint_name : string; proposal : string; expected_tradeoff : string }
type outcome = Feasible of { awards : award list; rejections : rejection list; objective : int; evidence : Capability_registry.capability } | Infeasible of { unassigned_loads : string list; reasons : string list; relaxations : relaxation list }

val rank_relaxations : reasons:string list -> relaxation list
val clear : Model_builder.t -> evidence:Capability_registry.capability option -> outcome
