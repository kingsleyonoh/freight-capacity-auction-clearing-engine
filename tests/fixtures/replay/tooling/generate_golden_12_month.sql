SET TimeZone='UTC';
SET threads=1;
SET preserve_insertion_order=true;
COPY (
WITH dimensions AS (
 SELECT tenant_index, month_index, auction_sequence, load_sequence, bid_sequence
 FROM range(2) tenant(tenant_index)
 CROSS JOIN range(12) month(month_index)
 CROSS JOIN range(2) auction(auction_sequence)
 CROSS JOIN range(3) load(load_sequence)
 CROSS JOIN range(3) bid(bid_sequence)
), facts AS (
 SELECT
  CAST(1 AS SMALLINT) AS schema_version,
  CASE tenant_index WHEN 0 THEN '11111111-1111-4111-8111-111111111111' ELSE '22222222-2222-4222-8222-222222222222' END::VARCHAR AS tenant_id,
  CAST(DATE '2025-01-01' + month_index * INTERVAL '1 month' AS DATE) AS window_month,
  printf('%08x-1000-4000-8000-%012d', 1000 + tenant_index * 24 + month_index * 2 + auction_sequence, 1000 + tenant_index * 24 + month_index * 2 + auction_sequence)::VARCHAR AS auction_id,
  ('Shared Monthly Scenario Auction ' || CAST(auction_sequence + 1 AS VARCHAR))::VARCHAR AS auction_name,
  'scenario_replay'::VARCHAR AS auction_mode,
  CAST(TIMESTAMPTZ '2025-01-05 12:00:00+00' + month_index * INTERVAL '1 month' + auction_sequence * INTERVAL '1 day' AS TIMESTAMPTZ) AS auction_closed_at,
  CAST(1 + (month_index % 3) AS INTEGER) AS policy_version,
  printf('%08x-2000-4000-8000-%012d', 2000 + tenant_index * 72 + month_index * 6 + auction_sequence * 3 + load_sequence, 2000 + tenant_index * 72 + month_index * 6 + auction_sequence * 3 + load_sequence)::VARCHAR AS load_id,
  ('LOAD-SHARED-' || lpad(CAST(load_sequence + 1 AS VARCHAR), 3, '0'))::VARCHAR AS load_external_ref,
  printf('%08x-3000-4000-8000-%012d', 3000 + tenant_index * 3 + load_sequence, 3000 + tenant_index * 3 + load_sequence)::VARCHAR AS lane_id,
  CASE load_sequence WHEN 0 THEN 'NORTH' WHEN 1 THEN 'CENTRAL' ELSE 'SOUTH' END::VARCHAR AS origin_region,
  CASE load_sequence WHEN 0 THEN 'EAST' WHEN 1 THEN 'WEST' ELSE 'NORTH' END::VARCHAR AS destination_region,
  CASE load_sequence WHEN 0 THEN 'REEFER' ELSE 'DRY_VAN' END::VARCHAR AS equipment_type,
  CASE load_sequence WHEN 0 THEN 'priority' ELSE 'standard' END::VARCHAR AS service_priority,
  CAST(1500 + load_sequence * 100 AS DECIMAL(12,2)) AS reserve_price,
  CAST(load_sequence + 1 AS INTEGER) AS load_sequence,
  printf('%08x-4000-4000-8000-%012d', 4000 + tenant_index * 216 + month_index * 18 + auction_sequence * 9 + load_sequence * 3 + bid_sequence, 4000 + tenant_index * 216 + month_index * 18 + auction_sequence * 9 + load_sequence * 3 + bid_sequence)::VARCHAR AS bid_id,
  printf('%08x-5000-4000-8000-%012d', 5000 + tenant_index * 6 + ((load_sequence * 3 + bid_sequence) % 6), 5000 + tenant_index * 6 + ((load_sequence * 3 + bid_sequence) % 6))::VARCHAR AS carrier_id,
  ('Shared Carrier ' || CAST(((load_sequence * 3 + bid_sequence) % 6) + 1 AS VARCHAR))::VARCHAR AS carrier_public_name,
  ('replay-' || CAST(tenant_index AS VARCHAR) || '-' || CAST(month_index AS VARCHAR) || '-' || CAST(auction_sequence AS VARCHAR) || '-' || CAST(load_sequence AS VARCHAR) || '-' || CAST(bid_sequence AS VARCHAR))::VARCHAR AS idempotency_key,
  CAST(1100 + month_index * 7 + load_sequence * 50 + bid_sequence * 25 AS DECIMAL(12,2)) AS bid_amount,
  CAST(bid_sequence * 10 AS DECIMAL(12,2)) AS accessorial_cost,
  CAST(TIMESTAMPTZ '2025-01-05 09:00:00+00' + month_index * INTERVAL '1 month' + auction_sequence * INTERVAL '1 day' + load_sequence * INTERVAL '10 minute' + bid_sequence * INTERVAL '1 minute' AS TIMESTAMPTZ) AS submitted_at,
  CAST(TIMESTAMPTZ '2025-01-05 13:00:00+00' + month_index * INTERVAL '1 month' + auction_sequence * INTERVAL '1 day' AS TIMESTAMPTZ) AS valid_until,
  CASE bid_sequence WHEN 2 THEN 'rejected' ELSE 'eligible' END::VARCHAR AS bid_status,
  CAST(0.9000 + bid_sequence * 0.0100 AS DECIMAL(5,4)) AS service_score_snapshot,
  CAST(0.9300 - bid_sequence * 0.0100 AS DECIMAL(5,4)) AS reliability_score,
  CAST(0.9500 - bid_sequence * 0.0100 AS DECIMAL(5,4)) AS historical_otd_rate,
  CAST(0.0100 + bid_sequence * 0.0050 AS DECIMAL(5,4)) AS withdrawal_rate,
  CAST(bid_sequence = 0 AS BOOLEAN) AS incumbent,
  CAST(bid_sequence + 1 AS INTEGER) AS first_acceptable_rank,
  CAST(bid_sequence = 1 AS BOOLEAN) AS historical_awarded,
  CAST(bid_sequence <> 2 AS BOOLEAN) AS delivered_on_time,
  CAST(bid_sequence = 2 AND month_index % 4 = 0 AS BOOLEAN) AS withdrawn_after_award,
  CAST(1125 + month_index * 7 + load_sequence * 50 + bid_sequence * 25 AS DECIMAL(12,2)) AS actual_landed_cost,
  CAST(bid_sequence <> 2 AS BOOLEAN) AS baseline_eligible
 FROM dimensions
)
SELECT * FROM facts
ORDER BY tenant_id, window_month, auction_id, load_id, submitted_at, bid_id
) TO 'tests/fixtures/replay/golden_12_month.parquet'
(FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 432);
