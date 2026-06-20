# P1A_DATABASE_MIGRATIONS.md
# Wedding Invitation SaaS Platform — Execution Package 1A: Database Migrations 001–017

> **Version:** 1.0.0
> **Authority:** IMPLEMENTATION_EXECUTION_PLAN.md §2 (Exact Migration Order) and §8 (Phase M1), both approved.
> **Source of truth for every table/column/constraint/policy below:** M1_CORE_MULTI_TENANT_FOUNDATION.md §13–§16, §25–§26 — itself a direct transcription of PHASE1_ARCHITECTURE.md §4.2–§4.3, §6.1.
> **Scope:** Migrations `001_create_tenants.sql` through `017_seed_free_package.sql` only. No migration outside this range is included.
> **Constraint discipline:** Every table, column, type, default, constraint, index, and RLS policy below is reproduced **exactly** as specified in M1_CORE_MULTI_TENANT_FOUNDATION.md — nothing is added, renamed, or omitted. No table, column, or policy beyond what M1 specifies is introduced. Where M1 itself recorded a column as nullable, optional, or without an index, that is preserved exactly (no index, constraint, or default is added on the assumption it "should" exist).
> **Environment assumption (not an architecture decision):** `gen_random_uuid()` requires the `pgcrypto` extension, enabled by default on Supabase projects (per the project setup in M0_FOUNDATION.md). No `CREATE EXTENSION` statement is included here since none is cited as a required migration step in M1; this is recorded as an environmental prerequisite, not a schema change.

---

## 1. Migration Execution Order

Strict, sequential, FK-respecting — identical to the order fixed in M1 §25 and restated in IMPLEMENTATION_EXECUTION_PLAN.md §2:

```
001_create_tenants.sql
002_create_users.sql
003_create_resellers.sql
004_create_reseller_tenants.sql
005_create_packages.sql
006_create_package_features.sql
007_create_tenant_subscriptions.sql
008_create_feature_flags.sql
009_create_invitation_themes.sql
010_create_invitations.sql
011_create_invitation_sections.sql
012_create_guests.sql
013_create_rsvp_responses.sql
014_create_orders.sql
015_create_audit_logs.sql
016_rls_core_policies.sql
017_seed_free_package.sql
```

No file may be applied before every file it depends on (§2) has already succeeded. This is a single linear chain — there is no valid parallel ordering within this range, because each migration from `002` onward references at least one table created earlier in the sequence.

---

## 2. Dependency Graph

```
001 tenants
  │
  ├──► 002 users  ──(FK: tenant_id)──┐  ──(FK: id → auth.users)
  │         │                         │
  │         ▼                         │
  │     003 resellers  ──(FK: owner_user_id)
  │         │
  │         ▼
  │     004 reseller_tenants  ──(FK: reseller_id, tenant_id)──► 001, 003
  │
005 packages
  │
  ├──► 006 package_features  ──(FK: package_id)──► 005
  │
  ├──► 007 tenant_subscriptions  ──(FK: tenant_id, package_id, reseller_id)──► 001, 005, 003
  │
008 feature_flags  ──(FK: tenant_id, created_by)──► 001, 002

009 invitation_themes  (no FK dependency)

010 invitations  ──(FK: tenant_id, created_by, theme_id)──► 001, 002, 009
  │
  ├──► 011 invitation_sections  ──(FK: invitation_id, ON DELETE CASCADE)──► 010
  │
  ├──► 012 guests  ──(FK: invitation_id ON DELETE CASCADE, tenant_id)──► 010, 001
  │         │
  │         ▼
  │     013 rsvp_responses  ──(FK: invitation_id ON DELETE CASCADE, guest_id)──► 010, 012
  │
014 orders  ──(FK: tenant_id, reseller_id, package_id)──► 001, 003, 005

015 audit_logs  ──(FK: tenant_id, user_id)──► 001, 002

016 rls_core_policies  ──(targets: 010 invitations, 012 guests, 013 rsvp_responses;
                          references: 004 reseller_tenants, inside the
                          reseller_client_read policy body)

017 seed_free_package  ──(targets: 005 packages, 006 package_features)
```

**Read order of the graph:** every arrow points from a dependency to its dependent. `001` and `005` and `009` are the three tables with zero incoming dependency, which is exactly why the linear order in §1 places `tenants` first, defers `packages`/`invitation_themes` only as far as their own first dependent requires, and why `010_create_invitations` cannot run before `002`, `005`'s sibling `009`, or `001` — it depends on all three at once.

---

## 3. File-by-File SQL Implementation

### `001_create_tenants.sql`
*Source: M1 §13 "tenants"*
```sql
CREATE TABLE tenants (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug        TEXT UNIQUE NOT NULL,
  name        TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'active'
                CHECK (status IN ('active', 'suspended', 'deleted')),
  metadata    JSONB NOT NULL DEFAULT '{}',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### `002_create_users.sql`
*Source: M1 §13 "users"; index per M1 §14*
```sql
CREATE TABLE users (
  id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  tenant_id   UUID NOT NULL REFERENCES tenants(id),
  email       TEXT NOT NULL,
  full_name   TEXT,
  avatar_url  TEXT,
  role        TEXT NOT NULL DEFAULT 'owner'
                CHECK (role IN ('owner', 'editor', 'viewer')),
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_users_tenant_id ON users(tenant_id);
```

### `003_create_resellers.sql`
*Source: M1 §13 "resellers"*
```sql
CREATE TABLE resellers (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name            TEXT NOT NULL,
  slug            TEXT UNIQUE NOT NULL,
  custom_domain   TEXT UNIQUE,
  owner_user_id   UUID NOT NULL REFERENCES users(id),
  commission_pct  NUMERIC(5,2) NOT NULL DEFAULT 20.00,
  branding        JSONB NOT NULL DEFAULT '{}',
  status          TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'suspended', 'pending')),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### `004_create_reseller_tenants.sql`
*Source: M1 §13 "reseller_tenants"*
```sql
CREATE TABLE reseller_tenants (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reseller_id   UUID NOT NULL REFERENCES resellers(id),
  tenant_id     UUID NOT NULL REFERENCES tenants(id),
  invited_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (reseller_id, tenant_id)
);
```

### `005_create_packages.sql`
*Source: M1 §13 "packages"*
```sql
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
```

### `006_create_package_features.sql`
*Source: M1 §13 "package_features"; index per M1 §14*
```sql
CREATE TABLE package_features (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  package_id    UUID NOT NULL REFERENCES packages(id),
  feature_key   TEXT NOT NULL,
  is_enabled    BOOLEAN NOT NULL DEFAULT TRUE,
  config        JSONB NOT NULL DEFAULT '{}',
  UNIQUE (package_id, feature_key)
);

CREATE INDEX idx_pf_package_id ON package_features(package_id);
```

### `007_create_tenant_subscriptions.sql`
*Source: M1 §13 "tenant_subscriptions"; index per M1 §14*
```sql
CREATE TABLE tenant_subscriptions (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id              UUID NOT NULL REFERENCES tenants(id),
  package_id             UUID NOT NULL REFERENCES packages(id),
  reseller_id            UUID REFERENCES resellers(id),
  billing_cycle          TEXT NOT NULL DEFAULT 'monthly'
                           CHECK (billing_cycle IN ('monthly', 'yearly', 'lifetime')),
  status                 TEXT NOT NULL DEFAULT 'active'
                           CHECK (status IN ('active', 'trialing', 'past_due', 'cancelled', 'paused')),
  current_period_start   TIMESTAMPTZ NOT NULL,
  current_period_end     TIMESTAMPTZ NOT NULL,
  payment_provider       TEXT,
  payment_ref            TEXT,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ts_tenant_id ON tenant_subscriptions(tenant_id);
```

### `008_create_feature_flags.sql`
*Source: M1 §13 "feature_flags"*
```sql
CREATE TABLE feature_flags (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID REFERENCES tenants(id),
  feature_key   TEXT NOT NULL,
  is_enabled    BOOLEAN NOT NULL DEFAULT TRUE,
  config        JSONB NOT NULL DEFAULT '{}',
  reason        TEXT,
  expires_at    TIMESTAMPTZ,
  created_by    UUID REFERENCES users(id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, feature_key)
);
```

### `009_create_invitation_themes.sql`
*Source: M1 §13 "invitation_themes"*
```sql
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
```

### `010_create_invitations.sql`
*Source: M1 §13 "invitations"; indexes per M1 §14*
```sql
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
```

### `011_create_invitation_sections.sql`
*Source: M1 §13 "invitation_sections"; index per M1 §14*
```sql
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
```

### `012_create_guests.sql`
*Source: M1 §13 "guests"; indexes per M1 §14*
```sql
CREATE TABLE guests (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id   UUID NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  tenant_id       UUID NOT NULL REFERENCES tenants(id),
  name            TEXT NOT NULL,
  phone           TEXT,
  email           TEXT,
  address         TEXT,
  group_label     TEXT,
  personal_link   TEXT UNIQUE,
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_guests_invitation_id ON guests(invitation_id);
CREATE INDEX idx_guests_tenant_id     ON guests(tenant_id);
```

### `013_create_rsvp_responses.sql`
*Source: M1 §13 "rsvp_responses"; index per M1 §14. No `tenant_id` column — confirmed absent per M1 §4/§10/§12, not added here.*
```sql
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
```

### `014_create_orders.sql`
*Source: M1 §13 "orders" (PHASE1 baseline shape — superseded by the full PHASE10 shape at migration `091`, not here); index per M1 §14*
```sql
CREATE TABLE orders (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           UUID NOT NULL REFERENCES tenants(id),
  reseller_id         UUID REFERENCES resellers(id),
  package_id          UUID NOT NULL REFERENCES packages(id),
  amount              NUMERIC(12,2) NOT NULL,
  currency            TEXT NOT NULL DEFAULT 'IDR',
  billing_cycle       TEXT NOT NULL,
  status              TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'paid', 'failed', 'refunded')),
  payment_provider    TEXT,
  payment_ref         TEXT,
  payment_data        JSONB NOT NULL DEFAULT '{}',
  commission_amount   NUMERIC(12,2),
  paid_at             TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_orders_tenant_id ON orders(tenant_id);
```

### `015_create_audit_logs.sql`
*Source: M1 §13 "audit_logs"; indexes per M1 §14*
```sql
CREATE TABLE audit_logs (
  id              BIGSERIAL PRIMARY KEY,
  tenant_id       UUID REFERENCES tenants(id),
  user_id         UUID REFERENCES users(id),
  action          TEXT NOT NULL,
  resource_type   TEXT NOT NULL,
  resource_id     TEXT,
  old_data        JSONB,
  new_data        JSONB,
  ip_address      TEXT,
  user_agent      TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_al_tenant_id  ON audit_logs(tenant_id);
CREATE INDEX idx_al_created_at ON audit_logs(created_at);
```

### `016_rls_core_policies.sql`
*Source: M1 §16 — the three named patterns, applied exactly to the three tables M1 §16 enables RLS on, with the join-adaptation M1 §12 specifies for `rsvp_responses` (no direct `tenant_id` column exists on that table). No RLS is enabled on any other table — this is a deliberate, cited boundary (M1 §16), not an omission.*
```sql
ALTER TABLE invitations    ENABLE ROW LEVEL SECURITY;
ALTER TABLE guests         ENABLE ROW LEVEL SECURITY;
ALTER TABLE rsvp_responses ENABLE ROW LEVEL SECURITY;

-- invitations: all three patterns apply (M1 §16)
CREATE POLICY "tenant_isolation" ON invitations
  USING (tenant_id = (auth.jwt() ->> 'tenant_id')::UUID);

CREATE POLICY "public_invitation_read" ON invitations
  FOR SELECT
  USING (status = 'published');

CREATE POLICY "reseller_client_read" ON invitations
  FOR SELECT
  USING (
    tenant_id IN (
      SELECT tenant_id FROM reseller_tenants
      WHERE reseller_id = (auth.jwt() ->> 'reseller_id')::UUID
    )
  );

-- guests: tenant_isolation only, direct-column form (M1 §16 — no public/reseller
-- read policy is specified for this table)
CREATE POLICY "tenant_isolation" ON guests
  USING (tenant_id = (auth.jwt() ->> 'tenant_id')::UUID);

-- rsvp_responses: tenant_isolation only, join-adapted form — this table has no
-- tenant_id column, so the policy must resolve tenant scope through invitations
-- (M1 §12's required adaptation, not a new policy)
CREATE POLICY "tenant_isolation" ON rsvp_responses
  USING (
    invitation_id IN (
      SELECT id FROM invitations
      WHERE tenant_id = (auth.jwt() ->> 'tenant_id')::UUID
    )
  );
```

### `017_seed_free_package.sql`
*Source: M1 §26 — exact tier values from PHASE1 §6.1, exact feature-flag values per M1's acceptance criteria*
```sql
INSERT INTO packages (
  name, slug, price_monthly, price_yearly, currency,
  max_invitations, max_guests, max_photos,
  is_active, is_reseller, sort_order
) VALUES (
  'Free', 'free', 0, 0, 'IDR',
  1, 50, 5,
  TRUE, FALSE, 0
);

INSERT INTO package_features (package_id, feature_key, is_enabled)
SELECT p.id, f.feature_key, f.is_enabled
FROM packages p
CROSS JOIN (VALUES
  ('countdown_timer',       TRUE),
  ('rsvp_open',             TRUE),
  ('music_player',          FALSE),
  ('gift_registry',         FALSE),
  ('custom_domain',         FALSE),
  ('guest_import_csv',      FALSE),
  ('export_rsvp_csv',       FALSE),
  ('analytics_basic',       FALSE),
  ('analytics_advanced',    FALSE),
  ('remove_platform_badge', FALSE),
  ('premium_themes',        FALSE),
  ('team_members',          FALSE)
) AS f(feature_key, is_enabled)
WHERE p.slug = 'free';
```
**Note (not a deviation, a recorded boundary):** only the twelve keys M1 §26 explicitly lists are seeded. The remaining `FEATURES` registry keys (`gallery_section`, `love_story_section`, `livestream_link`, `map_embed`, `rsvp_meal_choice`, `rsvp_plus_one`, `rsvp_wishes_wall`, `guest_personalized_link`, `guest_whatsapp_blast`, `custom_font`, `export_guest_csv`, `maintenance_mode`, `new_editor_ui`) are intentionally **not** seeded for the Free package here — per `resolveFeature()`'s own fourth priority tier (M1 §17), the absence of a `package_features` row resolves to "default: disabled," which is the correct outcome for all of them at the Free tier without needing an explicit row.

---

## 4. Validation Checklist

**Per-file structural validation (run after each individual migration):**
- [ ] `001`: `tenants` exists; `slug` rejects a duplicate insert; `status` rejects a value outside `active`/`suspended`/`deleted`.
- [ ] `002`: `users` exists; inserting a row with a `tenant_id` that doesn't exist in `tenants` fails; inserting a `role` outside `owner`/`editor`/`viewer` fails; deleting the referenced `auth.users` row cascades to delete the `users` row.
- [ ] `003`: `resellers` exists; `owner_user_id` must reference an existing `users.id`; `custom_domain` rejects a duplicate.
- [ ] `004`: `reseller_tenants` exists; a duplicate `(reseller_id, tenant_id)` pair is rejected.
- [ ] `005`: `packages` exists; no constraint beyond `NOT NULL`/defaults — confirm defaults populate correctly on a minimal insert.
- [ ] `006`: `package_features` exists; a duplicate `(package_id, feature_key)` pair is rejected.
- [ ] `007`: `tenant_subscriptions` exists; `billing_cycle`/`status` reject out-of-enum values; `current_period_start`/`end` reject `NULL` (no default exists, confirm `NOT NULL` is enforced).
- [ ] `008`: `feature_flags` exists; a duplicate `(tenant_id, feature_key)` pair is rejected, including the `tenant_id IS NULL` platform-wide case (confirm Postgres `UNIQUE` semantics treat repeated `NULL` `tenant_id` + same `feature_key` as a duplicate where intended, or document if the team's Postgres version treats `NULL`s as distinct — this is a standard Postgres `NULL`-in-`UNIQUE` behavior point worth confirming explicitly in this environment, not a deviation from M1).
- [ ] `009`: `invitation_themes` exists; `slug` rejects a duplicate.
- [ ] `010`: `invitations` exists; `theme_id` must reference an existing `invitation_themes.id`; `status` rejects out-of-enum values; `slug` rejects a duplicate.
- [ ] `011`: `invitation_sections` exists; deleting the parent `invitations` row cascades to delete its sections.
- [ ] `012`: `guests` exists; deleting the parent `invitations` row cascades to delete its guests; `personal_link` rejects a duplicate.
- [ ] `013`: `rsvp_responses` exists; deleting the parent `invitations` row cascades to delete its responses; `attendance` rejects out-of-enum values; **confirm no `tenant_id` column was added**.
- [ ] `014`: `orders` exists; `status` rejects out-of-enum values.
- [ ] `015`: `audit_logs` exists; `id` is `BIGSERIAL`, not `UUID` — confirm this is intentional and matches M1 §13 exactly (it is the one table in this batch with a different PK type).
- [ ] `016`: `SELECT relrowsecurity FROM pg_class WHERE relname IN ('invitations','guests','rsvp_responses')` returns `true` for exactly these three rows and **no others** in this migration batch; a cross-tenant `SELECT` against any of the three is denied in a test session; an anonymous `SELECT` against a `published` invitation succeeds; an anonymous `SELECT` against a `draft` invitation fails.
- [ ] `017`: exactly one `packages` row with `slug = 'free'` exists; exactly twelve `package_features` rows reference it, with the exact `is_enabled` values listed in §3.

**Whole-batch validation (run once, after `017`):**
- [ ] Total table count after this batch: 15 (matching M1 §13's exact count — `tenants`, `users`, `resellers`, `reseller_tenants`, `packages`, `package_features`, `tenant_subscriptions`, `feature_flags`, `invitation_themes`, `invitations`, `invitation_sections`, `guests`, `rsvp_responses`, `orders`, `audit_logs`).
- [ ] Total index count beyond PK/UNIQUE-implied indexes: 13 explicit `CREATE INDEX` statements across this batch (`idx_users_tenant_id`, `idx_pf_package_id`, `idx_ts_tenant_id`, `idx_inv_tenant_id`, `idx_inv_slug`, `idx_inv_status`, `idx_is_invitation_id`, `idx_guests_invitation_id`, `idx_guests_tenant_id`, `idx_rsvp_invitation_id`, `idx_orders_tenant_id`, `idx_al_tenant_id`, `idx_al_created_at`) — matching M1 §14 exactly.
- [ ] RLS policy count: exactly 5 (`tenant_isolation` ×3 — one per protected table — plus `public_invitation_read` and `reseller_client_read`, both on `invitations` only).
- [ ] No table outside the 15 above has RLS enabled.
- [ ] `npm run type-check`/Supabase type generation (if wired) succeeds against the new schema with no errors.

---

## 5. Rollback Strategy

**Context that shapes this strategy:** this is the platform's *first* migration batch — by definition, no production data can exist before it, and no later migration in this approved range (`001`–`037`, per IMPLEMENTATION_EXECUTION_PLAN.md §2) can have run yet either, since every one of them depends on this batch. Rollback here is therefore pure schema teardown, not data-preserving contraction — the expand/contract caution that governs later migrations (cited throughout M2/M5/M7) does not yet apply because there is nothing to preserve.

**Rule:** roll back in **exact reverse order** of §1, since every `DROP` must remove a dependent before the table it depends on.

```sql
-- Reverse-order rollback (017 → 001)

-- 017
DELETE FROM package_features WHERE package_id IN (SELECT id FROM packages WHERE slug = 'free');
DELETE FROM packages WHERE slug = 'free';

-- 016
DROP POLICY IF EXISTS "tenant_isolation" ON rsvp_responses;
DROP POLICY IF EXISTS "tenant_isolation" ON guests;
DROP POLICY IF EXISTS "reseller_client_read" ON invitations;
DROP POLICY IF EXISTS "public_invitation_read" ON invitations;
DROP POLICY IF EXISTS "tenant_isolation" ON invitations;
ALTER TABLE rsvp_responses DISABLE ROW LEVEL SECURITY;
ALTER TABLE guests         DISABLE ROW LEVEL SECURITY;
ALTER TABLE invitations    DISABLE ROW LEVEL SECURITY;

-- 015
DROP TABLE IF EXISTS audit_logs;

-- 014
DROP TABLE IF EXISTS orders;

-- 013
DROP TABLE IF EXISTS rsvp_responses;

-- 012
DROP TABLE IF EXISTS guests;

-- 011
DROP TABLE IF EXISTS invitation_sections;

-- 010
DROP TABLE IF EXISTS invitations;

-- 009
DROP TABLE IF EXISTS invitation_themes;

-- 008
DROP TABLE IF EXISTS feature_flags;

-- 007
DROP TABLE IF EXISTS tenant_subscriptions;

-- 006
DROP TABLE IF EXISTS package_features;

-- 005
DROP TABLE IF EXISTS packages;

-- 004
DROP TABLE IF EXISTS reseller_tenants;

-- 003
DROP TABLE IF EXISTS resellers;

-- 002
DROP TABLE IF EXISTS users;

-- 001
DROP TABLE IF EXISTS tenants;
```

**Partial-failure rule:** if migration `N` fails mid-application (e.g. a constraint typo caught at apply time), only migrations `001` through `N-1` have succeeded — roll back exactly that already-applied prefix, in reverse, using the corresponding statements above, fix the failing file, and re-run the full sequence from `001`. **Do not** attempt to resume from `N` alone on a partially-rolled-forward database; this batch has never been run in production before, so a full re-run from `001` carries no data-loss risk and is the safer path.

**What this rollback strategy explicitly does not cover (out of scope for this package):** any rollback of migrations `018` onward (M2's range) — those involve `ALTER TABLE` additions to tables this batch creates and, per the expand/contract philosophy cited from M2 onward, require a different, data-aware rollback approach once real rows may exist. This package's rollback plan is valid only for the `001`–`017` range, applied to an environment where this range has not yet been followed by any later migration.

---

## 6. Completion Criteria

- [ ] All 17 files applied, in order, to a local/staging Supabase instance with zero errors.
- [ ] §4's full validation checklist passes.
- [ ] The same 17 files applied, in order, to the staging Supabase project (per M0's provisioning), then to production, with the same validation checklist re-run against each environment.
- [ ] Rollback script (§5) tested once, end-to-end, against a disposable environment, before this package is considered production-ready.
- [ ] No table, column, index, or policy exists in the resulting schema beyond what §3 lists.

**Once every box above is checked, Execution Package 1B (the M2-range migrations, `018`–`033`) may begin.**

---

*End of P1A_DATABASE_MIGRATIONS.md*
