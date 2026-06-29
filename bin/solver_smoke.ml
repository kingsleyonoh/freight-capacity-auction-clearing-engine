module Runtime_config = Freight_capacity_auction_clearing_engine_config.Runtime_config
module Infra = Freight_capacity_auction_clearing_engine.Shared.Service_infrastructure

let () =
  let config = Runtime_config.load () in
  let summary = Infra.readiness_summary config in
  Printf.printf "solver smoke bootstrap ready: backend=%s binary=%s production_required=%b\n%!."
    summary.solver_backend summary.solver_binary summary.solver_required_for_production
