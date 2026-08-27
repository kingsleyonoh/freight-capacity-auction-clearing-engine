type capability = { backend : string; version : string; terminal_status : string; input_hash : string; output_hash : string }

type clearing_path = Registered | Explicitly_excluded of string

val register_single_round_spot_reserve_price_enforcement : unit -> clearing_path
val register_single_round_spot_reliability_weighting : unit -> clearing_path
val register_single_round_spot_sealed_bid_privacy : unit -> clearing_path
val register_single_round_spot_manual_approval_gate : unit -> clearing_path
val exclude_single_round_spot_multi_load_bundle_awards : unit -> clearing_path
val exclude_single_round_spot_intraday_reclear : unit -> clearing_path
val production_mode : string -> (unit, string) result
val single_round_spot_capabilities : unit -> (string * clearing_path) list

val production : backend:string -> version:string -> terminal_status:string -> input_hash:string -> output_hash:string -> (capability, string) result
val to_yojson : capability -> Yojson.Safe.t
