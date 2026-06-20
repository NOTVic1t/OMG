-- 015_create_audit_logs.sql

CREATE TABLE audit_logs (
  id              BIGSERIAL PRIMARY KEY,
  tenant_id       UUID REFERENCES tenants(id),
  user_id         UUID REFERENCES users(id),
  action          TEXT NOT NULL,
  resource_type   TEXT NOT NULL,
  resource_id     TEXT,
  old_data        JSONB,
  new_data        JSONB,
  ip_address      TEXT,
  user_agent      TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_al_tenant_id  ON audit_logs(tenant_id);
CREATE INDEX idx_al_created_at ON audit_logs(created_at);
