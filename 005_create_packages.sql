-- 005_create_packages.sql

CREATE TABLE packages (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name             TEXT NOT NULL,
  slug             TEXT UNIQUE NOT NULL,
  price_monthly    NUMERIC(10,2) NOT NULL DEFAULT 0,
  price_yearly     NUMERIC(10,2) NOT NULL DEFAULT 0,
  currency         TEXT NOT NULL DEFAULT 'IDR',
  max_invitations  INTEGER NOT NULL DEFAULT 1,
  max_guests       INTEGER NOT NULL DEFAULT 50,
  max_photos       INTEGER NOT NULL DEFAULT 5,
  is_active        BOOLEAN NOT NULL DEFAULT TRUE,
  is_reseller      BOOLEAN NOT NULL DEFAULT FALSE,
  sort_order       INTEGER NOT NULL DEFAULT 0,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
