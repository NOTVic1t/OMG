-- 013_create_rsvp_responses.sql

CREATE TABLE rsvp_responses (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id   UUID NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  guest_id        UUID REFERENCES guests(id),
  name            TEXT NOT NULL,
  email           TEXT,
  phone           TEXT,
  attendance      TEXT NOT NULL
                    CHECK (attendance IN ('attending', 'not_attending', 'maybe')),
  pax_count       INTEGER NOT NULL DEFAULT 1,
  message         TEXT,
  wishes          TEXT,
  submitted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ip_address      TEXT,
  metadata        JSONB NOT NULL DEFAULT '{}'
);

CREATE INDEX idx_rsvp_invitation_id ON rsvp_responses(invitation_id);
