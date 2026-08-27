type validation_error =
  | Invalid_event_id
  | Invalid_event_type
  | Invalid_idempotency_key
  | Invalid_target_url_env_var
  | Secret_bearing_field
  | Payload_too_large

type target = Notification_hub | Workflow_engine | Webhook_engine
type event

val event :
  tenant_id:Tenant_context.Tenant_id.t ->
  event_id:string ->
  event_type:string ->
  idempotency_key:string ->
  target:target ->
  target_url_env_var:string ->
  payload:Yojson.Safe.t ->
  (event, validation_error) result

val has_secret_field : Yojson.Safe.t -> bool

val tenant_id : event -> Tenant_context.Tenant_id.t
val event_id : event -> string
val event_type : event -> string
val idempotency_key : event -> string
val target : event -> target
val target_url_env_var : event -> string
val payload : event -> Yojson.Safe.t

module type WRITER = sig
  type transaction
  type error

  val enqueue :
    transaction ->
    event ->
    ([ `Inserted of string | `Existing of string ], error) result Lwt.t
end
