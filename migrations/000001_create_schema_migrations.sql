CREATE TABLE schema_migrations (
  version BIGINT PRIMARY KEY CHECK (version > 0),
  filename TEXT NOT NULL UNIQUE CHECK (filename ~ '^[0-9]{6}_[a-z][a-z0-9]*(_[a-z0-9]+)*\.sql$'),
  checksum_sha256 CHAR(64) NOT NULL CHECK (checksum_sha256 ~ '^[0-9a-f]{64}$'),
  applied_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
