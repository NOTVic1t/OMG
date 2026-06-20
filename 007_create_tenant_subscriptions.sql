-- 007_create_tenant_subscriptions.sql

CREATE TABLE tenant_subscriptions (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id              UUID NOT NULL REFERENCES tenants(id),
  package_id             UUID NOT NULL REFERENCES packages(id),
  reseller_id            UUID REFERENCES resellers(id),
  billing_cycle          TEXT NOT NULL DEFAULT 'monthly'
                           CHECK (billing_cycle IN ('monthly', 'yearly', 'lifetime')),
  status                 TEXT NOT NULL DEFAULT 'active'
                           CHECK (status IN ('active', 'trialing', 'past_due', 'cancelled', 'paused')),
  current_period_start   TIMESTAMPTZ NOT NULL,
  current_period_end     TIMESTAMPTZ NOT NULL,
  payment_provider       TEXT,
  payment_ref            TEXT,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ts_tenant_id ON tenant_subscriptions(tenant_id);
