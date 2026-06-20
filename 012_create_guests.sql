-- 012_create_guests.sql

CREATE TABLE guests (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id   UUID NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  tenant_id       UUID NOT NULL REFERENCES tenants(id),
  name            TEXT NOT NULL,
  phone           TEXT,
  email           TEXT,
  address         TEXT,
  group_label     TEXT,
  personal_link   TEXT UNIQUE,
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_guests_invitation_id ON guests(invitation_id);
CREATE INDEX idx_guests_tenant_id     ON guests(tenant_id);
