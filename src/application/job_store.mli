type job = { id : string; tenant_id : string; auction_id : string; input : Yojson.Safe.t }

val claim : unit -> (job option, string) result Lwt.t
val mark_infeasible : job -> reason:string -> relaxations:string -> (unit, string) result Lwt.t
val mark_failed : job -> error_code:string -> error_message:string -> (unit, string) result Lwt.t
val cancel : tenant_id:string -> job_id:string -> (unit, string) result Lwt.t
val retry : tenant_id:string -> job_id:string -> (unit, string) result Lwt.t
val mark_succeeded : job -> solver_version:string -> input_hash:string -> output_hash:string -> assignments:(string * string) list -> (unit, string) result Lwt.t
