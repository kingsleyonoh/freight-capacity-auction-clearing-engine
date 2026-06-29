module Runtime_config = Freight_capacity_auction_clearing_engine_config.Runtime_config

type service = {
  name : string;
  kind : string;
  endpoint : string;
  required_for_local_dev : bool;
}

type readiness_summary = {
  postgres_url : string;
  redis_url : string;
  duckdb_path : string;
  solver_backend : string;
  solver_binary : string;
  solver_required_for_production : bool;
  services : service list;
}

let services config =
  [
    {
      name = "postgres";
      kind = "postgresql";
      endpoint = config.Runtime_config.database_url;
      required_for_local_dev = true;
    };
    {
      name = "redis";
      kind = "redis";
      endpoint = config.redis_url;
      required_for_local_dev = true;
    };
    {
      name = "duckdb";
      kind = "file";
      endpoint = config.replay_store_path;
      required_for_local_dev = true;
    };
    {
      name = "solver";
      kind = config.solver_backend;
      endpoint =
        (if config.ortools_worker_path <> "" then config.ortools_worker_path
         else config.minizinc_binary_path);
      required_for_local_dev = false;
    };
  ]

let service_names config = services config |> List.map (fun service -> service.name)

let solver_is_optional config =
  (not config.Runtime_config.production_clearing_requires_solver)
  || config.minizinc_binary_path <> "" || config.ortools_worker_path <> ""

let readiness_summary config =
  {
    postgres_url = config.Runtime_config.database_url;
    redis_url = config.redis_url;
    duckdb_path = config.replay_store_path;
    solver_backend = config.solver_backend;
    solver_binary =
      (if config.ortools_worker_path <> "" then config.ortools_worker_path
       else config.minizinc_binary_path);
    solver_required_for_production = config.production_clearing_requires_solver;
    services = services config;
  }
