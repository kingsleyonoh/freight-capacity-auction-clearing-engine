(* TEST-ONLY lifecycle supervisor. It manages only the compiled fixture server
   and fixture worker through Process_runner. *)

open Lwt.Infix

exception Lifecycle_error of string

type child = {
  task : (Process_runner.output, Process_runner.error) result Lwt.t;
  cancel : unit Lwt.t;
  wake : unit Lwt.u;
}

let value_after name =
  let rec loop index =
    if index + 1 >= Array.length Sys.argv then None
    else if Sys.argv.(index) = name then Some Sys.argv.(index + 1)
    else loop (index + 1)
  in
  loop 1

let required name =
  match value_after name with
  | Some value -> value
  | None -> raise (Lifecycle_error "SUPERVISOR_ARGUMENT_REQUIRED")

let bounded_port value =
  match int_of_string_opt value with
  | Some port when port >= 1024 && port <= 65535 -> port
  | _ -> raise (Lifecycle_error "SUPERVISOR_PORT_INVALID")

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun child -> remove_tree (Filename.concat path child));
      Unix.rmdir path)
    else Sys.remove path

let create_control root =
  if Sys.file_exists root then raise (Lifecycle_error "CONTROL_ALREADY_EXISTS");
  match Lifecycle_protocol.ensure_private_directory root with
  | Error code -> raise (Lifecycle_error code)
  | Ok () ->
      List.iter
        (fun name ->
          match
            Lifecycle_protocol.ensure_private_directory
              (Filename.concat root name)
          with
          | Ok () -> ()
          | Error code -> raise (Lifecycle_error code))
        [ "commands"; "results" ]

let child_request ~executable argv =
  Process_runner.request ~executable ~argv ~env:[] ~stdin:"" ~stdin_limit:0
    ~stdout_limit:(64 * 1024) ~stderr_limit:(64 * 1024) ~timeout:3600.
    ~term_grace:0.2 ()

let ready_file path expected_role =
  match Lifecycle_protocol.read_json_bounded path with
  | Ok (`Assoc fields) ->
      List.assoc_opt "protocolVersion" fields = Some (`Int 1)
      && List.assoc_opt "event" fields = Some (`String "ready")
      && List.assoc_opt "role" fields = Some (`String expected_role)
  | Ok _ | Error _ -> false

let child_still_running task =
  match Lwt.state task with
  | Lwt.Sleep -> true
  | Lwt.Return _ | Lwt.Fail _ -> false

let http_ready port =
  let uri =
    Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/__test/ready" port)
  in
  Lwt.catch
    (fun () ->
      Cohttp_lwt_unix.Client.get uri >>= fun (response, body) ->
      Cohttp_lwt.Body.drain_body body >|= fun () ->
      Cohttp.Response.status response = `OK)
    (fun _ -> Lwt.return_false)

let wait_ready ~control ~port ~server_task ~worker_task =
  let deadline = Unix.gettimeofday () +. 10.0 in
  let server_ready = Filename.concat control "server-ready.json" in
  let worker_ready = Filename.concat control "worker-ready.json" in
  let server_error = Filename.concat control "server-error.json" in
  let worker_error = Filename.concat control "worker-error.json" in
  let rec loop () =
    if Sys.file_exists server_error || Sys.file_exists worker_error then
      Lwt.fail (Lifecycle_error "CHILD_REPORTED_ERROR")
    else if
      not (child_still_running server_task && child_still_running worker_task)
    then Lwt.fail (Lifecycle_error "CHILD_EXITED_BEFORE_READY")
    else if
      Sys.file_exists server_ready
      && ready_file server_ready "server"
      && Sys.file_exists worker_ready
      && ready_file worker_ready "worker"
    then
      http_ready port >>= fun ready ->
      if ready then Lwt.return_unit
      else if Unix.gettimeofday () >= deadline then
        Lwt.fail (Lifecycle_error "HTTP_READY_TIMEOUT")
      else Lwt_unix.sleep 0.05 >>= loop
    else if Unix.gettimeofday () >= deadline then
      Lwt.fail (Lifecycle_error "CHILD_READY_TIMEOUT")
    else Lwt_unix.sleep 0.05 >>= loop
  in
  loop ()

let emit event fields =
  `Assoc (("protocolVersion", `Int 1) :: ("event", `String event) :: fields)
  |> Yojson.Safe.to_string |> print_endline;
  flush stdout

let parse_stop line =
  if String.length line > 4096 then Error "STOP_COMMAND_TOO_LARGE"
  else
    try
      match Yojson.Safe.from_string line with
      | `Assoc fields
        when List.length fields = 2
             && List.assoc_opt "protocolVersion" fields = Some (`Int 1)
             && List.assoc_opt "command" fields = Some (`String "stop") ->
          Ok ()
      | _ -> Error "STOP_COMMAND_INVALID"
    with _ -> Error "STOP_COMMAND_INVALID"

let cancelled = function
  | Error Process_runner.Cancelled -> true
  | Ok _ | Error _ -> false

let launch_child runner executable argv =
  let cancel, wake = Lwt.wait () in
  let task =
    Process_runner.run ~cancel runner (child_request ~executable argv)
  in
  { task; cancel; wake }

let cancel_children server worker =
  if Lwt.is_sleeping server.cancel then Lwt.wakeup_later server.wake ();
  if Lwt.is_sleeping worker.cancel then Lwt.wakeup_later worker.wake ();
  Lwt.both server.task worker.task >|= fun (server_result, worker_result) ->
  if not (cancelled server_result && cancelled worker_result) then
    raise (Lifecycle_error "CHILD_CANCEL_REAP_FAILED")

let supervise ~control ~port server worker =
  let cleanup_children () =
    if child_still_running server.task || child_still_running worker.task then
      Lwt.catch
        (fun () -> cancel_children server worker)
        (fun _ -> Lwt.return_unit)
    else Lwt.return_unit
  in
  Lwt.finalize
    (fun () ->
      wait_ready ~control ~port ~server_task:server.task
        ~worker_task:worker.task
      >>= fun () ->
      emit "ready" [ ("port", `Int port) ];
      Lwt_io.read_line_opt Lwt_io.stdin >>= function
      | None -> Lwt.fail (Lifecycle_error "STOP_COMMAND_REQUIRED")
      | Some line -> (
          match parse_stop line with
          | Error code -> Lwt.fail (Lifecycle_error code)
          | Ok () ->
              cancel_children server worker >>= fun () ->
              remove_tree control;
              emit "stopped" [];
              Lwt.return_unit))
    (fun () ->
      cleanup_children () >|= fun () ->
      if Sys.file_exists control then try remove_tree control with _ -> ())

let run () =
  let server_path = required "--server" |> Unix.realpath in
  let worker_path = required "--worker" |> Unix.realpath in
  let fixture = required "--fixture" |> Unix.realpath in
  let control = required "--control" in
  let port = required "--port" |> bounded_port in
  if Filename.is_relative control then
    raise (Lifecycle_error "CONTROL_PATH_MUST_BE_ABSOLUTE");
  create_control control;
  let runner = Process_runner.create ~allowed_env:[] in
  let server =
    launch_child runner server_path
      [
        "--fixture";
        fixture;
        "--control";
        control;
        "--interface";
        "127.0.0.1";
        "--port";
        string_of_int port;
      ]
  in
  let worker =
    launch_child runner worker_path
      [ "--fixture"; fixture; "--control"; control ]
  in
  supervise ~control ~port server worker

let () =
  try Lwt_main.run (run ())
  with Lifecycle_error code ->
    emit "error" [ ("code", `String code) ];
    exit 4
