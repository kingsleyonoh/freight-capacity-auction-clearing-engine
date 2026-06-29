module Runtime_config = Freight_capacity_auction_clearing_engine_config.Runtime_config
module Console = Freight_capacity_auction_clearing_engine.Ui.Operations_console
module Infra = Freight_capacity_auction_clearing_engine.Shared.Service_infrastructure

let json_escape value =
  value |> String.to_seq
  |> Seq.flat_map (function
       | '"' -> List.to_seq [ '\\'; '"' ]
       | '\\' -> List.to_seq [ '\\'; '\\' ]
       | c -> List.to_seq [ c ])
  |> String.of_seq

let health_json config =
  let summary = Infra.readiness_summary config in
  Printf.sprintf
    {|{"status":"ok","app":"freight-capacity-auction-clearing-engine","postgres_url":"%s","redis_url":"%s","duckdb_path":"%s","solver_backend":"%s"}|}
    (json_escape summary.postgres_url) (json_escape summary.redis_url)
    (json_escape summary.duckdb_path) (json_escape summary.solver_backend)

let login_page =
  {|<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>API key login</title></head><body><main><h1>API key login</h1><form method="post" action="/login"><label for="api-key">Tenant API key</label><input id="api-key" name="api_key" autocomplete="off"><button type="submit">Continue</button></form></main></body></html>|}

let routes config =
  Dream.router
    [
      Dream.get "/" (fun _request -> Dream.html (Console.render ()));
      Dream.get "/login" (fun _request -> Dream.html login_page);
      Dream.get "/health" (fun _request -> Dream.json (health_json config));
      Dream.get "/health/ready" (fun _request -> Dream.json (health_json config));
    ]

let () =
  let config = Runtime_config.load () in
  Dream.run ~interface:"0.0.0.0" ~port:config.app_port (routes config)
