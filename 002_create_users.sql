-- 002_create_users.sql

CREATE TABLE users (
  id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  tenant_id   UUID NOT NULL REFERENCES tenants(id),
  email       TEXT NOT NULL,
  full_name   TEXT,
  avatar_url  TEXT,
  role        TEXT NOT NULL DEFAULT 'owner'
                CHECK (role IN ('owner', 'editor', 'viewer')),
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_users_tenant_id ON users(tenant_id);
