exception Invalid of string

val load_json : string -> Yojson.Safe.t
val read_text : string -> string
val assoc : Yojson.Safe.t -> (string * Yojson.Safe.t) list
val list : Yojson.Safe.t -> Yojson.Safe.t list
val member : string -> (string * Yojson.Safe.t) list -> Yojson.Safe.t
val string : string -> (string * Yojson.Safe.t) list -> string
val int : string -> (string * Yojson.Safe.t) list -> int
val bool : string -> (string * Yojson.Safe.t) list -> bool
val string_list : string -> (string * Yojson.Safe.t) list -> string list
val exact_fields : string list -> (string * Yojson.Safe.t) list -> unit
val expect_string : string -> string -> (string * Yojson.Safe.t) list -> unit
val expect_int : int -> string -> (string * Yojson.Safe.t) list -> unit
val expect_bool : bool -> string -> (string * Yojson.Safe.t) list -> unit
val lines : string -> string list
val contains : substring:string -> string -> bool
val root : unit -> string
val path : string -> string
val tenant_ids : unit -> string list
val files_under : string -> string list
val csv_rows : string -> string list * string list list
val ndjson : string -> Yojson.Safe.t list
val validate_schema : Yojson.Safe.t -> Yojson.Safe.t -> unit
val validate_schema_file : schema_path:string -> instance_path:string -> unit

val reject_private_data :
  ?allowed_signature_path:string -> Yojson.Safe.t -> unit

val reject_secret_keys : ?allow_redacted_signature:bool -> Yojson.Safe.t -> unit
