type error

module Schema : sig
  type t

  val of_string : string -> (t, error) result
  val to_string : t -> string
end

type status = {
  applied_count : int;
  pending_count : int;
  current_version : int64 option;
}

val run :
  ?schema:Schema.t ->
  ?lock_timeout_s:float ->
  Migration_catalog.t ->
  (status, error) result Lwt.t

val status :
  ?schema:Schema.t -> Migration_catalog.t -> (status, error) result Lwt.t

val current :
  ?schema:Schema.t -> Migration_catalog.t -> (int64 option, error) result Lwt.t

val error_code : error -> string
val error_message : error -> string
