type t

val of_string : string -> (t, string) result
val to_string : t -> string
val is_redacted : string -> bool
