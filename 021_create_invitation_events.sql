-- 021_create_invitation_events.sql

CREATE TABLE invitation_events (
  id              BIGSERIAL PRIMARY KEY,
  invitation_id   UUID NOT NULL REFERENCES invitations(id),
  tenant_id       UUID NOT NULL REFERENCES tenants(id),
  event_type      TEXT NOT NULL
                    CHECK (event_type IN (
                      'page_view', 'rsvp_open', 'rsvp_submit',
                      'guestbook_submit', 'music_play', 'gallery_view',
                      'qr_scan', 'gift_view', 'share_click'
                    )),
  guest_id        UUID REFERENCES guests(id),
  session_id      TEXT NOT NULL,
  metadata        JSONB NOT NULL DEFAULT '{}',
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
