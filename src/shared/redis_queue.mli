type t
type error

module Queue : sig
  type t

  val make :
    name:string -> max_depth:int -> max_payload_bytes:int -> (t, error) result
end

module Payload : sig
  type t

  val bytes : bytes -> t
  val json : Yojson.Safe.t -> t
  val bytes_value : t -> bytes option
  val json_value : t -> Yojson.Safe.t option
end

module Owner_token : sig
  type t

  val of_string : string -> (t, error) result
end

module Lock : sig
  type t

  val make :
    tenant_id:Tenant_context.Tenant_id.t -> resource:string -> (t, error) result
end

module Progress_stream : sig
  type t

  val make :
    tenant_id:Tenant_context.Tenant_id.t ->
    job_id:string ->
    max_length:int ->
    (t, error) result
end

module Progress : sig
  type t

  val make :
    state:string -> ?completed:int -> ?total:int -> unit -> (t, error) result

  val state : t -> string
  val completed : t -> int option
  val total : t -> int option
end

val start : timeout_s:float -> Uri.t -> (t, error) result Lwt.t
val get : unit -> (t, error) result
val enqueue : t -> Queue.t -> Payload.t -> (unit, error) result Lwt.t
val dequeue : t -> Queue.t -> (Payload.t option, error) result Lwt.t

val acquire :
  t -> Lock.t -> owner:Owner_token.t -> ttl_ms:int -> (bool, error) result Lwt.t

val renew :
  t ->
  Lock.t ->
  owner:Owner_token.t ->
  ttl_ms:int ->
  ([ `Renewed | `Not_owner ], error) result Lwt.t

val release :
  t ->
  Lock.t ->
  owner:Owner_token.t ->
  ([ `Released | `Not_owner ], error) result Lwt.t

val append_progress :
  t -> Progress_stream.t -> Progress.t -> (string, error) result Lwt.t

val read_progress :
  t ->
  Progress_stream.t ->
  after:string option ->
  limit:int ->
  ((string * Progress.t) list, error) result Lwt.t

val shutdown : unit -> unit Lwt.t
val error_code : error -> Errors.Code.t
val error_message : error -> string
