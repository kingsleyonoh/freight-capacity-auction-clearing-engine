let replace_env name value environment =
  let prefix = name ^ "=" in
  let keep entry = not (String.starts_with ~prefix entry) in
  Array.to_list environment |> List.filter keep
  |> List.cons (prefix ^ value)
  |> Array.of_list

let run_postgres_child scenario =
  let environment =
    Unix.environment ()
    |> replace_env "FCA_INTEGRATION_SUITE" "postgres"
    |> replace_env "FCA_POSTGRES_SCENARIO" scenario
  in
  let executable = Sys.executable_name in
  let pid =
    Unix.create_process_env executable [| executable |] environment Unix.stdin
      Unix.stdout Unix.stderr
  in
  match snd (Unix.waitpid [] pid) with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED code ->
      prerr_endline
        (Printf.sprintf "PostgreSQL %s scenario exited %d" scenario code);
      exit code
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
      prerr_endline
        (Printf.sprintf "PostgreSQL %s scenario stopped by signal %d" scenario
           signal);
      exit 1

let run_postgres () =
  match Sys.getenv_opt "FCA_POSTGRES_SCENARIO" with
  | Some "pool" -> Db_pool_test.run ()
  | Some "schema" -> Sql_schema_test.run ()
  | Some "migrations" -> Migration_runner_test.run ()
  | None -> List.iter run_postgres_child [ "pool"; "schema"; "migrations" ]
  | Some _ ->
      prerr_endline "FCA_POSTGRES_SCENARIO must be pool, schema, or migrations";
      exit 2

let run_redis_child scenario =
  let environment =
    Unix.environment ()
    |> replace_env "FCA_INTEGRATION_SUITE" "redis"
    |> replace_env "FCA_REDIS_SCENARIO" scenario
  in
  let executable = Sys.executable_name in
  let pid =
    Unix.create_process_env executable [| executable |] environment Unix.stdin
      Unix.stdout Unix.stderr
  in
  match snd (Unix.waitpid [] pid) with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED code ->
      prerr_endline (Printf.sprintf "Redis %s scenario exited %d" scenario code);
      exit code
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
      prerr_endline
        (Printf.sprintf "Redis %s scenario stopped by signal %d" scenario signal);
      exit 1

let run_redis () =
  match Sys.getenv_opt "FCA_REDIS_SCENARIO" with
  | Some _ -> Redis_queue_test.run ()
  | None -> List.iter run_redis_child [ "core"; "acl"; "failure"; "drain" ]

let run_suite_child suite =
  let environment =
    Unix.environment () |> replace_env "FCA_INTEGRATION_SUITE" suite
  in
  let executable = Sys.executable_name in
  let pid =
    Unix.create_process_env executable [| executable |] environment Unix.stdin
      Unix.stdout Unix.stderr
  in
  match snd (Unix.waitpid [] pid) with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED code ->
      prerr_endline (Printf.sprintf "%s integration exited %d" suite code);
      exit code
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
      prerr_endline
        (Printf.sprintf "%s integration stopped by signal %d" suite signal);
      exit 1

let run_all () =
  List.iter run_suite_child
    [ "postgres"; "redis"; "http"; "dream"; "e2e-lifecycle" ]

let () =
  match Sys.getenv_opt "FCA_INTEGRATION_SUITE" with
  | Some "postgres" -> run_postgres ()
  | Some "redis" -> run_redis ()
  | Some "http" -> Http_client_test.run ()
  | Some "dream" -> Dream_request_test.run ()
  | Some "e2e-lifecycle" -> E2e_lifecycle_test.run ()
  | None | Some "all" -> run_all ()
  | Some _ ->
      prerr_endline
        "FCA_INTEGRATION_SUITE must be all, postgres, redis, http, dream, or \
         e2e-lifecycle";
      exit 2
