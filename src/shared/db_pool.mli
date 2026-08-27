type t
type error

val start : ?max_size:int -> Uri.t -> (t, error) result Lwt.t
val get : unit -> (t, error) result

val with_connection :
  (Caqti_lwt.connection -> ('a, Caqti_error.t) result Lwt.t) ->
  ('a, error) result Lwt.t

val shutdown : unit -> unit Lwt.t
val error_code : error -> Errors.Code.t
val error_message : error -> string
