(* TEST-ONLY loopback Dream server. It is never linked from production bins. *)

open Lwt.Infix

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
  | None ->
      prerr_endline ("missing argument " ^ name);
      exit 2

let bounded_port value =
  match int_of_string_opt value with
  | Some port when port >= 1024 && port <= 65535 -> port
  | _ ->
      prerr_endline "invalid loopback port";
      exit 2

let write_ready control name json =
  match Lifecycle_protocol.atomic_write_json ~directory:control ~name json with
  | Ok () -> ()
  | Error code ->
      prerr_endline code;
      exit 3

let counter = Atomic.make 0

let request_id () =
  Printf.sprintf "%d-%d-%06x" (Unix.getpid ())
    (Atomic.fetch_and_add counter 1)
    (Random.bits ())

let result_error fields =
  match List.assoc_opt "code" fields with
  | Some (`String code) -> code
  | _ -> "WORKER_RESULT_INVALID"

let parse_result expected = function
  | `Assoc fields -> (
      match
        ( List.assoc_opt "protocolVersion" fields,
          List.assoc_opt "requestId" fields,
          List.assoc_opt "status" fields )
      with
      | Some (`Int 1), Some (`String request_id), Some (`String "validated")
        when request_id = expected ->
          Ok (`Assoc fields)
      | Some (`Int 1), Some (`String request_id), Some (`String "error")
        when request_id = expected ->
          Error (result_error fields)
      | _ -> Error "WORKER_RESULT_INVALID")
  | _ -> Error "WORKER_RESULT_INVALID"

let worker_check ~control tenant_id =
  let commands = Filename.concat control "commands" in
  let results = Filename.concat control "results" in
  let request_id = request_id () in
  match
    Lifecycle_protocol.atomic_write_json ~directory:commands
      ~name:(Lifecycle_protocol.command_name request_id)
      (Lifecycle_protocol.command_json ~request_id ~tenant_id)
  with
  | Error _ -> Lwt.return (Error "WORKER_COMMAND_WRITE_FAILED")
  | Ok () ->
      let result_path =
        Filename.concat results (Lifecycle_protocol.result_name request_id)
      in
      let deadline = Unix.gettimeofday () +. 2.0 in
      let rec wait () =
        if Sys.file_exists result_path then (
          let parsed = Lifecycle_protocol.read_json_bounded result_path in
          (try Sys.remove result_path with _ -> ());
          Lwt.return
            (match parsed with
            | Ok json -> parse_result request_id json
            | Error _ -> Error "WORKER_RESULT_INVALID"))
        else if Unix.gettimeofday () >= deadline then
          Lwt.return (Error "WORKER_VALIDATION_TIMEOUT")
        else Lwt_unix.sleep 0.02 >>= wait
      in
      wait ()

let () =
  Random.self_init ();
  let fixture_path = required "--fixture" |> Unix.realpath in
  let control = required "--control" |> Unix.realpath in
  let interface = required "--interface" in
  if interface <> "127.0.0.1" then (
    write_ready control "server-error.json"
      (Lifecycle_protocol.error_json ~role:"server"
         ~code:"SERVER_LOOPBACK_REQUIRED");
    exit 2);
  let port = required "--port" |> bounded_port in
  match Tenant_fixture.load_file fixture_path with
  | Error _ ->
      write_ready control "server-error.json"
        (Lifecycle_protocol.error_json ~role:"server"
           ~code:"SERVER_FIXTURE_INVALID");
      exit 3
  | Ok fixture ->
      write_ready control "server-ready.json"
        (Lifecycle_protocol.ready_json ~role:"server");
      Dream.run ~interface ~port ~greeting:false ~adjust_terminal:false
        (Dream_tenant_probe_app.build ~fixture
           ~worker_check:(worker_check ~control))
