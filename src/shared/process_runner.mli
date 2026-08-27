type t
type exit_outcome = [ `Exited of int | `Signaled of int | `Stopped of int ]
type stream = [ `Stdout | `Stderr ]
type capture
type request

type output = {
  stdout : string;
  stderr : string;
  capture_directory : string option;
}

type error =
  | Invalid_request
  | Invalid_environment
  | Spawn_failed
  | Stdin_limit_exceeded
  | Output_limit_exceeded of stream
  | Timed_out
  | Cancelled
  | Nonzero_exit of exit_outcome
  | Termination_unavailable
  | Artifact_invalid
  | Artifact_write_failed

val create : allowed_env:string list -> t
val capture : root:string -> namespace:string -> capture

val request :
  executable:string ->
  argv:string list ->
  env:(string * string) list ->
  stdin:string ->
  stdin_limit:int ->
  stdout_limit:int ->
  stderr_limit:int ->
  timeout:float ->
  term_grace:float ->
  ?capture:capture ->
  unit ->
  request

val run : ?cancel:unit Lwt.t -> t -> request -> (output, error) result Lwt.t
val error_code : error -> string
val error_to_string : error -> string
