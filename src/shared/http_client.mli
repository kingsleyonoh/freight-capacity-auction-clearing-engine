type t
type error
type meth = [ `GET | `HEAD | `POST | `PUT | `PATCH | `DELETE ]
type policy
type request
type 'a decoder
type 'a response

val policy :
  total_timeout_s:float ->
  attempt_timeout_s:float ->
  max_attempts:int ->
  initial_backoff_s:float ->
  max_backoff_s:float ->
  max_retry_after_s:float ->
  max_request_bytes:int ->
  max_response_bytes:int ->
  (policy, error) result

val create : max_concurrency:int -> policy -> (t, error) result
val bytes : bytes decoder
val json : Yojson.Safe.t decoder

val request :
  meth:meth ->
  uri:Uri.t ->
  ?headers:(string * string) list ->
  ?body:bytes ->
  ?idempotency_key:string ->
  unit ->
  (request, error) result

val call :
  t -> decoder:'a decoder -> request -> ('a response, error) result Lwt.t

val status : 'a response -> int
val body : 'a response -> 'a
val attempts : 'a response -> int
val error_code : error -> Errors.Code.t
val error_message : error -> string
