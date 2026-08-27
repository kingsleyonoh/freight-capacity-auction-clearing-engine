type claims = { tenant_id : string; user_id : string; role : string; expires_at : float }

val issue : secret:string -> tenant_id:string -> user_id:string -> role:string -> ttl_seconds:int -> string
val verify : secret:string -> token:string -> (claims, string) result
