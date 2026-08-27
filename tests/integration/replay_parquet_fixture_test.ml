let failf format = Printf.ksprintf (fun message -> Alcotest.fail message) format

let required_env name =
  match Sys.getenv_opt name with
  | Some value when String.trim value <> "" -> value
  | _ -> failf "%s is required" name

let sql_path value = String.concat "''" (String.split_on_char '\'' value)

let run_query binary query =
  let arguments =
    [|
      binary; "-batch"; "-bail"; "-noheader"; "-csv"; ":memory:"; "-c"; query;
    |]
  in
  let channel = Unix.open_process_args_in binary arguments in
  let output = Buffer.create 256 in
  (try
     while true do
       Buffer.add_string output (input_line channel);
       Buffer.add_char output '\n'
     done
   with End_of_file -> ());
  match Unix.close_process_in channel with
  | Unix.WEXITED 0 -> String.trim (Buffer.contents output)
  | Unix.WEXITED code -> failf "DuckDB query exited %d" code
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
      failf "DuckDB query stopped by signal %d" signal

let csv_scalar value =
  let length = String.length value in
  if length >= 2 && value.[0] = '"' && value.[length - 1] = '"' then
    String.sub value 1 (length - 2)
  else value

let bind_parquet query parquet =
  match String.split_on_char '%' query with
  | [ before; after ] when String.starts_with ~prefix:"s" after ->
      before ^ sql_path parquet ^ String.sub after 1 (String.length after - 1)
  | _ -> failf "DuckDB fixture query must contain exactly one path marker"

let expect binary parquet query expected label =
  let query = bind_parquet query parquet in
  Alcotest.(check string) label expected (run_query binary query |> csv_scalar)

let expected_schema =
  String.concat "|"
    [
      "schema_version:SMALLINT";
      "tenant_id:VARCHAR";
      "window_month:DATE";
      "auction_id:VARCHAR";
      "auction_name:VARCHAR";
      "auction_mode:VARCHAR";
      "auction_closed_at:TIMESTAMP WITH TIME ZONE";
      "policy_version:INTEGER";
      "load_id:VARCHAR";
      "load_external_ref:VARCHAR";
      "lane_id:VARCHAR";
      "origin_region:VARCHAR";
      "destination_region:VARCHAR";
      "equipment_type:VARCHAR";
      "service_priority:VARCHAR";
      "reserve_price:DECIMAL(12,2)";
      "load_sequence:INTEGER";
      "bid_id:VARCHAR";
      "carrier_id:VARCHAR";
      "carrier_public_name:VARCHAR";
      "idempotency_key:VARCHAR";
      "bid_amount:DECIMAL(12,2)";
      "accessorial_cost:DECIMAL(12,2)";
      "submitted_at:TIMESTAMP WITH TIME ZONE";
      "valid_until:TIMESTAMP WITH TIME ZONE";
      "bid_status:VARCHAR";
      "service_score_snapshot:DECIMAL(5,4)";
      "reliability_score:DECIMAL(5,4)";
      "historical_otd_rate:DECIMAL(5,4)";
      "withdrawal_rate:DECIMAL(5,4)";
      "incumbent:BOOLEAN";
      "first_acceptable_rank:INTEGER";
      "historical_awarded:BOOLEAN";
      "delivered_on_time:BOOLEAN";
      "withdrawn_after_award:BOOLEAN";
      "actual_landed_cost:DECIMAL(12,2)";
      "baseline_eligible:BOOLEAN";
    ]

let validate_version_and_schema binary parquet =
  Alcotest.(check string)
    "exact DuckDB version" "v1.3.2"
    (run_query binary "SELECT version();");
  let schema_query =
    Printf.sprintf
      "CREATE TEMP VIEW facts AS SELECT * FROM read_parquet('%s'); SELECT \
       string_agg(column_name || ':' || data_type, '|' ORDER BY column_index) \
       FROM duckdb_columns() WHERE table_name='facts';"
      (sql_path parquet)
  in
  Alcotest.(check string)
    "ordered logical schema" expected_schema
    (run_query binary schema_query |> csv_scalar)

let validate_counts binary parquet =
  expect binary parquet "SELECT count(*) FROM read_parquet('%s');" "432" "rows";
  expect binary parquet
    "SELECT count(DISTINCT tenant_id)||','||count(DISTINCT \
     window_month)||','||count(DISTINCT auction_id)||','||count(DISTINCT \
     load_id)||','||count(DISTINCT bid_id) FROM read_parquet('%s');"
    "2,12,48,144,432" "cardinalities";
  expect binary parquet
    "SELECT count(*) FROM (SELECT tenant_id, window_month, count(*) n FROM \
     read_parquet('%s') GROUP BY ALL HAVING n <> 18);"
    "0" "monthly counts";
  expect binary parquet
    "SELECT min(window_month)||','||max(window_month) FROM read_parquet('%s');"
    "2025-01-01,2025-12-01" "exact monthly window";
  expect binary parquet
    "SELECT count(*) FROM (SELECT tenant_id,window_month, count(DISTINCT \
     auction_id) n FROM read_parquet('%s') GROUP BY ALL HAVING n<>2);"
    "0" "two auctions per tenant month";
  expect binary parquet
    "SELECT count(*) FROM (SELECT tenant_id,auction_id, count(DISTINCT \
     load_id) loads,count(*) bids FROM read_parquet('%s') GROUP BY ALL HAVING \
     loads<>3 OR bids<>9);"
    "0" "three loads and nine bids per auction";
  expect binary parquet
    "SELECT count(*) FROM (SELECT tenant_id,load_id,count(*) n FROM \
     read_parquet('%s') GROUP BY ALL HAVING n<>3);"
    "0" "three bids per load";
  expect binary parquet
    "SELECT count(*) FROM (SELECT tenant_id,count(DISTINCT carrier_id) n FROM \
     read_parquet('%s') GROUP BY tenant_id HAVING n<>6);"
    "0" "six carriers per tenant";
  expect binary parquet
    "SELECT count(*) FROM (SELECT tenant_id,bid_id FROM read_parquet('%s') \
     GROUP BY ALL HAVING count(*)<>1);"
    "0" "unique tenant bid IDs";
  expect binary parquet
    "SELECT count(*) FROM (SELECT tenant_id,auction_id,idempotency_key FROM \
     read_parquet('%s') GROUP BY ALL HAVING count(*)<>1);"
    "0" "unique tenant auction idempotency keys"

let validate_isolation binary parquet =
  List.iter
    (fun (column, label) ->
      expect binary parquet
        (Printf.sprintf
           "SELECT count(*) FROM (SELECT %s FROM read_parquet('%%s') GROUP BY \
            %s HAVING count(DISTINCT tenant_id)>1);"
           column column)
        "0" label)
    [
      ("auction_id", "auction isolation");
      ("load_id", "load isolation");
      ("bid_id", "bid isolation");
      ("carrier_id", "carrier isolation");
    ];
  expect binary parquet
    "SELECT CASE WHEN count(DISTINCT carrier_public_name)<count(DISTINCT \
     tenant_id||carrier_public_name) AND count(DISTINCT \
     load_external_ref)<count(DISTINCT tenant_id||load_external_ref) THEN 1 \
     ELSE 0 END FROM read_parquet('%s');"
    "1" "public overlap"

let validate_values_order_hash binary parquet expected_hash =
  expect binary parquet
    "SELECT \
     hex(content[1:4])||','||hex(content[octet_length(content)-3:octet_length(content)]) \
     FROM read_blob('%s');"
    "50415231,50415231" "PAR1 magic";
  expect binary parquet
    "SELECT count(*) FROM read_parquet('%s') WHERE schema_version<>1 OR \
     auction_mode<>'scenario_replay' OR equipment_type NOT IN \
     ('REEFER','DRY_VAN') OR service_priority NOT IN ('priority','standard') \
     OR bid_status NOT IN ('eligible','rejected') OR reserve_price<0 OR \
     bid_amount<0 OR service_score_snapshot NOT BETWEEN 0 AND 1 OR \
     reliability_score NOT BETWEEN 0 AND 1 OR historical_otd_rate NOT BETWEEN \
     0 AND 1 OR withdrawal_rate NOT BETWEEN 0 AND 1 OR tenant_id IS NULL OR \
     auction_id IS NULL OR load_id IS NULL OR bid_id IS NULL;"
    "0" "enums decimals ranges nullability";
  expect binary parquet
    "WITH physical AS (SELECT *, row_number() OVER () p FROM \
     read_parquet('%s')), ordered AS (SELECT p,row_number() OVER (ORDER BY \
     tenant_id,window_month,auction_id,load_id,submitted_at,bid_id) o FROM \
     physical) SELECT count(*) FROM ordered WHERE p<>o;"
    "0" "physical order";
  expect binary parquet
    "SELECT count(DISTINCT row_group_id) FROM parquet_metadata('%s');" "1"
    "one row group";
  expect binary parquet
    "SELECT coalesce(sum(stats_null_count),0) FROM parquet_metadata('%s');" "0"
    "zero nulls across all columns";
  expect binary parquet "SELECT sha256(content) FROM read_blob('%s');"
    expected_hash "artifact hash"

let test_official_parquet () =
  let binary = required_env "FCA_DUCKDB_BINARY" in
  let parquet = required_env "FCA_REPLAY_PARQUET" in
  let expected_hash = required_env "FCA_REPLAY_PARQUET_SHA256" in
  validate_version_and_schema binary parquet;
  validate_counts binary parquet;
  validate_isolation binary parquet;
  validate_values_order_hash binary parquet expected_hash

let () =
  Alcotest.run "official DuckDB replay fixture"
    [
      ( "parquet",
        [
          Alcotest.test_case "schema and semantics" `Quick test_official_parquet;
        ] );
    ]
