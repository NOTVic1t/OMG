-- 004_create_reseller_tenants.sql

CREATE TABLE reseller_tenants (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reseller_id   UUID NOT NULL REFERENCES resellers(id),
  tenant_id     UUID NOT NULL REFERENCES tenants(id),
  invited_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (reseller_id, tenant_id)
);
