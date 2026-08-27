type worker_check = string -> (Yojson.Safe.t, string) result Lwt.t

val tenant_header : string
val request_field : Tenant_context.t Dream.field

val build :
  fixture:Tenant_fixture.t -> worker_check:worker_check -> Dream.handler
