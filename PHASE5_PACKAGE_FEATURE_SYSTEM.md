# PHASE5_PACKAGE_FEATURE_SYSTEM.md
# Wedding Invitation SaaS Platform — Package Management & Feature Toggle System

> **Version:** 1.0.0
> **Date:** 2026-06-12
> **Status:** Approved for Development
> **Depends on:** PHASE1_ARCHITECTURE.md, PHASE2_DATABASE.md, PHASE3_AUTH.md, PHASE4_ADMIN_ARCHITECTURE.md

---

## Table of Contents

1. [Package System Overview](#1-package-system-overview)
2. [Feature Toggle Architecture](#2-feature-toggle-architecture)
3. [Database Design](#3-database-design)
4. [Feature Resolution Engine](#4-feature-resolution-engine)
5. [Add-On System](#5-add-on-system)
6. [Package Upgrade Flow](#6-package-upgrade-flow)
7. [Reseller Package System](#7-reseller-package-system)
8. [White Label Preparation](#8-white-label-preparation)
9. [Admin Management](#9-admin-management)
10. [Permission Mapping](#10-permission-mapping)
11. [Pricing Architecture](#11-pricing-architecture)
12. [Scalability Considerations](#12-scalability-considerations)

---

## 1. Package System Overview

### 1.1 Architecture Philosophy

The package system is **entirely database-driven**. No package behavior is hardcoded in application logic. Every quota limit, feature entitlement, pricing rule, and reseller constraint is stored in the database and resolved at runtime.

This means:
- New packages can be created without a code deploy.
- Features can be added to or removed from packages instantly via the admin panel.
- Resellers can define their own packages using platform packages as a foundation.
- Pricing can be adjusted per tenant, per reseller, or platform-wide with no downtime.

### 1.2 Package Hierarchy

```
PLATFORM PACKAGES (managed by Super Admin)
  ├── Free
  ├── Basic
  ├── Premium
  ├── Ultimate
  └── Reseller Base (wholesale — not sold directly to end users)
         │
         ▼
  RESELLER PACKAGES (derived from platform packages, managed by Reseller Admin)
  ├── Reseller A — Silver Plan   (based on Basic)
  ├── Reseller A — Gold Plan     (based on Premium)
  └── Reseller B — Standard      (based on Basic)
         │
         ▼
  TENANT SUBSCRIPTION (one active subscription per tenant)
         │
         ▼
  ADD-ON SUBSCRIPTIONS (zero or more, layered on top)
  ├── QR Check-In Add-On
  ├── Custom Domain Add-On
  └── Extra Storage Add-On
         │
         ▼
  INVITATION FEATURE OVERRIDES (per-invitation, admin/reseller only)
  └── e.g., enable livestream for one specific invitation
```

### 1.3 Package Lifecycle

```
DRAFT → ACTIVE → DEPRECATED → ARCHIVED

DRAFT:       Created but not visible to customers. Used for staging new tiers.
ACTIVE:      Publicly available. New subscriptions can be created.
DEPRECATED:  Hidden from pricing page. Existing subscribers keep access. No new signups.
ARCHIVED:    Fully retired. Existing subscribers migrated to a successor package.
```

State transitions are admin-only and audit-logged. No package can be hard-deleted while active subscriptions reference it.

### 1.4 Upgrade Flow

```
User selects higher-tier package
  │
  ▼
System calculates prorated credit from current period
  │   credit = (days_remaining / period_days) × current_package_price
  │
  ▼
New order created:
  amount_gross = new_package_price
  amount_discount = prorated_credit
  amount_net = amount_gross - amount_discount
  │
  ▼
Payment processed (Midtrans / Stripe / manual)
  │
  ├─ SUCCESS
  │     │
  │     ▼
  │   tenant_subscriptions: status → 'active', package_id → new package
  │   New current_period_start = NOW()
  │   New current_period_end = NOW() + billing_cycle_duration
  │   Feature flags cache invalidated for this tenant
  │   JWT refreshed on next request (picks up new package_id claim)
  │
  └─ FAILURE → Order status → 'failed'. Subscription unchanged.
```

### 1.5 Downgrade Flow

```
User selects lower-tier package
  │
  ▼
System schedules downgrade at end of current billing period
  (No proration on downgrade — user keeps current tier until period ends)
  │
  ▼
pending_downgrade_package_id written to tenant_subscriptions
  │
  ▼
At period end (nightly cron or webhook):
  │
  ├─ Package switched to new lower tier
  ├─ Usage quota check run:
  │     if current_invitations > new_package.max_invitations:
  │       oldest excess invitations auto-archived (not deleted)
  │     if current_team_members > new_package.max_team_members:
  │       newest team members deactivated (not deleted)
  │
  └─ Email notification sent to tenant owner
```

### 1.6 Renewal Flow

```
7 days before period end → renewal reminder email sent
  │
  ▼
At period end:
  │
  ├─ AUTO-RENEW ENABLED (default)
  │     │
  │     ▼
  │   New order created for same package + billing cycle
  │     │
  │     ├─ Payment SUCCESS → new period starts, subscription stays 'active'
  │     │
  │     └─ Payment FAILURE → status → 'past_due'
  │           │
  │           ├─ Retry after 3 days
  │           ├─ Retry after 7 days
  │           └─ After 14 days: status → 'expired', features downgraded to Free
  │
  └─ AUTO-RENEW DISABLED
        │
        └─ At period end: status → 'expired', grace period of 7 days
              │
              ├─ If renewed within grace: restored without data loss
              └─ After grace: features downgraded to Free
```

### 1.7 Grace Period

```
GRACE_PERIOD_DAYS = 7   (configurable per package via packages.metadata.grace_period_days)

During grace period:
  - Tenant retains full feature access
  - Dashboard shows prominent renewal banner
  - Invitation public pages remain live
  - No new invitations can be created if over Free quota

After grace period expires:
  - Subscription status → 'expired'
  - Feature access reverts to Free tier entitlements
  - Excess invitations archived (not deleted)
  - Data preserved for 90 days before purge eligibility
```

---

## 2. Feature Toggle Architecture

### 2.1 Design Principles

1. **Features are rows, not code branches.** A feature is a record in the `features` table. Enabling or disabling it requires no code change.
2. **Config, not flags.** Each feature can carry a JSONB `config` object that defines its behavior (e.g., `{ max_photos: 20, formats: ["jpg","png"] }`). The application reads config — it does not branch on package name.
3. **Layered resolution.** Feature access is resolved by merging multiple sources in priority order. The highest-priority source wins.
4. **Single DB round-trip.** All features for a tenant are resolved in one query and cached for the request lifetime. No per-feature DB calls in hot paths.

### 2.2 Complete Feature Registry

All features must be registered in the `features` table before they can be assigned to packages.

```typescript
// config/features.ts — TypeScript mirror of the features table
// Used for type safety. The DB is the source of truth.

export const FEATURE_KEYS = {
  // ── Invitation Content ──────────────────────────────────────
  RSVP:                    'rsvp',
  GUESTBOOK:               'guestbook',
  GUESTBOOK_MODERATION:    'guestbook_moderation',
  LOVE_STORY:              'love_story',
  GALLERY:                 'gallery',
  MUSIC_PLAYER:            'music_player',
  VIDEO_BACKGROUND:        'video_background',
  COUNTDOWN_TIMER:         'countdown_timer',
  LIVESTREAM_EMBED:        'livestream_embed',
  MAP_EMBED:               'map_embed',
  GIFT_REGISTRY:           'gift_registry',
  QRIS_PAYMENT:            'qris_payment',

  // ── RSVP Controls ───────────────────────────────────────────
  RSVP_MEAL_CHOICE:        'rsvp_meal_choice',
  RSVP_PLUS_ONE:           'rsvp_plus_one',
  RSVP_OPEN_LINK:          'rsvp_open_link',       // RSVP without guest token

  // ── Guest Management ────────────────────────────────────────
  GUEST_IMPORT_CSV:        'guest_import_csv',
  GUEST_EXPORT_CSV:        'guest_export_csv',
  GUEST_PERSONALIZED_LINK: 'guest_personalized_link',
  GUEST_WHATSAPP_BLAST:    'guest_whatsapp_blast',

  // ── QR System ───────────────────────────────────────────────
  QR_CODE_INVITATION:      'qr_code_invitation',
  QR_CHECKIN:              'qr_checkin',

  // ── Analytics ───────────────────────────────────────────────
  ANALYTICS_BASIC:         'analytics_basic',
  ANALYTICS_ADVANCED:      'analytics_advanced',
  ANALYTICS_EXPORT:        'analytics_export',

  // ── Customization ───────────────────────────────────────────
  CUSTOM_FONT:             'custom_font',
  CUSTOM_COLOR:            'custom_color',
  CUSTOM_DOMAIN:           'custom_domain',
  REMOVE_PLATFORM_BADGE:   'remove_platform_badge',
  PREMIUM_THEMES:          'premium_themes',
  PASSWORD_PROTECTION:     'password_protection',

  // ── Export / Import ─────────────────────────────────────────
  EXPORT_RSVP_CSV:         'export_rsvp_csv',
  EXPORT_GUEST_CSV:        'export_guest_csv',

  // ── Team ────────────────────────────────────────────────────
  TEAM_MEMBERS:            'team_members',

  // ── Storage ─────────────────────────────────────────────────
  EXTRA_STORAGE:           'extra_storage',        // config: { storage_gb: 5 }
  EXTRA_GALLERY_PHOTOS:    'extra_gallery_photos', // config: { max_photos: 50 }

  // ── Platform / Admin ────────────────────────────────────────
  MAINTENANCE_MODE:        'maintenance_mode',
  NEW_EDITOR_UI:           'new_editor_ui',        // gradual rollout
  BETA_FEATURES:           'beta_features',
} as const;

export type FeatureKey = typeof FEATURE_KEYS[keyof typeof FEATURE_KEYS];
```

### 2.3 Feature Config Schema

Each feature can carry a typed config object. The schema is defined per feature in the `features` table (`config_schema` column) and validated by the application before writing.

```typescript
// Config shapes per feature (application-layer type definitions)

type FeatureConfigs = {
  'gallery':                { max_photos: number };
  'music_player':           { max_tracks: number; max_file_mb: number };
  'team_members':           { max_members: number };
  'analytics_advanced':     { retention_days: number };
  'extra_storage':          { storage_gb: number };
  'extra_gallery_photos':   { max_photos: number };
  'custom_font':            { allowed_fonts: string[] | 'all' };
  'rsvp_meal_choice':       { max_options: number };
  'guest_whatsapp_blast':   { max_recipients_per_day: number };
  'qr_checkin':             { max_devices: number };
  // Most features have no config: {}
};
```

### 2.4 Feature Categories

Features are grouped into categories for the admin UI and pricing page display:

| Category | Feature Keys |
|---|---|
| `content` | rsvp, guestbook, love_story, gallery, music_player, video_background, countdown_timer, livestream_embed, map_embed, gift_registry, qris_payment |
| `rsvp` | rsvp_meal_choice, rsvp_plus_one, rsvp_open_link |
| `guest_management` | guest_import_csv, guest_export_csv, guest_personalized_link, guest_whatsapp_blast |
| `qr` | qr_code_invitation, qr_checkin |
| `analytics` | analytics_basic, analytics_advanced, analytics_export |
| `customization` | custom_font, custom_color, custom_domain, remove_platform_badge, premium_themes, password_protection |
| `export` | export_rsvp_csv, export_guest_csv |
| `team` | team_members |
| `storage` | extra_storage, extra_gallery_photos |
| `platform` | maintenance_mode, new_editor_ui, beta_features |

---

## 3. Database Design

### 3.1 Complete ERD — Package & Feature Domain

```
┌──────────────┐       ┌───────────────────┐       ┌──────────────────────┐
│   features   │       │  package_features  │       │      packages        │
│──────────────│       │───────────────────│       │──────────────────────│
│ id (PK)      │◄──────│ feature_id (FK)   │──────►│ id (PK)              │
│ key (UNIQUE) │       │ package_id (FK)   │       │ slug (UNIQUE)        │
│ name         │       │ is_enabled        │       │ name                 │
│ category     │       │ config JSONB      │       │ status               │
│ description  │       │ limit_value       │       │ type                 │
│ config_schema│       └───────────────────┘       │ price_monthly        │
│ is_system    │                                   │ price_yearly         │
│ is_active    │       ┌───────────────────┐       │ price_lifetime       │
│ sort_order   │       │   add_on_features  │       │ currency             │
└──────────────┘       │───────────────────│       │ trial_days           │
        │              │ feature_id (FK)   │       │ grace_period_days    │
        │              │ add_on_id (FK)    │       │ max_invitations      │
        │              │ is_enabled        │       │ max_guests           │
        │              │ config JSONB      │       │ max_photos           │
        │              └───────────────────┘       │ max_team_members     │
        │                      │                   │ max_music_tracks     │
        │              ┌───────▼──────────┐        │ max_storage_mb       │
        │              │    add_ons       │        │ is_public            │
        │              │──────────────────│        │ is_reseller_base     │
        │              │ id (PK)          │        │ parent_package_id FK │
        │              │ slug (UNIQUE)    │        │ metadata JSONB       │
        │              │ name             │        └──────────────────────┘
        │              │ description      │                  │
        │              │ price            │                  │
        │              │ billing_cycle    │         ┌────────▼────────────┐
        │              │ is_active        │         │ tenant_subscriptions│
        │              └──────────────────┘         │─────────────────────│
        │                      │                   │ id (PK)             │
        │              ┌───────▼──────────┐        │ tenant_id (FK)      │
        │              │ tenant_add_ons   │        │ package_id (FK)     │
        │              │──────────────────│        │ reseller_package_id │
        │              │ id (PK)          │        │ billing_cycle       │
        │              │ tenant_id (FK)   │        │ status              │
        │              │ add_on_id (FK)   │        │ current_period_start│
        │              │ status           │        │ current_period_end  │
        │              │ expires_at       │        │ trial_ends_at       │
        │              └──────────────────┘        │ pending_downgrade_  │
        │                                          │   package_id (FK)   │
        ▼                                          │ cancelled_at        │
┌──────────────────────────────┐                  │ auto_renew          │
│ invitation_feature_overrides │                  └─────────────────────┘
│──────────────────────────────│
│ id (PK)                      │         ┌─────────────────────────┐
│ invitation_id (FK)           │         │    reseller_packages    │
│ feature_id (FK)              │         │─────────────────────────│
│ is_enabled                   │         │ id (PK)                 │
│ config JSONB                 │         │ reseller_id (FK)        │
│ override_reason              │         │ base_package_id (FK)    │
│ created_by (FK)              │         │ name                    │
│ expires_at                   │         │ slug (UNIQUE)           │
└──────────────────────────────┘         │ price_monthly           │
                                         │ price_yearly            │
                                         │ price_lifetime          │
                                         │ is_active               │
                                         │ metadata JSONB          │
                                         └─────────────────────────┘
                                                    │
                                         ┌──────────▼──────────────┐
                                         │ reseller_package_       │
                                         │ features                │
                                         │─────────────────────────│
                                         │ id (PK)                 │
                                         │ reseller_package_id(FK) │
                                         │ feature_id (FK)         │
                                         │ is_enabled              │
                                         │ config JSONB            │
                                         └─────────────────────────┘
```

### 3.2 Table: `features`

**Purpose:** Master registry of every feature the platform supports. Adding a new feature requires inserting a row here — no code changes.

```sql
CREATE TABLE features (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  key           TEXT        NOT NULL UNIQUE,
  -- e.g. 'rsvp', 'gallery', 'qr_checkin'
  name          TEXT        NOT NULL,
  -- Display name: "RSVP Form", "Photo Gallery", "QR Check-In"
  description   TEXT,
  category      TEXT        NOT NULL DEFAULT 'content'
                            CHECK (category IN (
                              'content', 'rsvp', 'guest_management', 'qr',
                              'analytics', 'customization', 'export',
                              'team', 'storage', 'platform'
                            )),
  config_schema JSONB       NOT NULL DEFAULT '{}',
  -- JSON Schema defining valid config shape for this feature.
  -- Example for 'gallery': { "max_photos": { "type": "integer", "minimum": 1 } }
  default_config JSONB      NOT NULL DEFAULT '{}',
  -- Default config values when feature is enabled without explicit config
  is_system     BOOLEAN     NOT NULL DEFAULT FALSE,
  -- TRUE = cannot be disabled platform-wide (e.g. basic RSVP on Free plan)
  is_active     BOOLEAN     NOT NULL DEFAULT TRUE,
  -- FALSE = feature hidden from admin UI and never resolved as enabled
  is_add_on_eligible BOOLEAN NOT NULL DEFAULT FALSE,
  -- TRUE = can be sold as a standalone add-on
  sort_order    INTEGER     NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_features_updated_at
  BEFORE UPDATE ON features
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_features_key      ON features(key);
CREATE INDEX idx_features_category ON features(category, sort_order);
CREATE INDEX idx_features_active   ON features(is_active);
```

---

### 3.3 Table: `packages`

**Purpose:** Subscription tier definitions. All quota and pricing lives here. No business logic references package slugs directly.

```sql
CREATE TABLE packages (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  slug                TEXT        NOT NULL UNIQUE,
  name                TEXT        NOT NULL,
  description         TEXT,
  status              TEXT        NOT NULL DEFAULT 'draft'
                                  CHECK (status IN ('draft', 'active', 'deprecated', 'archived')),
  type                TEXT        NOT NULL DEFAULT 'platform'
                                  CHECK (type IN ('platform', 'reseller_base', 'internal')),
  -- 'platform'      : sold directly to end users
  -- 'reseller_base' : wholesale tier; resellers build their own packages from this
  -- 'internal'      : used for trial, promotional, or enterprise custom plans

  -- Pricing
  price_monthly       NUMERIC(12,2) NOT NULL DEFAULT 0,
  price_yearly        NUMERIC(12,2) NOT NULL DEFAULT 0,
  price_lifetime      NUMERIC(12,2),               -- null = not offered as lifetime
  currency            TEXT        NOT NULL DEFAULT 'IDR',
  trial_days          INTEGER     NOT NULL DEFAULT 0,
  grace_period_days   INTEGER     NOT NULL DEFAULT 7,

  -- Quotas (-1 = unlimited)
  max_invitations     INTEGER     NOT NULL DEFAULT 1,
  max_guests          INTEGER     NOT NULL DEFAULT 50,
  max_photos          INTEGER     NOT NULL DEFAULT 5,
  max_team_members    INTEGER     NOT NULL DEFAULT 1,
  max_music_tracks    INTEGER     NOT NULL DEFAULT 1,
  max_storage_mb      INTEGER     NOT NULL DEFAULT 100,
  max_video_mb        INTEGER     NOT NULL DEFAULT 0,

  -- Display
  is_public           BOOLEAN     NOT NULL DEFAULT FALSE,
  -- TRUE = appears on public pricing page
  is_featured         BOOLEAN     NOT NULL DEFAULT FALSE,
  is_reseller_base    BOOLEAN     NOT NULL DEFAULT FALSE,
  -- TRUE = resellers can derive custom packages from this
  sort_order          INTEGER     NOT NULL DEFAULT 0,

  -- Successor for deprecated/archived packages
  successor_package_id UUID       REFERENCES packages(id),
  parent_package_id    UUID       REFERENCES packages(id),
  -- For reseller-derived packages, references the base platform package

  metadata            JSONB       NOT NULL DEFAULT '{}',
  -- { badge_label, highlight_color, cta_text, stripe_price_id, midtrans_plan_id }

  created_by          UUID        REFERENCES users(id),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_packages_updated_at
  BEFORE UPDATE ON packages
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_packages_slug   ON packages(slug);
CREATE INDEX idx_packages_status ON packages(status, is_public, sort_order);
CREATE INDEX idx_packages_type   ON packages(type);
```

---

### 3.4 Table: `package_features`

**Purpose:** Maps which features are enabled for each package tier, and at what configuration level.

```sql
CREATE TABLE package_features (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  package_id      UUID        NOT NULL REFERENCES packages(id) ON DELETE CASCADE,
  feature_id      UUID        NOT NULL REFERENCES features(id) ON DELETE CASCADE,
  is_enabled      BOOLEAN     NOT NULL DEFAULT TRUE,
  config          JSONB       NOT NULL DEFAULT '{}',
  -- Overrides features.default_config for this package level.
  -- e.g. for 'gallery' on Premium: { "max_photos": 50 }
  limit_value     INTEGER,
  -- Convenience column for simple numeric limits (max_photos, max_tracks, etc.)
  -- If set, takes precedence over config.max_* for quota checks.
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (package_id, feature_id)
);

CREATE TRIGGER trg_package_features_updated_at
  BEFORE UPDATE ON package_features
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_pf_package_id ON package_features(package_id);
CREATE INDEX idx_pf_feature_id ON package_features(feature_id);
```

---

### 3.5 Table: `tenant_subscriptions`

**Purpose:** Tracks the active subscription for each tenant. Extended from Phase 2 to support downgrade scheduling and auto-renew control.

```sql
CREATE TABLE tenant_subscriptions (
  id                       UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                UUID        NOT NULL REFERENCES tenants(id),
  package_id               UUID        NOT NULL REFERENCES packages(id),
  reseller_package_id      UUID        REFERENCES reseller_packages(id),
  -- Set when the tenant subscribed through a reseller's custom package
  reseller_id              UUID        REFERENCES resellers(id),
  billing_cycle            TEXT        NOT NULL DEFAULT 'monthly'
                                       CHECK (billing_cycle IN ('monthly', 'yearly', 'lifetime')),
  status                   TEXT        NOT NULL DEFAULT 'trialing'
                                       CHECK (status IN (
                                         'active', 'trialing', 'past_due',
                                         'cancelled', 'paused', 'expired'
                                       )),
  current_period_start     TIMESTAMPTZ NOT NULL,
  current_period_end       TIMESTAMPTZ NOT NULL,
  trial_ends_at            TIMESTAMPTZ,
  grace_ends_at            TIMESTAMPTZ,
  -- Computed at expiry: current_period_end + grace_period_days
  auto_renew               BOOLEAN     NOT NULL DEFAULT TRUE,
  pending_downgrade_package_id UUID    REFERENCES packages(id),
  -- If set, this package will be applied at next renewal
  cancelled_at             TIMESTAMPTZ,
  cancel_reason            TEXT,
  payment_provider         TEXT        CHECK (payment_provider IN ('midtrans', 'stripe', 'manual')),
  payment_ref              TEXT,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_tenant_subscriptions_updated_at
  BEFORE UPDATE ON tenant_subscriptions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Hot path: get active subscription for a tenant
CREATE INDEX idx_ts_tenant_active ON tenant_subscriptions(tenant_id, status)
  WHERE status IN ('active', 'trialing', 'past_due');
CREATE INDEX idx_ts_period_end    ON tenant_subscriptions(current_period_end)
  WHERE status IN ('active', 'trialing');
```

---

### 3.6 Table: `add_ons`

**Purpose:** Standalone purchasable feature bundles that layer on top of a base subscription.

```sql
CREATE TABLE add_ons (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  slug            TEXT        NOT NULL UNIQUE,
  name            TEXT        NOT NULL,
  description     TEXT,
  price           NUMERIC(12,2) NOT NULL,
  currency        TEXT        NOT NULL DEFAULT 'IDR',
  billing_cycle   TEXT        NOT NULL DEFAULT 'monthly'
                              CHECK (billing_cycle IN ('monthly', 'yearly', 'one_time')),
  -- 'one_time' = purchase once, access until subscription expires
  is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
  is_stackable    BOOLEAN     NOT NULL DEFAULT FALSE,
  -- TRUE = multiple units can be purchased (e.g. extra storage × 3)
  sort_order      INTEGER     NOT NULL DEFAULT 0,
  metadata        JSONB       NOT NULL DEFAULT '{}',
  -- { stripe_price_id, midtrans_plan_id, icon, badge_color }
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_add_ons_updated_at
  BEFORE UPDATE ON add_ons
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_add_ons_slug   ON add_ons(slug);
CREATE INDEX idx_add_ons_active ON add_ons(is_active, sort_order);
```

---

### 3.7 Table: `add_on_features`

**Purpose:** Maps which features (and at what config) an add-on unlocks.

```sql
CREATE TABLE add_on_features (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  add_on_id   UUID        NOT NULL REFERENCES add_ons(id) ON DELETE CASCADE,
  feature_id  UUID        NOT NULL REFERENCES features(id) ON DELETE CASCADE,
  is_enabled  BOOLEAN     NOT NULL DEFAULT TRUE,
  config      JSONB       NOT NULL DEFAULT '{}',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (add_on_id, feature_id)
);

CREATE INDEX idx_aof_add_on_id  ON add_on_features(add_on_id);
CREATE INDEX idx_aof_feature_id ON add_on_features(feature_id);
```

---

### 3.8 Table: `tenant_add_ons`

**Purpose:** Tracks which add-ons a tenant has purchased and when they expire.

```sql
CREATE TABLE tenant_add_ons (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID        NOT NULL REFERENCES tenants(id),
  add_on_id       UUID        NOT NULL REFERENCES add_ons(id),
  quantity        INTEGER     NOT NULL DEFAULT 1 CHECK (quantity >= 1),
  -- For stackable add-ons (e.g. 3× extra storage)
  status          TEXT        NOT NULL DEFAULT 'active'
                              CHECK (status IN ('active', 'expired', 'cancelled')),
  starts_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at      TIMESTAMPTZ,
  -- null = tied to subscription lifetime; non-null = fixed expiry
  order_id        UUID        REFERENCES orders(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_tenant_add_ons_updated_at
  BEFORE UPDATE ON tenant_add_ons
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_tao_tenant_id ON tenant_add_ons(tenant_id, status)
  WHERE status = 'active';
CREATE INDEX idx_tao_expires_at ON tenant_add_ons(expires_at)
  WHERE status = 'active';
```

---

### 3.9 Table: `invitation_feature_overrides`

**Purpose:** Per-invitation feature overrides, settable by Super Admin or Reseller Admin. Allows enabling a premium feature for a single invitation regardless of tenant package.

```sql
CREATE TABLE invitation_feature_overrides (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id   UUID        NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  feature_id      UUID        NOT NULL REFERENCES features(id) ON DELETE CASCADE,
  tenant_id       UUID        NOT NULL REFERENCES tenants(id),
  is_enabled      BOOLEAN     NOT NULL DEFAULT TRUE,
  config          JSONB       NOT NULL DEFAULT '{}',
  override_reason TEXT,
  expires_at      TIMESTAMPTZ,
  -- null = permanent for invitation lifetime
  created_by      UUID        REFERENCES users(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (invitation_id, feature_id)
);

CREATE TRIGGER trg_ifo_updated_at
  BEFORE UPDATE ON invitation_feature_overrides
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_ifo_invitation_id ON invitation_feature_overrides(invitation_id);
CREATE INDEX idx_ifo_tenant_id     ON invitation_feature_overrides(tenant_id);
```

---

### 3.10 Table: `reseller_packages`

**Purpose:** Custom packages created by resellers, derived from platform base packages. Resellers control name, pricing, and which features are included (within the ceiling of their own base package).

```sql
CREATE TABLE reseller_packages (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reseller_id      UUID        NOT NULL REFERENCES resellers(id) ON DELETE CASCADE,
  base_package_id  UUID        NOT NULL REFERENCES packages(id),
  -- The platform package this is derived from. Defines the feature ceiling.
  slug             TEXT        NOT NULL UNIQUE,
  name             TEXT        NOT NULL,
  description      TEXT,
  price_monthly    NUMERIC(12,2) NOT NULL DEFAULT 0,
  price_yearly     NUMERIC(12,2) NOT NULL DEFAULT 0,
  price_lifetime   NUMERIC(12,2),
  currency         TEXT        NOT NULL DEFAULT 'IDR',
  is_active        BOOLEAN     NOT NULL DEFAULT TRUE,
  sort_order       INTEGER     NOT NULL DEFAULT 0,
  metadata         JSONB       NOT NULL DEFAULT '{}',
  -- { badge_label, highlight_color, notes }
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_reseller_packages_updated_at
  BEFORE UPDATE ON reseller_packages
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_rp_reseller_id ON reseller_packages(reseller_id, is_active);
CREATE INDEX idx_rp_base_pkg    ON reseller_packages(base_package_id);
```

---

### 3.11 Table: `reseller_package_features`

**Purpose:** Feature entitlements for reseller packages. Cannot exceed the entitlements of the `base_package_id` — enforced at application layer.

```sql
CREATE TABLE reseller_package_features (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reseller_package_id   UUID        NOT NULL REFERENCES reseller_packages(id) ON DELETE CASCADE,
  feature_id            UUID        NOT NULL REFERENCES features(id) ON DELETE CASCADE,
  is_enabled            BOOLEAN     NOT NULL DEFAULT TRUE,
  config                JSONB       NOT NULL DEFAULT '{}',
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (reseller_package_id, feature_id)
);

CREATE TRIGGER trg_rpf_updated_at
  BEFORE UPDATE ON reseller_package_features
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_rpf_pkg_id     ON reseller_package_features(reseller_package_id);
CREATE INDEX idx_rpf_feature_id ON reseller_package_features(feature_id);
```

---

### 3.12 Table: `feature_flag_overrides`

**Purpose:** Runtime overrides by Super Admin. Can enable or disable any feature for any tenant, independent of their package. Replaces the `feature_flags` table from Phase 2 with a normalized design.

```sql
CREATE TABLE feature_flag_overrides (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID        REFERENCES tenants(id) ON DELETE CASCADE,
  -- NULL = platform-wide override (affects all tenants)
  feature_id    UUID        NOT NULL REFERENCES features(id) ON DELETE CASCADE,
  is_enabled    BOOLEAN     NOT NULL DEFAULT TRUE,
  config        JSONB       NOT NULL DEFAULT '{}',
  reason        TEXT        NOT NULL,
  expires_at    TIMESTAMPTZ,
  created_by    UUID        NOT NULL REFERENCES users(id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, feature_id)
);

CREATE TRIGGER trg_ffo_updated_at
  BEFORE UPDATE ON feature_flag_overrides
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Partial index: platform-wide flags (tenant_id IS NULL)
CREATE INDEX idx_ffo_platform ON feature_flag_overrides(feature_id)
  WHERE tenant_id IS NULL;

-- Per-tenant overrides
CREATE INDEX idx_ffo_tenant ON feature_flag_overrides(tenant_id, feature_id)
  WHERE tenant_id IS NOT NULL;
```

---

## 4. Feature Resolution Engine

### 4.1 Resolution Priority

Features are resolved by merging multiple sources. **Higher priority wins.**

```
PRIORITY 1 (highest) — Platform Kill Switch
  feature_flag_overrides WHERE tenant_id IS NULL AND is_enabled = FALSE
  → If found: feature is DISABLED globally. Return immediately.

PRIORITY 2 — Platform Force-Enable
  feature_flag_overrides WHERE tenant_id IS NULL AND is_enabled = TRUE
  → If found: feature is ENABLED globally (e.g. for beta rollout).

PRIORITY 3 — Tenant-Level Override
  feature_flag_overrides WHERE tenant_id = $tenantId
  → If found: use this value (enabled or disabled). Overrides package entitlement.

PRIORITY 4 — Add-On Entitlement
  tenant_add_ons JOIN add_on_features WHERE tenant_id = $tenantId AND status = 'active'
  → If feature found in active add-on: ENABLED with add-on config.

PRIORITY 5 — Reseller Package Entitlement
  (if subscription was via a reseller_package_id)
  reseller_package_features WHERE reseller_package_id = $resellerPackageId
  → If found: use reseller package's is_enabled + config.

PRIORITY 6 — Base Package Entitlement
  package_features WHERE package_id = $packageId
  → If found: use package's is_enabled + config.

PRIORITY 7 (lowest) — Default
  features.default_config, is_enabled = FALSE
```

### 4.2 Resolution Algorithm (TypeScript)

```typescript
// lib/packages/feature-resolver.ts

import { createServerClient } from '@/lib/supabase/server';
import type { FeatureKey } from '@/config/features';

export interface FeatureResolution {
  enabled: boolean;
  config: Record<string, unknown>;
  source: ResolutionSource;
  limitValue?: number;
}

export type ResolutionSource =
  | 'platform_kill_switch'
  | 'platform_force_enable'
  | 'tenant_override'
  | 'add_on'
  | 'reseller_package'
  | 'package'
  | 'default';

export interface TenantFeatureContext {
  tenantId: string;
  packageId: string;
  resellerPackageId?: string;
}

// ─────────────────────────────────────────────────────────────────
// Resolve a SINGLE feature for a tenant (used for one-off checks)
// ─────────────────────────────────────────────────────────────────
export async function resolveFeature(
  ctx: TenantFeatureContext,
  featureKey: FeatureKey
): Promise<FeatureResolution> {
  const all = await resolveAllFeatures(ctx);
  return all[featureKey] ?? { enabled: false, config: {}, source: 'default' };
}

// ─────────────────────────────────────────────────────────────────
// Resolve ALL features for a tenant in a single DB round-trip.
// Call this once per request in the root layout, then pass via context.
// ─────────────────────────────────────────────────────────────────
export async function resolveAllFeatures(
  ctx: TenantFeatureContext
): Promise<Record<FeatureKey, FeatureResolution>> {
  const supabase = createServerClient();

  // 1. Fetch everything in parallel
  const [
    allFeatures,
    platformOverrides,
    tenantOverrides,
    packageEntitlements,
    resellerEntitlements,
    addOnEntitlements,
  ] = await Promise.all([
    getAllFeatures(supabase),
    getPlatformOverrides(supabase),
    getTenantOverrides(supabase, ctx.tenantId),
    getPackageEntitlements(supabase, ctx.packageId),
    ctx.resellerPackageId
      ? getResellerEntitlements(supabase, ctx.resellerPackageId)
      : Promise.resolve([]),
    getActiveAddOnEntitlements(supabase, ctx.tenantId),
  ]);

  // 2. Build resolution map
  const result: Record<string, FeatureResolution> = {};

  for (const feature of allFeatures) {
    if (!feature.is_active) {
      result[feature.key] = { enabled: false, config: {}, source: 'default' };
      continue;
    }

    // Priority 1 & 2: Platform overrides
    const platformOverride = platformOverrides.find(f => f.feature_id === feature.id);
    if (platformOverride) {
      result[feature.key] = {
        enabled: platformOverride.is_enabled,
        config: platformOverride.config,
        source: platformOverride.is_enabled ? 'platform_force_enable' : 'platform_kill_switch',
      };
      continue;
    }

    // Priority 3: Tenant-level override
    const tenantOverride = tenantOverrides.find(f => f.feature_id === feature.id);
    if (tenantOverride) {
      result[feature.key] = {
        enabled: tenantOverride.is_enabled,
        config: mergeConfig(feature.default_config, tenantOverride.config),
        source: 'tenant_override',
      };
      continue;
    }

    // Priority 4: Add-on entitlement
    const addOnEntry = addOnEntitlements.find(f => f.feature_id === feature.id);
    if (addOnEntry?.is_enabled) {
      result[feature.key] = {
        enabled: true,
        config: mergeConfig(feature.default_config, addOnEntry.config),
        source: 'add_on',
      };
      continue;
    }

    // Priority 5: Reseller package entitlement
    const resellerEntry = resellerEntitlements.find(f => f.feature_id === feature.id);
    if (resellerEntry) {
      result[feature.key] = {
        enabled: resellerEntry.is_enabled,
        config: mergeConfig(feature.default_config, resellerEntry.config),
        limitValue: resellerEntry.limit_value ?? undefined,
        source: 'reseller_package',
      };
      continue;
    }

    // Priority 6: Base package entitlement
    const packageEntry = packageEntitlements.find(f => f.feature_id === feature.id);
    if (packageEntry) {
      result[feature.key] = {
        enabled: packageEntry.is_enabled,
        config: mergeConfig(feature.default_config, packageEntry.config),
        limitValue: packageEntry.limit_value ?? undefined,
        source: 'package',
      };
      continue;
    }

    // Priority 7: Default (disabled)
    result[feature.key] = {
      enabled: false,
      config: feature.default_config,
      source: 'default',
    };
  }

  return result as Record<FeatureKey, FeatureResolution>;
}

// ─────────────────────────────────────────────────────────────────
// Invitation-level override check (called on public invitation page)
// Merged on top of the tenant resolution result
// ─────────────────────────────────────────────────────────────────
export async function resolveInvitationFeature(
  tenantResolution: Record<FeatureKey, FeatureResolution>,
  invitationId: string,
  featureKey: FeatureKey
): Promise<FeatureResolution> {
  const supabase = createServerClient();

  const { data: override } = await supabase
    .from('invitation_feature_overrides')
    .select('is_enabled, config, expires_at')
    .eq('invitation_id', invitationId)
    .eq('feature_id', getFeatureId(featureKey))
    .single();

  if (!override) return tenantResolution[featureKey];

  // Check expiry
  if (override.expires_at && new Date(override.expires_at) < new Date()) {
    return tenantResolution[featureKey];
  }

  return {
    enabled: override.is_enabled,
    config: override.config,
    source: 'tenant_override',   // closest semantic match for invitation overrides
  };
}

function mergeConfig(
  defaults: Record<string, unknown>,
  override: Record<string, unknown>
): Record<string, unknown> {
  return { ...defaults, ...override };
}
```

### 4.3 React Context Integration

```typescript
// app/(app)/layout.tsx — server component

import { resolveAllFeatures } from '@/lib/packages/feature-resolver';
import { FeatureFlagProvider } from '@/components/providers/FeatureFlagProvider';
import { requireSession } from '@/lib/auth/session';

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const user = await requireSession();

  // Single DB round-trip — resolves all features for this tenant
  const features = await resolveAllFeatures({
    tenantId: user.tenantId,
    packageId: user.packageId,
    resellerPackageId: user.resellerPackageId,
  });

  return (
    <FeatureFlagProvider features={features}>
      {children}
    </FeatureFlagProvider>
  );
}
```

```typescript
// hooks/use-feature.ts

import { useFeatureFlagContext } from '@/components/providers/FeatureFlagProvider';
import type { FeatureKey } from '@/config/features';
import type { FeatureResolution } from '@/lib/packages/feature-resolver';

export function useFeature(key: FeatureKey): FeatureResolution {
  const features = useFeatureFlagContext();
  return features[key] ?? { enabled: false, config: {}, source: 'default' };
}

export function useIsEnabled(key: FeatureKey): boolean {
  return useFeature(key).enabled;
}

export function useFeatureConfig<T extends Record<string, unknown>>(key: FeatureKey): T {
  return useFeature(key).config as T;
}

// Component usage
function GallerySection() {
  const isEnabled = useIsEnabled('gallery');
  const config = useFeatureConfig<{ max_photos: number }>('gallery');

  if (!isEnabled) return <UpgradePrompt feature="Photo Gallery" plan="Basic" />;

  return <Gallery maxPhotos={config.max_photos} />;
}
```

### 4.4 Quota Resolution

Quotas (max_invitations, max_guests, etc.) are resolved from the packages table, not from feature flags. They are checked server-side before any create operation.

```typescript
// lib/packages/quota.ts

export interface QuotaCheck {
  allowed: boolean;
  limit: number;          // -1 = unlimited
  current: number;
  remaining: number;      // -1 = unlimited
}

export async function checkQuota(
  tenantId: string,
  resource: 'invitations' | 'guests' | 'photos' | 'team_members' | 'music_tracks' | 'storage_mb'
): Promise<QuotaCheck> {
  const supabase = createServerClient();

  // Get active subscription with package quotas
  const { data: sub } = await supabase
    .from('tenant_subscriptions')
    .select(`
      package:packages (
        max_invitations, max_guests, max_photos,
        max_team_members, max_music_tracks, max_storage_mb
      )
    `)
    .eq('tenant_id', tenantId)
    .in('status', ['active', 'trialing'])
    .order('created_at', { ascending: false })
    .limit(1)
    .single();

  const pkg = sub?.package;
  if (!pkg) return { allowed: false, limit: 0, current: 0, remaining: 0 };

  const limitKey = `max_${resource}` as keyof typeof pkg;
  const limit = (pkg[limitKey] as number) ?? 0;

  const current = await getCurrentUsage(supabase, tenantId, resource);

  // Check add-on quota boost
  const addOnBoost = await getAddOnQuotaBoost(supabase, tenantId, resource);
  const effectiveLimit = limit === -1 ? -1 : limit + addOnBoost;

  if (effectiveLimit === -1) {
    return { allowed: true, limit: -1, current, remaining: -1 };
  }

  return {
    allowed: current < effectiveLimit,
    limit: effectiveLimit,
    current,
    remaining: Math.max(0, effectiveLimit - current),
  };
}

// Add-ons can boost quotas (e.g. "Extra Storage" add-on adds 5GB)
async function getAddOnQuotaBoost(
  supabase: SupabaseClient,
  tenantId: string,
  resource: string
): Promise<number> {
  const featureKey = `extra_${resource}`;

  const { data: addOnFeatures } = await supabase
    .from('tenant_add_ons')
    .select(`
      quantity,
      add_on:add_ons (
        add_on_features (
          config,
          feature:features!inner (key)
        )
      )
    `)
    .eq('tenant_id', tenantId)
    .eq('status', 'active');

  let boost = 0;
  for (const tao of addOnFeatures ?? []) {
    for (const aof of tao.add_on?.add_on_features ?? []) {
      if (aof.feature?.key === featureKey) {
        const perUnit = (aof.config as any)?.boost_value ?? 0;
        boost += perUnit * tao.quantity;
      }
    }
  }
  return boost;
}
```

---

## 5. Add-On System

### 5.1 Available Add-Ons (Seed Data)

```sql
-- supabase/migrations/seed_add_ons.sql

INSERT INTO add_ons (slug, name, description, price, currency, billing_cycle, is_stackable) VALUES
  ('qr-checkin',      'QR Check-In',       'Physical event check-in scanner for unlimited guests', 49000,  'IDR', 'monthly',  FALSE),
  ('custom-domain',   'Custom Domain',     'Use your own domain for the invitation URL',            29000,  'IDR', 'monthly',  FALSE),
  ('extra-storage',   'Extra Storage',     'Add 5GB of media storage to your account',              19000,  'IDR', 'monthly',  TRUE),
  ('extra-photos',    'Extra Gallery',     'Add 50 photo slots per invitation',                     15000,  'IDR', 'monthly',  TRUE),
  ('livestream',      'Live Streaming',    'Embed a YouTube/Zoom livestream link',                  39000,  'IDR', 'one_time', FALSE),
  ('analytics-pro',   'Analytics Pro',    'Advanced analytics: device, referrer, heatmap',         29000,  'IDR', 'monthly',  FALSE),
  ('video-bg',        'Video Background', 'Add video background to Hero section',                  35000,  'IDR', 'one_time', FALSE),
  ('whatsapp-blast',  'WhatsApp Blast',   'Send personalized WhatsApp invites to all guests',      25000,  'IDR', 'one_time', FALSE);

-- Map add-on features
INSERT INTO add_on_features (add_on_id, feature_id, is_enabled, config) VALUES
  ((SELECT id FROM add_ons WHERE slug='qr-checkin'),    (SELECT id FROM features WHERE key='qr_checkin'),          TRUE, '{"max_devices": 3}'),
  ((SELECT id FROM add_ons WHERE slug='custom-domain'), (SELECT id FROM features WHERE key='custom_domain'),       TRUE, '{}'),
  ((SELECT id FROM add_ons WHERE slug='extra-storage'), (SELECT id FROM features WHERE key='extra_storage'),       TRUE, '{"boost_value": 5120}'),
  ((SELECT id FROM add_ons WHERE slug='extra-photos'),  (SELECT id FROM features WHERE key='extra_gallery_photos'),TRUE, '{"boost_value": 50}'),
  ((SELECT id FROM add_ons WHERE slug='livestream'),    (SELECT id FROM features WHERE key='livestream_embed'),    TRUE, '{}'),
  ((SELECT id FROM add_ons WHERE slug='analytics-pro'), (SELECT id FROM features WHERE key='analytics_advanced'),  TRUE, '{"retention_days": 180}'),
  ((SELECT id FROM add_ons WHERE slug='video-bg'),      (SELECT id FROM features WHERE key='video_background'),    TRUE, '{"max_video_mb": 100}'),
  ((SELECT id FROM add_ons WHERE slug='whatsapp-blast'),(SELECT id FROM features WHERE key='guest_whatsapp_blast'),TRUE, '{"max_recipients_per_day": 500}');
```

### 5.2 Add-On Purchase Flow

```
User views add-on in /subscription or during invitation creation
  │
  ▼
Clicks "Add" on add-on card
  │
  ▼
AddOnPurchaseModal opens:
  - Add-on name + description
  - Price + billing cycle
  - Quantity selector (if stackable)
  - Total calculation
  │
  ▼
POST /api/add-ons/purchase { add_on_id, quantity, billing_cycle }
  │
  ▼
Server: checkAddOnCompatibility()
  - Is add-on already active for this tenant?
  - If not stackable and already active → return error
  │
  ▼
Order created → payment processed
  │
  ├─ SUCCESS
  │     │
  │     ▼
  │   tenant_add_ons row inserted:
  │     status = 'active'
  │     expires_at = subscription.current_period_end (if monthly)
  │               = NULL (if one_time)
  │   Feature cache invalidated for tenant
  │
  └─ FAILURE → Order failed. No add-on created.
```

### 5.3 Add-On Lifecycle

```typescript
// lib/packages/add-ons.ts

// Add-ons tied to subscription period expire when subscription expires
// One-time add-ons persist as long as subscription is active

export async function syncAddOnExpiry(tenantId: string): Promise<void> {
  const supabase = createServerClient();

  const { data: sub } = await supabase
    .from('tenant_subscriptions')
    .select('current_period_end')
    .eq('tenant_id', tenantId)
    .in('status', ['active', 'trialing'])
    .single();

  if (!sub) return;

  // Sync monthly add-on expiry to subscription period end
  await supabase
    .from('tenant_add_ons')
    .update({ expires_at: sub.current_period_end })
    .eq('tenant_id', tenantId)
    .eq('status', 'active')
    .in('add_on_id',
      supabase
        .from('add_ons')
        .select('id')
        .eq('billing_cycle', 'monthly')
    );
}

// Nightly cron: expire add-ons past their expiry date
export async function expireStaleAddOns(): Promise<void> {
  const admin = createAdminClient();
  await admin
    .from('tenant_add_ons')
    .update({ status: 'expired' })
    .eq('status', 'active')
    .lt('expires_at', new Date().toISOString());
}
```

---

## 6. Package Upgrade Flow

### 6.1 Upgrade / Downgrade Server Action

```typescript
// app/api/subscription/change/route.ts

import { requireAuth } from '@/lib/auth/api-guard';
import { checkQuota } from '@/lib/packages/quota';
import { createOrder } from '@/lib/payments/orders';
import { writeAuditLog } from '@/lib/audit/write';

export async function POST(request: Request) {
  const auth = await requireAuth(request, 'subscription:write');
  if (auth instanceof NextResponse) return auth;

  const { package_id, billing_cycle } = await request.json();

  const supabase = createServerClient();

  // Validate target package exists and is public
  const { data: targetPackage } = await supabase
    .from('packages')
    .select('*')
    .eq('id', package_id)
    .eq('status', 'active')
    .eq('is_public', true)
    .single();

  if (!targetPackage) {
    return NextResponse.json({ error: 'Package not found' }, { status: 404 });
  }

  // Get current subscription
  const { data: currentSub } = await supabase
    .from('tenant_subscriptions')
    .select('*, package:packages(*)')
    .eq('tenant_id', auth.user.tenantId)
    .in('status', ['active', 'trialing'])
    .single();

  const isUpgrade = targetPackage.sort_order > (currentSub?.package?.sort_order ?? 0);
  const isDowngrade = targetPackage.sort_order < (currentSub?.package?.sort_order ?? 0);

  if (isUpgrade) {
    return handleUpgrade(auth.user, currentSub, targetPackage, billing_cycle);
  }

  if (isDowngrade) {
    return handleDowngrade(auth.user, currentSub, targetPackage);
  }

  // Same package — change billing cycle only
  return handleBillingCycleChange(auth.user, currentSub, billing_cycle);
}

async function handleUpgrade(user, currentSub, targetPackage, billingCycle) {
  // Calculate proration
  const now = new Date();
  const periodEnd = new Date(currentSub.current_period_end);
  const periodStart = new Date(currentSub.current_period_start);
  const totalDays = (periodEnd.getTime() - periodStart.getTime()) / 86400000;
  const remainingDays = (periodEnd.getTime() - now.getTime()) / 86400000;
  const currentMonthlyPrice = currentSub.package.price_monthly;
  const prorationCredit = (remainingDays / totalDays) * currentMonthlyPrice;

  const grossAmount = billingCycle === 'yearly'
    ? targetPackage.price_yearly
    : targetPackage.price_monthly;

  const order = await createOrder({
    tenantId: user.tenantId,
    packageId: targetPackage.id,
    billingCycle,
    amountGross: grossAmount,
    amountDiscount: Math.min(prorationCredit, grossAmount),
    amountNet: Math.max(0, grossAmount - prorationCredit),
    currency: targetPackage.currency,
  });

  return NextResponse.json({ order_id: order.id, payment_url: order.payment_url });
}

async function handleDowngrade(user, currentSub, targetPackage) {
  const supabase = createServerClient();

  // Schedule downgrade at period end — do not change package now
  await supabase
    .from('tenant_subscriptions')
    .update({ pending_downgrade_package_id: targetPackage.id })
    .eq('id', currentSub.id);

  await writeAuditLog(null, 'subscription.downgrade_scheduled', 'tenant_subscription', currentSub.id, {
    tenantId: user.tenantId,
    userId: user.id,
    newData: { pending_downgrade_package_id: targetPackage.id },
  });

  return NextResponse.json({
    scheduled: true,
    effective_date: currentSub.current_period_end,
    message: `Your plan will change to ${targetPackage.name} on ${formatDate(currentSub.current_period_end)}.`,
  });
}
```

### 6.2 Renewal Cron Job

```typescript
// supabase/functions/process-renewals/index.ts

import { createClient } from '@supabase/supabase-js';

const admin = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
);

Deno.serve(async () => {
  const now = new Date();

  // 1. Apply scheduled downgrades for expired periods
  const { data: pendingDowngrades } = await admin
    .from('tenant_subscriptions')
    .select('id, tenant_id, pending_downgrade_package_id')
    .not('pending_downgrade_package_id', 'is', null)
    .lte('current_period_end', now.toISOString())
    .in('status', ['active']);

  for (const sub of pendingDowngrades ?? []) {
    await admin
      .from('tenant_subscriptions')
      .update({
        package_id: sub.pending_downgrade_package_id,
        pending_downgrade_package_id: null,
        current_period_start: now.toISOString(),
        current_period_end: addMonths(now, 1).toISOString(),
      })
      .eq('id', sub.id);

    await enforceQuotaLimits(sub.tenant_id, sub.pending_downgrade_package_id);
    await sendEmail(sub.tenant_id, 'subscription_downgraded');
  }

  // 2. Expire past-grace subscriptions → downgrade to Free
  const { data: expiredGrace } = await admin
    .from('tenant_subscriptions')
    .select('id, tenant_id')
    .lte('grace_ends_at', now.toISOString())
    .eq('status', 'past_due');

  for (const sub of expiredGrace ?? []) {
    const { data: freePkg } = await admin
      .from('packages')
      .select('id')
      .eq('slug', 'free')
      .single();

    await admin
      .from('tenant_subscriptions')
      .update({ status: 'expired', package_id: freePkg!.id })
      .eq('id', sub.id);

    await enforceQuotaLimits(sub.tenant_id, freePkg!.id);
    await sendEmail(sub.tenant_id, 'subscription_expired');
  }

  // 3. Send renewal reminders (7 days before expiry)
  const reminderDate = addDays(now, 7);
  const { data: upcoming } = await admin
    .from('tenant_subscriptions')
    .select('tenant_id, current_period_end')
    .between('current_period_end', now.toISOString(), reminderDate.toISOString())
    .eq('status', 'active')
    .eq('auto_renew', true);

  for (const sub of upcoming ?? []) {
    await sendEmail(sub.tenant_id, 'renewal_reminder', {
      renewal_date: sub.current_period_end,
    });
  }

  return new Response(JSON.stringify({ processed: true }), { status: 200 });
});
```

---

## 7. Reseller Package System

### 7.1 Reseller Package Constraints

Reseller packages are **derived** from platform base packages. The platform base package defines a hard ceiling: a reseller cannot grant features or quota above what their own base package allows.

```
Platform "Reseller Base" package:
  max_invitations = -1 (unlimited)
  max_guests = -1
  Features: ALL enabled

Reseller creates "Silver Plan":
  base_package = "Reseller Base"
  max_invitations = 3       ← reseller sets sub-limit
  max_guests = 100
  price_monthly = 79000     ← reseller's own pricing
  Features: rsvp ✅, gallery ✅, music_player ❌   ← reseller limits features

Tenant subscribes to "Silver Plan" via Reseller:
  Effective features = reseller_package_features (Silver Plan) joined with add-ons
  Effective quotas   = reseller package's max_* columns
```

### 7.2 Reseller Package Management API

```typescript
// app/api/reseller/packages/route.ts

export async function POST(request: Request) {
  const auth = await requireAuth(request, 'reseller:write');
  if (auth instanceof NextResponse) return auth;

  const body = await request.json();
  const supabase = createServerClient();

  // Validate base package exists and is reseller-eligible
  const { data: basePkg } = await supabase
    .from('packages')
    .select('*')
    .eq('id', body.base_package_id)
    .eq('is_reseller_base', true)
    .eq('status', 'active')
    .single();

  if (!basePkg) {
    return NextResponse.json({ error: 'Invalid base package' }, { status: 400 });
  }

  // Enforce quota ceilings: reseller cannot exceed base package quotas
  const quotaFields = [
    'max_invitations', 'max_guests', 'max_photos',
    'max_team_members', 'max_music_tracks', 'max_storage_mb'
  ] as const;

  for (const field of quotaFields) {
    const baseLimit = basePkg[field];
    const resellerLimit = body[field];
    if (baseLimit !== -1 && resellerLimit > baseLimit) {
      return NextResponse.json({
        error: `${field} cannot exceed base package limit of ${baseLimit}`
      }, { status: 422 });
    }
  }

  // Create reseller package
  const { data: newPackage } = await supabase
    .from('reseller_packages')
    .insert({
      reseller_id: auth.user.resellerId,
      base_package_id: body.base_package_id,
      slug: body.slug,
      name: body.name,
      description: body.description,
      price_monthly: body.price_monthly,
      price_yearly: body.price_yearly,
      currency: body.currency ?? 'IDR',
    })
    .select()
    .single();

  // Copy base package features as default, then apply reseller overrides
  await seedResellerPackageFeatures(
    supabase,
    newPackage!.id,
    basePkg.id,
    body.feature_overrides ?? []
  );

  return NextResponse.json(newPackage);
}

async function seedResellerPackageFeatures(
  supabase: SupabaseClient,
  resellerPackageId: string,
  basePackageId: string,
  overrides: Array<{ feature_id: string; is_enabled: boolean; config: object }>
) {
  // Copy all features from base package
  const { data: baseFeatures } = await supabase
    .from('package_features')
    .select('feature_id, is_enabled, config, limit_value')
    .eq('package_id', basePackageId);

  const overrideMap = new Map(overrides.map(o => [o.feature_id, o]));

  const rows = (baseFeatures ?? []).map(bf => {
    const override = overrideMap.get(bf.feature_id);
    return {
      reseller_package_id: resellerPackageId,
      feature_id: bf.feature_id,
      // Reseller can only disable, not enable above base
      is_enabled: override ? (bf.is_enabled && override.is_enabled) : bf.is_enabled,
      config: override?.config ?? bf.config,
    };
  });

  await supabase.from('reseller_package_features').insert(rows);
}
```

### 7.3 Reseller Package Pricing Rules

```
Platform Reseller Base wholesale price: Rp 299.000/mo

Reseller creates packages:
  Silver Plan:  sells at Rp  79.000/mo → margin = Rp 299.000 distributed across clients
  Gold Plan:    sells at Rp 149.000/mo → margin = larger per client
  Platinum Plan: sells at Rp 249.000/mo

Reseller margin = (client_count × client_price_monthly) - reseller_base_subscription_cost

Commission is NOT applied to reseller package sales.
Commission (reseller.commission_pct) only applies to direct platform package sales
attributed to a reseller's referral link.

Reseller packages = wholesale model (reseller owns client billing)
Platform attribution = commission model (reseller earns % of referred direct sales)
```

---

## 8. White Label Preparation

### 8.1 White Label Package Fields

The `packages` table metadata JSONB already supports white-label extensions:

```typescript
// packages.metadata shape for white-label support

interface PackageMetadata {
  // Pricing display
  badge_label?: string;        // "Most Popular", "Best Value"
  highlight_color?: string;    // "#8B5CF6"
  cta_text?: string;           // "Start Free Trial"

  // Payment provider IDs
  stripe_price_id_monthly?: string;
  stripe_price_id_yearly?: string;
  midtrans_plan_id?: string;

  // White-label overrides (Phase 3+)
  white_label?: {
    allowed: boolean;
    custom_branding: boolean;     // reseller can set own logo/colors
    custom_domain: boolean;       // reseller client gets custom domain
    hide_platform_name: boolean;  // removes "Powered by" badge
    custom_email_from: boolean;   // reseller can set own From email
  };

  // Grace period override
  grace_period_days?: number;

  // Enterprise fields
  is_negotiable?: boolean;        // enterprise plan with custom pricing
  sla_uptime_pct?: number;        // 99.9
  dedicated_support?: boolean;
}
```

### 8.2 White Label Feature Resolution

When a tenant is under a reseller with white-label enabled, the feature resolution engine applies additional context:

```typescript
// lib/packages/white-label.ts

export interface WhiteLabelContext {
  resellerId: string;
  branding: {
    logo_url?: string;
    primary_color?: string;
    company_name: string;
    support_email?: string;
    hide_platform_badge: boolean;
    custom_domain?: string;
  };
  allowedFeatures: {
    custom_branding: boolean;
    custom_domain: boolean;
    custom_email_from: boolean;
  };
}

export async function getWhiteLabelContext(
  resellerId: string
): Promise<WhiteLabelContext | null> {
  const supabase = createServerClient();

  const { data: reseller } = await supabase
    .from('resellers')
    .select('branding, status')
    .eq('id', resellerId)
    .eq('status', 'active')
    .single();

  if (!reseller) return null;

  return {
    resellerId,
    branding: reseller.branding,
    allowedFeatures: {
      custom_branding: reseller.branding?.hide_platform_badge ?? false,
      custom_domain: !!(reseller.branding?.custom_domain),
      custom_email_from: false, // Phase 3+
    },
  };
}
```

### 8.3 CSS Variable Injection for White Label

```typescript
// app/(app)/layout.tsx

const whiteLabelCtx = user.resellerId
  ? await getWhiteLabelContext(user.resellerId)
  : null;

const cssVars = whiteLabelCtx ? `
  :root {
    --brand-primary: ${whiteLabelCtx.branding.primary_color ?? '#a855f7'};
    --brand-name: "${whiteLabelCtx.branding.company_name}";
    --brand-logo: url("${whiteLabelCtx.branding.logo_url ?? ''}");
  }
` : '';
```

---

## 9. Admin Management

### 9.1 Package Management UI

#### Create Package

```typescript
// Validation schema — enforced before DB write
const CreatePackageSchema = z.object({
  slug: z.string().min(2).max(50).regex(/^[a-z0-9-]+$/),
  name: z.string().min(1).max(100),
  description: z.string().max(500).optional(),
  status: z.enum(['draft', 'active']),
  type: z.enum(['platform', 'reseller_base', 'internal']),
  price_monthly: z.coerce.number().min(0),
  price_yearly: z.coerce.number().min(0),
  price_lifetime: z.coerce.number().min(0).optional(),
  currency: z.string().length(3),
  trial_days: z.coerce.number().min(0).max(90),
  grace_period_days: z.coerce.number().min(0).max(30),
  max_invitations: z.coerce.number().min(-1),
  max_guests: z.coerce.number().min(-1),
  max_photos: z.coerce.number().min(-1),
  max_team_members: z.coerce.number().min(-1),
  max_music_tracks: z.coerce.number().min(-1),
  max_storage_mb: z.coerce.number().min(-1),
  is_public: z.boolean(),
  is_featured: z.boolean(),
  is_reseller_base: z.boolean(),
  sort_order: z.coerce.number().min(0),
  metadata: z.record(z.unknown()).optional(),
});

export async function createPackageAction(
  prevState: FormState,
  formData: FormData
): Promise<FormState> {
  const user = await requireRole(['super_admin']);
  const parsed = CreatePackageSchema.safeParse(Object.fromEntries(formData));
  if (!parsed.success) return { errors: parsed.error.flatten().fieldErrors };

  const admin = createAdminClient();

  const { data: pkg, error } = await admin
    .from('packages')
    .insert(parsed.data)
    .select()
    .single();

  if (error) return { errors: { _form: [error.message] } };

  await writeAuditLog(null, 'package.create', 'package', pkg.id, {
    userId: user.id,
    newData: pkg,
  });

  revalidatePath('/admin/packages');
  redirect(`/admin/packages/${pkg.id}`);
}
```

#### Clone Package

```typescript
export async function clonePackageAction(packageId: string): Promise<string> {
  const user = await requireRole(['super_admin']);
  const admin = createAdminClient();

  // Fetch source package + its features
  const { data: source } = await admin
    .from('packages')
    .select('*, package_features(*)')
    .eq('id', packageId)
    .single();

  if (!source) throw new Error('Package not found');

  // Create clone with modified slug and draft status
  const { data: clone } = await admin
    .from('packages')
    .insert({
      ...omit(source, ['id', 'created_at', 'updated_at', 'package_features']),
      slug: `${source.slug}-copy-${Date.now()}`,
      name: `${source.name} (Copy)`,
      status: 'draft',
      is_public: false,
      created_by: user.id,
    })
    .select()
    .single();

  // Clone feature entitlements
  if (source.package_features?.length) {
    await admin.from('package_features').insert(
      source.package_features.map((pf: any) => ({
        package_id: clone!.id,
        feature_id: pf.feature_id,
        is_enabled: pf.is_enabled,
        config: pf.config,
        limit_value: pf.limit_value,
      }))
    );
  }

  await writeAuditLog(null, 'package.clone', 'package', clone!.id, {
    userId: user.id,
    oldData: { source_package_id: packageId },
    newData: clone,
  });

  return clone!.id;
}
```

#### Deprecate / Archive Package

```typescript
export async function deprecatePackageAction(packageId: string): Promise<void> {
  const user = await requireRole(['super_admin']);
  const admin = createAdminClient();

  // Check for active subscriptions
  const { count } = await admin
    .from('tenant_subscriptions')
    .select('id', { count: 'exact', head: true })
    .eq('package_id', packageId)
    .in('status', ['active', 'trialing']);

  if ((count ?? 0) > 0) {
    throw new Error(
      `Cannot deprecate: ${count} active subscriptions. Set a successor package first.`
    );
  }

  await admin
    .from('packages')
    .update({ status: 'deprecated', is_public: false })
    .eq('id', packageId);

  await writeAuditLog(null, 'package.deprecate', 'package', packageId, {
    userId: user.id,
  });
}
```

### 9.2 Feature Management UI

```typescript
// Create Feature
const CreateFeatureSchema = z.object({
  key: z.string().min(2).max(80).regex(/^[a-z0-9_]+$/),
  name: z.string().min(1).max(100),
  description: z.string().max(500).optional(),
  category: z.enum([
    'content', 'rsvp', 'guest_management', 'qr',
    'analytics', 'customization', 'export', 'team', 'storage', 'platform'
  ]),
  config_schema: z.record(z.unknown()).optional(),
  default_config: z.record(z.unknown()).optional(),
  is_system: z.boolean().default(false),
  is_add_on_eligible: z.boolean().default(false),
  sort_order: z.coerce.number().min(0),
});

export async function createFeatureAction(
  prevState: FormState,
  formData: FormData
): Promise<FormState> {
  const user = await requireRole(['super_admin']);
  const parsed = CreateFeatureSchema.safeParse(Object.fromEntries(formData));
  if (!parsed.success) return { errors: parsed.error.flatten().fieldErrors };

  const admin = createAdminClient();
  const { data: feature } = await admin
    .from('features')
    .insert(parsed.data)
    .select()
    .single();

  // Auto-add this feature (disabled) to all existing packages
  const { data: packages } = await admin
    .from('packages')
    .select('id')
    .neq('status', 'archived');

  if (packages?.length) {
    await admin.from('package_features').insert(
      packages.map(pkg => ({
        package_id: pkg.id,
        feature_id: feature!.id,
        is_enabled: false,
        config: {},
      }))
    );
  }

  await writeAuditLog(null, 'feature.create', 'feature', feature!.id, {
    userId: user.id,
    newData: feature,
  });

  revalidatePath('/admin/feature-flags');
  return { success: true };
}
```

### 9.3 Add-On Management UI

```typescript
const CreateAddOnSchema = z.object({
  slug: z.string().min(2).max(50).regex(/^[a-z0-9-]+$/),
  name: z.string().min(1).max(100),
  description: z.string().max(500).optional(),
  price: z.coerce.number().min(0),
  currency: z.string().length(3),
  billing_cycle: z.enum(['monthly', 'yearly', 'one_time']),
  is_stackable: z.boolean(),
  sort_order: z.coerce.number().min(0),
  features: z.array(z.object({
    feature_id: z.string().uuid(),
    is_enabled: z.boolean(),
    config: z.record(z.unknown()),
  })),
});

export async function createAddOnAction(
  prevState: FormState,
  formData: FormData
): Promise<FormState> {
  const user = await requireRole(['super_admin']);
  const raw = Object.fromEntries(formData);
  const parsed = CreateAddOnSchema.safeParse({
    ...raw,
    features: JSON.parse(raw.features as string),
  });

  if (!parsed.success) return { errors: parsed.error.flatten().fieldErrors };

  const admin = createAdminClient();

  const { data: addOn } = await admin
    .from('add_ons')
    .insert(omit(parsed.data, ['features']))
    .select()
    .single();

  if (parsed.data.features.length) {
    await admin.from('add_on_features').insert(
      parsed.data.features.map(f => ({
        add_on_id: addOn!.id,
        feature_id: f.feature_id,
        is_enabled: f.is_enabled,
        config: f.config,
      }))
    );
  }

  revalidatePath('/admin/add-ons');
  return { success: true };
}
```

---

## 10. Permission Mapping

### 10.1 Who Can Manage What

| Action | super_admin | reseller_admin | owner | editor | viewer |
|---|:---:|:---:|:---:|:---:|:---:|
| **PACKAGES** | | | | | |
| Create platform package | ✅ | ❌ | ❌ | ❌ | ❌ |
| Edit platform package | ✅ | ❌ | ❌ | ❌ | ❌ |
| Clone platform package | ✅ | ❌ | ❌ | ❌ | ❌ |
| Deprecate / archive package | ✅ | ❌ | ❌ | ❌ | ❌ |
| View platform packages (pricing) | ✅ | ✅ | ✅ | ❌ | ❌ |
| Create reseller package | ✅ | ✅ | ❌ | ❌ | ❌ |
| Edit own reseller package | ✅ | ✅ | ❌ | ❌ | ❌ |
| **FEATURES** | | | | | |
| Create feature | ✅ | ❌ | ❌ | ❌ | ❌ |
| Edit feature metadata | ✅ | ❌ | ❌ | ❌ | ❌ |
| Enable / disable feature platform-wide | ✅ | ❌ | ❌ | ❌ | ❌ |
| Enable / disable feature per tenant | ✅ | ❌ | ❌ | ❌ | ❌ |
| Enable / disable feature per invitation | ✅ | ✅ (own clients) | ❌ | ❌ | ❌ |
| **ADD-ONS** | | | | | |
| Create add-on | ✅ | ❌ | ❌ | ❌ | ❌ |
| Edit add-on | ✅ | ❌ | ❌ | ❌ | ❌ |
| Disable add-on | ✅ | ❌ | ❌ | ❌ | ❌ |
| Purchase add-on | ✅ | ✅ (for clients) | ✅ | ❌ | ❌ |
| View active add-ons | ✅ | ✅ | ✅ | ❌ | ❌ |
| **PRICING** | | | | | |
| Change platform pricing | ✅ | ❌ | ❌ | ❌ | ❌ |
| Change reseller package pricing | ✅ | ✅ (own) | ❌ | ❌ | ❌ |
| Override tenant pricing (manual) | ✅ | ❌ | ❌ | ❌ | ❌ |
| View own pricing | ✅ | ✅ | ✅ | ❌ | ❌ |
| **SUBSCRIPTION** | | | | | |
| Change own subscription | ✅ | ✅ | ✅ | ❌ | ❌ |
| Change client subscription | ✅ | ✅ | ❌ | ❌ | ❌ |
| Cancel subscription | ✅ | ✅ | ✅ | ❌ | ❌ |
| Apply voucher | ✅ | ✅ | ✅ | ❌ | ❌ |

### 10.2 RLS Policies — Package Tables

```sql
-- packages: public read for active+public packages; admin write only
ALTER TABLE packages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "packages_public_read" ON packages
  FOR SELECT USING (status = 'active' AND is_public = TRUE);

CREATE POLICY "packages_auth_read" ON packages
  FOR SELECT TO authenticated USING (TRUE);
-- All authenticated users can read all packages (for upgrade flow)
-- Service role handles all writes (admin only)

-- features: authenticated read; service role write
ALTER TABLE features ENABLE ROW LEVEL SECURITY;

CREATE POLICY "features_auth_read" ON features
  FOR SELECT TO authenticated USING (is_active = TRUE);

-- package_features: authenticated read
ALTER TABLE package_features ENABLE ROW LEVEL SECURITY;

CREATE POLICY "pf_auth_read" ON package_features
  FOR SELECT TO authenticated USING (TRUE);

-- add_ons: public read for active add-ons
ALTER TABLE add_ons ENABLE ROW LEVEL SECURITY;

CREATE POLICY "add_ons_public_read" ON add_ons
  FOR SELECT USING (is_active = TRUE);

-- tenant_add_ons: tenant read own; reseller read clients
ALTER TABLE tenant_add_ons ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tao_read_own" ON tenant_add_ons
  FOR SELECT USING (tenant_id = auth_tenant_id());

CREATE POLICY "tao_reseller_read" ON tenant_add_ons
  FOR SELECT USING (
    tenant_id IN (
      SELECT tenant_id FROM reseller_tenants
      WHERE reseller_id = auth_reseller_id()
    )
  );

-- feature_flag_overrides: tenant reads own + platform-wide
ALTER TABLE feature_flag_overrides ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ffo_read_own" ON feature_flag_overrides
  FOR SELECT USING (
    tenant_id = auth_tenant_id() OR tenant_id IS NULL
  );

-- invitation_feature_overrides: tenant reads own
ALTER TABLE invitation_feature_overrides ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ifo_read_tenant" ON invitation_feature_overrides
  FOR SELECT USING (tenant_id = auth_tenant_id());

-- reseller_packages: reseller reads/writes own; clients can read their assigned package
ALTER TABLE reseller_packages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "rp_reseller_own" ON reseller_packages
  FOR ALL USING (reseller_id = auth_reseller_id());

CREATE POLICY "rp_tenant_read" ON reseller_packages
  FOR SELECT USING (
    id IN (
      SELECT reseller_package_id FROM tenant_subscriptions
      WHERE tenant_id = auth_tenant_id()
    )
  );
```

---

## 11. Pricing Architecture

### 11.1 Default Package Pricing

```sql
-- supabase/migrations/030_seed_packages.sql

INSERT INTO packages (
  slug, name, description, status, type,
  price_monthly, price_yearly, price_lifetime, currency,
  trial_days, grace_period_days,
  max_invitations, max_guests, max_photos, max_team_members,
  max_music_tracks, max_storage_mb, max_video_mb,
  is_public, is_featured, is_reseller_base, sort_order, metadata
) VALUES

-- FREE
('free', 'Free', 'Get started at no cost', 'active', 'platform',
  0, 0, NULL, 'IDR',
  0, 7,
  1, 50, 5, 1, 1, 100, 0,
  TRUE, FALSE, FALSE, 0,
  '{"badge_label": null, "highlight_color": "#6B7280", "cta_text": "Get Started Free"}'
),

-- BASIC
('basic', 'Basic', 'Perfect for intimate weddings', 'active', 'platform',
  49000, 470000, NULL, 'IDR',
  7, 7,
  3, 200, 20, 1, 3, 500, 0,
  TRUE, FALSE, FALSE, 1,
  '{"badge_label": null, "highlight_color": "#3B82F6", "cta_text": "Start 7-Day Trial"}'
),

-- PREMIUM
('premium', 'Premium', 'The complete wedding experience', 'active', 'platform',
  99000, 950000, NULL, 'IDR',
  14, 14,
  10, -1, 100, 3, -1, 2048, 0,
  TRUE, TRUE, FALSE, 2,
  '{"badge_label": "Most Popular", "highlight_color": "#8B5CF6", "cta_text": "Start 14-Day Trial"}'
),

-- ULTIMATE
('ultimate', 'Ultimate', 'Unlimited everything, premium support', 'active', 'platform',
  199000, 1900000, 4900000, 'IDR',
  14, 30,
  -1, -1, -1, -1, -1, -1, 500,
  TRUE, FALSE, FALSE, 3,
  '{"badge_label": "Best Value", "highlight_color": "#F59E0B", "cta_text": "Start 14-Day Trial"}'
),

-- RESELLER BASE (wholesale — not shown on public pricing)
('reseller-base', 'Reseller Base', 'Wholesale plan for resellers', 'active', 'reseller_base',
  299000, 2990000, NULL, 'IDR',
  0, 30,
  -1, -1, -1, -1, -1, -1, -1,
  FALSE, FALSE, TRUE, 4,
  '{"badge_label": null, "cta_text": "Apply to Become a Reseller"}'
);
```

### 11.2 Package Feature Matrix (Seed)

```sql
-- supabase/migrations/031_seed_package_features.sql
-- Uses feature keys from the features table

DO $$
DECLARE
  v_free_id     UUID := (SELECT id FROM packages WHERE slug = 'free');
  v_basic_id    UUID := (SELECT id FROM packages WHERE slug = 'basic');
  v_premium_id  UUID := (SELECT id FROM packages WHERE slug = 'premium');
  v_ultimate_id UUID := (SELECT id FROM packages WHERE slug = 'ultimate');
  v_reseller_id UUID := (SELECT id FROM packages WHERE slug = 'reseller-base');

  -- Feature IDs
  f_rsvp              UUID := (SELECT id FROM features WHERE key = 'rsvp');
  f_guestbook         UUID := (SELECT id FROM features WHERE key = 'guestbook');
  f_guestbook_mod     UUID := (SELECT id FROM features WHERE key = 'guestbook_moderation');
  f_love_story        UUID := (SELECT id FROM features WHERE key = 'love_story');
  f_gallery           UUID := (SELECT id FROM features WHERE key = 'gallery');
  f_music             UUID := (SELECT id FROM features WHERE key = 'music_player');
  f_video_bg          UUID := (SELECT id FROM features WHERE key = 'video_background');
  f_countdown         UUID := (SELECT id FROM features WHERE key = 'countdown_timer');
  f_livestream        UUID := (SELECT id FROM features WHERE key = 'livestream_embed');
  f_map               UUID := (SELECT id FROM features WHERE key = 'map_embed');
  f_gift              UUID := (SELECT id FROM features WHERE key = 'gift_registry');
  f_qris              UUID := (SELECT id FROM features WHERE key = 'qris_payment');
  f_meal              UUID := (SELECT id FROM features WHERE key = 'rsvp_meal_choice');
  f_plus_one          UUID := (SELECT id FROM features WHERE key = 'rsvp_plus_one');
  f_open_rsvp         UUID := (SELECT id FROM features WHERE key = 'rsvp_open_link');
  f_import_csv        UUID := (SELECT id FROM features WHERE key = 'guest_import_csv');
  f_export_guest      UUID := (SELECT id FROM features WHERE key = 'guest_export_csv');
  f_personal_link     UUID := (SELECT id FROM features WHERE key = 'guest_personalized_link');
  f_whatsapp          UUID := (SELECT id FROM features WHERE key = 'guest_whatsapp_blast');
  f_qr_invite         UUID := (SELECT id FROM features WHERE key = 'qr_code_invitation');
  f_qr_checkin        UUID := (SELECT id FROM features WHERE key = 'qr_checkin');
  f_analytics_basic   UUID := (SELECT id FROM features WHERE key = 'analytics_basic');
  f_analytics_adv     UUID := (SELECT id FROM features WHERE key = 'analytics_advanced');
  f_analytics_export  UUID := (SELECT id FROM features WHERE key = 'analytics_export');
  f_custom_font       UUID := (SELECT id FROM features WHERE key = 'custom_font');
  f_custom_color      UUID := (SELECT id FROM features WHERE key = 'custom_color');
  f_custom_domain     UUID := (SELECT id FROM features WHERE key = 'custom_domain');
  f_remove_badge      UUID := (SELECT id FROM features WHERE key = 'remove_platform_badge');
  f_premium_themes    UUID := (SELECT id FROM features WHERE key = 'premium_themes');
  f_password          UUID := (SELECT id FROM features WHERE key = 'password_protection');
  f_export_rsvp       UUID := (SELECT id FROM features WHERE key = 'export_rsvp_csv');
  f_team              UUID := (SELECT id FROM features WHERE key = 'team_members');
BEGIN

  -- ─── FREE ──────────────────────────────────────────────────────────
  INSERT INTO package_features (package_id, feature_id, is_enabled, config, limit_value) VALUES
    (v_free_id, f_rsvp,          TRUE,  '{}',                        NULL),
    (v_free_id, f_countdown,     TRUE,  '{}',                        NULL),
    (v_free_id, f_map,           TRUE,  '{}',                        NULL),
    (v_free_id, f_gallery,       TRUE,  '{"max_photos": 5}',         5),
    (v_free_id, f_guestbook,     TRUE,  '{}',                        NULL),
    (v_free_id, f_open_rsvp,     TRUE,  '{}',                        NULL),
    (v_free_id, f_love_story,    FALSE, '{}',                        NULL),
    (v_free_id, f_music,         FALSE, '{}',                        NULL),
    (v_free_id, f_video_bg,      FALSE, '{}',                        NULL),
    (v_free_id, f_livestream,    FALSE, '{}',                        NULL),
    (v_free_id, f_gift,          FALSE, '{}',                        NULL),
    (v_free_id, f_qris,          FALSE, '{}',                        NULL),
    (v_free_id, f_meal,          FALSE, '{}',                        NULL),
    (v_free_id, f_plus_one,      FALSE, '{}',                        NULL),
    (v_free_id, f_import_csv,    FALSE, '{}',                        NULL),
    (v_free_id, f_export_guest,  FALSE, '{}',                        NULL),
    (v_free_id, f_personal_link, FALSE, '{}',                        NULL),
    (v_free_id, f_whatsapp,      FALSE, '{}',                        NULL),
    (v_free_id, f_qr_invite,     FALSE, '{}',                        NULL),
    (v_free_id, f_qr_checkin,    FALSE, '{}',                        NULL),
    (v_free_id, f_analytics_basic, FALSE, '{}',                      NULL),
    (v_free_id, f_analytics_adv,  FALSE, '{}',                       NULL),
    (v_free_id, f_custom_font,   FALSE, '{}',                        NULL),
    (v_free_id, f_custom_color,  FALSE, '{}',                        NULL),
    (v_free_id, f_custom_domain, FALSE, '{}',                        NULL),
    (v_free_id, f_remove_badge,  FALSE, '{}',                        NULL),
    (v_free_id, f_premium_themes,FALSE, '{}',                        NULL),
    (v_free_id, f_password,      FALSE, '{}',                        NULL),
    (v_free_id, f_export_rsvp,   FALSE, '{}',                        NULL),
    (v_free_id, f_team,          FALSE, '{"max_members": 1}',        1),
    (v_free_id, f_guestbook_mod, FALSE, '{}',                        NULL);

  -- ─── BASIC ─────────────────────────────────────────────────────────
  INSERT INTO package_features (package_id, feature_id, is_enabled, config, limit_value) VALUES
    (v_basic_id, f_rsvp,           TRUE, '{}',                        NULL),
    (v_basic_id, f_countdown,      TRUE, '{}',                        NULL),
    (v_basic_id, f_map,            TRUE, '{}',                        NULL),
    (v_basic_id, f_gallery,        TRUE, '{"max_photos": 20}',        20),
    (v_basic_id, f_guestbook,      TRUE, '{}',                        NULL),
    (v_basic_id, f_love_story,     TRUE, '{}',                        NULL),
    (v_basic_id, f_music,          TRUE, '{"max_tracks": 3}',         3),
    (v_basic_id, f_open_rsvp,      TRUE, '{}',                        NULL),
    (v_basic_id, f_personal_link,  TRUE, '{}',                        NULL),
    (v_basic_id, f_qr_invite,      TRUE, '{}',                        NULL),
    (v_basic_id, f_analytics_basic,TRUE, '{}',                        NULL),
    (v_basic_id, f_custom_color,   TRUE, '{}',                        NULL),
    (v_basic_id, f_export_rsvp,    TRUE, '{}',                        NULL),
    (v_basic_id, f_meal,           TRUE, '{}',                        NULL),
    (v_basic_id, f_password,       TRUE, '{}',                        NULL),
    (v_basic_id, f_guestbook_mod,  TRUE, '{}',                        NULL),
    (v_basic_id, f_team,           TRUE, '{"max_members": 1}',        1),
    (v_basic_id, f_video_bg,       FALSE, '{}',                       NULL),
    (v_basic_id, f_livestream,     FALSE, '{}',                       NULL),
    (v_basic_id, f_gift,           FALSE, '{}',                       NULL),
    (v_basic_id, f_qris,           FALSE, '{}',                       NULL),
    (v_basic_id, f_plus_one,       FALSE, '{}',                       NULL),
    (v_basic_id, f_import_csv,     FALSE, '{}',                       NULL),
    (v_basic_id, f_export_guest,   FALSE, '{}',                       NULL),
    (v_basic_id, f_whatsapp,       FALSE, '{}',                       NULL),
    (v_basic_id, f_qr_checkin,     FALSE, '{}',                       NULL),
    (v_basic_id, f_analytics_adv,  FALSE, '{}',                       NULL),
    (v_basic_id, f_analytics_export,FALSE,'{}',                       NULL),
    (v_basic_id, f_custom_font,    FALSE, '{}',                       NULL),
    (v_basic_id, f_custom_domain,  FALSE, '{}',                       NULL),
    (v_basic_id, f_remove_badge,   FALSE, '{}',                       NULL),
    (v_basic_id, f_premium_themes, FALSE, '{}',                       NULL);

  -- ─── PREMIUM ───────────────────────────────────────────────────────
  INSERT INTO package_features (package_id, feature_id, is_enabled, config, limit_value) VALUES
    (v_premium_id, f_rsvp,            TRUE, '{}',                     NULL),
    (v_premium_id, f_countdown,       TRUE, '{}',                     NULL),
    (v_premium_id, f_map,             TRUE, '{}',                     NULL),
    (v_premium_id, f_gallery,         TRUE, '{"max_photos": 100}',    100),
    (v_premium_id, f_guestbook,       TRUE, '{}',                     NULL),
    (v_premium_id, f_guestbook_mod,   TRUE, '{}',                     NULL),
    (v_premium_id, f_love_story,      TRUE, '{}',                     NULL),
    (v_premium_id, f_music,           TRUE, '{"max_tracks": 10}',     10),
    (v_premium_id, f_gift,            TRUE, '{}',                     NULL),
    (v_premium_id, f_qris,            TRUE, '{}',                     NULL),
    (v_premium_id, f_meal,            TRUE, '{}',                     NULL),
    (v_premium_id, f_plus_one,        TRUE, '{}',                     NULL),
    (v_premium_id, f_open_rsvp,       TRUE, '{}',                     NULL),
    (v_premium_id, f_personal_link,   TRUE, '{}',                     NULL),
    (v_premium_id, f_import_csv,      TRUE, '{}',                     NULL),
    (v_premium_id, f_export_guest,    TRUE, '{}',                     NULL),
    (v_premium_id, f_whatsapp,        TRUE, '{"max_recipients_per_day": 200}', NULL),
    (v_premium_id, f_qr_invite,       TRUE, '{}',                     NULL),
    (v_premium_id, f_qr_checkin,      TRUE, '{"max_devices": 2}',     NULL),
    (v_premium_id, f_analytics_basic, TRUE, '{}',                     NULL),
    (v_premium_id, f_analytics_adv,   TRUE, '{"retention_days": 90}', NULL),
    (v_premium_id, f_analytics_export,TRUE, '{}',                     NULL),
    (v_premium_id, f_custom_font,     TRUE, '{}',                     NULL),
    (v_premium_id, f_custom_color,    TRUE, '{}',                     NULL),
    (v_premium_id, f_custom_domain,   TRUE, '{}',                     NULL),
    (v_premium_id, f_remove_badge,    TRUE, '{}',                     NULL),
    (v_premium_id, f_premium_themes,  TRUE, '{}',                     NULL),
    (v_premium_id, f_password,        TRUE, '{}',                     NULL),
    (v_premium_id, f_export_rsvp,     TRUE, '{}',                     NULL),
    (v_premium_id, f_team,            TRUE, '{"max_members": 3}',     3),
    (v_premium_id, f_video_bg,        FALSE, '{}',                    NULL),
    (v_premium_id, f_livestream,      FALSE, '{}',                    NULL);

  -- ─── ULTIMATE ──────────────────────────────────────────────────────
  -- Ultimate gets everything enabled with maximum config
  INSERT INTO package_features (package_id, feature_id, is_enabled, config, limit_value)
  SELECT
    v_ultimate_id,
    id,
    TRUE,
    CASE key
      WHEN 'gallery'           THEN '{"max_photos": -1}'
      WHEN 'music_player'      THEN '{"max_tracks": -1, "max_file_mb": 50}'
      WHEN 'team_members'      THEN '{"max_members": -1}'
      WHEN 'analytics_advanced'THEN '{"retention_days": 365}'
      WHEN 'video_background'  THEN '{"max_video_mb": 500}'
      WHEN 'guest_whatsapp_blast' THEN '{"max_recipients_per_day": -1}'
      WHEN 'qr_checkin'        THEN '{"max_devices": -1}'
      ELSE '{}'
    END,
    NULL
  FROM features
  WHERE is_active = TRUE AND is_system = FALSE;

  -- ─── RESELLER BASE ─────────────────────────────────────────────────
  -- Reseller base mirrors Ultimate — resellers limit from here
  INSERT INTO package_features (package_id, feature_id, is_enabled, config, limit_value)
  SELECT
    v_reseller_id,
    id,
    TRUE,
    '{"max_photos": -1, "max_tracks": -1, "max_members": -1}',
    NULL
  FROM features
  WHERE is_active = TRUE;

END;
$$;
```

### 11.3 Billing Cycle Price Logic

```typescript
// lib/packages/pricing.ts

export interface PriceCalculation {
  basePrice: number;
  discountAmount: number;
  discountPct: number;
  finalPrice: number;
  currency: string;
  savingsVsMonthly?: number;  // for yearly plans
}

export function calculatePrice(
  pkg: Package,
  billingCycle: 'monthly' | 'yearly' | 'lifetime',
  voucherDiscount?: { type: 'percentage' | 'fixed'; value: number }
): PriceCalculation {
  let basePrice: number;

  switch (billingCycle) {
    case 'monthly':
      basePrice = pkg.price_monthly;
      break;
    case 'yearly':
      basePrice = pkg.price_yearly;
      break;
    case 'lifetime':
      basePrice = pkg.price_lifetime ?? pkg.price_monthly * 24;
      break;
  }

  let discountAmount = 0;
  if (voucherDiscount) {
    discountAmount = voucherDiscount.type === 'percentage'
      ? Math.floor(basePrice * (voucherDiscount.value / 100))
      : Math.min(voucherDiscount.value, basePrice);
  }

  const finalPrice = Math.max(0, basePrice - discountAmount);

  const savingsVsMonthly = billingCycle === 'yearly'
    ? (pkg.price_monthly * 12) - pkg.price_yearly
    : undefined;

  return {
    basePrice,
    discountAmount,
    discountPct: basePrice > 0 ? Math.round((discountAmount / basePrice) * 100) : 0,
    finalPrice,
    currency: pkg.currency,
    savingsVsMonthly,
  };
}
```

---

## 12. Scalability Considerations

### 12.1 Feature Resolution Caching

The feature resolution engine makes 6 parallel DB queries per request. For high-traffic scenarios, the resolved feature map should be cached at the edge.

```typescript
// lib/packages/feature-resolver.ts — with Redis cache layer

const CACHE_TTL_SECONDS = 60;  // 1 minute; invalidated on subscription change

export async function resolveAllFeaturesWithCache(
  ctx: TenantFeatureContext
): Promise<Record<FeatureKey, FeatureResolution>> {
  const cacheKey = `features:${ctx.tenantId}:${ctx.packageId}`;

  // Try Redis cache first
  const cached = await redis.get(cacheKey);
  if (cached) return JSON.parse(cached);

  // Cache miss — resolve from DB
  const resolved = await resolveAllFeatures(ctx);

  // Cache with TTL
  await redis.setex(cacheKey, CACHE_TTL_SECONDS, JSON.stringify(resolved));

  return resolved;
}

// Call this on subscription change, add-on purchase, or flag override
export async function invalidateFeatureCache(tenantId: string): Promise<void> {
  const keys = await redis.keys(`features:${tenantId}:*`);
  if (keys.length) await redis.del(...keys);
}
```

### 12.2 Package Features Denormalization

For >100 features and >100 packages, the JOIN-heavy feature resolution query can be replaced with a denormalized snapshot table:

```sql
-- Phase 4+: Materialized snapshot of resolved features per package
-- Refreshed whenever package_features changes

CREATE MATERIALIZED VIEW package_feature_snapshot AS
SELECT
  p.id AS package_id,
  p.slug AS package_slug,
  f.key AS feature_key,
  COALESCE(pf.is_enabled, FALSE) AS is_enabled,
  COALESCE(pf.config, f.default_config) AS config,
  pf.limit_value
FROM packages p
CROSS JOIN features f
LEFT JOIN package_features pf
  ON pf.package_id = p.id AND pf.feature_id = f.id
WHERE p.status != 'archived'
  AND f.is_active = TRUE;

CREATE UNIQUE INDEX ON package_feature_snapshot(package_id, feature_key);

-- Refresh trigger (call after any package_features change)
CREATE OR REPLACE FUNCTION refresh_package_feature_snapshot()
RETURNS TRIGGER AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY package_feature_snapshot;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_refresh_snapshot
  AFTER INSERT OR UPDATE OR DELETE ON package_features
  FOR EACH STATEMENT EXECUTE FUNCTION refresh_package_feature_snapshot();
```

### 12.3 Quota Usage Counters

Direct COUNT queries on `invitations` and `guests` are expensive at scale. Replace with dedicated counters:

```sql
-- Phase 3+: Usage counters table (incremented by triggers)
CREATE TABLE tenant_usage (
  tenant_id         UUID PRIMARY KEY REFERENCES tenants(id),
  invitation_count  INTEGER NOT NULL DEFAULT 0,
  guest_count       INTEGER NOT NULL DEFAULT 0,
  photo_count       INTEGER NOT NULL DEFAULT 0,
  storage_used_mb   INTEGER NOT NULL DEFAULT 0,
  team_count        INTEGER NOT NULL DEFAULT 0,
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Increment on invitation create
CREATE OR REPLACE FUNCTION increment_invitation_count()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO tenant_usage (tenant_id, invitation_count)
  VALUES (NEW.tenant_id, 1)
  ON CONFLICT (tenant_id) DO UPDATE
  SET invitation_count = tenant_usage.invitation_count + 1,
      updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_inv_count
  AFTER INSERT ON invitations
  FOR EACH ROW EXECUTE FUNCTION increment_invitation_count();
```

### 12.4 Future: 100 Packages × 100 Features

At this scale, the resolution engine remains performant because:

1. **Materialized view** reduces resolution to a single indexed lookup per feature key.
2. **Redis cache** with 60s TTL means most requests never hit the DB for feature resolution.
3. **Partial indexes** on `package_features(package_id)` keep feature lookups sub-millisecond.
4. **JSONB config** avoids schema migrations when adding config fields to existing features.

### 12.5 Enterprise Plan Extensions

```typescript
// Future enterprise fields (added to packages.metadata):

interface EnterprisePackageMetadata {
  is_negotiable: true;
  sla_uptime_pct: 99.9;
  dedicated_support: true;
  dedicated_db_schema: false;   // Phase 4: schema-per-tenant for >1M row tenants
  custom_jwt_secret: false;     // Phase 4: per-tenant JWT signing
  data_residency_region: 'ap-southeast-1' | 'us-east-1' | 'eu-west-1';
  allowed_oauth_providers: ['google', 'microsoft', 'okta'];
  custom_saml_enabled: false;   // Phase 4: per-tenant SAML SSO
}
```

---

## Appendix A — Migration Order (Package System Additions)

```
Previously from PHASE2:
  001–031: Core tables + package seed

New migrations (PHASE5 additions):
  032_features_table.sql          -- features master registry
  033_package_features_v2.sql     -- alter package_features: add feature_id FK, limit_value
  034_add_ons.sql                 -- add_ons, add_on_features
  035_tenant_add_ons.sql          -- tenant_add_ons
  036_invitation_feature_overrides.sql
  037_reseller_packages.sql       -- reseller_packages, reseller_package_features
  038_feature_flag_overrides.sql  -- replaces feature_flags with normalized version
  039_tenant_subscriptions_v2.sql -- add pending_downgrade_package_id, grace_ends_at, auto_renew
  040_tenant_usage.sql            -- tenant_usage counters
  041_indexes_phase5.sql          -- all new performance indexes
  042_rls_phase5.sql              -- RLS policies for new tables
  043_seed_features.sql           -- all feature keys seeded
  044_seed_add_ons.sql            -- default add-on catalog
  045_seed_package_features_v2.sql -- complete feature matrix for all packages
  046_package_feature_snapshot.sql -- materialized view (Phase 3+, optional)
```

## Appendix B — Feature Key Quick Reference

| Key | Category | Free | Basic | Premium | Ultimate |
|---|---|:---:|:---:|:---:|:---:|
| `rsvp` | content | ✅ | ✅ | ✅ | ✅ |
| `guestbook` | content | ✅ | ✅ | ✅ | ✅ |
| `guestbook_moderation` | content | ❌ | ✅ | ✅ | ✅ |
| `love_story` | content | ❌ | ✅ | ✅ | ✅ |
| `gallery` | content | ✅ (5) | ✅ (20) | ✅ (100) | ✅ (∞) |
| `music_player` | content | ❌ | ✅ (3) | ✅ (10) | ✅ (∞) |
| `video_background` | content | ❌ | ❌ | ❌ | ✅ |
| `countdown_timer` | content | ✅ | ✅ | ✅ | ✅ |
| `livestream_embed` | content | ❌ | ❌ | ❌ | ✅ |
| `map_embed` | content | ✅ | ✅ | ✅ | ✅ |
| `gift_registry` | content | ❌ | ❌ | ✅ | ✅ |
| `qris_payment` | content | ❌ | ❌ | ✅ | ✅ |
| `rsvp_meal_choice` | rsvp | ❌ | ✅ | ✅ | ✅ |
| `rsvp_plus_one` | rsvp | ❌ | ❌ | ✅ | ✅ |
| `rsvp_open_link` | rsvp | ✅ | ✅ | ✅ | ✅ |
| `guest_import_csv` | guest_management | ❌ | ❌ | ✅ | ✅ |
| `guest_export_csv` | guest_management | ❌ | ❌ | ✅ | ✅ |
| `guest_personalized_link` | guest_management | ❌ | ✅ | ✅ | ✅ |
| `guest_whatsapp_blast` | guest_management | ❌ | ❌ | ✅ (200/day) | ✅ (∞) |
| `qr_code_invitation` | qr | ❌ | ✅ | ✅ | ✅ |
| `qr_checkin` | qr | ❌ | ❌ | ✅ (2 devices) | ✅ (∞) |
| `analytics_basic` | analytics | ❌ | ✅ | ✅ | ✅ |
| `analytics_advanced` | analytics | ❌ | ❌ | ✅ | ✅ |
| `analytics_export` | analytics | ❌ | ❌ | ✅ | ✅ |
| `custom_font` | customization | ❌ | ❌ | ✅ | ✅ |
| `custom_color` | customization | ❌ | ✅ | ✅ | ✅ |
| `custom_domain` | customization | ❌ | ❌ | ✅ | ✅ |
| `remove_platform_badge` | customization | ❌ | ❌ | ✅ | ✅ |
| `premium_themes` | customization | ❌ | ❌ | ✅ | ✅ |
| `password_protection` | customization | ❌ | ✅ | ✅ | ✅ |
| `export_rsvp_csv` | export | ❌ | ✅ | ✅ | ✅ |
| `team_members` | team | ❌ (1) | ✅ (1) | ✅ (3) | ✅ (∞) |

---

*End of PHASE5_PACKAGE_FEATURE_SYSTEM.md*
