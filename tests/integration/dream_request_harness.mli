type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

val call :
  ?method_:Dream.method_ ->
  ?headers:(string * string) list ->
  target:string ->
  Dream.handler ->
  response

val header : string -> response -> string option
