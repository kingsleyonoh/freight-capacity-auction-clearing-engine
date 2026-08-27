type t = string

let allowed = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> true
  | _ -> false

let of_string value =
  if String.length value < 16 || String.length value > 256 then Error "API_KEY_INVALID"
  else if not (String.for_all allowed value) then Error "API_KEY_INVALID"
  else Ok value

let to_string value = value
let is_redacted value = value = "" || String.length value < 8
