module Runtime_config = Freight_capacity_auction_clearing_engine_config.Runtime_config

let () =
  let config = Runtime_config.load () in
  Printf.printf "setup bootstrap ready: tenant=%s admin=%s seed_sample_data=%b\n%!."
    config.default_tenant_name config.default_admin_email config.seed_sample_data
