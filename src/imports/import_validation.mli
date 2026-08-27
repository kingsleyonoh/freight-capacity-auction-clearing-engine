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

val validate_json_rows : resource_type:string -> context:context -> Yojson.Safe.t list -> result
val validate_csv : resource_type:string -> context:context -> string -> result
