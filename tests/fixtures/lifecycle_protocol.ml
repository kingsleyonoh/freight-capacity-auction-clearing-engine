let protocol_version = 1
let max_json_bytes = 16 * 1024

let valid_request_id value =
  value <> ""
  && String.length value <= 64
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> true | _ -> false)
       value

let valid_file_name value =
  value <> "" && value <> "." && value <> ".."
  && String.length value <= 96
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' -> true
         | _ -> false)
       value

let ensure_private_directory path =
  try
    if Sys.file_exists path then
      let stat = Unix.lstat path in
      if stat.st_kind <> Unix.S_DIR || stat.st_kind = Unix.S_LNK then
        Error "CONTROL_DIRECTORY_INVALID"
      else (
        Unix.chmod path 0o700;
        Ok ())
    else (
      Unix.mkdir path 0o700;
      Ok ())
  with _ -> Error "CONTROL_DIRECTORY_INVALID"

let write_all descriptor value =
  let bytes = Bytes.of_string value in
  let rec loop offset =
    if offset < Bytes.length bytes then
      let count =
        Unix.write descriptor bytes offset (Bytes.length bytes - offset)
      in
      if count = 0 then raise End_of_file else loop (offset + count)
  in
  loop 0

let atomic_write_json ~directory ~name json =
  if not (valid_file_name name) then Error "CONTROL_FILE_NAME_INVALID"
  else
    let value = Yojson.Safe.to_string json in
    if String.length value > max_json_bytes then Error "CONTROL_JSON_TOO_LARGE"
    else
      let temporary =
        Filename.concat directory
          (Printf.sprintf ".%s-%d-%06x.tmp" name (Unix.getpid ())
             (Random.bits ()))
      in
      let destination = Filename.concat directory name in
      try
        let descriptor =
          Unix.openfile temporary
            [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ]
            0o600
        in
        Fun.protect
          ~finally:(fun () -> try Unix.close descriptor with _ -> ())
          (fun () ->
            write_all descriptor value;
            Unix.fsync descriptor);
        Unix.rename temporary destination;
        Ok ()
      with _ ->
        (try Sys.remove temporary with _ -> ());
        Error "CONTROL_WRITE_FAILED"

let read_json_bounded path =
  try
    let stat = Unix.lstat path in
    if stat.st_kind <> Unix.S_REG || stat.st_size > max_json_bytes then
      Error "CONTROL_JSON_INVALID"
    else Ok (Yojson.Safe.from_file path)
  with _ -> Error "CONTROL_JSON_INVALID"

let ready_json ~role =
  `Assoc
    [
      ("protocolVersion", `Int protocol_version);
      ("event", `String "ready");
      ("role", `String role);
    ]

let error_json ~role ~code =
  `Assoc
    [
      ("protocolVersion", `Int protocol_version);
      ("event", `String "error");
      ("role", `String role);
      ("code", `String code);
    ]

let command_json ~request_id ~tenant_id =
  `Assoc
    [
      ("protocolVersion", `Int protocol_version);
      ("command", `String "validate_fixture");
      ("requestId", `String request_id);
      ("tenantId", `String tenant_id);
    ]

let parse_validate_command = function
  | `Assoc fields -> (
      match
        ( List.assoc_opt "protocolVersion" fields,
          List.assoc_opt "command" fields,
          List.assoc_opt "requestId" fields,
          List.assoc_opt "tenantId" fields )
      with
      | ( Some (`Int 1),
          Some (`String "validate_fixture"),
          Some (`String request_id),
          Some (`String tenant_id) )
        when List.length fields = 4 && valid_request_id request_id ->
          Ok (request_id, tenant_id)
      | Some (`Int version), _, _, _ when version <> protocol_version ->
          Error "WORKER_PROTOCOL_VERSION_UNSUPPORTED"
      | _ -> Error "WORKER_COMMAND_INVALID")
  | _ -> Error "WORKER_COMMAND_INVALID"

let success_result_json ~request_id ~tenant_id ~tenant_count =
  `Assoc
    [
      ("protocolVersion", `Int protocol_version);
      ("requestId", `String request_id);
      ("status", `String "validated");
      ("validated_tenant_id", `String tenant_id);
      ("tenant_count", `Int tenant_count);
      ("overlap_validated", `Bool true);
    ]

let failure_result_json ~request_id ~code =
  `Assoc
    [
      ("protocolVersion", `Int protocol_version);
      ("requestId", `String request_id);
      ("status", `String "error");
      ("code", `String code);
    ]

let result_name request_id = "result-" ^ request_id ^ ".json"
let command_name request_id = "command-" ^ request_id ^ ".json"
