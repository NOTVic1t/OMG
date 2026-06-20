# PHASE2_DATABASE.md
# Wedding Invitation SaaS Platform — Complete Database Architecture

> **Version:** 1.0.0
> **Date:** 2026-06-12
> **Status:** Approved for Development
> **Depends on:** PHASE1_ARCHITECTURE.md

---

## Table of Contents

1. [Database Overview](#1-database-overview)
2. [Complete ERD](#2-complete-erd)
3. [Table Definitions](#3-table-definitions)
4. [Relationships](#4-relationships)
5. [Indexing Strategy](#5-indexing-strategy)
6. [Row Level Security Strategy](#6-row-level-security-strategy)
7. [Storage Bucket Structure](#7-storage-bucket-structure)
8. [Migration Plan](#8-migration-plan)
9. [Scalability Considerations](#9-scalability-considerations)

---

## 1. Database Overview

### 1.1 Architecture Philosophy

The database is designed as a **single PostgreSQL instance** (Supabase managed) with **Row-Level Security (RLS)** as the primary multi-tenancy isolation mechanism. Every table that holds tenant-scoped data carries a `tenant_id` UUID column that is enforced by RLS policies — no application-layer tenant filtering is relied upon as a security boundary.

The schema is organized into **10 logical domains**:

| Domain | Tables | Purpose |
|---|---|---|
| Identity & Tenancy | `tenants`, `users` | Core multi-tenant foundation |
| Reseller | `resellers`, `reseller_tenants`, `reseller_domains` | White-label reseller program |
| Packages & Features | `packages`, `package_features`, `feature_flags` | Subscription tiers + feature gating |
| Subscriptions & Payments | `tenant_subscriptions`, `orders`, `vouchers`, `voucher_redemptions` | Billing lifecycle |
| Invitations | `invitations`, `invitation_sections`, `invitation_themes` | Core product |
| Guest & RSVP | `guests`, `rsvp_responses`, `guestbook_entries` | Guest experience |
| Media | `invitation_gallery`, `invitation_music`, `invitation_gifts` | Rich content |
| QR System | `qr_codes`, `qr_checkins` | QR invite + check-in |
| Analytics | `invitation_analytics`, `invitation_events` | Metrics |
| Platform | `audit_logs`, `email_notifications`, `custom_domains` | Ops + observability |

### 1.2 Key Design Decisions

**UUID primary keys everywhere.** Avoids sequential ID enumeration attacks on public-facing invitation slugs and guest tokens.

**Soft delete via `deleted_at TIMESTAMPTZ`.** Applied to high-value records (invitations, guests, tenants) so data can be recovered and audit trails remain intact. Hard delete only on low-risk ephemeral records (analytics events are append-only; RSVP spam rows may be purged by cron).

**JSONB for flexible config.** Theme `customization`, package `config`, reseller `branding`, and couple data are JSONB. This avoids wide sparse tables for properties that vary by context, while keeping the relational core strict and indexed.

**Computed columns avoided in favor of application-layer aggregation.** `view_count` on invitations is a materialized counter incremented by trigger, not a live COUNT() — this protects against N+1 analytics queries on the public page.

**Temporal integrity.** All tables carry `created_at`. Tables with mutable state carry `updated_at` maintained by a shared `set_updated_at()` trigger function. Subscription and order records also carry business-meaningful timestamps (`paid_at`, `published_at`, `expires_at`, etc.).

---

## 2. Complete ERD

```
═══════════════════════════════════════════════════════════════════════════════
  IDENTITY & TENANCY
═══════════════════════════════════════════════════════════════════════════════

  ┌──────────────────┐         ┌──────────────────────────┐
  │     tenants      │ 1     ∞ │          users           │
  │──────────────────│─────────│──────────────────────────│
  │ id (PK)          │         │ id (PK) → auth.users     │
  │ slug             │         │ tenant_id (FK)           │
  │ name             │         │ email                    │
  │ status           │         │ full_name                │
  │ metadata JSONB   │         │ avatar_url               │
  │ deleted_at       │         │ role                     │
  └──────────────────┘         │ is_active                │
           │                   │ deleted_at               │
           │                   └──────────────────────────┘
           │
═══════════════════════════════════════════════════════════════════════════════
  RESELLER
═══════════════════════════════════════════════════════════════════════════════
           │
           │  ┌──────────────────┐         ┌───────────────────┐
           │  │    resellers     │ 1     ∞  │ reseller_tenants  │
           │  │──────────────────│──────────│───────────────────│
           │  │ id (PK)          │          │ id (PK)           │
           │  │ name             │          │ reseller_id (FK)  │
           │  │ slug             │          │ tenant_id (FK)    │
           │  │ owner_user_id FK │          │ invited_at        │
           │  │ commission_pct   │          └───────────────────┘
           │  │ branding JSONB   │
           │  │ status           │         ┌───────────────────┐
           │  │ deleted_at       │ 1     ∞ │ reseller_domains  │
           │  └──────────────────┘─────────│───────────────────│
           │                               │ id (PK)           │
           │                               │ reseller_id (FK)  │
           │                               │ domain            │
           │                               │ is_primary        │
           │                               │ verified_at       │
           │                               └───────────────────┘
           │
═══════════════════════════════════════════════════════════════════════════════
  PACKAGES & FEATURES
═══════════════════════════════════════════════════════════════════════════════
           │
           │  ┌──────────────────┐         ┌───────────────────┐
           │  │    packages      │ 1     ∞  │ package_features  │
           │  │──────────────────│──────────│───────────────────│
           │  │ id (PK)          │          │ id (PK)           │
           │  │ name             │          │ package_id (FK)   │
           │  │ slug             │          │ feature_key       │
           │  │ price_monthly    │          │ is_enabled        │
           │  │ price_yearly     │          │ config JSONB      │
           │  │ currency         │          └───────────────────┘
           │  │ max_invitations  │
           │  │ max_guests       │         ┌───────────────────┐
           │  │ max_photos       │         │  feature_flags    │
           │  │ max_team_members │         │───────────────────│
           │  │ is_active        │         │ id (PK)           │
           │  │ is_reseller      │         │ tenant_id (FK)?   │
           │  └──────────────────┘         │ feature_key       │
           │                               │ is_enabled        │
           │                               │ config JSONB      │
           │                               │ reason            │
           │                               │ expires_at        │
           │                               │ created_by (FK)   │
           │                               └───────────────────┘
           │
═══════════════════════════════════════════════════════════════════════════════
  SUBSCRIPTIONS & PAYMENTS
═══════════════════════════════════════════════════════════════════════════════
           │
           ├──────────────────────────────────────────────────────────────────
           │  ┌────────────────────────┐
           │  │  tenant_subscriptions  │
           │  │────────────────────────│
           │  │ id (PK)               │
           │  │ tenant_id (FK)        │◄──── tenants
           │  │ package_id (FK)       │◄──── packages
           │  │ reseller_id (FK)?     │◄──── resellers
           │  │ billing_cycle         │
           │  │ status                │
           │  │ current_period_start  │
           │  │ current_period_end    │
           │  │ trial_ends_at         │
           │  │ cancelled_at          │
           │  │ payment_provider      │
           │  │ payment_ref           │
           │  └────────────────────────┘
           │
           │  ┌────────────────────────┐     ┌──────────────────────┐
           │  │        orders          │     │       vouchers        │
           │  │────────────────────────│     │──────────────────────│
           │  │ id (PK)               │     │ id (PK)              │
           │  │ tenant_id (FK)        │     │ code (UNIQUE)        │
           │  │ reseller_id (FK)?     │     │ discount_type        │
           │  │ package_id (FK)       │     │ discount_value       │
           │  │ voucher_id (FK)?      │     │ max_uses             │
           │  │ amount_gross          │     │ used_count           │
           │  │ amount_discount       │     │ valid_from           │
           │  │ amount_net            │     │ valid_until          │
           │  │ currency              │     │ applicable_packages  │
           │  │ billing_cycle         │     │   JSONB              │
           │  │ status                │     │ reseller_id (FK)?    │
           │  │ payment_provider      │     │ is_active            │
           │  │ payment_ref           │     └──────────────────────┘
           │  │ payment_data JSONB    │            │ 1
           │  │ commission_amount     │            │
           │  │ paid_at              │     ┌───────▼──────────────┐
           │  └────────────────────────┘     │ voucher_redemptions  │
           │                               │──────────────────────│
           │                               │ id (PK)              │
           │                               │ voucher_id (FK)      │
           │                               │ order_id (FK)        │
           │                               │ tenant_id (FK)       │
           │                               │ redeemed_at          │
           │                               └──────────────────────┘
           │
═══════════════════════════════════════════════════════════════════════════════
  INVITATIONS
═══════════════════════════════════════════════════════════════════════════════
           │
           └──────────────────────────────────────────────────────────────────
              ┌──────────────────────┐         ┌────────────────────────┐
              │  invitation_themes   │ 1     ∞  │      invitations       │
              │──────────────────────│──────────│────────────────────────│
              │ id (PK)             │          │ id (PK)               │
              │ name                │          │ tenant_id (FK)        │
              │ slug                │          │ created_by (FK)       │
              │ preview_url         │          │ theme_id (FK)         │
              │ category            │          │ slug (UNIQUE)         │
              │ is_premium          │          │ title                 │
              │ is_active           │          │ status                │
              │ config_schema JSONB │          │ event_date            │
              │ sort_order          │          │ event_time            │
              └──────────────────────┘          │ event_venue          │
                                               │ event_address         │
                                               │ event_maps_url        │
                                               │ couple_data JSONB     │
                                               │ customization JSONB   │
                                               │ is_rsvp_open          │
                                               │ rsvp_deadline         │
                                               │ password_hash         │
                                               │ meta_title            │
                                               │ meta_description      │
                                               │ og_image_url          │
                                               │ view_count            │
                                               │ published_at          │
                                               │ deleted_at            │
                                               └────────────────────────┘
                                                          │ 1
                        ┌─────────────────────────────────┼──────────────────┐
                        │                                 │                  │
                        ▼ ∞                               ▼ ∞               ▼ ∞
          ┌─────────────────────────┐   ┌─────────────────────┐   ┌─────────────────────┐
          │   invitation_sections   │   │  invitation_gallery  │   │  invitation_music   │
          │─────────────────────────│   │─────────────────────│   │─────────────────────│
          │ id (PK)                │   │ id (PK)             │   │ id (PK)             │
          │ invitation_id (FK)     │   │ invitation_id (FK)  │   │ invitation_id (FK)  │
          │ section_type           │   │ tenant_id (FK)      │   │ tenant_id (FK)      │
          │ sort_order             │   │ file_url            │   │ title               │
          │ is_visible             │   │ thumbnail_url       │   │ artist              │
          │ content JSONB          │   │ caption             │   │ file_url            │
          └─────────────────────────┘   │ sort_order          │   │ source_type         │
                                        │ is_visible          │   │ is_active           │
                                        └─────────────────────┘   └─────────────────────┘

                        ▼ ∞
          ┌───────────────────────────────────────────────────────────────────────┐
          │                          invitation_gifts                              │
          │───────────────────────────────────────────────────────────────────────│
          │ id (PK) │ invitation_id (FK) │ tenant_id (FK) │ gift_type             │
          │ bank_name │ account_number │ account_name │ qris_image_url           │
          │ e_wallet_type │ is_visible │ sort_order                               │
          └───────────────────────────────────────────────────────────────────────┘

═══════════════════════════════════════════════════════════════════════════════
  GUEST & RSVP
═══════════════════════════════════════════════════════════════════════════════

  invitations ──────────────────────────────────────────────────────
                    │ 1                          │ 1
                    ▼ ∞                          ▼ ∞
          ┌────────────────────┐       ┌──────────────────────┐
          │       guests       │       │    rsvp_responses    │
          │────────────────────│       │──────────────────────│
          │ id (PK)           │       │ id (PK)             │
          │ invitation_id (FK)│       │ invitation_id (FK)  │
          │ tenant_id (FK)    │       │ guest_id (FK)?      │
          │ name              │       │ name                │
          │ phone             │       │ email               │
          │ email             │       │ phone               │
          │ address           │       │ attendance          │
          │ group_label       │       │ pax_count           │
          │ personal_token    │       │ message             │
          │ is_invited        │       │ wishes              │
          │ notes             │       │ submitted_at        │
          │ deleted_at        │       │ ip_address          │
          └────────────────────┘       │ metadata JSONB      │
                    │ 1                └──────────────────────┘
                    ▼ ∞
          ┌────────────────────┐
          │  guestbook_entries │
          │────────────────────│
          │ id (PK)           │
          │ invitation_id (FK)│
          │ guest_id (FK)?    │
          │ name              │
          │ message           │
          │ is_approved       │
          │ submitted_at      │
          └────────────────────┘

═══════════════════════════════════════════════════════════════════════════════
  QR SYSTEM
═══════════════════════════════════════════════════════════════════════════════

  invitations ──────────────────────────────────────────────────────
                    │ 1                          │ 1
                    ▼ ∞                          ▼ ∞
          ┌────────────────────┐       ┌──────────────────────┐
          │      qr_codes      │       │     qr_checkins      │
          │────────────────────│       │──────────────────────│
          │ id (PK)           │       │ id (PK)             │
          │ invitation_id (FK)│       │ qr_code_id (FK)     │
          │ tenant_id (FK)    │       │ guest_id (FK)?      │
          │ guest_id (FK)?    │       │ checked_in_by (FK)  │
          │ token (UNIQUE)    │       │ checked_in_at       │
          │ qr_image_url      │       │ device_info JSONB   │
          │ type              │       │ notes               │
          │ scan_count        │       └──────────────────────┘
          │ last_scanned_at   │
          └────────────────────┘

═══════════════════════════════════════════════════════════════════════════════
  ANALYTICS
═══════════════════════════════════════════════════════════════════════════════

  invitations ──────────────────────────────────────────────────────
                    │ 1                          │ 1
                    ▼ ∞                          ▼ ∞
          ┌──────────────────────────┐  ┌──────────────────────────┐
          │   invitation_analytics   │  │    invitation_events     │
          │──────────────────────────│  │──────────────────────────│
          │ id (PK)                 │  │ id (PK)                 │
          │ invitation_id (FK)      │  │ invitation_id (FK)      │
          │ tenant_id (FK)          │  │ tenant_id (FK)          │
          │ date (DATE)             │  │ event_type              │
          │ views                   │  │ guest_id (FK)?          │
          │ unique_visitors         │  │ session_id              │
          │ rsvp_attending          │  │ metadata JSONB          │
          │ rsvp_not_attending      │  │ created_at              │
          │ rsvp_maybe              │  └──────────────────────────┘
          │ device_mobile           │
          │ device_desktop          │
          │ device_tablet           │
          │ top_referrers JSONB     │
          └──────────────────────────┘

═══════════════════════════════════════════════════════════════════════════════
  PLATFORM
═══════════════════════════════════════════════════════════════════════════════

  ┌──────────────────────────┐     ┌──────────────────────────┐
  │       audit_logs         │     │   email_notifications    │
  │──────────────────────────│     │──────────────────────────│
  │ id (BIGSERIAL PK)       │     │ id (PK)                 │
  │ tenant_id (FK)?         │     │ tenant_id (FK)?         │
  │ user_id (FK)?           │     │ invitation_id (FK)?     │
  │ action                  │     │ recipient_email         │
  │ resource_type           │     │ template_key            │
  │ resource_id             │     │ status                  │
  │ old_data JSONB          │     │ sent_at                 │
  │ new_data JSONB          │     │ metadata JSONB          │
  │ ip_address              │     └──────────────────────────┘
  │ user_agent              │
  │ created_at              │     ┌──────────────────────────┐
  └──────────────────────────┘     │     custom_domains       │
                                   │──────────────────────────│
                                   │ id (PK)                 │
                                   │ tenant_id (FK)          │
                                   │ reseller_id (FK)?       │
                                   │ domain (UNIQUE)         │
                                   │ type                    │
                                   │ verified_at             │
                                   │ ssl_provisioned_at      │
                                   │ status                  │
                                   └──────────────────────────┘
```

---

## 3. Table Definitions

### 3.1 Shared Trigger Function

Applied to all tables that need `updated_at` auto-maintenance:

```sql
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

---

### Domain 1: Identity & Tenancy

#### `tenants`

The root entity for multi-tenancy. Every user, invitation, and subscription belongs to a tenant.

```sql
CREATE TABLE tenants (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  slug          TEXT        NOT NULL UNIQUE,
  name          TEXT        NOT NULL,
  status        TEXT        NOT NULL DEFAULT 'active'
                            CHECK (status IN ('active', 'suspended', 'deleted')),
  metadata      JSONB       NOT NULL DEFAULT '{}',
  -- metadata shape: { locale, timezone, contact_email, branding: { logo_url, primary_color } }
  deleted_at    TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_tenants_updated_at
  BEFORE UPDATE ON tenants
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | PK, auto-generated |
| `slug` | TEXT | Subdomain identifier, URL-safe, immutable after creation |
| `name` | TEXT | Display name |
| `status` | TEXT | `active` \| `suspended` \| `deleted` |
| `metadata` | JSONB | Locale, timezone, branding overrides |
| `deleted_at` | TIMESTAMPTZ | Soft delete; null = active |

---

#### `users`

Maps to `auth.users` (Supabase Auth). One user belongs to exactly one tenant in Phase 1. Team-invite flow creates a new user row in the invitee's tenant.

```sql
CREATE TABLE users (
  id            UUID        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  tenant_id     UUID        NOT NULL REFERENCES tenants(id),
  email         TEXT        NOT NULL,
  full_name     TEXT,
  avatar_url    TEXT,
  role          TEXT        NOT NULL DEFAULT 'owner'
                            CHECK (role IN (
                              'super_admin', 'reseller_admin',
                              'owner', 'editor', 'viewer'
                            )),
  is_active     BOOLEAN     NOT NULL DEFAULT TRUE,
  last_login_at TIMESTAMPTZ,
  deleted_at    TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_users_updated_at
  BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | PK, mirrors `auth.users.id` |
| `tenant_id` | UUID | FK → `tenants.id` |
| `role` | TEXT | Enforced by JWT custom claim + RLS |
| `is_active` | BOOLEAN | Revocable access without deleting auth record |
| `deleted_at` | TIMESTAMPTZ | Soft delete |

---

### Domain 2: Reseller

#### `resellers`

A reseller is a business entity operating the platform under their own brand. One user (`owner_user_id`) owns a reseller account.

```sql
CREATE TABLE resellers (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name             TEXT        NOT NULL,
  slug             TEXT        NOT NULL UNIQUE,
  owner_user_id    UUID        NOT NULL REFERENCES users(id),
  commission_pct   NUMERIC(5,2) NOT NULL DEFAULT 20.00
                               CHECK (commission_pct >= 0 AND commission_pct <= 100),
  branding         JSONB       NOT NULL DEFAULT '{}',
  -- branding shape: { logo_url, favicon_url, primary_color, secondary_color,
  --                   company_name, support_email, support_phone,
  --                   footer_text, hide_platform_badge }
  status           TEXT        NOT NULL DEFAULT 'pending'
                               CHECK (status IN ('active', 'suspended', 'pending')),
  approved_at      TIMESTAMPTZ,
  approved_by      UUID        REFERENCES users(id),
  notes            TEXT,
  deleted_at       TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_resellers_updated_at
  BEFORE UPDATE ON resellers
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

---

#### `reseller_tenants`

Join table linking resellers to the tenants (clients) they manage.

```sql
CREATE TABLE reseller_tenants (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reseller_id   UUID        NOT NULL REFERENCES resellers(id),
  tenant_id     UUID        NOT NULL REFERENCES tenants(id),
  invited_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (reseller_id, tenant_id)
);
```

---

#### `reseller_domains`

Stores custom domains claimed by resellers. Supports multiple domains per reseller (one primary, rest aliases).

```sql
CREATE TABLE reseller_domains (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reseller_id   UUID        NOT NULL REFERENCES resellers(id) ON DELETE CASCADE,
  domain        TEXT        NOT NULL UNIQUE,
  is_primary    BOOLEAN     NOT NULL DEFAULT FALSE,
  dns_verified  BOOLEAN     NOT NULL DEFAULT FALSE,
  verified_at   TIMESTAMPTZ,
  ssl_status    TEXT        NOT NULL DEFAULT 'pending'
                            CHECK (ssl_status IN ('pending', 'active', 'failed')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_reseller_domains_updated_at
  BEFORE UPDATE ON reseller_domains
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

---

### Domain 3: Packages & Features

#### `packages`

Defines subscription tiers. All quota limits live here. `-1` means unlimited.

```sql
CREATE TABLE packages (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name              TEXT        NOT NULL,
  slug              TEXT        NOT NULL UNIQUE,
  description       TEXT,
  price_monthly     NUMERIC(12,2) NOT NULL DEFAULT 0,
  price_yearly      NUMERIC(12,2) NOT NULL DEFAULT 0,
  currency          TEXT        NOT NULL DEFAULT 'IDR',
  max_invitations   INTEGER     NOT NULL DEFAULT 1,
  max_guests        INTEGER     NOT NULL DEFAULT 50,
  max_photos        INTEGER     NOT NULL DEFAULT 5,
  max_team_members  INTEGER     NOT NULL DEFAULT 1,
  max_music_tracks  INTEGER     NOT NULL DEFAULT 1,
  is_active         BOOLEAN     NOT NULL DEFAULT TRUE,
  is_reseller       BOOLEAN     NOT NULL DEFAULT FALSE,
  is_featured       BOOLEAN     NOT NULL DEFAULT FALSE,
  trial_days        INTEGER     NOT NULL DEFAULT 0,
  sort_order        INTEGER     NOT NULL DEFAULT 0,
  metadata          JSONB       NOT NULL DEFAULT '{}',
  -- metadata shape: { badge_label, highlight_color, cta_text }
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_packages_updated_at
  BEFORE UPDATE ON packages
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

---

#### `package_features`

Maps which features are enabled for each package, and optionally how (via `config` JSONB).

```sql
CREATE TABLE package_features (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  package_id    UUID        NOT NULL REFERENCES packages(id) ON DELETE CASCADE,
  feature_key   TEXT        NOT NULL,
  is_enabled    BOOLEAN     NOT NULL DEFAULT TRUE,
  config        JSONB       NOT NULL DEFAULT '{}',
  -- config examples:
  --   music_player:          { max_tracks: 3 }
  --   analytics_advanced:    { retention_days: 90 }
  --   custom_domain:         {}
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (package_id, feature_key)
);
```

---

#### `feature_flags`

Runtime feature overrides. `tenant_id IS NULL` = platform-wide flag affecting all tenants.
`tenant_id IS NOT NULL` = per-tenant override (can enable a feature above their package, or kill-switch one).

```sql
CREATE TABLE feature_flags (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID        REFERENCES tenants(id) ON DELETE CASCADE,
  feature_key   TEXT        NOT NULL,
  is_enabled    BOOLEAN     NOT NULL DEFAULT TRUE,
  config        JSONB       NOT NULL DEFAULT '{}',
  reason        TEXT,
  expires_at    TIMESTAMPTZ,
  created_by    UUID        REFERENCES users(id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, feature_key)
);

CREATE TRIGGER trg_feature_flags_updated_at
  BEFORE UPDATE ON feature_flags
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

---

### Domain 4: Subscriptions & Payments

#### `tenant_subscriptions`

Active subscription per tenant. A tenant has at most one `active` or `trialing` subscription at any time; old ones move to `cancelled`.

```sql
CREATE TABLE tenant_subscriptions (
  id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            UUID        NOT NULL REFERENCES tenants(id),
  package_id           UUID        NOT NULL REFERENCES packages(id),
  reseller_id          UUID        REFERENCES resellers(id),
  billing_cycle        TEXT        NOT NULL DEFAULT 'monthly'
                                   CHECK (billing_cycle IN ('monthly', 'yearly', 'lifetime')),
  status               TEXT        NOT NULL DEFAULT 'trialing'
                                   CHECK (status IN (
                                     'active', 'trialing', 'past_due',
                                     'cancelled', 'paused', 'expired'
                                   )),
  current_period_start TIMESTAMPTZ NOT NULL,
  current_period_end   TIMESTAMPTZ NOT NULL,
  trial_ends_at        TIMESTAMPTZ,
  cancelled_at         TIMESTAMPTZ,
  cancel_reason        TEXT,
  payment_provider     TEXT        CHECK (payment_provider IN ('midtrans', 'stripe', 'manual')),
  payment_ref          TEXT,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_tenant_subscriptions_updated_at
  BEFORE UPDATE ON tenant_subscriptions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

---

#### `vouchers`

Discount codes, either platform-wide or scoped to a reseller (for resellers creating their own promo codes).

```sql
CREATE TABLE vouchers (
  id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  code                 TEXT        NOT NULL UNIQUE,
  description          TEXT,
  discount_type        TEXT        NOT NULL
                                   CHECK (discount_type IN ('percentage', 'fixed')),
  discount_value       NUMERIC(12,2) NOT NULL,
  currency             TEXT        DEFAULT 'IDR',
  max_uses             INTEGER,    -- null = unlimited
  used_count           INTEGER     NOT NULL DEFAULT 0,
  valid_from           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  valid_until          TIMESTAMPTZ,
  applicable_packages  JSONB       NOT NULL DEFAULT '[]',
  -- JSON array of package slugs; empty = applies to all
  applicable_cycles    JSONB       NOT NULL DEFAULT '[]',
  -- JSON array: ["monthly", "yearly"]
  reseller_id          UUID        REFERENCES resellers(id),
  is_active            BOOLEAN     NOT NULL DEFAULT TRUE,
  created_by           UUID        REFERENCES users(id),
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_vouchers_updated_at
  BEFORE UPDATE ON vouchers
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

---

#### `voucher_redemptions`

Append-only ledger of every voucher use.

```sql
CREATE TABLE voucher_redemptions (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  voucher_id    UUID        NOT NULL REFERENCES vouchers(id),
  order_id      UUID        NOT NULL REFERENCES orders(id),
  tenant_id     UUID        NOT NULL REFERENCES tenants(id),
  discount_applied NUMERIC(12,2) NOT NULL,
  redeemed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

---

#### `orders`

Payment records. One order = one billing event. Commission is frozen at insert time.

```sql
CREATE TABLE orders (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         UUID        NOT NULL REFERENCES tenants(id),
  reseller_id       UUID        REFERENCES resellers(id),
  package_id        UUID        NOT NULL REFERENCES packages(id),
  subscription_id   UUID        REFERENCES tenant_subscriptions(id),
  voucher_id        UUID        REFERENCES vouchers(id),
  amount_gross      NUMERIC(12,2) NOT NULL,
  amount_discount   NUMERIC(12,2) NOT NULL DEFAULT 0,
  amount_net        NUMERIC(12,2) NOT NULL,
  currency          TEXT        NOT NULL DEFAULT 'IDR',
  billing_cycle     TEXT        NOT NULL,
  status            TEXT        NOT NULL DEFAULT 'pending'
                                CHECK (status IN (
                                  'pending', 'paid', 'failed', 'refunded', 'expired'
                                )),
  payment_provider  TEXT        CHECK (payment_provider IN ('midtrans', 'stripe', 'manual')),
  payment_ref       TEXT,
  payment_data      JSONB       NOT NULL DEFAULT '{}',
  commission_amount NUMERIC(12,2),
  paid_at           TIMESTAMPTZ,
  expires_at        TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_orders_updated_at
  BEFORE UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

---

### Domain 5: Invitations

#### `invitation_themes`

Template library managed by platform admin. Themes define the visual skeleton; `config_schema` describes which properties are user-customizable.

```sql
CREATE TABLE invitation_themes (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name           TEXT        NOT NULL,
  slug           TEXT        NOT NULL UNIQUE,
  preview_url    TEXT,
  thumbnail_url  TEXT,
  category       TEXT        NOT NULL DEFAULT 'wedding'
                             CHECK (category IN ('wedding', 'engagement', 'general')),
  is_premium     BOOLEAN     NOT NULL DEFAULT FALSE,
  is_active      BOOLEAN     NOT NULL DEFAULT TRUE,
  config_schema  JSONB       NOT NULL DEFAULT '{}',
  -- Describes editable fields: colors, fonts, section visibility defaults
  sort_order     INTEGER     NOT NULL DEFAULT 0,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_invitation_themes_updated_at
  BEFORE UPDATE ON invitation_themes
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

---

#### `invitations`

Core product record. One invitation = one public wedding page.

```sql
CREATE TABLE invitations (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        UUID        NOT NULL REFERENCES tenants(id),
  created_by       UUID        NOT NULL REFERENCES users(id),
  theme_id         UUID        NOT NULL REFERENCES invitation_themes(id),
  slug             TEXT        NOT NULL UNIQUE,
  title            TEXT        NOT NULL,
  status           TEXT        NOT NULL DEFAULT 'draft'
                               CHECK (status IN ('draft', 'published', 'archived')),
  event_date       DATE,
  event_time       TIME,
  event_venue      TEXT,
  event_address    TEXT,
  event_maps_url   TEXT,
  event_maps_embed TEXT,
  couple_data      JSONB       NOT NULL DEFAULT '{}',
  -- { groom_name, bride_name, groom_photo_url, bride_photo_url,
  --   groom_parents, bride_parents, love_story }
  customization    JSONB       NOT NULL DEFAULT '{}',
  -- Stores all property-panel overrides keyed by theme config_schema fields
  is_rsvp_open     BOOLEAN     NOT NULL DEFAULT TRUE,
  rsvp_deadline    DATE,
  password_hash    TEXT,
  -- If set, public page requires a passphrase (bcrypt)
  meta_title       TEXT,
  meta_description TEXT,
  og_image_url     TEXT,
  view_count       INTEGER     NOT NULL DEFAULT 0,
  published_at     TIMESTAMPTZ,
  deleted_at       TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_invitations_updated_at
  BEFORE UPDATE ON invitations
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

---

#### `invitation_sections`

Ordered content blocks within an invitation. Section types are fixed; content schema varies by `section_type`.

```sql
CREATE TABLE invitation_sections (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id  UUID        NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  section_type   TEXT        NOT NULL
                             CHECK (section_type IN (
                               'hero', 'couple', 'event_details', 'countdown',
                               'gallery', 'love_story', 'music', 'rsvp',
                               'guestbook', 'gift', 'livestream', 'closing'
                             )),
  sort_order     INTEGER     NOT NULL DEFAULT 0,
  is_visible     BOOLEAN     NOT NULL DEFAULT TRUE,
  content        JSONB       NOT NULL DEFAULT '{}',
  -- Section-specific overrides on top of invitation.customization
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (invitation_id, section_type)
);

CREATE TRIGGER trg_invitation_sections_updated_at
  BEFORE UPDATE ON invitation_sections
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

---

#### `invitation_gallery`

Photo gallery items attached to an invitation.

```sql
CREATE TABLE invitation_gallery (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id  UUID        NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  tenant_id      UUID        NOT NULL REFERENCES tenants(id),
  file_url       TEXT        NOT NULL,
  thumbnail_url  TEXT,
  caption        TEXT,
  sort_order     INTEGER     NOT NULL DEFAULT 0,
  is_visible     BOOLEAN     NOT NULL DEFAULT TRUE,
  file_size_kb   INTEGER,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

---

#### `invitation_music`

Background music tracks. Multiple tracks stored; only `is_active = TRUE` plays on page load.

```sql
CREATE TABLE invitation_music (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id  UUID        NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  tenant_id      UUID        NOT NULL REFERENCES tenants(id),
  title          TEXT        NOT NULL,
  artist         TEXT,
  file_url       TEXT,
  -- null if source_type = 'youtube' or 'spotify'
  external_url   TEXT,
  -- YouTube / Spotify link if not self-hosted
  source_type    TEXT        NOT NULL DEFAULT 'upload'
                             CHECK (source_type IN ('upload', 'youtube', 'spotify')),
  is_active      BOOLEAN     NOT NULL DEFAULT TRUE,
  duration_sec   INTEGER,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_invitation_music_updated_at
  BEFORE UPDATE ON invitation_music
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

---

#### `invitation_gifts`

Bank transfer accounts and QRIS codes for digital gift / dana amplop sections.

```sql
CREATE TABLE invitation_gifts (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id    UUID        NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  tenant_id        UUID        NOT NULL REFERENCES tenants(id),
  gift_type        TEXT        NOT NULL
                               CHECK (gift_type IN ('bank_transfer', 'qris', 'e_wallet')),
  label            TEXT,
  -- Display label e.g. "BCA - Groom", "Dana - Bride"
  bank_name        TEXT,
  account_number   TEXT,
  account_name     TEXT,
  qris_image_url   TEXT,
  e_wallet_type    TEXT
                   CHECK (e_wallet_type IN ('gopay', 'ovo', 'dana', 'shopeepay', 'other')),
  e_wallet_number  TEXT,
  is_visible       BOOLEAN     NOT NULL DEFAULT TRUE,
  sort_order       INTEGER     NOT NULL DEFAULT 0,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_invitation_gifts_updated_at
  BEFORE UPDATE ON invitation_gifts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

---

### Domain 6: Guest & RSVP

#### `guests`

Pre-seeded guest list. A `personal_token` generates a personalized invitation URL.

```sql
CREATE TABLE guests (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id   UUID        NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  tenant_id       UUID        NOT NULL REFERENCES tenants(id),
  name            TEXT        NOT NULL,
  phone           TEXT,
  email           TEXT,
  address         TEXT,
  group_label     TEXT,
  -- free text e.g. "Keluarga", "Teman Kampus", "Rekan Kerja"
  personal_token  TEXT        UNIQUE DEFAULT gen_random_uuid()::TEXT,
  -- Used in URL: /inv/[slug]?t=[personal_token]
  is_invited      BOOLEAN     NOT NULL DEFAULT TRUE,
  notes           TEXT,
  imported_from   TEXT,
  -- 'csv' | 'manual'
  deleted_at      TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_guests_updated_at
  BEFORE UPDATE ON guests
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

---

#### `rsvp_responses`

Immutable append-only RSVP submissions. Duplicate control is handled at application layer (one response per `guest_id`), not DB constraint, to allow corrections.

```sql
CREATE TABLE rsvp_responses (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id  UUID        NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  guest_id       UUID        REFERENCES guests(id),
  -- null if open RSVP (no guest list)
  name           TEXT        NOT NULL,
  email          TEXT,
  phone          TEXT,
  attendance     TEXT        NOT NULL
                             CHECK (attendance IN ('attending', 'not_attending', 'maybe')),
  pax_count      INTEGER     NOT NULL DEFAULT 1 CHECK (pax_count >= 1),
  meal_choice    TEXT,
  message        TEXT,
  wishes         TEXT,
  submitted_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ip_address     INET,
  user_agent     TEXT,
  metadata       JSONB       NOT NULL DEFAULT '{}'
);
```

---

#### `guestbook_entries`

Public wishes / pesan & kesan wall. Moderated via `is_approved`.

```sql
CREATE TABLE guestbook_entries (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id  UUID        NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  tenant_id      UUID        NOT NULL REFERENCES tenants(id),
  guest_id       UUID        REFERENCES guests(id),
  name           TEXT        NOT NULL,
  message        TEXT        NOT NULL,
  is_approved    BOOLEAN     NOT NULL DEFAULT TRUE,
  -- FALSE = requires manual moderation (feature flag: guestbook_moderation)
  submitted_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ip_address     INET
);
```

---

### Domain 7: QR System

#### `qr_codes`

Generated QR codes. `type = 'invitation'` is the main shareable QR; `type = 'guest'` is a personalized QR per guest for check-in.

```sql
CREATE TABLE qr_codes (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id   UUID        NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  tenant_id       UUID        NOT NULL REFERENCES tenants(id),
  guest_id        UUID        REFERENCES guests(id),
  token           TEXT        NOT NULL UNIQUE DEFAULT gen_random_uuid()::TEXT,
  qr_image_url    TEXT,
  type            TEXT        NOT NULL DEFAULT 'invitation'
                              CHECK (type IN ('invitation', 'guest', 'checkin_only')),
  scan_count      INTEGER     NOT NULL DEFAULT 0,
  last_scanned_at TIMESTAMPTZ,
  expires_at      TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

---

#### `qr_checkins`

Scan log for check-in events. `checked_in_by` is the user (usher/admin) who scanned.

```sql
CREATE TABLE qr_checkins (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  qr_code_id      UUID        NOT NULL REFERENCES qr_codes(id),
  tenant_id       UUID        NOT NULL REFERENCES tenants(id),
  guest_id        UUID        REFERENCES guests(id),
  checked_in_by   UUID        REFERENCES users(id),
  checked_in_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  device_info     JSONB       NOT NULL DEFAULT '{}',
  -- { user_agent, ip_address, location_hint }
  notes           TEXT
);
```

---

### Domain 8: Analytics

#### `invitation_analytics`

Daily roll-up per invitation. One row per `(invitation_id, date)` pair. Written by a nightly Supabase Edge Function aggregating raw events.

```sql
CREATE TABLE invitation_analytics (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id     UUID        NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  tenant_id         UUID        NOT NULL REFERENCES tenants(id),
  date              DATE        NOT NULL,
  views             INTEGER     NOT NULL DEFAULT 0,
  unique_visitors   INTEGER     NOT NULL DEFAULT 0,
  rsvp_attending    INTEGER     NOT NULL DEFAULT 0,
  rsvp_not_attending INTEGER    NOT NULL DEFAULT 0,
  rsvp_maybe        INTEGER     NOT NULL DEFAULT 0,
  guestbook_count   INTEGER     NOT NULL DEFAULT 0,
  device_mobile     INTEGER     NOT NULL DEFAULT 0,
  device_desktop    INTEGER     NOT NULL DEFAULT 0,
  device_tablet     INTEGER     NOT NULL DEFAULT 0,
  top_referrers     JSONB       NOT NULL DEFAULT '[]',
  -- [{ referrer: "wa.me", count: 42 }, ...]
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (invitation_id, date)
);

CREATE TRIGGER trg_invitation_analytics_updated_at
  BEFORE UPDATE ON invitation_analytics
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

---

#### `invitation_events`

Raw event stream. Append-only. Used to power real-time analytics and feed the nightly aggregation job.

```sql
CREATE TABLE invitation_events (
  id             BIGSERIAL   PRIMARY KEY,
  invitation_id  UUID        NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  tenant_id      UUID        NOT NULL REFERENCES tenants(id),
  event_type     TEXT        NOT NULL
                             CHECK (event_type IN (
                               'page_view', 'rsvp_open', 'rsvp_submit',
                               'guestbook_submit', 'music_play', 'gallery_view',
                               'qr_scan', 'gift_view', 'share_click'
                             )),
  guest_id       UUID        REFERENCES guests(id),
  session_id     TEXT,
  metadata       JSONB       NOT NULL DEFAULT '{}',
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

> **Note:** `invitation_events` uses `BIGSERIAL` (not UUID) for primary key — it is a high-volume append-only log, not a referenced entity. Sequential IDs keep insert performance optimal and simplify range-based archival.

---

### Domain 9: Platform Operations

#### `audit_logs`

Immutable record of all admin and destructive actions. Never updated or soft-deleted.

```sql
CREATE TABLE audit_logs (
  id             BIGSERIAL   PRIMARY KEY,
  tenant_id      UUID        REFERENCES tenants(id),
  user_id        UUID        REFERENCES users(id),
  actor_role     TEXT,
  -- snapshot of role at time of action
  action         TEXT        NOT NULL,
  -- e.g. 'invitation.publish', 'tenant.suspend', 'impersonation.start'
  resource_type  TEXT        NOT NULL,
  resource_id    TEXT,
  old_data       JSONB,
  new_data       JSONB,
  ip_address     INET,
  user_agent     TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

---

#### `email_notifications`

Outbound email ledger. Decoupled from Resend; this table tracks what was requested and its delivery status.

```sql
CREATE TABLE email_notifications (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        UUID        REFERENCES tenants(id),
  invitation_id    UUID        REFERENCES invitations(id),
  recipient_email  TEXT        NOT NULL,
  recipient_name   TEXT,
  template_key     TEXT        NOT NULL,
  -- e.g. 'rsvp_confirmation', 'payment_receipt', 'invitation_published'
  status           TEXT        NOT NULL DEFAULT 'pending'
                               CHECK (status IN ('pending', 'sent', 'failed', 'bounced')),
  provider_ref     TEXT,
  -- Resend message ID
  error_message    TEXT,
  sent_at          TIMESTAMPTZ,
  metadata         JSONB       NOT NULL DEFAULT '{}',
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

---

#### `custom_domains`

Tenant-level custom domains (Premium+). Distinct from `reseller_domains` which are reseller portal domains.

```sql
CREATE TABLE custom_domains (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           UUID        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  reseller_id         UUID        REFERENCES resellers(id),
  domain              TEXT        NOT NULL UNIQUE,
  type                TEXT        NOT NULL DEFAULT 'invitation'
                                  CHECK (type IN ('invitation', 'dashboard')),
  dns_verified        BOOLEAN     NOT NULL DEFAULT FALSE,
  verified_at         TIMESTAMPTZ,
  ssl_provisioned_at  TIMESTAMPTZ,
  status              TEXT        NOT NULL DEFAULT 'pending'
                                  CHECK (status IN ('pending', 'active', 'failed', 'removed')),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_custom_domains_updated_at
  BEFORE UPDATE ON custom_domains
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

---

## 4. Relationships

### 4.1 Foreign Key Map

```
auth.users.id             ←── users.id
tenants.id                ←── users.tenant_id
tenants.id                ←── reseller_tenants.tenant_id
tenants.id                ←── tenant_subscriptions.tenant_id
tenants.id                ←── feature_flags.tenant_id (nullable)
tenants.id                ←── invitations.tenant_id
tenants.id                ←── guests.tenant_id
tenants.id                ←── invitation_gallery.tenant_id
tenants.id                ←── invitation_music.tenant_id
tenants.id                ←── invitation_gifts.tenant_id
tenants.id                ←── guestbook_entries.tenant_id
tenants.id                ←── qr_codes.tenant_id
tenants.id                ←── qr_checkins.tenant_id
tenants.id                ←── invitation_analytics.tenant_id
tenants.id                ←── invitation_events.tenant_id
tenants.id                ←── orders.tenant_id
tenants.id                ←── voucher_redemptions.tenant_id
tenants.id                ←── custom_domains.tenant_id
tenants.id                ←── audit_logs.tenant_id (nullable)
tenants.id                ←── email_notifications.tenant_id (nullable)

users.id                  ←── resellers.owner_user_id
users.id                  ←── resellers.approved_by (nullable)
users.id                  ←── feature_flags.created_by (nullable)
users.id                  ←── invitations.created_by
users.id                  ←── qr_checkins.checked_in_by (nullable)
users.id                  ←── audit_logs.user_id (nullable)
users.id                  ←── vouchers.created_by (nullable)

resellers.id              ←── reseller_tenants.reseller_id
resellers.id              ←── reseller_domains.reseller_id
resellers.id              ←── tenant_subscriptions.reseller_id (nullable)
resellers.id              ←── orders.reseller_id (nullable)
resellers.id              ←── vouchers.reseller_id (nullable)
resellers.id              ←── custom_domains.reseller_id (nullable)

packages.id               ←── package_features.package_id
packages.id               ←── tenant_subscriptions.package_id
packages.id               ←── orders.package_id

tenant_subscriptions.id   ←── orders.subscription_id (nullable)

vouchers.id               ←── voucher_redemptions.voucher_id
vouchers.id               ←── orders.voucher_id (nullable)

orders.id                 ←── voucher_redemptions.order_id

invitation_themes.id      ←── invitations.theme_id

invitations.id            ←── invitation_sections.invitation_id
invitations.id            ←── invitation_gallery.invitation_id
invitations.id            ←── invitation_music.invitation_id
invitations.id            ←── invitation_gifts.invitation_id
invitations.id            ←── guests.invitation_id
invitations.id            ←── rsvp_responses.invitation_id
invitations.id            ←── guestbook_entries.invitation_id
invitations.id            ←── qr_codes.invitation_id
invitations.id            ←── invitation_analytics.invitation_id
invitations.id            ←── invitation_events.invitation_id
invitations.id            ←── email_notifications.invitation_id (nullable)

guests.id                 ←── rsvp_responses.guest_id (nullable)
guests.id                 ←── guestbook_entries.guest_id (nullable)
guests.id                 ←── qr_codes.guest_id (nullable)
guests.id                 ←── qr_checkins.guest_id (nullable)
guests.id                 ←── invitation_events.guest_id (nullable)

qr_codes.id               ←── qr_checkins.qr_code_id
```

---

## 5. Indexing Strategy

### 5.1 All Indexes

```sql
-- ============================================================
-- TENANTS
-- ============================================================
CREATE INDEX idx_tenants_slug      ON tenants(slug);
CREATE INDEX idx_tenants_status    ON tenants(status) WHERE deleted_at IS NULL;

-- ============================================================
-- USERS
-- ============================================================
CREATE INDEX idx_users_tenant_id   ON users(tenant_id);
CREATE INDEX idx_users_email       ON users(email);
CREATE INDEX idx_users_role        ON users(role);

-- ============================================================
-- RESELLERS
-- ============================================================
CREATE INDEX idx_resellers_slug    ON resellers(slug);
CREATE INDEX idx_resellers_status  ON resellers(status);
CREATE INDEX idx_reseller_tenants_reseller  ON reseller_tenants(reseller_id);
CREATE INDEX idx_reseller_tenants_tenant    ON reseller_tenants(tenant_id);
CREATE INDEX idx_reseller_domains_domain    ON reseller_domains(domain);
CREATE INDEX idx_reseller_domains_reseller  ON reseller_domains(reseller_id);

-- ============================================================
-- PACKAGES & FEATURES
-- ============================================================
CREATE INDEX idx_packages_slug        ON packages(slug);
CREATE INDEX idx_packages_active      ON packages(is_active, sort_order);
CREATE INDEX idx_package_features_pkg ON package_features(package_id);
CREATE INDEX idx_feature_flags_tenant ON feature_flags(tenant_id, feature_key);
-- Partial index for platform-wide flags
CREATE INDEX idx_feature_flags_platform ON feature_flags(feature_key)
  WHERE tenant_id IS NULL;

-- ============================================================
-- SUBSCRIPTIONS & PAYMENTS
-- ============================================================
CREATE INDEX idx_subscriptions_tenant    ON tenant_subscriptions(tenant_id);
CREATE INDEX idx_subscriptions_status    ON tenant_subscriptions(status);
-- Lookup: find active subscription for a tenant (hot path)
CREATE INDEX idx_subscriptions_tenant_active ON tenant_subscriptions(tenant_id, status)
  WHERE status IN ('active', 'trialing');

CREATE INDEX idx_orders_tenant_id    ON orders(tenant_id);
CREATE INDEX idx_orders_status       ON orders(status);
CREATE INDEX idx_orders_payment_ref  ON orders(payment_ref) WHERE payment_ref IS NOT NULL;
CREATE INDEX idx_orders_reseller_id  ON orders(reseller_id) WHERE reseller_id IS NOT NULL;
CREATE INDEX idx_orders_paid_at      ON orders(paid_at DESC) WHERE paid_at IS NOT NULL;

CREATE INDEX idx_vouchers_code       ON vouchers(code);
CREATE INDEX idx_vouchers_active     ON vouchers(is_active, valid_from, valid_until);
CREATE INDEX idx_voucher_red_voucher ON voucher_redemptions(voucher_id);
CREATE INDEX idx_voucher_red_tenant  ON voucher_redemptions(tenant_id);

-- ============================================================
-- INVITATIONS
-- ============================================================
CREATE INDEX idx_inv_tenant_id       ON invitations(tenant_id);
CREATE INDEX idx_inv_slug            ON invitations(slug);
CREATE INDEX idx_inv_status          ON invitations(status) WHERE deleted_at IS NULL;
-- For admin listing by tenant + status
CREATE INDEX idx_inv_tenant_status   ON invitations(tenant_id, status)
  WHERE deleted_at IS NULL;
CREATE INDEX idx_inv_published_at    ON invitations(published_at DESC)
  WHERE status = 'published';

CREATE INDEX idx_inv_sections_inv    ON invitation_sections(invitation_id, sort_order);
CREATE INDEX idx_gallery_inv         ON invitation_gallery(invitation_id, sort_order);
CREATE INDEX idx_music_inv           ON invitation_music(invitation_id);
CREATE INDEX idx_gifts_inv           ON invitation_gifts(invitation_id, sort_order);

-- ============================================================
-- GUESTS & RSVP
-- ============================================================
CREATE INDEX idx_guests_invitation   ON guests(invitation_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_guests_tenant       ON guests(tenant_id);
CREATE INDEX idx_guests_token        ON guests(personal_token);
CREATE INDEX idx_guests_phone        ON guests(phone) WHERE phone IS NOT NULL;

CREATE INDEX idx_rsvp_invitation     ON rsvp_responses(invitation_id);
CREATE INDEX idx_rsvp_guest          ON rsvp_responses(guest_id) WHERE guest_id IS NOT NULL;
CREATE INDEX idx_rsvp_attendance     ON rsvp_responses(invitation_id, attendance);
CREATE INDEX idx_rsvp_submitted      ON rsvp_responses(submitted_at DESC);

CREATE INDEX idx_guestbook_inv       ON guestbook_entries(invitation_id, submitted_at DESC);
CREATE INDEX idx_guestbook_approved  ON guestbook_entries(invitation_id, is_approved)
  WHERE is_approved = TRUE;

-- ============================================================
-- QR SYSTEM
-- ============================================================
CREATE INDEX idx_qr_codes_invitation ON qr_codes(invitation_id);
CREATE INDEX idx_qr_codes_token      ON qr_codes(token);
CREATE INDEX idx_qr_codes_guest      ON qr_codes(guest_id) WHERE guest_id IS NOT NULL;
CREATE INDEX idx_qr_checkins_qr      ON qr_checkins(qr_code_id);
CREATE INDEX idx_qr_checkins_inv     ON qr_checkins(tenant_id, checked_in_at DESC);

-- ============================================================
-- ANALYTICS
-- ============================================================
-- Hot path: fetch analytics for an invitation in a date range
CREATE INDEX idx_analytics_inv_date  ON invitation_analytics(invitation_id, date DESC);
CREATE INDEX idx_analytics_tenant    ON invitation_analytics(tenant_id, date DESC);

-- invitation_events is high-volume; index only the lookup axes needed
CREATE INDEX idx_events_invitation   ON invitation_events(invitation_id, created_at DESC);
CREATE INDEX idx_events_type         ON invitation_events(event_type, created_at DESC);
-- Partial: only page_view events for visitor counting
CREATE INDEX idx_events_pageview     ON invitation_events(invitation_id, created_at)
  WHERE event_type = 'page_view';

-- ============================================================
-- PLATFORM
-- ============================================================
CREATE INDEX idx_audit_tenant        ON audit_logs(tenant_id, created_at DESC);
CREATE INDEX idx_audit_user          ON audit_logs(user_id, created_at DESC);
CREATE INDEX idx_audit_action        ON audit_logs(action, resource_type);

CREATE INDEX idx_email_notif_tenant  ON email_notifications(tenant_id, created_at DESC);
CREATE INDEX idx_email_notif_status  ON email_notifications(status)
  WHERE status = 'pending';

CREATE INDEX idx_custom_domains_dom  ON custom_domains(domain);
CREATE INDEX idx_custom_domains_ten  ON custom_domains(tenant_id);
```

---

## 6. Row Level Security Strategy

### 6.1 Overview

Four security principals exist in the system:

| Principal | JWT `role` claim | Access scope |
|---|---|---|
| Super Admin | `super_admin` | All rows, all tables (via service role client — bypasses RLS) |
| Reseller Admin | `reseller_admin` | Own reseller data + linked tenant data |
| Tenant Owner/Editor/Viewer | `owner` \| `editor` \| `viewer` | Own tenant data only |
| Public (unauthenticated) | — | Published invitations, RSVP submit only |

**Super Admin** always uses the Supabase `service_role` client server-side and never hits RLS. RLS policies are therefore written for the other three principals + public.

### 6.2 Shared Helper Functions

```sql
-- Returns the tenant_id from the JWT claims
CREATE OR REPLACE FUNCTION auth_tenant_id()
RETURNS UUID AS $$
  SELECT NULLIF(auth.jwt() ->> 'tenant_id', '')::UUID;
$$ LANGUAGE SQL STABLE;

-- Returns the role from the JWT claims
CREATE OR REPLACE FUNCTION auth_role()
RETURNS TEXT AS $$
  SELECT auth.jwt() ->> 'role';
$$ LANGUAGE SQL STABLE;

-- Returns the reseller_id from the JWT claims (null for non-resellers)
CREATE OR REPLACE FUNCTION auth_reseller_id()
RETURNS UUID AS $$
  SELECT NULLIF(auth.jwt() ->> 'reseller_id', '')::UUID;
$$ LANGUAGE SQL STABLE;
```

### 6.3 RLS Policies by Table

#### `tenants`

```sql
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;

-- Tenant members can read their own tenant
CREATE POLICY "tenant_read_own" ON tenants
  FOR SELECT
  USING (id = auth_tenant_id());

-- Reseller admins can read their linked tenants
CREATE POLICY "reseller_read_clients" ON tenants
  FOR SELECT
  USING (
    id IN (
      SELECT tenant_id FROM reseller_tenants
      WHERE reseller_id = auth_reseller_id()
    )
  );

-- Only app-layer (service role) can INSERT/UPDATE/DELETE tenants
```

---

#### `users`

```sql
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

-- Users can read members of their own tenant
CREATE POLICY "users_read_own_tenant" ON users
  FOR SELECT
  USING (tenant_id = auth_tenant_id());

-- Users can update their own profile
CREATE POLICY "users_update_own" ON users
  FOR UPDATE
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

-- Only owners can insert new users (team invite flow goes through service role)
```

---

#### `invitations`

```sql
ALTER TABLE invitations ENABLE ROW LEVEL SECURITY;

-- Tenant members read their own invitations
CREATE POLICY "inv_read_own_tenant" ON invitations
  FOR SELECT
  USING (tenant_id = auth_tenant_id() AND deleted_at IS NULL);

-- Reseller admins read their clients' invitations
CREATE POLICY "inv_read_reseller_clients" ON invitations
  FOR SELECT
  USING (
    deleted_at IS NULL AND
    tenant_id IN (
      SELECT tenant_id FROM reseller_tenants
      WHERE reseller_id = auth_reseller_id()
    )
  );

-- Public read: published invitations (no auth required)
CREATE POLICY "inv_public_read" ON invitations
  FOR SELECT
  USING (status = 'published' AND deleted_at IS NULL);

-- Owners and editors can insert
CREATE POLICY "inv_insert_tenant" ON invitations
  FOR INSERT
  WITH CHECK (
    tenant_id = auth_tenant_id() AND
    auth_role() IN ('owner', 'editor')
  );

-- Owners and editors can update (publish restricted at app layer to owner only)
CREATE POLICY "inv_update_tenant" ON invitations
  FOR UPDATE
  USING (
    tenant_id = auth_tenant_id() AND
    auth_role() IN ('owner', 'editor') AND
    deleted_at IS NULL
  );

-- Soft delete: owners only (implemented as UPDATE deleted_at)
```

---

#### `guests`

```sql
ALTER TABLE guests ENABLE ROW LEVEL SECURITY;

-- Tenant members manage their own guests
CREATE POLICY "guests_crud_own_tenant" ON guests
  FOR ALL
  USING (tenant_id = auth_tenant_id() AND deleted_at IS NULL)
  WITH CHECK (tenant_id = auth_tenant_id());

-- Reseller admin read
CREATE POLICY "guests_read_reseller" ON guests
  FOR SELECT
  USING (
    tenant_id IN (
      SELECT tenant_id FROM reseller_tenants
      WHERE reseller_id = auth_reseller_id()
    )
  );
```

---

#### `rsvp_responses`

```sql
ALTER TABLE rsvp_responses ENABLE ROW LEVEL SECURITY;

-- Public can INSERT (submit RSVP) — rate-limited at API layer
CREATE POLICY "rsvp_public_insert" ON rsvp_responses
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM invitations
      WHERE id = invitation_id
        AND status = 'published'
        AND is_rsvp_open = TRUE
        AND (rsvp_deadline IS NULL OR rsvp_deadline >= CURRENT_DATE)
    )
  );

-- Tenant members can read RSVP responses for their invitations
CREATE POLICY "rsvp_read_own_tenant" ON rsvp_responses
  FOR SELECT
  USING (
    invitation_id IN (
      SELECT id FROM invitations WHERE tenant_id = auth_tenant_id()
    )
  );

-- Reseller admins can read
CREATE POLICY "rsvp_read_reseller" ON rsvp_responses
  FOR SELECT
  USING (
    invitation_id IN (
      SELECT i.id FROM invitations i
      JOIN reseller_tenants rt ON rt.tenant_id = i.tenant_id
      WHERE rt.reseller_id = auth_reseller_id()
    )
  );
```

---

#### `guestbook_entries`

```sql
ALTER TABLE guestbook_entries ENABLE ROW LEVEL SECURITY;

-- Public can submit guestbook messages on published invitations
CREATE POLICY "guestbook_public_insert" ON guestbook_entries
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM invitations
      WHERE id = invitation_id AND status = 'published'
    )
  );

-- Public can read approved entries
CREATE POLICY "guestbook_public_read" ON guestbook_entries
  FOR SELECT
  USING (
    is_approved = TRUE AND
    EXISTS (
      SELECT 1 FROM invitations
      WHERE id = invitation_id AND status = 'published'
    )
  );

-- Tenant can read and moderate all (including unapproved)
CREATE POLICY "guestbook_tenant_all" ON guestbook_entries
  FOR ALL
  USING (tenant_id = auth_tenant_id());
```

---

#### `invitation_analytics` and `invitation_events`

```sql
ALTER TABLE invitation_analytics ENABLE ROW LEVEL SECURITY;
ALTER TABLE invitation_events ENABLE ROW LEVEL SECURITY;

-- Tenant read own analytics
CREATE POLICY "analytics_read_tenant" ON invitation_analytics
  FOR SELECT USING (tenant_id = auth_tenant_id());

-- Public insert events (page views etc.) — no auth needed
-- Rate-limited at API layer
CREATE POLICY "events_public_insert" ON invitation_events
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM invitations
      WHERE id = invitation_id AND status = 'published'
    )
  );

CREATE POLICY "events_read_tenant" ON invitation_events
  FOR SELECT USING (tenant_id = auth_tenant_id());
```

---

#### `orders` and `tenant_subscriptions`

```sql
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_subscriptions ENABLE ROW LEVEL SECURITY;

-- Tenants read their own billing data
CREATE POLICY "orders_read_tenant" ON orders
  FOR SELECT USING (tenant_id = auth_tenant_id());

CREATE POLICY "subscriptions_read_tenant" ON tenant_subscriptions
  FOR SELECT USING (tenant_id = auth_tenant_id());

-- Reseller admins read their clients' billing data
CREATE POLICY "orders_read_reseller" ON orders
  FOR SELECT
  USING (
    tenant_id IN (
      SELECT tenant_id FROM reseller_tenants
      WHERE reseller_id = auth_reseller_id()
    )
  );
```

---

#### `qr_codes` and `qr_checkins`

```sql
ALTER TABLE qr_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE qr_checkins ENABLE ROW LEVEL SECURITY;

-- Tenant CRUD on their QR codes
CREATE POLICY "qr_codes_tenant" ON qr_codes
  FOR ALL USING (tenant_id = auth_tenant_id());

-- Public can read a QR code by token (for scan validation)
CREATE POLICY "qr_codes_public_token_read" ON qr_codes
  FOR SELECT USING (TRUE);
  -- Further access control done at application layer by token lookup

-- Authenticated users (ushers) can insert check-in records
CREATE POLICY "qr_checkins_insert" ON qr_checkins
  FOR INSERT WITH CHECK (tenant_id = auth_tenant_id());

CREATE POLICY "qr_checkins_read_tenant" ON qr_checkins
  FOR SELECT USING (tenant_id = auth_tenant_id());
```

---

#### `feature_flags`

```sql
ALTER TABLE feature_flags ENABLE ROW LEVEL SECURITY;

-- Tenants can read flags that apply to them (own + platform-wide)
CREATE POLICY "flags_read_own" ON feature_flags
  FOR SELECT
  USING (tenant_id = auth_tenant_id() OR tenant_id IS NULL);

-- Only service role (super admin) can write feature flags
```

---

## 7. Storage Bucket Structure

### 7.1 Bucket Definitions

```
supabase storage
├── avatars/                        Public: false
│   └── {user_id}/
│       └── avatar.{ext}
│
├── invitation-images/              Public: false
│   └── {tenant_id}/
│       └── {invitation_id}/
│           ├── couple-groom.jpg
│           ├── couple-bride.jpg
│           └── og-image.jpg
│
├── gallery/                        Public: true (CDN-served)
│   └── {tenant_id}/
│       └── {invitation_id}/
│           ├── {uuid}.jpg
│           └── thumbs/
│               └── {uuid}.jpg
│
├── music/                          Public: true (CDN-served)
│   └── {tenant_id}/
│       └── {invitation_id}/
│           └── {uuid}.mp3
│
├── gifts/                          Public: true
│   └── {tenant_id}/
│       └── {invitation_id}/
│           └── qris-{uuid}.jpg
│
├── qrcodes/                        Public: true
│   └── {tenant_id}/
│       └── {invitation_id}/
│           ├── invitation-qr.png
│           └── guests/
│               └── {guest_id}.png
│
├── themes/                         Public: true (admin-managed)
│   └── {theme_slug}/
│       ├── preview.jpg
│       └── thumbnail.jpg
│
└── reseller-assets/                Public: false
    └── {reseller_id}/
        ├── logo.{ext}
        └── favicon.{ext}
```

### 7.2 Bucket Policies

```sql
-- avatars: owner-only write, owner-only read
CREATE POLICY "avatars_upload" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'avatars' AND
    (storage.foldername(name))[1] = auth.uid()::TEXT
  );

CREATE POLICY "avatars_read" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'avatars' AND
    (storage.foldername(name))[1] = auth.uid()::TEXT
  );

-- invitation-images: tenant-scoped write, public read via signed URL
CREATE POLICY "inv_images_tenant_write" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'invitation-images' AND
    (storage.foldername(name))[1] = auth_tenant_id()::TEXT
  );

-- gallery: tenant-scoped write, public read (CDN)
CREATE POLICY "gallery_tenant_write" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'gallery' AND
    (storage.foldername(name))[1] = auth_tenant_id()::TEXT
  );

CREATE POLICY "gallery_public_read" ON storage.objects
  FOR SELECT TO anon, authenticated
  USING (bucket_id = 'gallery');

-- music: same pattern as gallery
CREATE POLICY "music_tenant_write" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'music' AND
    (storage.foldername(name))[1] = auth_tenant_id()::TEXT
  );

CREATE POLICY "music_public_read" ON storage.objects
  FOR SELECT TO anon, authenticated
  USING (bucket_id = 'music');

-- qrcodes: tenant write, public read
CREATE POLICY "qr_tenant_write" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'qrcodes' AND
    (storage.foldername(name))[1] = auth_tenant_id()::TEXT
  );

CREATE POLICY "qr_public_read" ON storage.objects
  FOR SELECT TO anon, authenticated
  USING (bucket_id = 'qrcodes');
```

### 7.3 File Size & Type Limits (enforced at API layer)

| Bucket | Max size | Allowed types |
|---|---|---|
| `avatars` | 2 MB | jpg, png, webp |
| `invitation-images` | 5 MB | jpg, png, webp |
| `gallery` | 8 MB per image | jpg, png, webp |
| `music` | 10 MB | mp3, m4a, ogg |
| `gifts` | 2 MB | jpg, png |
| `qrcodes` | 512 KB | png, svg |
| `themes` | 10 MB | jpg, png, webp |
| `reseller-assets` | 2 MB | jpg, png, svg, webp, ico |

---

## 8. Migration Plan

### 8.1 Migration Order

Migrations must run in dependency order. Each migration is a separate timestamped file in `supabase/migrations/`.

```
Migration Order
───────────────────────────────────────────────────────────
001_extensions.sql
002_functions.sql              -- set_updated_at(), auth helpers
003_tenants.sql
004_users.sql
005_resellers.sql              -- resellers, reseller_tenants, reseller_domains
006_packages.sql               -- packages, package_features
007_feature_flags.sql
008_subscriptions.sql          -- tenant_subscriptions
009_vouchers.sql               -- vouchers, voucher_redemptions
010_orders.sql
011_invitation_themes.sql
012_invitations.sql
013_invitation_sections.sql
014_invitation_gallery.sql
015_invitation_music.sql
016_invitation_gifts.sql
017_guests.sql
018_rsvp_responses.sql
019_guestbook_entries.sql
020_qr_codes.sql
021_qr_checkins.sql
022_invitation_analytics.sql
023_invitation_events.sql
024_audit_logs.sql
025_email_notifications.sql
026_custom_domains.sql
027_indexes.sql                -- All performance indexes
028_rls.sql                    -- All RLS ENABLE + policies
029_storage_buckets.sql        -- Bucket creation + policies
030_seed_packages.sql          -- Initial package + feature data
031_seed_themes.sql            -- Initial invitation themes
```

### 8.2 `001_extensions.sql`

```sql
-- Enable required PostgreSQL extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";    -- for future full-text search on guest names
```

### 8.3 `030_seed_packages.sql` (abridged)

```sql
-- Free package
INSERT INTO packages (name, slug, price_monthly, price_yearly,
  max_invitations, max_guests, max_photos, max_team_members, max_music_tracks,
  is_active, sort_order)
VALUES ('Free', 'free', 0, 0, 1, 50, 5, 1, 1, TRUE, 0);

-- Starter
INSERT INTO packages (name, slug, price_monthly, price_yearly,
  max_invitations, max_guests, max_photos, max_team_members, max_music_tracks,
  is_active, sort_order)
VALUES ('Starter', 'starter', 49000, 470000, 3, 200, 20, 1, 3, TRUE, 1);

-- Premium
INSERT INTO packages (name, slug, price_monthly, price_yearly,
  max_invitations, max_guests, max_photos, max_team_members, max_music_tracks,
  is_active, sort_order)
VALUES ('Premium', 'premium', 99000, 950000, -1, -1, -1, 3, -1, TRUE, 2);

-- Enterprise (manual billing, no price set here)
INSERT INTO packages (name, slug, price_monthly, price_yearly,
  max_invitations, max_guests, max_photos, max_team_members, max_music_tracks,
  is_active, sort_order)
VALUES ('Enterprise', 'enterprise', 0, 0, -1, -1, -1, -1, -1, TRUE, 3);

-- Reseller wholesale package
INSERT INTO packages (name, slug, price_monthly, price_yearly,
  max_invitations, max_guests, max_photos, max_team_members, max_music_tracks,
  is_active, is_reseller, sort_order)
VALUES ('Reseller', 'reseller', 299000, 2990000, -1, -1, -1, -1, -1, TRUE, TRUE, 4);

-- Seed package_features for each package
-- (abbreviated — full seed file maps every FEATURES key per package)
INSERT INTO package_features (package_id, feature_key, is_enabled) VALUES
  ((SELECT id FROM packages WHERE slug = 'free'), 'countdown_timer',    TRUE),
  ((SELECT id FROM packages WHERE slug = 'free'), 'rsvp_open',          TRUE),
  ((SELECT id FROM packages WHERE slug = 'free'), 'music_player',       FALSE),
  ((SELECT id FROM packages WHERE slug = 'free'), 'gift_registry',      FALSE),
  ((SELECT id FROM packages WHERE slug = 'free'), 'analytics_basic',    FALSE),
  ((SELECT id FROM packages WHERE slug = 'free'), 'export_rsvp_csv',    FALSE),
  ((SELECT id FROM packages WHERE slug = 'free'), 'remove_platform_badge', FALSE),
  ((SELECT id FROM packages WHERE slug = 'free'), 'premium_themes',     FALSE),
  ((SELECT id FROM packages WHERE slug = 'free'), 'custom_domain',      FALSE),
  ((SELECT id FROM packages WHERE slug = 'free'), 'guest_import_csv',   FALSE),
  ((SELECT id FROM packages WHERE slug = 'free'), 'qr_checkin',         FALSE),
  ((SELECT id FROM packages WHERE slug = 'starter'), 'music_player',    TRUE),
  ((SELECT id FROM packages WHERE slug = 'starter'), 'analytics_basic', TRUE),
  ((SELECT id FROM packages WHERE slug = 'starter'), 'export_rsvp_csv', TRUE),
  ((SELECT id FROM packages WHERE slug = 'starter'), 'qr_checkin',      FALSE),
  ((SELECT id FROM packages WHERE slug = 'premium'), 'music_player',    TRUE),
  ((SELECT id FROM packages WHERE slug = 'premium'), 'analytics_basic', TRUE),
  ((SELECT id FROM packages WHERE slug = 'premium'), 'analytics_advanced', TRUE),
  ((SELECT id FROM packages WHERE slug = 'premium'), 'export_rsvp_csv', TRUE),
  ((SELECT id FROM packages WHERE slug = 'premium'), 'export_guest_csv', TRUE),
  ((SELECT id FROM packages WHERE slug = 'premium'), 'guest_import_csv', TRUE),
  ((SELECT id FROM packages WHERE slug = 'premium'), 'gift_registry',   TRUE),
  ((SELECT id FROM packages WHERE slug = 'premium'), 'custom_domain',   TRUE),
  ((SELECT id FROM packages WHERE slug = 'premium'), 'remove_platform_badge', TRUE),
  ((SELECT id FROM packages WHERE slug = 'premium'), 'premium_themes',  TRUE),
  ((SELECT id FROM packages WHERE slug = 'premium'), 'qr_checkin',      TRUE),
  ((SELECT id FROM packages WHERE slug = 'premium'), 'team_members',    TRUE),
  ((SELECT id FROM packages WHERE slug = 'enterprise'), 'qr_checkin',   TRUE),
  ((SELECT id FROM packages WHERE slug = 'enterprise'), 'team_members', TRUE),
  ((SELECT id FROM packages WHERE slug = 'enterprise'), 'custom_domain', TRUE),
  ((SELECT id FROM packages WHERE slug = 'enterprise'), 'remove_platform_badge', TRUE),
  ((SELECT id FROM packages WHERE slug = 'enterprise'), 'analytics_advanced', TRUE);
```

---

## 9. Scalability Considerations

### 9.1 Partitioning Strategy

The two highest-volume tables are `invitation_events` (raw analytics) and `audit_logs`. Both should be range-partitioned by `created_at` once volume warrants it (typically >10M rows).

```sql
-- Future: convert invitation_events to partitioned table
-- This is the schema target for Phase 4+

CREATE TABLE invitation_events (
  id             BIGSERIAL,
  invitation_id  UUID NOT NULL,
  tenant_id      UUID NOT NULL,
  event_type     TEXT NOT NULL,
  guest_id       UUID,
  session_id     TEXT,
  metadata       JSONB NOT NULL DEFAULT '{}',
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
) PARTITION BY RANGE (created_at);

CREATE TABLE invitation_events_2026_06
  PARTITION OF invitation_events
  FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');

-- Automate with pg_partman (Supabase Pro supports this extension)
```

### 9.2 `view_count` Increment Strategy

Avoid `UPDATE invitations SET view_count = view_count + 1` on every page load under concurrent traffic — this creates row-level lock contention.

**Phase 1–2:** Use a Supabase Edge Function to batch-flush view counts every 60 seconds using a Redis counter (Upstash) as a buffer, then apply with `UPDATE ... SET view_count = view_count + $batch`.

**Phase 3+:** Derive live view counts from `invitation_analytics` daily roll-ups. The `view_count` column on `invitations` becomes a cached value refreshed nightly rather than a real-time counter.

### 9.3 `invitation_events` Archival

Events older than 90 days (configurable per package) should be moved to cold storage or deleted. A Supabase Edge Function on a nightly schedule handles this:

```sql
-- Example: archive events older than 90 days by deleting after analytics are rolled up
DELETE FROM invitation_events
WHERE created_at < NOW() - INTERVAL '90 days';
```

The `invitation_analytics` daily roll-ups are the permanent record; raw events are only needed for the rolling analysis window.

### 9.4 Read Replicas

Supabase Pro supports read replicas. Public invitation pages (ISR) bypass the DB entirely for cached renders. When cache misses occur, queries should be directed to the read replica:

- `invitations` SELECT (public render)
- `invitation_sections` SELECT
- `invitation_gallery` SELECT
- `guestbook_entries` SELECT (approved only)

Write operations (RSVP submit, event tracking) always go to the primary.

### 9.5 Connection Pooling

PgBouncer (transaction mode) is enabled by default on Supabase Pro. All Next.js API routes use the pooled connection string (`?pgbouncer=true`). Direct connections are only used for:
- Long-running migrations
- Supabase Edge Functions that need `LISTEN/NOTIFY`

### 9.6 Future Schema Extensions

The following columns / tables are intentionally deferred to avoid over-engineering:

| Feature | Deferred table/column | When to add |
|---|---|---|
| Multi-event per invitation | `events[]` JSON or `invitation_events` table | Phase 3 if demand |
| AI-generated content | `ai_generations` table | Out of scope |
| Physical print orders | `print_orders` table | Phase 5+ |
| Affiliate program | `affiliates`, `affiliate_clicks` | Phase 4+ |
| Livestream embed | `livestream_url` on `invitation_sections.content` | Already in JSONB |
| SMS notifications | `sms_notifications` table | Phase 3 |
| Tenant-level billing alerts | `billing_alerts` table | Phase 3 |

### 9.7 Multi-Region Considerations

The current architecture targets a single Supabase project in `ap-southeast-1` (Singapore), appropriate for the Indonesian market. For Phase 4+ global expansion:

- Consider Supabase's multi-region read replicas
- `tenants.metadata` already has a `locale` and `timezone` field for i18n
- The `currency` field on `packages` and `orders` supports non-IDR billing without schema changes
- `custom_domains` table already supports any domain regardless of region

---

## Appendix A — Complete Feature Key Reference

```typescript
export const FEATURES = {
  // Invitation core
  MUSIC_PLAYER:              'music_player',
  COUNTDOWN_TIMER:           'countdown_timer',
  GIFT_REGISTRY:             'gift_registry',
  GALLERY_SECTION:           'gallery_section',
  LOVE_STORY_SECTION:        'love_story_section',
  LIVESTREAM_LINK:           'livestream_link',
  MAP_EMBED:                 'map_embed',
  INVITATION_PASSWORD:       'invitation_password',

  // RSVP
  RSVP_OPEN:                 'rsvp_open',
  RSVP_MEAL_CHOICE:          'rsvp_meal_choice',
  RSVP_PLUS_ONE:             'rsvp_plus_one',
  RSVP_WISHES_WALL:          'rsvp_wishes_wall',

  // Guestbook
  GUESTBOOK:                 'guestbook',
  GUESTBOOK_MODERATION:      'guestbook_moderation',

  // Guest management
  GUEST_IMPORT_CSV:          'guest_import_csv',
  GUEST_PERSONALIZED_LINK:   'guest_personalized_link',
  GUEST_WHATSAPP_BLAST:      'guest_whatsapp_blast',

  // QR
  QR_INVITATION:             'qr_invitation',
  QR_CHECKIN:                'qr_checkin',

  // Analytics
  ANALYTICS_BASIC:           'analytics_basic',
  ANALYTICS_ADVANCED:        'analytics_advanced',

  // Branding
  REMOVE_PLATFORM_BADGE:     'remove_platform_badge',
  CUSTOM_DOMAIN:             'custom_domain',
  CUSTOM_FONT:               'custom_font',

  // Export
  EXPORT_RSVP_CSV:           'export_rsvp_csv',
  EXPORT_GUEST_CSV:          'export_guest_csv',

  // Premium content
  PREMIUM_THEMES:            'premium_themes',

  // Team
  TEAM_MEMBERS:              'team_members',

  // Platform / admin
  MAINTENANCE_MODE:          'maintenance_mode',
  NEW_EDITOR_UI:             'new_editor_ui',
} as const;
```

---

## Appendix B — JWT Custom Claims Hook

```sql
-- Supabase Auth Hook: runs on every sign-in
-- Injects tenant_id, role, reseller_id, package_id into JWT

CREATE OR REPLACE FUNCTION auth.custom_claims(event JSONB)
RETURNS JSONB AS $$
DECLARE
  user_record  RECORD;
  sub_record   RECORD;
  reseller_rec RECORD;
  claims       JSONB;
BEGIN
  SELECT u.tenant_id, u.role
    INTO user_record
    FROM users u
   WHERE u.id = (event->>'userId')::UUID;

  SELECT ts.package_id
    INTO sub_record
    FROM tenant_subscriptions ts
   WHERE ts.tenant_id = user_record.tenant_id
     AND ts.status IN ('active', 'trialing')
   ORDER BY ts.created_at DESC
   LIMIT 1;

  -- Only look up reseller_id for reseller_admin role
  IF user_record.role = 'reseller_admin' THEN
    SELECT r.id INTO reseller_rec
      FROM resellers r
     WHERE r.owner_user_id = (event->>'userId')::UUID
     LIMIT 1;
  END IF;

  claims := event->'claims';
  claims := jsonb_set(claims, '{tenant_id}',  to_jsonb(user_record.tenant_id::TEXT));
  claims := jsonb_set(claims, '{role}',        to_jsonb(user_record.role));
  claims := jsonb_set(claims, '{package_id}', to_jsonb(COALESCE(sub_record.package_id::TEXT, '')));

  IF reseller_rec.id IS NOT NULL THEN
    claims := jsonb_set(claims, '{reseller_id}', to_jsonb(reseller_rec.id::TEXT));
  END IF;

  RETURN jsonb_set(event, '{claims}', claims);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

---

*End of PHASE2_DATABASE.md*
