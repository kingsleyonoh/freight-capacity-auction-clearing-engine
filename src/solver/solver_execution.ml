open Lwt.Infix

type result = { terminal_status : string; stdout : string; stderr : string; input_hash : string; output_hash : string }

let read_file path =
  try
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> really_input_string channel (in_channel_length channel))
  with Sys_error _ -> ""

let run runner ~executable ~model_path ~data_path ~timeout =
  let input = read_file model_path ^ "\n" ^ read_file data_path in
  let request = Process_runner.request ~executable ~argv:[ model_path; data_path ] ~env:[] ~stdin:"" ~stdin_limit:0 ~stdout_limit:1_048_576 ~stderr_limit:65_536 ~timeout ~term_grace:0.2 () in
  Process_runner.run runner request >|= function
  | Error error -> Error (Process_runner.error_code error)
  | Ok output ->
      (match Solver_backend.parse_minizinc_stream output.stdout with
       | Error _ -> Error "SOLVER_OUTPUT_INVALID"
       | Ok status -> Ok { terminal_status = Solver_backend.terminal_status_name status; stdout = output.stdout; stderr = output.stderr; input_hash = Digestif.SHA256.digest_string input |> Digestif.SHA256.to_hex; output_hash = Digestif.SHA256.digest_string output.stdout |> Digestif.SHA256.to_hex })
