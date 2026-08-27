CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE tenants (
  id UUID PRIMARY KEY,
  name TEXT NOT NULL,
  api_key_hash TEXT NOT NULL UNIQUE,
  legal_name TEXT NOT NULL,
  full_legal_name TEXT NOT NULL,
  display_name TEXT NOT NULL,
  address JSONB NOT NULL DEFAULT '{}'::jsonb,
  registration JSONB NOT NULL DEFAULT '{}'::jsonb,
  contact JSONB NOT NULL DEFAULT '{}'::jsonb,
  wordmark TEXT,
  brand_color TEXT,
  timezone TEXT NOT NULL DEFAULT 'UTC',
  default_currency TEXT NOT NULL DEFAULT 'USD',
  audit_retention_days INTEGER NOT NULL DEFAULT 365 CHECK (audit_retention_days > 0),
  solver_artifact_retention_days INTEGER NOT NULL DEFAULT 90 CHECK (solver_artifact_retention_days > 0),
  operator_license TEXT,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE INDEX tenants_active_idx ON tenants (is_active);

CREATE TABLE carriers (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  legal_name TEXT NOT NULL,
  display_name TEXT NOT NULL,
  mc_number TEXT,
  dot_number TEXT,
  contact JSONB NOT NULL DEFAULT '{}'::jsonb,
  equipment_types TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  service_regions JSONB NOT NULL DEFAULT '[]'::jsonb,
  reliability_score NUMERIC(5,4) NOT NULL DEFAULT 0.7500 CHECK (reliability_score BETWEEN 0 AND 1),
  historical_otd_rate NUMERIC(5,4) NOT NULL DEFAULT 0.0000 CHECK (historical_otd_rate BETWEEN 0 AND 1),
  withdrawal_rate NUMERIC(5,4) NOT NULL DEFAULT 0.0000 CHECK (withdrawal_rate BETWEEN 0 AND 1),
  status TEXT NOT NULL CHECK (status IN ('active','suspended','inactive','pending_review')),
  risk_flags JSONB NOT NULL DEFAULT '[]'::jsonb,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, mc_number)
);
CREATE INDEX carriers_tenant_status_idx ON carriers (tenant_id, status);
CREATE INDEX carriers_tenant_reliability_idx ON carriers (tenant_id, reliability_score DESC);

CREATE TABLE users (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  email TEXT NOT NULL,
  name TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('tenant_admin','auction_manager','procurement_analyst','carrier_viewer')),
  carrier_id UUID REFERENCES carriers(id),
  password_hash TEXT,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  last_login_at TIMESTAMP,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, email),
  CHECK ((role = 'carrier_viewer' AND carrier_id IS NOT NULL) OR role <> 'carrier_viewer')
);
CREATE INDEX users_tenant_role_idx ON users (tenant_id, role);
CREATE INDEX users_tenant_carrier_idx ON users (tenant_id, carrier_id);

CREATE TABLE lanes (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  origin_region TEXT NOT NULL,
  destination_region TEXT NOT NULL,
  equipment_type TEXT NOT NULL,
  distance_miles INTEGER NOT NULL CHECK (distance_miles > 0),
  reserve_price NUMERIC(12,2) NOT NULL CHECK (reserve_price >= 0),
  target_service_score NUMERIC(5,4) NOT NULL DEFAULT 0.9000 CHECK (target_service_score BETWEEN 0 AND 1),
  accessorial_rules JSONB NOT NULL DEFAULT '{}'::jsonb,
  status TEXT NOT NULL CHECK (status IN ('active','paused','archived')),
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, origin_region, destination_region, equipment_type)
);
CREATE INDEX lanes_tenant_status_idx ON lanes (tenant_id, status);
CREATE INDEX lanes_tenant_equipment_idx ON lanes (tenant_id, equipment_type);

CREATE TABLE auction_policies (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  name TEXT NOT NULL,
  version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
  status TEXT NOT NULL CHECK (status IN ('draft','active','retired')),
  max_service_risk NUMERIC(5,4) NOT NULL DEFAULT 0.1500 CHECK (max_service_risk BETWEEN 0 AND 1),
  max_single_carrier_share NUMERIC(5,4) NOT NULL DEFAULT 0.3000 CHECK (max_single_carrier_share > 0 AND max_single_carrier_share <= 1),
  reserve_price_behavior TEXT NOT NULL CHECK (reserve_price_behavior IN ('hard_reject','approval_required','allow_with_reason')),
  fairness_rules JSONB NOT NULL DEFAULT '{}'::jsonb,
  relaxation_order JSONB NOT NULL DEFAULT '[]'::jsonb,
  approval_thresholds JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, name, version)
);
CREATE UNIQUE INDEX policies_one_active_idx ON auction_policies (tenant_id, name) WHERE status = 'active';
CREATE INDEX policies_tenant_status_idx ON auction_policies (tenant_id, status);

CREATE TABLE auctions (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  name TEXT NOT NULL,
  mode TEXT NOT NULL CHECK (mode IN ('single_round_spot','multi_round_spot','emergency_reclear','scenario_replay')),
  status TEXT NOT NULL CHECK (status IN ('draft','open','closed','clearing_queued','clearing_running','infeasible','pending_approval','awarded','exported','cancelled','failed','archived')),
  bid_open_at TIMESTAMP NOT NULL,
  bid_close_at TIMESTAMP NOT NULL,
  auto_clear_on_close BOOLEAN NOT NULL DEFAULT FALSE,
  policy_id UUID NOT NULL REFERENCES auction_policies(id),
  source_replay_id UUID,
  clearing_job_id UUID,
  summary_metrics JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_by_user_id UUID NOT NULL REFERENCES users(id),
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now(),
  CHECK (bid_close_at > bid_open_at)
);
CREATE INDEX auctions_tenant_status_idx ON auctions (tenant_id, status, bid_close_at);
CREATE INDEX auctions_tenant_mode_idx ON auctions (tenant_id, mode, status);
CREATE INDEX auctions_tenant_policy_idx ON auctions (tenant_id, policy_id);

CREATE TABLE loads (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  auction_id UUID NOT NULL REFERENCES auctions(id),
  lane_id UUID NOT NULL REFERENCES lanes(id),
  external_ref TEXT NOT NULL,
  pickup_window_start TIMESTAMP NOT NULL,
  pickup_window_end TIMESTAMP NOT NULL,
  delivery_window_start TIMESTAMP NOT NULL,
  delivery_window_end TIMESTAMP NOT NULL,
  weight_lbs INTEGER NOT NULL CHECK (weight_lbs > 0),
  equipment_type TEXT NOT NULL,
  hazmat_required BOOLEAN NOT NULL DEFAULT FALSE,
  temperature_controlled BOOLEAN NOT NULL DEFAULT FALSE,
  service_priority TEXT NOT NULL CHECK (service_priority IN ('standard','expedited','critical')),
  status TEXT NOT NULL CHECK (status IN ('draft','eligible','bid_open','clearing','awarded','unassigned','cancelled','exported')),
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, auction_id, external_ref),
  CHECK (pickup_window_end > pickup_window_start),
  CHECK (delivery_window_end > delivery_window_start)
);
CREATE INDEX loads_tenant_auction_idx ON loads (tenant_id, auction_id, status);
CREATE INDEX loads_tenant_lane_idx ON loads (tenant_id, lane_id, pickup_window_start);

CREATE TABLE bids (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  auction_id UUID NOT NULL REFERENCES auctions(id),
  load_id UUID NOT NULL REFERENCES loads(id),
  carrier_id UUID NOT NULL REFERENCES carriers(id),
  idempotency_key TEXT NOT NULL,
  bid_amount NUMERIC(12,2) NOT NULL CHECK (bid_amount >= 0),
  currency TEXT NOT NULL DEFAULT 'USD',
  capacity_units INTEGER NOT NULL DEFAULT 1 CHECK (capacity_units > 0),
  service_score_snapshot NUMERIC(5,4) NOT NULL CHECK (service_score_snapshot BETWEEN 0 AND 1),
  submitted_at TIMESTAMP NOT NULL,
  valid_until TIMESTAMP,
  source TEXT NOT NULL CHECK (source IN ('ui','csv_import','api','webhook_engine','synthetic_replay')),
  status TEXT NOT NULL CHECK (status IN ('submitted','late','duplicate','withdrawn','eligible','rejected_policy','rejected_infeasible','awarded','expired')),
  rejection_reason TEXT,
  raw_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, auction_id, idempotency_key)
);
CREATE INDEX bids_tenant_auction_idx ON bids (tenant_id, auction_id, status);
CREATE INDEX bids_tenant_load_idx ON bids (tenant_id, load_id, bid_amount);
CREATE INDEX bids_tenant_carrier_idx ON bids (tenant_id, carrier_id, submitted_at DESC);

CREATE TABLE clearing_jobs (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  auction_id UUID NOT NULL REFERENCES auctions(id),
  status TEXT NOT NULL CHECK (status IN ('queued','running','succeeded','infeasible','failed','cancelled','retry_scheduled')),
  requested_by_user_id UUID NOT NULL REFERENCES users(id),
  policy_snapshot JSONB NOT NULL,
  input_snapshot JSONB NOT NULL,
  solver_backend TEXT NOT NULL CHECK (solver_backend IN ('minizinc','ortools','heuristic_baseline')),
  solver_version TEXT NOT NULL,
  solver_input_uri TEXT,
  solver_output_uri TEXT,
  infeasibility_snapshot JSONB NOT NULL DEFAULT '{}'::jsonb,
  relaxation_suggestions JSONB NOT NULL DEFAULT '[]'::jsonb,
  error_code TEXT,
  error_message TEXT,
  retry_count INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
  queued_at TIMESTAMP NOT NULL DEFAULT now(),
  started_at TIMESTAMP,
  finished_at TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE INDEX clearing_jobs_tenant_auction_idx ON clearing_jobs (tenant_id, auction_id, status);
CREATE INDEX clearing_jobs_tenant_status_idx ON clearing_jobs (tenant_id, status, queued_at);
CREATE INDEX clearing_jobs_tenant_finished_idx ON clearing_jobs (tenant_id, finished_at DESC);

CREATE TABLE awards (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  auction_id UUID NOT NULL REFERENCES auctions(id),
  load_id UUID NOT NULL REFERENCES loads(id),
  bid_id UUID NOT NULL REFERENCES bids(id),
  carrier_id UUID NOT NULL REFERENCES carriers(id),
  clearing_job_id UUID NOT NULL REFERENCES clearing_jobs(id),
  award_amount NUMERIC(12,2) NOT NULL CHECK (award_amount >= 0),
  service_score NUMERIC(5,4) NOT NULL CHECK (service_score BETWEEN 0 AND 1),
  total_score NUMERIC(12,6) NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('proposed','approval_required','approved','rejected_by_operator','published','exported','carrier_withdrawn','recleared')),
  approval_id UUID,
  explanation_snapshot JSONB NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX awards_published_load_idx ON awards (tenant_id, auction_id, load_id) WHERE status IN ('approved','published','exported');
CREATE INDEX awards_tenant_auction_idx ON awards (tenant_id, auction_id, status);
CREATE INDEX awards_tenant_carrier_idx ON awards (tenant_id, carrier_id, created_at DESC);

CREATE TABLE clearing_decisions (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  clearing_job_id UUID NOT NULL REFERENCES clearing_jobs(id),
  auction_id UUID NOT NULL REFERENCES auctions(id),
  bid_id UUID REFERENCES bids(id),
  load_id UUID REFERENCES loads(id),
  decision_type TEXT NOT NULL CHECK (decision_type IN ('awarded','rejected_policy','rejected_infeasible','unassigned','relaxation_suggested')),
  binding_constraints JSONB NOT NULL DEFAULT '[]'::jsonb,
  rejected_reason TEXT,
  infeasibility_details JSONB NOT NULL DEFAULT '{}'::jsonb,
  redaction_scope TEXT NOT NULL CHECK (redaction_scope IN ('operator','carrier','public')),
  explanation_snapshot JSONB NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE INDEX clearing_decisions_tenant_job_idx ON clearing_decisions (tenant_id, clearing_job_id, decision_type);
CREATE INDEX clearing_decisions_tenant_auction_idx ON clearing_decisions (tenant_id, auction_id, load_id);
CREATE INDEX clearing_decisions_tenant_bid_idx ON clearing_decisions (tenant_id, bid_id) WHERE bid_id IS NOT NULL;

CREATE TABLE report_exports (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  auction_id UUID NOT NULL REFERENCES auctions(id),
  clearing_job_id UUID REFERENCES clearing_jobs(id),
  source_type TEXT NOT NULL CHECK (source_type IN ('auction','clearing_job','replay_run','approval_request')),
  source_id UUID NOT NULL,
  format TEXT NOT NULL CHECK (format IN ('csv','json','html','pdf')),
  template_id TEXT NOT NULL,
  template_version TEXT NOT NULL,
  snapshot_json JSONB NOT NULL,
  artifact_uri TEXT,
  redaction_scope TEXT NOT NULL CHECK (redaction_scope IN ('operator','carrier','public')),
  status TEXT NOT NULL CHECK (status IN ('queued','rendered','failed','archived')),
  generated_by_user_id UUID REFERENCES users(id),
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE INDEX report_exports_tenant_auction_idx ON report_exports (tenant_id, auction_id, created_at DESC);
CREATE INDEX report_exports_tenant_source_idx ON report_exports (tenant_id, source_type, source_id);
CREATE INDEX report_exports_tenant_status_idx ON report_exports (tenant_id, status);

CREATE TABLE audit_events (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  actor_user_id UUID REFERENCES users(id),
  entity_type TEXT NOT NULL,
  entity_id UUID NOT NULL,
  event_type TEXT NOT NULL,
  event_payload JSONB NOT NULL,
  request_id TEXT,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE INDEX audit_events_tenant_entity_idx ON audit_events (tenant_id, entity_type, entity_id, created_at DESC);
CREATE INDEX audit_events_tenant_type_idx ON audit_events (tenant_id, event_type, created_at DESC);
CREATE INDEX audit_events_tenant_request_idx ON audit_events (tenant_id, request_id);

CREATE TABLE import_runs (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  auction_id UUID REFERENCES auctions(id),
  resource_type TEXT NOT NULL CHECK (resource_type IN ('carriers','lanes','loads','bids','replay_dataset')),
  source_filename TEXT NOT NULL,
  source_format TEXT NOT NULL CHECK (source_format IN ('csv','parquet','json_api')),
  source_object_uri TEXT,
  status TEXT NOT NULL CHECK (status IN ('uploaded','previewing','validated','committing','committed','failed','cancelled','quarantined')),
  mapping_snapshot JSONB NOT NULL DEFAULT '{}'::jsonb,
  validation_summary JSONB NOT NULL DEFAULT '{}'::jsonb,
  row_count INTEGER NOT NULL DEFAULT 0 CHECK (row_count >= 0),
  valid_row_count INTEGER NOT NULL DEFAULT 0 CHECK (valid_row_count >= 0),
  invalid_row_count INTEGER NOT NULL DEFAULT 0 CHECK (invalid_row_count >= 0),
  requested_by_user_id UUID NOT NULL REFERENCES users(id),
  previewed_at TIMESTAMP,
  committed_at TIMESTAMP,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE INDEX import_runs_tenant_status_idx ON import_runs (tenant_id, status, created_at DESC);
CREATE INDEX import_runs_tenant_auction_idx ON import_runs (tenant_id, auction_id, resource_type);

CREATE TABLE import_staging_rows (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  import_run_id UUID NOT NULL REFERENCES import_runs(id),
  auction_id UUID REFERENCES auctions(id),
  row_number INTEGER NOT NULL CHECK (row_number > 0),
  resource_type TEXT NOT NULL,
  raw_payload JSONB NOT NULL,
  normalized_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  status TEXT NOT NULL CHECK (status IN ('pending','valid','invalid','quarantined','committed','skipped')),
  idempotency_key TEXT,
  target_record_id UUID,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, import_run_id, row_number)
);
CREATE INDEX import_staging_tenant_run_idx ON import_staging_rows (tenant_id, import_run_id, status);
CREATE INDEX import_staging_tenant_idempotency_idx ON import_staging_rows (tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL;

CREATE TABLE import_row_errors (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  import_run_id UUID NOT NULL REFERENCES import_runs(id),
  staging_row_id UUID REFERENCES import_staging_rows(id),
  auction_id UUID REFERENCES auctions(id),
  row_number INTEGER NOT NULL,
  error_code TEXT NOT NULL,
  error_message TEXT NOT NULL,
  field_name TEXT,
  severity TEXT NOT NULL CHECK (severity IN ('warning','error','fatal')),
  quarantine_reason TEXT,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE INDEX import_errors_tenant_run_idx ON import_row_errors (tenant_id, import_run_id, severity);
CREATE INDEX import_errors_tenant_auction_idx ON import_row_errors (tenant_id, auction_id, error_code);

ALTER TABLE auctions ADD CONSTRAINT auctions_clearing_job_fk FOREIGN KEY (clearing_job_id) REFERENCES clearing_jobs(id);
