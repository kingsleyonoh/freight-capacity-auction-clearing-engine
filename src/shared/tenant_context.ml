type role =
  | Tenant_admin
  | Auction_manager
  | Procurement_analyst
  | Carrier_viewer
  | System

type t = {
  tenant_id : string;
  user_id : string option;
  role : role;
  request_id : string;
  carrier_id : string option;
}

let role_to_string = function
  | Tenant_admin -> "tenant_admin"
  | Auction_manager -> "auction_manager"
  | Procurement_analyst -> "procurement_analyst"
  | Carrier_viewer -> "carrier_viewer"
  | System -> "system"

let role_of_string = function
  | "tenant_admin" -> Ok Tenant_admin
  | "auction_manager" -> Ok Auction_manager
  | "procurement_analyst" -> Ok Procurement_analyst
  | "carrier_viewer" -> Ok Carrier_viewer
  | "system" -> Ok System
  | value -> Error ("unknown role: " ^ value)

let require_non_blank field value =
  if String.trim value = "" then invalid_arg (field ^ " is required") else value

let create ?user_id ?carrier_id ~tenant_id ~role ~request_id () =
  {
    tenant_id = require_non_blank "tenant_id" tenant_id;
    user_id;
    role;
    request_id = require_non_blank "request_id" request_id;
    carrier_id;
  }

let system ?(request_id = "system") tenant_id =
  create ~tenant_id ~role:System ~request_id ()

let tenant_key context = "tenant:" ^ context.tenant_id

let require_same_tenant context ~resource_tenant_id =
  let resource_tenant_id = require_non_blank "resource_tenant_id" resource_tenant_id in
  if String.equal context.tenant_id resource_tenant_id then Ok ()
  else
    Error
      (Printf.sprintf "TENANT_SCOPE_VIOLATION: expected %s but got %s"
         context.tenant_id resource_tenant_id)

let can_access_carrier context ~carrier_id =
  let carrier_id = require_non_blank "carrier_id" carrier_id in
  match context.role with
  | Carrier_viewer -> Option.equal String.equal context.carrier_id (Some carrier_id)
  | Tenant_admin | Auction_manager | Procurement_analyst | System -> true
