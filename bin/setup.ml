let print_error code = Printf.eprintf "{\"status\":\"error\",\"code\":\"%s\"}\n%!" code

let () =
  match Runtime_config.from_process_env () with
  | Error _ -> print_error "SETUP_CONFIG_INVALID"; exit 2
  | Ok config ->
      let data = Runtime_config.data config in
      Runtime_config.Secret.with_value data.database_url (fun database_url ->
          match Lwt_main.run (Db_pool.start (Uri.of_string database_url)) with
          | Error _ -> print_error "DATABASE_STARTUP_FAILED"; exit 1
          | Ok _ ->
              let result = Lwt_main.run (Migration_runner.run Migration_catalog.production) in
              (match result with Error error -> print_error (Migration_runner.error_code error); exit 1 | Ok _ -> ());
              let seeded_key =
                if (Runtime_config.tenant config).seed_sample_data then
                  match Lwt_main.run (Store.seed_demo ()) with Error _ -> print_error "SEED_FAILED"; exit 1 | Ok (_, key) -> Some key
                else None
              in
              (match seeded_key with
               | Some key -> Printf.printf "{\"status\":\"ready\",\"service\":\"setup\",\"api_key\":\"%s\"}\n%!" key
               | None -> Printf.printf "{\"status\":\"ready\",\"service\":\"setup\"}\n%!");
              ignore (Lwt_main.run (Db_pool.shutdown ())))
