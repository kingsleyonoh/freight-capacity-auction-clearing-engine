type 'a t = {
  name : string;
  mutable value : 'a option;
}

let require_name name =
  if String.trim name = "" then invalid_arg "cache name is required" else name

let create name = { name = require_name name; value = None }

let name cache = cache.name

let peek cache = cache.value

let clear cache = cache.value <- None

let get_or_compute cache ~compute =
  match cache.value with
  | Some value -> value
  | None ->
      let value = compute () in
      cache.value <- Some value;
      value
