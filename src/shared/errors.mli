module Code : sig
  type t
  type validation_error = Invalid_format

  val of_string : string -> (t, validation_error) result
  val to_string : t -> string
end

type validation_error =
  | Empty_message
  | Empty_detail_message
  | Empty_detail_field

type detail
type t

val detail :
  ?field:string ->
  code:Code.t ->
  message:string ->
  unit ->
  (detail, validation_error) result

val make :
  code:Code.t ->
  message:string ->
  ?details:detail list ->
  unit ->
  (t, validation_error) result

val code : t -> Code.t
val message : t -> string
val details : t -> detail list
val to_yojson : t -> Yojson.Safe.t
