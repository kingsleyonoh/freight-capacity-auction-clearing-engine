let config_failure errors =
  let reasons =
    List.map
      (fun error -> `String (Solver_backend.config_error_code error))
      errors
  in
  print_endline
    (Yojson.Safe.to_string
       (`Assoc
          [
            ("smoke", `String "failed");
            ("reason", `String "SOLVER_CONFIGURATION_INVALID");
            ("errors", `List reasons);
          ]));
  2

let report_result (report : Solver_backend.selected_report) =
  match report.availability with
  | Solver_backend.Missing "MINIZINC_DEFAULT_NOT_FOUND" ->
      ("skipped", Some "SOLVER_DEFAULT_MINIZINC_NOT_FOUND", 0)
  | Solver_backend.Available _ -> ("passed", None, 0)
  | Solver_backend.Missing reason | Solver_backend.Unhealthy reason ->
      ("failed", Some reason, 1)

let run config =
  let runner = Process_runner.create ~allowed_env:[] in
  let report = Lwt_main.run (Solver_backend.probe_selected runner config) in
  let status, reason, exit_code = report_result report in
  let fields =
    [
      ("smoke", `String status);
      ("backend_report", Solver_backend.selected_report_to_yojson report);
    ]
    @ Option.fold ~none:[]
        ~some:(fun value -> [ ("reason", `String value) ])
        reason
  in
  print_endline (Yojson.Safe.to_string (`Assoc fields));
  exit_code

let () =
  let exit_code =
    match Solver_backend.config_from_lookup ~get:Sys.getenv_opt with
    | Error errors -> config_failure errors
    | Ok config -> run config
  in
  exit exit_code
