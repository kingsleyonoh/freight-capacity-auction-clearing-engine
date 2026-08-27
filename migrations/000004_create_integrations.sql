CREATE TABLE integration_settings (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  integration_name TEXT NOT NULL CHECK (integration_name IN ('notification_hub','workflow_engine','webhook_engine')),
  enabled BOOLEAN NOT NULL DEFAULT FALSE,
  config JSONB NOT NULL DEFAULT '{}'::jsonb,
  last_health_status TEXT NOT NULL CHECK (last_health_status IN ('unknown','healthy','degraded','failed','disabled')),
  last_checked_at TIMESTAMP,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, integration_name)
);
CREATE INDEX integration_settings_tenant_state_idx ON integration_settings (tenant_id, enabled, last_health_status);

CREATE TABLE integration_outbox (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL REFERENCES tenants(id),
  integration_name TEXT NOT NULL CHECK (integration_name IN ('notification_hub','workflow_engine','webhook_engine')),
  event_type TEXT NOT NULL,
  target_url_env_var TEXT NOT NULL,
  payload JSONB NOT NULL,
  idempotency_key TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('queued','running','succeeded','failed','retry_scheduled','dead_lettered','cancelled','disabled')),
  retry_count INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
  next_attempt_at TIMESTAMP,
  last_error_code TEXT,
  last_error_message TEXT,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, integration_name, idempotency_key)
);
CREATE INDEX integration_outbox_tenant_status_idx ON integration_outbox (tenant_id, status, next_attempt_at);
CREATE INDEX integration_outbox_tenant_name_idx ON integration_outbox (tenant_id, integration_name, created_at DESC);
