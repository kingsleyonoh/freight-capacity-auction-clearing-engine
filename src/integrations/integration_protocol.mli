type adapter = Notification_hub | Workflow_engine | Webhook_engine
type environment = Sandbox | Production
type request = { adapter : adapter; environment : environment; idempotency_key : string; event_type : string; payload : Yojson.Safe.t }
type response = Accepted of string | Disabled | Retry of string | Rejected of string

val adapter_to_string : adapter -> string
val request_valid : request -> bool
val webhook_signature : secret:string -> body:string -> string
val verify_webhook : secret:string -> body:string -> signature:string -> bool
