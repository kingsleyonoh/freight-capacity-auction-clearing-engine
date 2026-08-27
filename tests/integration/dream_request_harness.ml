type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

let call ?(method_ = `GET) ?(headers = []) ~target app =
  let request = Dream.request ~method_ ~target ~headers "" in
  let response = Dream.test app request in
  let body = Lwt_main.run (Dream.body response) in
  {
    status = Dream.status response |> Dream.status_to_int;
    headers = Dream.all_headers response |> Dream.sort_headers;
    body;
  }

let header name response =
  let name = String.lowercase_ascii name in
  response.headers
  |> List.find_map (fun (key, value) ->
      if String.lowercase_ascii key = name then Some value else None)
