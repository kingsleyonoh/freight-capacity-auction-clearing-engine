(* TEST-ONLY bounded file-spool worker. Not a production job worker. *)

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

let write_or_exit ~directory ~name json =
  match Lifecycle_protocol.atomic_write_json ~directory ~name json with
  | Ok () -> ()
  | Error code ->
      prerr_endline code;
      exit 3

let starts_with ~prefix value =
  String.length value >= String.length prefix
  && String.sub value 0 (String.length prefix) = prefix

let ends_with ~suffix value =
  String.length value >= String.length suffix
  && String.sub value
       (String.length value - String.length suffix)
       (String.length suffix)
     = suffix

let request_id_from_name name =
  let prefix = "command-" and suffix = ".json" in
  if starts_with ~prefix name && ends_with ~suffix name then
    let length =
      String.length name - String.length prefix - String.length suffix
    in
    let request_id = String.sub name (String.length prefix) length in
    if Lifecycle_protocol.valid_request_id request_id then Some request_id
    else None
  else None

let result_for_command ~fixture_path command =
  match Lifecycle_protocol.parse_validate_command command with
  | Error code ->
      ( "invalid",
        Lifecycle_protocol.failure_result_json ~request_id:"invalid" ~code )
  | Ok (request_id, tenant_id) -> (
      match Tenant_fixture.load_file fixture_path with
      | Error _ ->
          ( request_id,
            Lifecycle_protocol.failure_result_json ~request_id
              ~code:"WORKER_FIXTURE_INVALID" )
      | Ok fixture -> (
          match Tenant_fixture.find_tenant fixture tenant_id with
          | None ->
              ( request_id,
                Lifecycle_protocol.failure_result_json ~request_id
                  ~code:"WORKER_TENANT_UNKNOWN" )
          | Some _ ->
              ( request_id,
                Lifecycle_protocol.success_result_json ~request_id ~tenant_id
                  ~tenant_count:(List.length fixture.tenants) )))

let process_file ~fixture_path ~commands ~results name =
  match request_id_from_name name with
  | None -> ()
  | Some name_request_id -> (
      let source = Filename.concat commands name in
      let claimed =
        Filename.concat commands ("processing-" ^ name_request_id ^ ".json")
      in
      try
        Unix.rename source claimed;
        let parsed_request_id, parsed_result =
          match Lifecycle_protocol.read_json_bounded claimed with
          | Error code ->
              ( name_request_id,
                Lifecycle_protocol.failure_result_json
                  ~request_id:name_request_id ~code )
          | Ok command -> result_for_command ~fixture_path command
        in
        let result =
          if parsed_request_id = name_request_id then parsed_result
          else
            Lifecycle_protocol.failure_result_json ~request_id:name_request_id
              ~code:"WORKER_COMMAND_ID_MISMATCH"
        in
        write_or_exit ~directory:results
          ~name:(Lifecycle_protocol.result_name name_request_id)
          result;
        Sys.remove claimed
      with Unix.Unix_error (Unix.ENOENT, _, _) -> ())

let () =
  Random.self_init ();
  let fixture_path = required "--fixture" |> Unix.realpath in
  let control = required "--control" |> Unix.realpath in
  let commands = Filename.concat control "commands" in
  let results = Filename.concat control "results" in
  write_or_exit ~directory:control ~name:"worker-ready.json"
    (Lifecycle_protocol.ready_json ~role:"worker");
  while true do
    Sys.readdir commands |> Array.to_list |> List.sort String.compare
    |> List.iter (process_file ~fixture_path ~commands ~results);
    Unix.sleepf 0.02
  done
