type t
type health = { version : string }

type benchmark = {
  duckdb_version : string;
  row_count : int;
  tenant_count : int;
  month_count : int;
  auction_count : int;
  load_count : int;
  bid_count : int;
  baseline_eligible_count : int;
  landed_cost_sum : string;
}

type error =
  | Path_invalid
  | Process_failed
  | Malformed_output
  | Row_budget_exceeded

val create :
  runner:Process_runner.t ->
  executable:string ->
  replay_root:string ->
  database_path:string ->
  timeout:float ->
  output_limit:int ->
  max_rows:int ->
  (t, error) result

val check_row_count : t -> int -> (unit, error) result
val health : t -> (health, error) result Lwt.t
val csv_capability : t -> (bool, error) result Lwt.t
val parquet_capability : t -> (bool, error) result Lwt.t

val read_parquet_rows :
  t -> fixture_path:string -> (Yojson.Safe.t list, error) result Lwt.t

val benchmark_parquet :
  t -> fixture_path:string -> (benchmark, error) result Lwt.t

val benchmark_dataset :
  t -> dataset_path:string -> (benchmark, error) result Lwt.t

val error_code : error -> string
val error_to_string : error -> string
