type unknown_carrier_policy = Reject | Quarantine

type load = {
  external_id : string;
  origin : string;
  destination : string;
  equipment : string;
  pickup_at : string;
  delivery_at : string;
  quantity : int;
}

type error_reason =
  | Malformed_row
  | Missing_field of string
  | Invalid_quantity
  | Invalid_time_window
  | Duplicate_external_id
  | Unknown_carrier
  | Suspended_carrier
  | Unsupported_equipment
  | Reserve_violation

type row_result = Accepted of load | Rejected of error_reason | Quarantined of error_reason

val error_code : error_reason -> string
val validate_load : known_carriers:string list -> suspended_carriers:string list -> supported_equipment:string list -> load -> row_result
val parse_csv : unknown_carrier_policy:unknown_carrier_policy -> known_carriers:string list -> suspended_carriers:string list -> supported_equipment:string list -> string -> row_result list
