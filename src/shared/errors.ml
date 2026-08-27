module Code = struct
  type t = string
  type validation_error = Invalid_format

  let is_upper = function 'A' .. 'Z' -> true | _ -> false

  let is_tail = function
    | 'A' .. 'Z' | '0' .. '9' | '_' -> true
    | _ -> false

  let of_string value =
    if String.length value = 0 || not (is_upper value.[0]) then
      Error Invalid_format
    else if String.for_all is_tail value then Ok value
    else Error Invalid_format

  let to_string value = value
end

type validation_error =
  | Empty_message
  | Empty_detail_message
  | Empty_detail_field

type detail = {
  field : string option;
  code : Code.t;
  message : string;
}

type t = {
  code : Code.t;
  message : string;
  details : detail list;
}

let is_blank value = String.trim value = ""

let detail ?field ~code ~message () =
  if is_blank message then Error Empty_detail_message
  else
    match field with
    | Some value when is_blank value -> Error Empty_detail_field
    | _ -> Ok { field; code; message }

let make ~code ~message ?(details = []) () =
  if is_blank message then Error Empty_message else Ok { code; message; details }

let code error = error.code
let message error = error.message
let details error = error.details

let detail_to_yojson (detail : detail) =
  let required =
    [ ("code", `String (Code.to_string detail.code));
      ("message", `String detail.message) ]
  in
  match detail.field with
  | None -> `Assoc required
  | Some field -> `Assoc (("field", `String field) :: required)

let to_yojson error =
  `Assoc
    [ ( "error",
        `Assoc
          [ ("code", `String (Code.to_string error.code));
            ("message", `String error.message);
            ("details", `List (List.map detail_to_yojson error.details)) ] ) ]
