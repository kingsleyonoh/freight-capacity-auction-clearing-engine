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

let error_code = function
  | Malformed_row -> "MALFORMED_ROW"
  | Missing_field field -> "MISSING_" ^ String.uppercase_ascii field
  | Invalid_quantity -> "INVALID_QUANTITY"
  | Invalid_time_window -> "INVALID_TIME_WINDOW"
  | Duplicate_external_id -> "DUPLICATE_EXTERNAL_ID"
  | Unknown_carrier -> "UNKNOWN_CARRIER"
  | Suspended_carrier -> "SUSPENDED_CARRIER"
  | Unsupported_equipment -> "UNSUPPORTED_EQUIPMENT"
  | Reserve_violation -> "RESERVE_VIOLATION"

let trim = String.trim
let member_ci value values = List.exists (fun item -> String.equal (String.lowercase_ascii item) (String.lowercase_ascii value)) values

let validate_load ~known_carriers ~suspended_carriers ~supported_equipment load =
  if load.external_id = "" then Rejected (Missing_field "external_id")
  else if load.origin = "" then Rejected (Missing_field "origin")
  else if load.destination = "" then Rejected (Missing_field "destination")
  else if load.quantity <= 0 then Rejected Invalid_quantity
  else if load.pickup_at = "" || load.delivery_at = "" || load.pickup_at >= load.delivery_at then Rejected Invalid_time_window
  else if not (member_ci load.equipment supported_equipment) then Rejected Unsupported_equipment
  else if not (member_ci load.destination known_carriers) then Rejected Unknown_carrier
  else if member_ci load.destination suspended_carriers then Rejected Suspended_carrier
  else Accepted load

let split_csv_line line =
  let fields = String.split_on_char ',' line in
  List.map trim fields

let parse_csv ~unknown_carrier_policy ~known_carriers ~suspended_carriers ~supported_equipment csv =
  let lines = String.split_on_char '\n' csv |> List.map trim |> List.filter (fun line -> line <> "") in
  let lines = match lines with [] -> [] | header :: rest when String.lowercase_ascii header |> String.starts_with ~prefix:"external_id" -> rest | _ -> lines in
  let seen = Hashtbl.create (List.length lines) in
  let parse_row fields =
    match fields with
    | [ external_id; origin; destination; equipment; pickup_at; delivery_at; quantity ] ->
        if Hashtbl.mem seen external_id then Rejected Duplicate_external_id
        else (
          Hashtbl.replace seen external_id ();
          match int_of_string_opt quantity with
          | None -> Rejected Invalid_quantity
          | Some quantity ->
              let result = validate_load ~known_carriers ~suspended_carriers ~supported_equipment
                { external_id; origin; destination; equipment; pickup_at; delivery_at; quantity } in
              match result with
              | Rejected Unknown_carrier when unknown_carrier_policy = Quarantine -> Quarantined Unknown_carrier
              | other -> other)
    | _ -> Rejected Malformed_row
  in
  List.map (fun line -> parse_row (split_csv_line line)) lines
