type context = {
  carrier_ids : string list;
  suspended_carrier_ids : string list;
  lane_ids : string list;
  load_ids : string list;
}

type result = {
  rows : Yojson.Safe.t list;
  errors : Yojson.Safe.t list;
  row_count : int;
  valid_row_count : int;
  invalid_row_count : int;
  status : string;
}

let member name json = Yojson.Safe.Util.member name json

let string_member name json =
  match member name json with
  | `String value -> Some (String.trim value)
  | `Int value -> Some (string_of_int value)
  | `Float value -> Some (string_of_float value)
  | `Intlit value -> Some value
  | `Bool value -> Some (if value then "true" else "false")
  | _ -> None

let value_or_empty name json = Option.value ~default:"" (string_member name json)

let normalize_header value =
  value
  |> String.trim
  |> String.lowercase_ascii
  |> String.map (function ' ' | '-' -> '_' | value -> value)

let rec split_csv_line line index field fields quoted escaped =
  if index >= String.length line then
    List.rev (Buffer.contents field :: fields)
  else
    let character = line.[index] in
    if quoted then
      if character = '"' && not escaped then
        if index + 1 < String.length line && line.[index + 1] = '"' then
          split_csv_line line (index + 2) field fields true true
        else split_csv_line line (index + 1) field fields false false
      else begin
        if escaped then Buffer.add_char field '"' else Buffer.add_char field character;
        split_csv_line line (index + 1) field fields true false
      end
    else if character = '"' && Buffer.length field = 0 then
      split_csv_line line (index + 1) field fields true false
    else if character = ',' then begin
      let value = Buffer.contents field in
      Buffer.clear field;
      split_csv_line line (index + 1) field (value :: fields) false false
    end
    else begin
      Buffer.add_char field character;
      split_csv_line line (index + 1) field fields false false
    end

let csv_fields line = split_csv_line line 0 (Buffer.create 32) [] false false |> List.map String.trim

let non_empty name json = value_or_empty name json <> ""

let contains value values = List.exists (String.equal value) values

let error_json ~row_number ~code ~message ?field_name ?(severity = "error") ?quarantine_reason () =
  `Assoc
    [ ("row_number", `Int row_number);
      ("error_code", `String code);
      ("error_message", `String message);
      ("field_name", Option.fold ~none:`Null ~some:(fun value -> `String value) field_name);
      ("severity", `String severity);
      ("quarantine_reason", Option.fold ~none:`Null ~some:(fun value -> `String value) quarantine_reason) ]

let wrapper ~row_number ~raw_payload ~normalized_payload ~status error =
  let fields =
    [ ("row_number", `Int row_number);
      ("raw_payload", raw_payload);
      ("normalized_payload", normalized_payload);
      ("status", `String status) ]
  in
  match error with
  | None -> `Assoc fields
  | Some (`Assoc error_fields) ->
      `Assoc (fields @ List.map (fun (name, value) -> (name, value)) error_fields)
  | Some _ -> `Assoc fields

let required_fields = function
  | "carriers" -> [ [ "legal_name"; "name" ]; [ "display_name"; "legal_name"; "name" ]; [ "equipment_type" ] ]
  | "lanes" -> [ [ "origin_region" ]; [ "destination_region" ]; [ "equipment_type" ] ]
  | "loads" -> [ [ "lane_id" ]; [ "external_ref"; "external_id" ]; [ "pickup_start"; "pickup_at" ]; [ "pickup_end" ]; [ "delivery_start"; "delivery_at" ]; [ "delivery_end" ]; [ "weight_lbs"; "quantity" ]; [ "equipment_type"; "equipment" ] ]
  | "bids" -> [ [ "load_id"; "load_ref" ]; [ "carrier_id"; "carrier_ref" ]; [ "idempotency_key" ]; [ "bid_amount" ]; [ "submitted_at" ] ]
  | "replay_dataset" -> [ [ "tenant_id" ]; [ "auction_id" ]; [ "load_id" ]; [ "bid_id" ]; [ "actual_landed_cost" ]; [ "baseline_eligible" ] ]
  | _ -> []

let allowed_fields = function
  | "carriers" -> [ "legal_name"; "name"; "display_name"; "mc_number"; "dot_number"; "equipment_type"; "status" ]
  | "lanes" -> [ "origin_region"; "destination_region"; "equipment_type"; "distance_miles"; "reserve_price"; "status" ]
  | "loads" -> [ "lane_id"; "external_ref"; "external_id"; "pickup_start"; "pickup_at"; "pickup_end"; "delivery_start"; "delivery_at"; "delivery_end"; "weight_lbs"; "quantity"; "equipment_type"; "equipment"; "service_priority"; "status" ]
  | "bids" -> [ "case_id"; "auction_ref"; "load_id"; "load_ref"; "carrier_id"; "carrier_ref"; "idempotency_key"; "bid_amount"; "currency"; "capacity_units"; "equipment_type"; "service_score"; "service_score_milli"; "submitted_at"; "valid_until" ]
  | "replay_dataset" -> [ "tenant_id"; "auction_id"; "load_id"; "bid_id"; "actual_landed_cost"; "baseline_eligible"; "service_score_snapshot"; "window_month"; "carrier_id"; "equipment_type" ]
  | _ -> []

let first_present names json = List.find_opt (fun name -> non_empty name json) names

let missing_fields resource_type json =
  required_fields resource_type
  |> List.filter_map (fun alternatives ->
         match first_present alternatives json with
         | Some _ -> None
         | None -> Some (String.concat " or " alternatives))

let normalize_payload resource_type json =
  let aliases =
    match resource_type with
    | "carriers" -> [ ("legal_name", [ "legal_name"; "name" ]); ("display_name", [ "display_name"; "legal_name"; "name" ]); ("equipment_type", [ "equipment_type" ]) ]
    | "loads" -> [ ("external_ref", [ "external_ref"; "external_id" ]); ("pickup_start", [ "pickup_start"; "pickup_at" ]); ("delivery_start", [ "delivery_start"; "delivery_at" ]); ("weight_lbs", [ "weight_lbs"; "quantity" ]); ("equipment_type", [ "equipment_type"; "equipment" ]) ]
    | "bids" -> [ ("load_id", [ "load_id"; "load_ref" ]); ("carrier_id", [ "carrier_id"; "carrier_ref" ]); ("bid_amount", [ "bid_amount" ]); ("service_score", [ "service_score" ]) ]
    | _ -> []
  in
  let fields =
    match json with
    | `Assoc fields -> fields
    | _ -> []
  in
  let add_alias output (target, names) =
    if List.mem_assoc target output then output
    else match first_present names json with None -> output | Some source -> (target, `String (value_or_empty source json)) :: output
  in
  `Assoc (List.fold_left add_alias fields aliases)

let numeric_error field json =
  match float_of_string_opt (value_or_empty field json) with
  | Some value when Float.is_finite value && value >= 0. -> None
  | _ -> Some (error_json ~row_number:0 ~code:"INVALID_NUMBER" ~message:(field ^ " must be a non-negative number") ~field_name:field ())

let validate_row ~resource_type ~context ~row_number raw_payload seen =
  let normalized_payload = normalize_payload resource_type raw_payload in
  let missing = missing_fields resource_type normalized_payload in
  let duplicate_key =
    match resource_type with
    | "bids" -> Option.map (fun name -> value_or_empty name normalized_payload) (first_present [ "idempotency_key" ] normalized_payload)
    | "loads" -> Option.map (fun name -> value_or_empty name normalized_payload) (first_present [ "external_ref" ] normalized_payload)
    | _ -> None
  in
  let duplicate = match duplicate_key with Some key when contains key !seen -> true | _ -> false in
  Option.iter (fun key -> seen := key :: !seen) duplicate_key;
  let semantic_error =
    match resource_type with
    | "bids" -> numeric_error "bid_amount" normalized_payload
    | "lanes" -> numeric_error "distance_miles" normalized_payload
    | "loads" -> numeric_error "weight_lbs" normalized_payload
    | "replay_dataset" -> numeric_error "actual_landed_cost" normalized_payload
    | _ -> None
  in
  let reference_error =
    match resource_type with
    | "bids" ->
        (match string_member "carrier_id" normalized_payload with
         | Some carrier when context.carrier_ids <> [] && not (contains carrier context.carrier_ids) -> Some ("UNKNOWN_CARRIER", "The carrier reference is not present in this tenant.", "carrier_id", "quarantined")
         | Some carrier when contains carrier context.suspended_carrier_ids -> Some ("CARRIER_SUSPENDED", "The carrier is suspended and cannot submit bids.", "carrier_id", "invalid")
         | _ -> None)
    | "loads" ->
        (match string_member "lane_id" normalized_payload with
         | Some lane when context.lane_ids <> [] && not (contains lane context.lane_ids) -> Some ("UNKNOWN_LANE", "The lane reference is not present in this tenant.", "lane_id", "quarantined")
         | _ -> None)
    | _ -> None
  in
  if missing <> [] then
    let field = List.hd missing in
    let error = error_json ~row_number ~code:"IMPORT_REQUIRED_FIELD" ~message:("Required field is missing: " ^ field) ~field_name:field () in
    wrapper ~row_number ~raw_payload ~normalized_payload ~status:"invalid" (Some error), [ error ]
  else if duplicate then
    let error = error_json ~row_number ~code:(if resource_type = "bids" then "BID_DUPLICATE" else "DUPLICATE_EXTERNAL_ID") ~message:"The idempotency or external reference already appears in this import." ~severity:"warning" () in
    wrapper ~row_number ~raw_payload ~normalized_payload ~status:"skipped" (Some error), [ error ]
  else match reference_error, semantic_error with
    | Some (code, message, field, status), _ ->
        let severity = if status = "quarantined" then "fatal" else "error" in
        let error = error_json ~row_number ~code ~message ~field_name:field ~severity ?quarantine_reason:(if status = "quarantined" then Some "reference_unresolved" else None) () in
        wrapper ~row_number ~raw_payload ~normalized_payload ~status (Some error), [ error ]
    | None, Some error ->
        let error = match error with `Assoc fields -> `Assoc (List.map (fun (name, value) -> if name = "row_number" then (name, `Int row_number) else (name, value)) fields) | value -> value in
        wrapper ~row_number ~raw_payload ~normalized_payload ~status:"invalid" (Some error), [ error ]
    | None, None -> wrapper ~row_number ~raw_payload ~normalized_payload ~status:"valid" None, []

let result_of_rows ~resource_type ~context rows =
  let seen = ref [] in
  let wrapped, errors =
    List.mapi (fun index row -> validate_row ~resource_type ~context ~row_number:(index + 1) row seen) rows
    |> List.split
  in
  let invalid = List.length (List.filter (fun row -> List.mem (value_or_empty "status" row) [ "invalid"; "quarantined" ]) wrapped) in
  let valid = List.length wrapped - invalid in
  { rows = wrapped; errors = List.concat errors; row_count = List.length wrapped; valid_row_count = valid; invalid_row_count = invalid; status = if invalid > 0 then "quarantined" else "validated" }

let schema_result ~resource_type headers =
  let normalized = List.map normalize_header headers in
  let missing = List.filter (fun alternatives -> not (List.exists (fun field -> List.mem field normalized) alternatives)) (required_fields resource_type) |> List.map (String.concat " or ") in
  let unknown = List.filter (fun field -> not (List.mem field (allowed_fields resource_type))) normalized in
  if missing = [] && unknown = [] then None
  else
    let details =
      `Assoc [ ("missing_columns", `List (List.map (fun value -> `String value) missing)); ("unknown_columns", `List (List.map (fun value -> `String value) unknown)) ]
    in
    let error = error_json ~row_number:0 ~code:"IMPORT_SCHEMA_DRIFT" ~message:(Yojson.Safe.to_string details) ~severity:"fatal" ~quarantine_reason:"schema_drift" () in
    Some { rows = []; errors = [ error ]; row_count = 0; valid_row_count = 0; invalid_row_count = 0; status = "quarantined" }

let rows_from_csv csv =
  match String.split_on_char '\n' csv |> List.map String.trim |> List.filter (fun value -> value <> "") with
  | [] -> []
  | header :: lines ->
      let headers = csv_fields header |> List.map normalize_header in
      lines
      |> List.map (fun line ->
             let values = csv_fields line in
             `Assoc (List.mapi (fun index name -> (name, `String (Option.value ~default:"" (List.nth_opt values index)))) headers))

let validate_csv ~resource_type ~context csv =
  match String.split_on_char '\n' csv |> List.map String.trim |> List.filter (fun value -> value <> "") with
  | [] -> { rows = []; errors = []; row_count = 0; valid_row_count = 0; invalid_row_count = 0; status = "validated" }
  | header :: _ ->
      let headers = csv_fields header in
      (match schema_result ~resource_type headers with Some result -> result | None -> result_of_rows ~resource_type ~context (rows_from_csv csv))

let validate_json_rows ~resource_type ~context rows = result_of_rows ~resource_type ~context rows
