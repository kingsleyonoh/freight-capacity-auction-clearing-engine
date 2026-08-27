module Schema_name : sig
  type t

  val compare : t -> t -> int
  val is_valid : t -> bool
  val length : t -> int
  val to_string : t -> string
end

type t
type error = [ `Database_operation_failed ]

val sample_generated_names_for_test : int -> Schema_name.t list
val create : unit -> (t, error) result Lwt.t
val schema_name : t -> Schema_name.t

val with_transaction :
  t ->
  ((module Caqti_lwt.CONNECTION) -> ('a, Caqti_error.t) result Lwt.t) ->
  ('a, error) result Lwt.t

val with_rollback :
  t ->
  ((module Caqti_lwt.CONNECTION) -> ('a, Caqti_error.t) result Lwt.t) ->
  ('a, error) result Lwt.t

val schema_exists : Schema_name.t -> (bool, error) result Lwt.t
val close : t -> (unit, error) result Lwt.t
val with_harness : (t -> 'a Lwt.t) -> 'a Lwt.t
