-- 020_create_guest_groups.sql

CREATE TABLE guest_groups (
  id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name   TEXT NOT NULL,
  color  TEXT
);
