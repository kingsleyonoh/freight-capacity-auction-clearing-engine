type source = { filename : string; sql : string }
type entry
type t
type error

val of_sources : source list -> (t, error) result
val production : t
val entries : t -> entry list
val entry_version : entry -> int64
val entry_filename : entry -> string
val entry_sql : entry -> string
val entry_statements : entry -> Caqti_query.t list
val error_code : error -> string
val error_message : error -> string
