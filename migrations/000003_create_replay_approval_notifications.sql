CREATE TABLE approval_requests (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  auction_id UUID NOT NULL REFERENCES auctions(id),
  award_id UUID REFERENCES awards(id),
  workflow_execution_id TEXT,
  status TEXT NOT NULL CHECK (status IN ('pending','approved','rejected','expired','workflow_failed','cancelled')),
  reason TEXT NOT NULL,
  payload_snapshot JSONB NOT NULL,
  requested_by_user_id UUID NOT NULL REFERENCES users(id),
  decided_by_user_id UUID REFERENCES users(id),
  requested_at TIMESTAMP NOT NULL DEFAULT now(),
  decided_at TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE INDEX approval_requests_tenant_auction_idx ON approval_requests (tenant_id, auction_id, status);
CREATE INDEX approval_requests_tenant_status_idx ON approval_requests (tenant_id, status, requested_at);
CREATE INDEX approval_requests_tenant_workflow_idx ON approval_requests (tenant_id, workflow_execution_id);
ALTER TABLE awards ADD CONSTRAINT awards_approval_fk FOREIGN KEY (approval_id) REFERENCES approval_requests(id);

CREATE TABLE replay_runs (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  name TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('draft','queued','running','succeeded','failed','cancelled')),
  dataset_uri TEXT NOT NULL,
  baseline_strategy TEXT NOT NULL CHECK (baseline_strategy IN ('lowest_cost','first_acceptable','incumbent_preference','historical_awards')),
  policy_id UUID NOT NULL REFERENCES auction_policies(id),
  metrics_snapshot JSONB NOT NULL DEFAULT '{}'::jsonb,
  started_at TIMESTAMP,
  finished_at TIMESTAMP,
  created_by_user_id UUID NOT NULL REFERENCES users(id),
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE INDEX replay_runs_tenant_status_idx ON replay_runs (tenant_id, status, created_at DESC);
CREATE INDEX replay_runs_tenant_policy_idx ON replay_runs (tenant_id, policy_id);
ALTER TABLE auctions ADD CONSTRAINT auctions_source_replay_fk FOREIGN KEY (source_replay_id) REFERENCES replay_runs(id);

CREATE TABLE notifications (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  user_id UUID REFERENCES users(id),
  event_type TEXT NOT NULL,
  template_id TEXT NOT NULL,
  channel TEXT NOT NULL CHECK (channel IN ('in_app','email','workflow')),
  urgency TEXT NOT NULL CHECK (urgency IN ('low','medium','high','critical')),
  payload_snapshot JSONB NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('queued','delivered','read','failed','suppressed','retry_scheduled','cancelled')),
  delivery_ref TEXT,
  retry_count INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
  next_attempt_at TIMESTAMP,
  delivered_at TIMESTAMP,
  read_at TIMESTAMP,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE INDEX notifications_tenant_user_idx ON notifications (tenant_id, user_id, status, created_at DESC);
CREATE INDEX notifications_tenant_event_idx ON notifications (tenant_id, event_type, created_at DESC);
CREATE INDEX notifications_tenant_status_idx ON notifications (tenant_id, status, next_attempt_at);

CREATE TABLE notification_preferences (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  user_id UUID NOT NULL REFERENCES users(id),
  event_type TEXT NOT NULL,
  channel TEXT NOT NULL CHECK (channel IN ('in_app','email','workflow')),
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  quiet_hours JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, user_id, event_type, channel)
);
CREATE INDEX notification_preferences_tenant_user_idx ON notification_preferences (tenant_id, user_id, enabled);
