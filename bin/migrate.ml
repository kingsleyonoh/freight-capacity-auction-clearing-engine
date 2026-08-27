let print_error code =
  Printf.eprintf "{\"status\":\"error\",\"code\":\"%s\"}\n%!" code

let print_status status =
  let current =
    match status.Migration_runner.current_version with
    | None -> "null"
    | Some version -> Int64.to_string version
  in
  Printf.printf
    "{\"status\":\"current\",\"applied\":%d,\"pending\":%d,\"current_version\":%s}\n\
     %!"
    status.applied_count status.pending_count current

let run config =
  let data = Runtime_config.data config in
  Runtime_config.Secret.with_value data.database_url (fun raw_database_url ->
      let database_uri = Uri.of_string raw_database_url in
      Lwt_main.run
        (let open Lwt.Syntax in
         let* started = Db_pool.start database_uri in
         match started with
         | Error error ->
             print_error (Errors.Code.to_string (Db_pool.error_code error));
             Lwt.return 1
         | Ok _ ->
             Lwt.finalize
               (fun () ->
                 let* migrated =
                   Migration_runner.run Migration_catalog.production
                 in
                 match migrated with
                 | Ok status ->
                     print_status status;
                     Lwt.return 0
                 | Error error ->
                     print_error (Migration_runner.error_code error);
                     Lwt.return 1)
               (fun () -> Db_pool.shutdown ())))

let () =
  let exit_code =
    match Runtime_config.from_process_env () with
    | Error _ ->
        print_error "MIGRATION_CONFIG_INVALID";
        2
    | Ok config -> run config
  in
  exit exit_code
