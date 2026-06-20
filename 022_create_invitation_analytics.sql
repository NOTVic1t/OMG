-- 022_create_invitation_analytics.sql

CREATE TABLE invitation_analytics (
  invitation_id        UUID NOT NULL REFERENCES invitations(id),
  tenant_id            UUID NOT NULL REFERENCES tenants(id),
  date                 DATE NOT NULL,
  views                INTEGER NOT NULL DEFAULT 0,
  unique_visitors      INTEGER NOT NULL DEFAULT 0,
  rsvp_attending       INTEGER NOT NULL DEFAULT 0,
  rsvp_not_attending   INTEGER NOT NULL DEFAULT 0,
  rsvp_maybe           INTEGER NOT NULL DEFAULT 0,
  guestbook_count      INTEGER NOT NULL DEFAULT 0,
  device_mobile        INTEGER NOT NULL DEFAULT 0,
  device_desktop       INTEGER NOT NULL DEFAULT 0,
  device_tablet        INTEGER NOT NULL DEFAULT 0,
  top_referrers        JSONB NOT NULL DEFAULT '[]',
  UNIQUE (invitation_id, date)
);
