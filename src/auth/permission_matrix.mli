type role = Tenant_admin | Auction_manager | Procurement_analyst | Carrier_viewer

type action =
  | Read_tenant
  | Manage_users
  | Manage_auctions
  | Submit_bid
  | Read_own_bid
  | Read_competitor_bid
  | Close_auction
  | Request_clear
  | Approve_award
  | Export_report
  | Manage_policy
  | Manage_integration
  | Read_replay
  | Withdraw_award

type resource_scope = Tenant | Own_carrier | Any_carrier

val role_of_string : string -> role option
val role_to_string : role -> string
val action_to_string : action -> string
val allowed : role:role -> action:action -> resource_scope -> bool
val can : role:string -> action:action -> resource_scope -> bool
