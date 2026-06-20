-- 014_create_orders.sql

CREATE TABLE orders (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           UUID NOT NULL REFERENCES tenants(id),
  reseller_id         UUID REFERENCES resellers(id),
  package_id          UUID NOT NULL REFERENCES packages(id),
  amount              NUMERIC(12,2) NOT NULL,
  currency            TEXT NOT NULL DEFAULT 'IDR',
  billing_cycle       TEXT NOT NULL,
  status              TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'paid', 'failed', 'refunded')),
  payment_provider    TEXT,
  payment_ref         TEXT,
  payment_data        JSONB NOT NULL DEFAULT '{}',
  commission_amount   NUMERIC(12,2),
  paid_at             TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_orders_tenant_id ON orders(tenant_id);
