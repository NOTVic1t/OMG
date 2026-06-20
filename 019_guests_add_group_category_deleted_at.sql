-- 019_guests_add_group_category_deleted_at.sql

ALTER TABLE guests
  ADD COLUMN group_id UUID,
  ADD COLUMN category_id UUID,
  ADD COLUMN deleted_at TIMESTAMPTZ;
