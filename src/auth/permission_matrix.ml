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

let role_of_string = function
  | "tenant_admin" -> Some Tenant_admin
  | "auction_manager" -> Some Auction_manager
  | "procurement_analyst" -> Some Procurement_analyst
  | "carrier_viewer" -> Some Carrier_viewer
  | _ -> None

let role_to_string = function
  | Tenant_admin -> "tenant_admin"
  | Auction_manager -> "auction_manager"
  | Procurement_analyst -> "procurement_analyst"
  | Carrier_viewer -> "carrier_viewer"

let action_to_string = function
  | Read_tenant -> "read_tenant"
  | Manage_users -> "manage_users"
  | Manage_auctions -> "manage_auctions"
  | Submit_bid -> "submit_bid"
  | Read_own_bid -> "read_own_bid"
  | Read_competitor_bid -> "read_competitor_bid"
  | Close_auction -> "close_auction"
  | Request_clear -> "request_clear"
  | Approve_award -> "approve_award"
  | Export_report -> "export_report"
  | Manage_policy -> "manage_policy"
  | Manage_integration -> "manage_integration"
  | Read_replay -> "read_replay"
  | Withdraw_award -> "withdraw_award"

let internal role action =
  match role with
  | Tenant_admin -> true
  | Auction_manager ->
    List.mem action
        [ Read_tenant; Manage_auctions; Close_auction; Request_clear;
          Approve_award; Read_competitor_bid; Export_report; Read_replay;
          Withdraw_award ]
  | Procurement_analyst ->
      List.mem action
        [ Read_tenant; Read_own_bid; Read_competitor_bid; Request_clear;
          Export_report; Read_replay ]
  | Carrier_viewer -> List.mem action [ Read_tenant; Submit_bid; Read_own_bid; Withdraw_award ]

let allowed ~role ~action scope =
  match (scope, role) with
  | Any_carrier, Carrier_viewer -> false
  | Own_carrier, Carrier_viewer -> internal role action
  | (Tenant | Any_carrier | Own_carrier), _ -> internal role action

let can ~role ~action scope =
  match role_of_string role with None -> false | Some value -> allowed ~role:value ~action scope
