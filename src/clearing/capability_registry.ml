type capability = { backend : string; version : string; terminal_status : string; input_hash : string; output_hash : string }

type clearing_path = Registered | Explicitly_excluded of string

let register_single_round_spot_reserve_price_enforcement () = Registered

let register_single_round_spot_reliability_weighting () = Registered

let register_single_round_spot_sealed_bid_privacy () = Registered

let register_single_round_spot_manual_approval_gate () = Registered

let exclude_single_round_spot_multi_load_bundle_awards () =
  Explicitly_excluded "single-round mode has no bundled-lane schema"

let exclude_single_round_spot_intraday_reclear () =
  Explicitly_excluded "single-round mode has one award window"

let production_mode mode =
  if mode = "single_round_spot" then Ok ()
  else Error "AUCTION_MODE_UNSUPPORTED"

let single_round_spot_capabilities () =
  [ ("reserve_price_enforcement", register_single_round_spot_reserve_price_enforcement ());
    ("reliability_weighting", register_single_round_spot_reliability_weighting ());
    ("manual_approval_gate", register_single_round_spot_manual_approval_gate ());
    ("sealed_bid_privacy", register_single_round_spot_sealed_bid_privacy ());
    ("multi_load_bundle_awards", exclude_single_round_spot_multi_load_bundle_awards ());
    ("intraday_reclear", exclude_single_round_spot_intraday_reclear ()) ]

let safe value = value <> "" && String.length value <= 128 && String.for_all (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true | _ -> false) value

let production ~backend ~version ~terminal_status ~input_hash ~output_hash =
  if not (List.for_all safe [ backend; version; terminal_status; input_hash; output_hash ]) then Error "SOLVER_EVIDENCE_INVALID"
  else if terminal_status <> "OPTIMAL_SOLUTION" && terminal_status <> "SATISFIED" then Error "SOLVER_NOT_TERMINAL_SUCCESS"
  else Ok { backend; version; terminal_status; input_hash; output_hash }

let to_yojson value =
  `Assoc [ ("backend", `String value.backend); ("version", `String value.version); ("terminal_status", `String value.terminal_status); ("input_hash", `String value.input_hash); ("output_hash", `String value.output_hash) ]
