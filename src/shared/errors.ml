type t = {
  code : string;
  message : string;
  status : int;
  request_id : string option;
  details : (string * string) list;
}

let require_non_blank field value =
  if String.trim value = "" then invalid_arg (field ^ " is required") else value

let require_http_error_status status =
  if status < 400 || status > 599 then invalid_arg "status must be a 4xx or 5xx HTTP status"
  else status

let create ?request_id ?(details = []) ~code ~message ~status () =
  {
    code = require_non_blank "code" code;
    message = require_non_blank "message" message;
    status = require_http_error_status status;
    request_id;
    details;
  }

let detail_json details =
  `Assoc (List.map (fun (key, value) -> (key, `String value)) details)

let to_yojson error =
  let base =
    [
      ("code", `String error.code);
      ("message", `String error.message);
      ("status", `Int error.status);
      ("details", detail_json error.details);
    ]
  in
  let fields =
    match error.request_id with
    | None -> base
    | Some request_id -> ("request_id", `String request_id) :: base
  in
  `Assoc [ ("error", `Assoc fields) ]

let to_json_string error = Yojson.Safe.to_string (to_yojson error)

let bad_request ?request_id ?details message =
  create ?request_id ?details ~code:"BAD_REQUEST" ~message ~status:400 ()

let tenant_scope_violation ?request_id ~resource () =
  create ?request_id ~details:[ ("resource", resource) ]
    ~code:"TENANT_SCOPE_VIOLATION"
    ~message:"Requested resource belongs to another tenant" ~status:403 ()
