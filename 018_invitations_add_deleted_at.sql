-- 018_invitations_add_deleted_at.sql

ALTER TABLE invitations
  ADD COLUMN deleted_at TIMESTAMPTZ;
