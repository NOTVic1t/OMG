-- 010_create_invitations.sql

CREATE TABLE invitations (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         UUID NOT NULL REFERENCES tenants(id),
  created_by        UUID NOT NULL REFERENCES users(id),
  theme_id          UUID NOT NULL REFERENCES invitation_themes(id),
  slug              TEXT UNIQUE NOT NULL,
  title             TEXT NOT NULL,
  status            TEXT NOT NULL DEFAULT 'draft'
                      CHECK (status IN ('draft', 'published', 'archived')),
  event_date        DATE,
  event_time        TIME,
  event_venue       TEXT,
  event_address     TEXT,
  event_maps_url    TEXT,
  couple_data       JSONB NOT NULL DEFAULT '{}',
  customization     JSONB NOT NULL DEFAULT '{}',
  music_url         TEXT,
  is_rsvp_open      BOOLEAN NOT NULL DEFAULT TRUE,
  rsvp_deadline     DATE,
  meta_title        TEXT,
  meta_description  TEXT,
  view_count        INTEGER NOT NULL DEFAULT 0,
  published_at      TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_inv_tenant_id ON invitations(tenant_id);
CREATE INDEX idx_inv_slug      ON invitations(slug);
CREATE INDEX idx_inv_status    ON invitations(status);
