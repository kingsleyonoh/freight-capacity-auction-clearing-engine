module Runtime_config = Freight_capacity_auction_clearing_engine_config.Runtime_config

let () =
  let config = Runtime_config.load () in
  Printf.printf "worker bootstrap ready: redis=%s replay_store=%s\n%!." config.redis_url
    config.replay_store_path
