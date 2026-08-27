type validation_error =
  | Empty_message
  | Empty_field of string
  | Negative_duration

type context = {
  tenant_id : string option;
  user_id : string option;
  role : string option;
  request_id : string option;
  job_id : string option;
  entity_id : string option;
}

type event = {
  context : context;
  status : string option;
  duration_ms : int option;
  error_code : Errors.Code.t option;
  message : string;
}

let empty_context =
  { tenant_id = None; user_id = None; role = None; request_id = None;
    job_id = None; entity_id = None }

let is_blank value = String.trim value = ""

let first_empty fields =
  List.find_map
    (fun (name, value) ->
      match value with Some content when is_blank content -> Some name | _ -> None)
    fields

let context ?tenant_id ?user_id ?role ?request_id ?job_id ?entity_id () =
  let fields =
    [ ("tenant_id", tenant_id); ("user_id", user_id); ("role", role);
      ("request_id", request_id); ("job_id", job_id); ("entity_id", entity_id) ]
  in
  match first_empty fields with
  | Some name -> Error (Empty_field name)
  | None -> Ok { tenant_id; user_id; role; request_id; job_id; entity_id }

let event ?(context = empty_context) ?status ?duration_ms ?error_code ~message () =
  if is_blank message then Error Empty_message
  else
    match status, duration_ms with
    | Some value, _ when is_blank value -> Error (Empty_field "status")
    | _, Some value when value < 0 -> Error Negative_duration
    | _ -> Ok { context; status; duration_ms; error_code; message }

let level_name = function
  | Logs.App -> "app"
  | Logs.Error -> "error"
  | Logs.Warning -> "warning"
  | Logs.Info -> "info"
  | Logs.Debug -> "debug"

let optional_string name = function
  | None -> []
  | Some value -> [ (name, `String value) ]

let context_fields context =
  optional_string "tenant_id" context.tenant_id
  @ optional_string "user_id" context.user_id
  @ optional_string "role" context.role
  @ optional_string "request_id" context.request_id
  @ optional_string "job_id" context.job_id
  @ optional_string "entity_id" context.entity_id

let event_fields event =
  context_fields event.context
  @ optional_string "status" event.status
  @ (match event.duration_ms with
     | None -> []
     | Some value -> [ ("duration_ms", `Int value) ])
  @ (match event.error_code with
     | None -> []
     | Some code -> [ ("error_code", `String (Errors.Code.to_string code)) ])

let to_yojson ~now ~source level event =
  let timestamp_ms = int_of_float (now () *. 1000.) in
  `Assoc
    ([ ("timestamp_unix_ms", `Int timestamp_ms);
       ("level", `String (level_name level));
       ("module", `String source);
       ("message", `String event.message) ]
     @ event_fields event)

let reporter_marker = "fca-structured-json-event"
let current_now = ref Unix.gettimeofday

let default_write line =
  output_string stdout line;
  flush stdout

let reporter write =
  let report _source _level ~over continuation messagef =
    messagef @@ fun ?header ?tags:_ format ->
    Format.kasprintf
      (fun message ->
        (match header with
         | Some marker when marker = reporter_marker -> write (message ^ "\n")
         | _ -> ());
        over ();
        continuation ())
      format
  in
  { Logs.report }

let configure ~level ?(now = Unix.gettimeofday) ?(write = default_write) () =
  current_now := now;
  Logs.set_level ~all:true level;
  Logs.set_reporter (reporter write)

let emit ~src level event =
  let json =
    to_yojson ~now:!current_now ~source:(Logs.Src.name src) level event
    |> Yojson.Safe.to_string
  in
  let module Log = (val Logs.src_log src : Logs.LOG) in
  Log.msg level (fun message -> message ~header:reporter_marker "%s" json)
