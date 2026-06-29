module Runtime_config = Freight_capacity_auction_clearing_engine_config.Runtime_config

let () =
  let config = Runtime_config.load () in
  Printf.printf "replay bench bootstrap ready: duckdb=%s max_rows=%d\n%!."
    config.replay_store_path config.replay_max_rows
