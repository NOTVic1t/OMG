-- 008_create_feature_flags.sql

CREATE TABLE feature_flags (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID REFERENCES tenants(id),
  feature_key   TEXT NOT NULL,
  is_enabled    BOOLEAN NOT NULL DEFAULT TRUE,
  config        JSONB NOT NULL DEFAULT '{}',
  reason        TEXT,
  expires_at    TIMESTAMPTZ,
  created_by    UUID REFERENCES users(id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, feature_key)
);
