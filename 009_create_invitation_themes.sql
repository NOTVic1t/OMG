-- 009_create_invitation_themes.sql

CREATE TABLE invitation_themes (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name            TEXT NOT NULL,
  slug            TEXT UNIQUE NOT NULL,
  preview_url     TEXT,
  category        TEXT NOT NULL DEFAULT 'general',
  is_premium      BOOLEAN NOT NULL DEFAULT FALSE,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  config_schema   JSONB NOT NULL DEFAULT '{}',
  sort_order      INTEGER NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
