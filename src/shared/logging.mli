type validation_error =
  | Empty_message
  | Empty_field of string
  | Negative_duration

type context
type event

val empty_context : context

val context :
  ?tenant_id:string ->
  ?user_id:string ->
  ?role:string ->
  ?request_id:string ->
  ?job_id:string ->
  ?entity_id:string ->
  unit ->
  (context, validation_error) result

val event :
  ?context:context ->
  ?status:string ->
  ?duration_ms:int ->
  ?error_code:Errors.Code.t ->
  message:string ->
  unit ->
  (event, validation_error) result

val to_yojson :
  now:(unit -> float) -> source:string -> Logs.level -> event -> Yojson.Safe.t

val configure :
  level:Logs.level option ->
  ?now:(unit -> float) ->
  ?write:(string -> unit) ->
  unit ->
  unit

val emit : src:Logs.Src.t -> Logs.level -> event -> unit
