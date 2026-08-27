type validation_error =
  | Invalid_uuid
  | Invalid_request_id
  | Invalid_actor_name
  | Carrier_scope_required
  | Carrier_scope_forbidden

module Tenant_id : sig
  type t

  val of_string : string -> (t, validation_error) result
  val to_string : t -> string
end

module User_id : sig
  type t

  val of_string : string -> (t, validation_error) result
  val to_string : t -> string
end

module Carrier_id : sig
  type t

  val of_string : string -> (t, validation_error) result
  val to_string : t -> string
end

type role =
  | Tenant_admin
  | Auction_manager
  | Procurement_analyst
  | Carrier_viewer

type actor = private User | System | Integration
type t

val user :
  tenant_id:Tenant_id.t ->
  user_id:User_id.t ->
  role:role ->
  ?carrier_id:Carrier_id.t ->
  request_id:string ->
  unit ->
  (t, validation_error) result

val system :
  tenant_id:Tenant_id.t ->
  name:string ->
  request_id:string ->
  unit ->
  (t, validation_error) result

val integration :
  tenant_id:Tenant_id.t ->
  name:string ->
  request_id:string ->
  unit ->
  (t, validation_error) result

val tenant_id : t -> Tenant_id.t
val actor : t -> actor
val user_id : t -> User_id.t option
val role : t -> role option
val carrier_id : t -> Carrier_id.t option
val actor_name : t -> string option
val request_id : t -> string
