-- 011_create_invitation_sections.sql

CREATE TABLE invitation_sections (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id   UUID NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  section_type    TEXT NOT NULL,
  sort_order      INTEGER NOT NULL DEFAULT 0,
  is_visible      BOOLEAN NOT NULL DEFAULT TRUE,
  content         JSONB NOT NULL DEFAULT '{}',
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_is_invitation_id ON invitation_sections(invitation_id);
