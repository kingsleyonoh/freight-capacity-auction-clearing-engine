type validation_error =
  | Invalid_uuid
  | Invalid_request_id
  | Invalid_actor_name
  | Carrier_scope_required
  | Carrier_scope_forbidden

let is_hex = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false

let string_for_alli predicate value =
  let rec loop index =
    index = String.length value
    || (predicate index value.[index] && loop (index + 1))
  in
  loop 0

let valid_uuid value =
  String.length value = 36
  && List.for_all (fun index -> value.[index] = '-') [ 8; 13; 18; 23 ]
  && string_for_alli
       (fun index character ->
         List.mem index [ 8; 13; 18; 23 ] || is_hex character)
       value
  && (match value.[14] with '1' .. '5' -> true | _ -> false)
  &&
  match Char.lowercase_ascii value.[19] with
  | '8' | '9' | 'a' | 'b' -> true
  | _ -> false

module Id = struct
  type t = string

  let of_string value =
    if valid_uuid value then Ok value else Error Invalid_uuid

  let to_string value = value
end

module Tenant_id = Id
module User_id = Id
module Carrier_id = Id

type role =
  | Tenant_admin
  | Auction_manager
  | Procurement_analyst
  | Carrier_viewer

type actor = User | System | Integration

type t = {
  tenant_id : Tenant_id.t;
  actor : actor;
  user_id : User_id.t option;
  role : role option;
  carrier_id : Carrier_id.t option;
  actor_name : string option;
  request_id : string;
}

let valid_component ~max_length value =
  let length = String.length value in
  length > 0 && length <= max_length
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | ':' -> true
         | _ -> false)
       value

let user ~tenant_id ~user_id ~role ?carrier_id ~request_id () =
  if not (valid_component ~max_length:128 request_id) then
    Error Invalid_request_id
  else
    match (role, carrier_id) with
    | Carrier_viewer, None -> Error Carrier_scope_required
    | (Tenant_admin | Auction_manager | Procurement_analyst), Some _ ->
        Error Carrier_scope_forbidden
    | _ ->
        Ok
          {
            tenant_id;
            actor = User;
            user_id = Some user_id;
            role = Some role;
            carrier_id;
            actor_name = None;
            request_id;
          }

let non_user actor ~tenant_id ~name ~request_id =
  if not (valid_component ~max_length:64 name) then Error Invalid_actor_name
  else if not (valid_component ~max_length:128 request_id) then
    Error Invalid_request_id
  else
    Ok
      {
        tenant_id;
        actor;
        user_id = None;
        role = None;
        carrier_id = None;
        actor_name = Some name;
        request_id;
      }

let system ~tenant_id ~name ~request_id () =
  non_user System ~tenant_id ~name ~request_id

let integration ~tenant_id ~name ~request_id () =
  non_user Integration ~tenant_id ~name ~request_id

let tenant_id context = context.tenant_id
let actor context = context.actor
let user_id context = context.user_id
let role context = context.role
let carrier_id context = context.carrier_id
let actor_name context = context.actor_name
let request_id context = context.request_id
