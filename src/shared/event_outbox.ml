type validation_error =
  | Invalid_event_id
  | Invalid_event_type
  | Invalid_idempotency_key
  | Invalid_target_url_env_var
  | Secret_bearing_field
  | Payload_too_large

type target = Notification_hub | Workflow_engine | Webhook_engine

type event = {
  tenant_id : Tenant_context.Tenant_id.t;
  event_id : string;
  event_type : string;
  idempotency_key : string;
  target : target;
  target_url_env_var : string;
  payload : Yojson.Safe.t;
}

let valid_word value =
  let length = String.length value in
  length > 0 && length <= 48
  && String.for_all
       (function 'a' .. 'z' | '0' .. '9' | '_' -> true | _ -> false)
       value

let valid_event_type value =
  match String.split_on_char '.' value with
  | [ "freight_auction"; noun; verb ] -> valid_word noun && valid_word verb
  | _ -> false

let valid_idempotency value =
  let length = String.length value in
  length > 0 && length <= 128
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | ':' -> true
         | _ -> false)
       value

let expected_env_var = function
  | Notification_hub -> "NOTIFICATION_HUB_URL"
  | Workflow_engine -> "WORKFLOW_ENGINE_URL"
  | Webhook_engine -> "WEBHOOK_ENGINE_URL"

let denied_fragments =
  [
    "password";
    "secret";
    "token";
    "authorization";
    "cookie";
    "apikey";
    "privatekey";
    "signature";
    "credential";
  ]

let contains ~needle value =
  let needle_length = String.length needle in
  let rec loop index =
    if index + needle_length > String.length value then false
    else if String.sub value index needle_length = needle then true
    else loop (index + 1)
  in
  needle_length = 0 || loop 0

let secret_bearing name =
  let normalized =
    String.lowercase_ascii name
    |> String.to_seq
    |> Seq.filter (function 'a' .. 'z' | '0' .. '9' -> true | _ -> false)
    |> String.of_seq
  in
  List.exists
    (fun fragment -> contains ~needle:fragment normalized)
    denied_fragments

let rec has_secret_field = function
  | `Assoc fields ->
      List.exists
        (fun (name, value) -> secret_bearing name || has_secret_field value)
        fields
  | `List values | `Tuple values -> List.exists has_secret_field values
  | `Variant (_, Some value) -> has_secret_field value
  | `Variant (_, None)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ ->
      false

let event ~tenant_id ~event_id ~event_type ~idempotency_key ~target
    ~target_url_env_var ~payload =
  if Result.is_error (Tenant_context.Tenant_id.of_string event_id) then
    Error Invalid_event_id
  else if not (valid_event_type event_type) then Error Invalid_event_type
  else if not (valid_idempotency idempotency_key) then
    Error Invalid_idempotency_key
  else if target_url_env_var <> expected_env_var target then
    Error Invalid_target_url_env_var
  else if has_secret_field payload then Error Secret_bearing_field
  else if String.length (Yojson.Safe.to_string payload) > 65_536 then
    Error Payload_too_large
  else
    Ok
      {
        tenant_id;
        event_id;
        event_type;
        idempotency_key;
        target;
        target_url_env_var;
        payload;
      }

let tenant_id value = value.tenant_id
let event_id value = value.event_id
let event_type value = value.event_type
let idempotency_key value = value.idempotency_key
let target value = value.target
let target_url_env_var value = value.target_url_env_var
let payload value = value.payload

module type WRITER = sig
  type transaction
  type error

  val enqueue :
    transaction ->
    event ->
    ([ `Inserted of string | `Existing of string ], error) result Lwt.t
end
