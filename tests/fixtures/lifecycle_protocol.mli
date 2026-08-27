val protocol_version : int
val max_json_bytes : int
val valid_request_id : string -> bool
val ensure_private_directory : string -> (unit, string) result

val atomic_write_json :
  directory:string -> name:string -> Yojson.Safe.t -> (unit, string) result

val read_json_bounded : string -> (Yojson.Safe.t, string) result
val ready_json : role:string -> Yojson.Safe.t
val error_json : role:string -> code:string -> Yojson.Safe.t
val command_json : request_id:string -> tenant_id:string -> Yojson.Safe.t
val parse_validate_command : Yojson.Safe.t -> (string * string, string) result

val success_result_json :
  request_id:string -> tenant_id:string -> tenant_count:int -> Yojson.Safe.t

val failure_result_json : request_id:string -> code:string -> Yojson.Safe.t
val result_name : string -> string
val command_name : string -> string
