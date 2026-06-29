module Runtime_config = Freight_capacity_auction_clearing_engine_config.Runtime_config

let () =
  let config = Runtime_config.load () in
  Printf.printf "migration runner bootstrap ready: database=%s auto_run=%b\n%!."
    config.database_url config.migrations_auto_run
