open Alcotest

module Runtime_config = Freight_capacity_auction_clearing_engine_config.Runtime_config
module Infra = Freight_capacity_auction_clearing_engine.Shared.Service_infrastructure

let read path =
  let channel = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let contains haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index =
    index + needle_len <= haystack_len
    && (String.sub haystack index needle_len = needle || loop (index + 1))
  in
  needle_len = 0 || loop 0

let compose_declares_local_postgres_redis_and_replay_volume () =
  let compose = read "docker-compose.yml" in
  check bool "postgres 16 declared" true (contains compose "postgres:16-alpine");
  check bool "redis 7 declared" true (contains compose "redis:7-alpine");
  check bool "postgres dev port declared" true (contains compose "15439:5432");
  check bool "redis dev port declared" true (contains compose "16439:6379");
  check bool "replay data bind path declared" true (contains compose "./data")

let env_example_uses_safe_placeholders_only () =
  let env_file = read ".env.example" in
  check bool "no legacy xxxxx placeholders" false (contains env_file "xxxxx");
  check bool "database url is parameterized" true
    (contains env_file "DATABASE_URL=postgresql://freight_app:${POSTGRES_PASSWORD}@localhost:15439/freight_auction");
  check bool "optional hub key is empty" true (contains env_file "NOTIFICATION_HUB_API_KEY=");
  check bool "secret base points to local env" true (contains env_file "SECRET_KEY_BASE=change-me-in-local-env")

let replay_store_directory_exists () =
  check bool "data/replay directory exists" true (Sys.file_exists "data/replay/.gitkeep")

let infrastructure_summary_matches_runtime_config () =
  let config = Runtime_config.load ~getenv:(fun _ -> None) () in
  let summary = Infra.readiness_summary config in
  check string "postgres url" config.database_url summary.postgres_url;
  check string "redis url" config.redis_url summary.redis_url;
  check string "duckdb path" config.replay_store_path summary.duckdb_path

let shared_architecture_docs_cover_all_required_helpers () =
  let index = read ".agent/knowledge/foundation/_index.md" in
  let foundation = read ".agent/knowledge/foundation/shared-architecture-contracts.md" in
  check bool "foundation index links shared architecture contracts" true
    (contains index "shared-architecture-contracts.md");
  List.iter
    (fun helper ->
      check bool (helper ^ " documented") true (contains foundation helper))
    [
      "DB pool";
      "Redis queue";
      "HTTP client";
      "event outbox";
      "tenant context";
      "solver adapter";
      "error response";
      "cached helper";
    ];
  check bool "protected rule file not used as new docs target" false
    (contains foundation ".agent/rules/CODEBASE_CONTEXT.md")

let () =
  run "integration bootstrap"
    [
      ( "docker compose",
        [ test_case "declares local services" `Quick compose_declares_local_postgres_redis_and_replay_volume ] );
      ( "environment",
        [ test_case "uses safe placeholders" `Quick env_example_uses_safe_placeholders_only ] );
      ( "replay store",
        [ test_case "has durable directory" `Quick replay_store_directory_exists ] );
      ( "runtime infrastructure",
        [ test_case "matches config" `Quick infrastructure_summary_matches_runtime_config ] );
      ( "shared architecture docs",
        [ test_case "cover required helper contracts" `Quick shared_architecture_docs_cover_all_required_helpers ] );
    ]
