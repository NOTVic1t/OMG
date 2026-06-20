# PHASE1_ARCHITECTURE.md
# Wedding Invitation SaaS Platform — Production Architecture

> **Version:** 1.0.0
> **Date:** 2026-06-12
> **Status:** Approved for Development

---

## Table of Contents

1. [Product Vision](#1-product-vision)
2. [System Architecture](#2-system-architecture)
3. [Folder Structure](#3-folder-structure)
4. [Database ERD](#4-database-erd)
5. [User Roles & Permissions](#5-user-roles--permissions)
6. [Package System](#6-package-system)
7. [Feature Toggle System](#7-feature-toggle-system)
8. [Admin Panel Architecture](#8-admin-panel-architecture)
9. [Reseller Architecture](#9-reseller-architecture)
10. [Deployment Architecture](#10-deployment-architecture)
11. [Development Roadmap](#11-development-roadmap)

---

## 1. Product Vision

### 1.1 Overview

A multi-tenant SaaS platform enabling couples, event organizers, and resellers to create, customize, and publish digital wedding invitations. The platform monetizes via tiered subscription packages and a white-label reseller program.

### 1.2 Core Value Propositions

| Stakeholder | Value |
|---|---|
| Couples | Beautiful, shareable digital invitations without technical skills |
| Event Organizers | Bulk invitation management for multiple clients |
| Resellers | White-label platform to sell under their own brand |
| Platform Admin | Recurring revenue, reseller commissions, full analytics |

### 1.3 Key Differentiators

- **Multi-tenant from day one** — tenant isolation at DB row level (RLS)
- **Reseller white-label** — custom domain, logo, pricing per reseller
- **Package-gated features** — granular feature flags per subscription tier
- **RSVP + Guest Management** — not just a static page; interactive guest experience
- **No-code customization** — drag-free but property-based editor (performant)
- **Mobile-first rendering** — invitations optimized for WhatsApp/social sharing

### 1.4 Out of Scope (Phase 1)

- AI-generated content
- Native mobile app (PWA only)
- Video background uploads
- Physical printing integration

---

## 2. System Architecture

### 2.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        CLIENTS                                   │
│  Browser (Next.js SSR/SSG)   │   WhatsApp / Social Share Link   │
└──────────────┬───────────────┴──────────────────────────────────┘
               │ HTTPS
┌──────────────▼───────────────────────────────────────────────────┐
│                    VERCEL EDGE NETWORK                            │
│  - CDN (static assets, OG images)                                │
│  - Edge Middleware (tenant resolution, auth checks)              │
│  - Serverless Functions (API routes)                             │
└──────────────┬───────────────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────────────┐
│                    NEXT.JS APPLICATION                            │
│                                                                   │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────────┐ │
│  │  Public Site  │  │  User App    │  │  Admin / Reseller Panel │ │
│  │  (marketing) │  │  (dashboard) │  │  (/admin, /reseller)    │ │
│  └──────────────┘  └──────────────┘  └────────────────────────┘ │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                    API Routes (/api/*)                       │ │
│  │  auth │ invitations │ rsvp │ guests │ packages │ webhooks   │ │
│  └─────────────────────────────────────────────────────────────┘ │
└──────────────┬───────────────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────────────┐
│                       SUPABASE                                    │
│                                                                   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │  Auth         │  │  PostgreSQL  │  │  Storage             │   │
│  │  (JWT/OAuth) │  │  (RLS)       │  │  (photos, assets)    │   │
│  └──────────────┘  └──────────────┘  └──────────────────────┘   │
│                                                                   │
│  ┌──────────────┐  ┌──────────────┐                             │
│  │  Realtime    │  │  Edge Fns    │                             │
│  │  (RSVP live) │  │  (webhooks)  │                             │
│  └──────────────┘  └──────────────┘                             │
└──────────────────────────────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────────────┐
│                    EXTERNAL SERVICES                              │
│  Resend (transactional email) │ Midtrans/Stripe (payments)       │
│  Cloudflare (custom domains)  │ Upstash Redis (rate limiting)    │
└──────────────────────────────────────────────────────────────────┘
```

### 2.2 Tenant Resolution Strategy

**Trade-off decision:** We use **subdomain-based tenant resolution** at the Edge Middleware layer rather than path-based (`/[tenant]/`) because:

- Subdomains enable future custom domain mapping per reseller
- Cleaner URL structure for public invitation links
- Edge Middleware runs before any React rendering, keeping tenant context fast

```
app.weddingplatform.com         → Platform main app (auth, dashboard)
[tenant].weddingplatform.com    → Reseller white-label frontend
inv.weddingplatform.com/[slug]  → Public invitation page (tenant-scoped)
admin.weddingplatform.com       → Super admin panel
```

For resellers with custom domains:
```
dashboard.resellerbrand.com     → Mapped via Cloudflare CNAME + Edge Middleware lookup
```

### 2.3 Multi-Tenancy Model

**Row-Level Security (RLS)** is the primary isolation mechanism. Every table carrying tenant data has a `tenant_id` foreign key. Supabase RLS policies enforce that users can only read/write rows belonging to their tenant.

**Trade-off:** RLS-per-row vs. schema-per-tenant.
- RLS is chosen for simplicity, cost (one DB instance), and because the platform is B2C-focused with high tenant count but low per-tenant data volume.
- Schema-per-tenant would be considered if any single tenant requires dedicated SLA or data residency guarantees (Phase 3+).

### 2.4 Authentication Flow

```
User visits app → Supabase Auth (email/password + Google OAuth)
                → JWT issued with custom claims: { tenant_id, role, package_id }
                → Next.js middleware validates JWT on every request
                → Role-based routing enforced server-side
```

---

## 3. Folder Structure

```
wedding-saas/
├── apps/
│   └── web/                          # Next.js 14 App Router
│       ├── app/
│       │   ├── (marketing)/          # Public marketing site
│       │   │   ├── page.tsx          # Landing page
│       │   │   ├── pricing/
│       │   │   └── layout.tsx
│       │   ├── (auth)/               # Auth pages (no sidebar)
│       │   │   ├── login/
│       │   │   ├── register/
│       │   │   └── layout.tsx
│       │   ├── (app)/                # Authenticated user app
│       │   │   ├── dashboard/
│       │   │   ├── invitations/
│       │   │   │   ├── [id]/
│       │   │   │   │   ├── edit/
│       │   │   │   │   ├── guests/
│       │   │   │   │   ├── rsvp/
│       │   │   │   │   └── analytics/
│       │   │   │   └── new/
│       │   │   ├── packages/
│       │   │   ├── settings/
│       │   │   └── layout.tsx
│       │   ├── (admin)/              # Super admin panel
│       │   │   ├── tenants/
│       │   │   ├── packages/
│       │   │   ├── resellers/
│       │   │   ├── feature-flags/
│       │   │   ├── analytics/
│       │   │   └── layout.tsx
│       │   ├── (reseller)/           # Reseller portal
│       │   │   ├── dashboard/
│       │   │   ├── clients/
│       │   │   ├── billing/
│       │   │   ├── branding/
│       │   │   └── layout.tsx
│       │   ├── inv/
│       │   │   └── [slug]/           # Public invitation page
│       │   │       └── page.tsx
│       │   ├── api/
│       │   │   ├── auth/
│       │   │   ├── invitations/
│       │   │   ├── rsvp/
│       │   │   ├── guests/
│       │   │   ├── packages/
│       │   │   ├── payments/
│       │   │   ├── resellers/
│       │   │   └── webhooks/
│       │   ├── layout.tsx
│       │   └── middleware.ts         # Tenant resolution + auth
│       │
│       ├── components/
│       │   ├── ui/                   # Base design system (shadcn/ui)
│       │   ├── invitation/           # Invitation renderer components
│       │   │   ├── themes/
│       │   │   │   ├── classic/
│       │   │   │   ├── modern/
│       │   │   │   ├── floral/
│       │   │   │   └── index.ts
│       │   │   ├── sections/         # Hero, Couple, Event, RSVP, Gallery
│       │   │   └── editor/           # Property editor panel
│       │   ├── dashboard/
│       │   ├── admin/
│       │   ├── reseller/
│       │   └── shared/
│       │
│       ├── lib/
│       │   ├── supabase/
│       │   │   ├── client.ts         # Browser client
│       │   │   ├── server.ts         # Server client
│       │   │   └── middleware.ts     # Auth middleware helper
│       │   ├── auth/
│       │   │   ├── session.ts
│       │   │   └── permissions.ts    # RBAC helpers
│       │   ├── packages/
│       │   │   ├── features.ts       # Feature flag resolver
│       │   │   └── limits.ts         # Quota checker
│       │   ├── tenant/
│       │   │   └── resolver.ts       # Subdomain → tenant_id
│       │   ├── payments/
│       │   │   └── index.ts
│       │   └── utils/
│       │
│       ├── types/
│       │   ├── database.ts           # Generated from Supabase
│       │   ├── invitation.ts
│       │   ├── package.ts
│       │   └── tenant.ts
│       │
│       ├── hooks/
│       │   ├── use-invitation.ts
│       │   ├── use-feature-flag.ts
│       │   ├── use-quota.ts
│       │   └── use-tenant.ts
│       │
│       ├── config/
│       │   ├── packages.ts           # Package definitions (source of truth)
│       │   ├── features.ts           # All feature keys enum
│       │   └── site.ts               # Platform-wide constants
│       │
│       └── public/
│           ├── themes/               # Theme preview thumbnails
│           └── fonts/
│
├── supabase/
│   ├── migrations/                   # SQL migration files
│   ├── seed.sql                      # Dev seed data
│   ├── functions/                    # Edge Functions
│   │   ├── send-rsvp-notification/
│   │   └── process-payment-webhook/
│   └── config.toml
│
├── docs/
│   ├── PHASE1_ARCHITECTURE.md        # This file
│   ├── API.md
│   ├── DATABASE.md
│   └── DEPLOYMENT.md
│
├── .env.example
├── .env.local
├── next.config.ts
├── tailwind.config.ts
├── tsconfig.json
└── package.json
```

---

## 4. Database ERD

### 4.1 Schema Overview

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│   tenants   │────<│    users     │     │    resellers    │
└─────────────┘     └──────────────┘     └─────────────────┘
       │                   │                      │
       │                   │              ┌───────▼────────┐
       │                   │              │ reseller_tenants│
       │                   │              └────────────────┘
       │
       ├──────────────────────────────────────────────────────┐
       │                                                      │
┌──────▼───────┐     ┌──────────────┐     ┌──────────────────▼──┐
│ invitations  │────<│    guests    │     │ tenant_subscriptions │
└──────────────┘     └──────────────┘     └─────────────────────┘
       │                   │                        │
       │             ┌─────▼──────┐        ┌────────▼──────┐
       │             │ rsvp_resp. │        │   packages    │
       │             └────────────┘        └───────────────┘
       │                                           │
┌──────▼───────┐                        ┌──────────▼────────┐
│  inv_themes  │                        │  package_features │
└──────────────┘                        └───────────────────┘
       │
┌──────▼──────────┐     ┌──────────────────┐
│ inv_sections    │     │  feature_flags   │
└─────────────────┘     └──────────────────┘
```

### 4.2 Full Table Definitions

```sql
-- ============================================================
-- TENANTS (top-level multi-tenant unit)
-- ============================================================
CREATE TABLE tenants (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug          TEXT UNIQUE NOT NULL,          -- subdomain identifier
  name          TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'active' -- active | suspended | deleted
    CHECK (status IN ('active', 'suspended', 'deleted')),
  metadata      JSONB NOT NULL DEFAULT '{}',   -- branding, locale, etc.
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- USERS
-- ============================================================
CREATE TABLE users (
  id            UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  tenant_id     UUID NOT NULL REFERENCES tenants(id),
  email         TEXT NOT NULL,
  full_name     TEXT,
  avatar_url    TEXT,
  role          TEXT NOT NULL DEFAULT 'owner'
    CHECK (role IN ('owner', 'editor', 'viewer')),
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_users_tenant_id ON users(tenant_id);

-- ============================================================
-- RESELLERS
-- ============================================================
CREATE TABLE resellers (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name             TEXT NOT NULL,
  slug             TEXT UNIQUE NOT NULL,
  custom_domain    TEXT UNIQUE,
  owner_user_id    UUID NOT NULL REFERENCES users(id),
  commission_pct   NUMERIC(5,2) NOT NULL DEFAULT 20.00,
  branding         JSONB NOT NULL DEFAULT '{}',
    -- { logo_url, primary_color, company_name, support_email }
  status           TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'suspended', 'pending')),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- RESELLER ↔ TENANT LINK
-- ============================================================
CREATE TABLE reseller_tenants (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reseller_id   UUID NOT NULL REFERENCES resellers(id),
  tenant_id     UUID NOT NULL REFERENCES tenants(id),
  invited_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (reseller_id, tenant_id)
);

-- ============================================================
-- PACKAGES
-- ============================================================
CREATE TABLE packages (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name            TEXT NOT NULL,                   -- Free, Starter, Premium, Enterprise
  slug            TEXT UNIQUE NOT NULL,
  price_monthly   NUMERIC(10,2) NOT NULL DEFAULT 0,
  price_yearly    NUMERIC(10,2) NOT NULL DEFAULT 0,
  currency        TEXT NOT NULL DEFAULT 'IDR',
  max_invitations INTEGER NOT NULL DEFAULT 1,      -- -1 = unlimited
  max_guests      INTEGER NOT NULL DEFAULT 50,     -- per invitation
  max_photos      INTEGER NOT NULL DEFAULT 5,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  is_reseller     BOOLEAN NOT NULL DEFAULT FALSE,  -- reseller-only plans
  sort_order      INTEGER NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- PACKAGE → FEATURE MAP
-- ============================================================
CREATE TABLE package_features (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  package_id    UUID NOT NULL REFERENCES packages(id),
  feature_key   TEXT NOT NULL,
    -- see Feature Toggle System for all keys
  is_enabled    BOOLEAN NOT NULL DEFAULT TRUE,
  config        JSONB NOT NULL DEFAULT '{}',
    -- optional per-feature config, e.g. { max_count: 10 }
  UNIQUE (package_id, feature_key)
);
CREATE INDEX idx_pf_package_id ON package_features(package_id);

-- ============================================================
-- TENANT SUBSCRIPTIONS
-- ============================================================
CREATE TABLE tenant_subscriptions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES tenants(id),
  package_id      UUID NOT NULL REFERENCES packages(id),
  reseller_id     UUID REFERENCES resellers(id),   -- null if direct
  billing_cycle   TEXT NOT NULL DEFAULT 'monthly'
    CHECK (billing_cycle IN ('monthly', 'yearly', 'lifetime')),
  status          TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'trialing', 'past_due', 'cancelled', 'paused')),
  current_period_start  TIMESTAMPTZ NOT NULL,
  current_period_end    TIMESTAMPTZ NOT NULL,
  payment_provider      TEXT,                      -- stripe | midtrans | manual
  payment_ref           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_ts_tenant_id ON tenant_subscriptions(tenant_id);

-- ============================================================
-- FEATURE FLAGS (tenant-level overrides)
-- ============================================================
CREATE TABLE feature_flags (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID REFERENCES tenants(id),       -- null = platform-wide
  feature_key   TEXT NOT NULL,
  is_enabled    BOOLEAN NOT NULL DEFAULT TRUE,
  config        JSONB NOT NULL DEFAULT '{}',
  reason        TEXT,                              -- audit reason for override
  expires_at    TIMESTAMPTZ,                       -- null = permanent
  created_by    UUID REFERENCES users(id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, feature_key)
);

-- ============================================================
-- INVITATION THEMES (template library)
-- ============================================================
CREATE TABLE invitation_themes (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT NOT NULL,
  slug          TEXT UNIQUE NOT NULL,
  preview_url   TEXT,
  category      TEXT NOT NULL DEFAULT 'general',  -- wedding | engagement | etc.
  is_premium    BOOLEAN NOT NULL DEFAULT FALSE,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  config_schema JSONB NOT NULL DEFAULT '{}',       -- customizable fields schema
  sort_order    INTEGER NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- INVITATIONS
-- ============================================================
CREATE TABLE invitations (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES tenants(id),
  created_by      UUID NOT NULL REFERENCES users(id),
  theme_id        UUID NOT NULL REFERENCES invitation_themes(id),
  slug            TEXT UNIQUE NOT NULL,            -- public URL slug
  title           TEXT NOT NULL,
  status          TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'published', 'archived')),
  event_date      DATE,
  event_time      TIME,
  event_venue     TEXT,
  event_address   TEXT,
  event_maps_url  TEXT,
  couple_data     JSONB NOT NULL DEFAULT '{}',
    -- { groom_name, bride_name, groom_photo, bride_photo, love_story }
  customization   JSONB NOT NULL DEFAULT '{}',
    -- all theme property overrides
  music_url       TEXT,
  is_rsvp_open    BOOLEAN NOT NULL DEFAULT TRUE,
  rsvp_deadline   DATE,
  meta_title      TEXT,                            -- OG / SEO
  meta_description TEXT,
  view_count      INTEGER NOT NULL DEFAULT 0,
  published_at    TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_inv_tenant_id    ON invitations(tenant_id);
CREATE INDEX idx_inv_slug         ON invitations(slug);
CREATE INDEX idx_inv_status       ON invitations(status);

-- ============================================================
-- INVITATION SECTIONS (ordered content blocks)
-- ============================================================
CREATE TABLE invitation_sections (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id   UUID NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  section_type    TEXT NOT NULL,
    -- hero | couple | event_details | gallery | rsvp | gift | countdown | story
  sort_order      INTEGER NOT NULL DEFAULT 0,
  is_visible      BOOLEAN NOT NULL DEFAULT TRUE,
  content         JSONB NOT NULL DEFAULT '{}',
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_is_invitation_id ON invitation_sections(invitation_id);

-- ============================================================
-- GUESTS
-- ============================================================
CREATE TABLE guests (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id   UUID NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  tenant_id       UUID NOT NULL REFERENCES tenants(id),
  name            TEXT NOT NULL,
  phone           TEXT,
  email           TEXT,
  address         TEXT,
  group_label     TEXT,                            -- family | friends | colleague
  personal_link   TEXT UNIQUE,                     -- personalized URL token
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_guests_invitation_id ON guests(invitation_id);
CREATE INDEX idx_guests_tenant_id     ON guests(tenant_id);

-- ============================================================
-- RSVP RESPONSES
-- ============================================================
CREATE TABLE rsvp_responses (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id   UUID NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  guest_id        UUID REFERENCES guests(id),      -- null if open RSVP
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

-- ============================================================
-- PAYMENTS / ORDERS
-- ============================================================
CREATE TABLE orders (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         UUID NOT NULL REFERENCES tenants(id),
  reseller_id       UUID REFERENCES resellers(id),
  package_id        UUID NOT NULL REFERENCES packages(id),
  amount            NUMERIC(12,2) NOT NULL,
  currency          TEXT NOT NULL DEFAULT 'IDR',
  billing_cycle     TEXT NOT NULL,
  status            TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'paid', 'failed', 'refunded')),
  payment_provider  TEXT,
  payment_ref       TEXT,
  payment_data      JSONB NOT NULL DEFAULT '{}',
  commission_amount NUMERIC(12,2),                 -- calculated at time of order
  paid_at           TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_orders_tenant_id ON orders(tenant_id);

-- ============================================================
-- AUDIT LOG
-- ============================================================
CREATE TABLE audit_logs (
  id            BIGSERIAL PRIMARY KEY,
  tenant_id     UUID REFERENCES tenants(id),
  user_id       UUID REFERENCES users(id),
  action        TEXT NOT NULL,
  resource_type TEXT NOT NULL,
  resource_id   TEXT,
  old_data      JSONB,
  new_data      JSONB,
  ip_address    TEXT,
  user_agent    TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_al_tenant_id  ON audit_logs(tenant_id);
CREATE INDEX idx_al_created_at ON audit_logs(created_at);
```

### 4.3 Row-Level Security Policies (Patterns)

```sql
-- Enable RLS on all tenant-scoped tables
ALTER TABLE invitations ENABLE ROW LEVEL SECURITY;
ALTER TABLE guests ENABLE ROW LEVEL SECURITY;
ALTER TABLE rsvp_responses ENABLE ROW LEVEL SECURITY;

-- Pattern: tenant isolation via JWT claim
CREATE POLICY "tenant_isolation" ON invitations
  USING (tenant_id = (auth.jwt() ->> 'tenant_id')::UUID);

-- Pattern: public read for published invitations (no auth required)
CREATE POLICY "public_invitation_read" ON invitations
  FOR SELECT
  USING (status = 'published');

-- Pattern: reseller can read their clients' data
CREATE POLICY "reseller_client_read" ON invitations
  FOR SELECT
  USING (
    tenant_id IN (
      SELECT tenant_id FROM reseller_tenants
      WHERE reseller_id = (auth.jwt() ->> 'reseller_id')::UUID
    )
  );
```

---

## 5. User Roles & Permissions

### 5.1 Role Hierarchy

```
SUPER_ADMIN
    └── RESELLER_ADMIN
            └── TENANT_OWNER
                    ├── TENANT_EDITOR
                    └── TENANT_VIEWER
```

### 5.2 Permission Matrix

| Action | super_admin | reseller_admin | tenant_owner | tenant_editor | tenant_viewer |
|---|:---:|:---:|:---:|:---:|:---:|
| Manage all tenants | ✅ | ❌ | ❌ | ❌ | ❌ |
| Manage packages/pricing | ✅ | ❌ | ❌ | ❌ | ❌ |
| Manage feature flags | ✅ | ❌ | ❌ | ❌ | ❌ |
| View platform analytics | ✅ | ❌ | ❌ | ❌ | ❌ |
| Manage own reseller clients | ✅ | ✅ | ❌ | ❌ | ❌ |
| Set reseller branding | ✅ | ✅ | ❌ | ❌ | ❌ |
| View reseller billing | ✅ | ✅ | ❌ | ❌ | ❌ |
| Create invitations | ✅ | ✅ | ✅ | ✅ | ❌ |
| Edit invitations | ✅ | ✅ | ✅ | ✅ | ❌ |
| Publish invitations | ✅ | ✅ | ✅ | ❌ | ❌ |
| Manage guests | ✅ | ✅ | ✅ | ✅ | ❌ |
| View RSVP responses | ✅ | ✅ | ✅ | ✅ | ✅ |
| Export guest data | ✅ | ✅ | ✅ | ❌ | ❌ |
| Manage subscription | ✅ | ✅ | ✅ | ❌ | ❌ |
| Invite team members | ✅ | ✅ | ✅ | ❌ | ❌ |

### 5.3 JWT Custom Claims

```typescript
// Injected via Supabase Auth Hook (DB Function on user login)
interface JWTClaims {
  sub: string;          // user.id
  tenant_id: string;
  role: 'super_admin' | 'reseller_admin' | 'tenant_owner' | 'tenant_editor' | 'tenant_viewer';
  reseller_id?: string; // present only for reseller_admin
  package_id: string;   // active subscription package
  exp: number;
}
```

---

## 6. Package System

### 6.1 Package Tiers

| Attribute | Free | Starter | Premium | Enterprise |
|---|---|---|---|---|
| **Price/mo** | Rp 0 | Rp 49.000 | Rp 99.000 | Custom |
| **Invitations** | 1 | 3 | Unlimited | Unlimited |
| **Guests/invitation** | 50 | 200 | Unlimited | Unlimited |
| **Photos** | 5 | 20 | Unlimited | Unlimited |
| **Themes** | 3 basic | All free | All + premium | All |
| **Custom domain** | ❌ | ❌ | ✅ | ✅ |
| **Music player** | ❌ | ✅ | ✅ | ✅ |
| **Countdown timer** | ✅ | ✅ | ✅ | ✅ |
| **Gift registry** | ❌ | ❌ | ✅ | ✅ |
| **RSVP** | ✅ | ✅ | ✅ | ✅ |
| **Guest import (CSV)** | ❌ | ❌ | ✅ | ✅ |
| **Export RSVP (CSV)** | ❌ | ✅ | ✅ | ✅ |
| **Analytics** | ❌ | Basic | Advanced | Advanced |
| **Remove branding** | ❌ | ❌ | ✅ | ✅ |
| **Team members** | 1 | 1 | 3 | Unlimited |
| **Priority support** | ❌ | ❌ | ✅ | ✅ |

### 6.2 Package Resolution Logic

```typescript
// lib/packages/features.ts

export async function resolveFeature(
  tenantId: string,
  featureKey: FeatureKey
): Promise<FeatureResolution> {

  // Priority order (highest → lowest):
  // 1. Platform-wide kill switch (feature_flags WHERE tenant_id IS NULL)
  // 2. Tenant-level override (feature_flags WHERE tenant_id = ?)
  // 3. Package-level entitlement (package_features via active subscription)
  // 4. Default: disabled

  const [platformFlag, tenantFlag, packageFeature] =
    await Promise.all([
      getPlatformFlag(featureKey),
      getTenantFlag(tenantId, featureKey),
      getPackageFeature(tenantId, featureKey),
    ]);

  if (platformFlag?.is_enabled === false) {
    return { enabled: false, source: 'platform_kill_switch' };
  }

  if (tenantFlag !== null) {
    return {
      enabled: tenantFlag.is_enabled,
      config: tenantFlag.config,
      source: 'tenant_override'
    };
  }

  if (packageFeature !== null) {
    return {
      enabled: packageFeature.is_enabled,
      config: packageFeature.config,
      source: 'package'
    };
  }

  return { enabled: false, source: 'default' };
}
```

### 6.3 Quota Enforcement

```typescript
// lib/packages/limits.ts

export async function checkQuota(
  tenantId: string,
  resource: 'invitations' | 'guests' | 'photos' | 'team_members'
): Promise<QuotaResult> {
  const subscription = await getActiveSubscription(tenantId);
  const pkg = await getPackage(subscription.package_id);
  const current = await getCurrentUsage(tenantId, resource);

  const limit = pkg[`max_${resource}`];
  if (limit === -1) return { allowed: true, limit: -1, current };

  return {
    allowed: current < limit,
    limit,
    current,
    remaining: limit - current
  };
}
```

---

## 7. Feature Toggle System

### 7.1 Feature Key Registry

```typescript
// config/features.ts

export const FEATURES = {
  // Invitation features
  MUSIC_PLAYER:         'music_player',
  COUNTDOWN_TIMER:      'countdown_timer',
  GIFT_REGISTRY:        'gift_registry',
  GALLERY_SECTION:      'gallery_section',
  LOVE_STORY_SECTION:   'love_story_section',
  LIVESTREAM_LINK:      'livestream_link',
  MAP_EMBED:            'map_embed',

  // RSVP features
  RSVP_OPEN:            'rsvp_open',
  RSVP_MEAL_CHOICE:     'rsvp_meal_choice',
  RSVP_PLUS_ONE:        'rsvp_plus_one',
  RSVP_WISHES_WALL:     'rsvp_wishes_wall',

  // Guest management
  GUEST_IMPORT_CSV:     'guest_import_csv',
  GUEST_PERSONALIZED_LINK: 'guest_personalized_link',
  GUEST_WHATSAPP_BLAST: 'guest_whatsapp_blast',

  // Analytics
  ANALYTICS_BASIC:      'analytics_basic',
  ANALYTICS_ADVANCED:   'analytics_advanced',

  // Branding
  REMOVE_PLATFORM_BADGE: 'remove_platform_badge',
  CUSTOM_DOMAIN:        'custom_domain',
  CUSTOM_FONT:          'custom_font',

  // Export
  EXPORT_RSVP_CSV:      'export_rsvp_csv',
  EXPORT_GUEST_CSV:     'export_guest_csv',

  // Premium themes
  PREMIUM_THEMES:       'premium_themes',

  // Team
  TEAM_MEMBERS:         'team_members',

  // Admin / platform
  MAINTENANCE_MODE:     'maintenance_mode',
  NEW_EDITOR_UI:        'new_editor_ui',       -- gradual rollout flag
} as const;

export type FeatureKey = typeof FEATURES[keyof typeof FEATURES];
```

### 7.2 React Hook Usage

```typescript
// hooks/use-feature-flag.ts

export function useFeatureFlag(key: FeatureKey): FeatureResolution {
  // Resolved server-side and passed via context, no client-side DB call
  const flags = useFeatureFlagContext();
  return flags[key] ?? { enabled: false, source: 'default' };
}

// Usage in components
function GiftRegistrySection() {
  const flag = useFeatureFlag(FEATURES.GIFT_REGISTRY);
  if (!flag.enabled) return <UpgradePrompt feature="Gift Registry" />;
  return <GiftRegistryContent />;
}
```

### 7.3 Feature Flag Resolution on Server

Feature flags are resolved once per request in the root layout server component and injected into context. This prevents N+1 flag queries per render.

```typescript
// app/(app)/layout.tsx (server component)
const flags = await resolveAllFeatures(tenantId); // single DB round-trip
return (
  <FeatureFlagProvider flags={flags}>
    {children}
  </FeatureFlagProvider>
);
```

---

## 8. Admin Panel Architecture

### 8.1 Super Admin Modules

```
/admin
├── /dashboard          Aggregate metrics: MRR, active tenants, RSVP volume
├── /tenants            List, search, view, suspend, impersonate tenants
│   └── /[id]           Tenant detail: subscription, usage, audit log
├── /packages           Create/edit packages and feature entitlements
├── /resellers          Manage resellers, commission rates, custom domains
│   └── /[id]           Reseller detail, client list, revenue share
├── /feature-flags      Platform-wide and per-tenant flag overrides
├── /themes             Upload and manage invitation themes
├── /orders             Payment history, refunds
├── /analytics          Platform-wide charts: signups, conversions, churn
└── /settings           Platform config: maintenance mode, email templates
```

### 8.2 Admin Data Access Pattern

The super admin uses a service-role Supabase client that bypasses RLS entirely. This client is **only instantiated server-side** within `/api/admin/*` routes, protected by middleware that validates `role === 'super_admin'` from JWT.

```typescript
// lib/supabase/server.ts
export function createAdminClient() {
  // Uses SERVICE_ROLE key — never expose to client
  return createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false }
  });
}
```

### 8.3 Impersonation

Admins can view any tenant's dashboard via a signed impersonation token (24h TTL), generating a scoped JWT with the target tenant's `tenant_id` and `role: tenant_owner`. All impersonated actions are written to `audit_logs` with the admin's `user_id` as the actor.

---

## 9. Reseller Architecture

### 9.1 Reseller Capabilities

| Capability | Detail |
|---|---|
| White-label branding | Custom logo, primary color, company name |
| Custom domain | `dashboard.resellerbrand.com` via CNAME |
| Client management | Create clients, assign packages, manage subscriptions |
| Custom pricing | Resellers set their own prices (above platform floor) |
| Commission tracking | Revenue share dashboard |
| Client impersonation | View any client dashboard (audit-logged) |

### 9.2 Reseller White-Label Flow

```
1. Reseller registers → pending review
2. Admin approves → reseller account activated
3. Reseller adds custom domain → DNS CNAME created by reseller
4. Platform Edge Middleware reads Host header → looks up resellers.custom_domain
5. Matching reseller_id found → reseller branding loaded from resellers.branding JSONB
6. All pages render with reseller branding; platform attribution hidden
7. Clients sign up via reseller domain → tenant_id linked to reseller_id
```

### 9.3 Commission Calculation

Commissions are calculated at order creation time (not retroactively), stored in `orders.commission_amount`.

```sql
-- At order insert time (trigger or app logic)
commission_amount = amount * (reseller.commission_pct / 100)
```

Monthly reconciliation report generated as CSV, exportable by both platform admin and the reseller.

### 9.4 Reseller Package Constraints

Resellers can only assign packages flagged `is_reseller = TRUE` to their clients. Platform admin controls which packages are reseller-eligible. This prevents resellers from under-selling direct packages.

---

## 10. Deployment Architecture

### 10.1 Infrastructure

```
┌─────────────────────────────────────────────────────────────┐
│                    VERCEL                                    │
│                                                             │
│  Production (main branch)                                   │
│  ├── Primary: weddingplatform.com                           │
│  ├── Wildcard: *.weddingplatform.com                        │
│  └── Auto-assigned per PR: preview-*.vercel.app             │
│                                                             │
│  Staging (staging branch)                                   │
│  └── staging.weddingplatform.com                            │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    SUPABASE                                  │
│                                                             │
│  Production Project  (region: ap-southeast-1 Singapore)    │
│  Staging Project     (separate project, same region)       │
│                                                             │
│  Connection Pooling: PgBouncer (transaction mode)           │
│  Backups: Daily automated (Supabase Pro)                    │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                  EXTERNAL SERVICES                           │
│                                                             │
│  Resend           → Transactional email (RSVP notifications)│
│  Midtrans/Stripe  → Payment processing                      │
│  Cloudflare       → DNS, WAF, DDoS protection               │
│  Upstash Redis    → Rate limiting API routes                │
│  Sentry           → Error monitoring                        │
│  PostHog          → Product analytics (self-hosted option)  │
└─────────────────────────────────────────────────────────────┘
```

### 10.2 Environment Variables

```bash
# Supabase
NEXT_PUBLIC_SUPABASE_URL=
NEXT_PUBLIC_SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=           # server-only, never NEXT_PUBLIC_

# App
NEXT_PUBLIC_APP_URL=
NEXT_PUBLIC_APP_DOMAIN=

# Payments
MIDTRANS_SERVER_KEY=
MIDTRANS_CLIENT_KEY=
MIDTRANS_WEBHOOK_SECRET=

# Email
RESEND_API_KEY=
EMAIL_FROM=

# Rate limiting
UPSTASH_REDIS_REST_URL=
UPSTASH_REDIS_REST_TOKEN=

# Monitoring
SENTRY_DSN=
NEXT_PUBLIC_POSTHOG_KEY=
```

### 10.3 CI/CD Pipeline

```
Push to branch → GitHub Actions:
  1. Type check (tsc --noEmit)
  2. Lint (eslint)
  3. Unit tests (jest/vitest)
  4. Supabase migration dry-run (staging)
  └── PR merge to main:
        1. Supabase migration apply (production)
        2. Vercel deploy (production)
        3. Sentry release tag
```

### 10.4 Performance Targets

| Metric | Target |
|---|---|
| Public invitation page LCP | < 1.5s |
| Dashboard TTFB | < 400ms |
| RSVP form submission | < 800ms |
| Supabase query P95 | < 100ms |
| Vercel Edge Middleware latency | < 15ms |

### 10.5 Public Invitation Page Strategy

Public invitation pages (`/inv/[slug]`) are rendered using **ISR (Incremental Static Regeneration)** with a 60-second revalidation window for published invitations. Unpublished (draft) invitations always use SSR. This gives near-static performance for live invitations without a CDN purge system.

---

## 11. Development Roadmap

### Phase 1 — Foundation (Weeks 1–4)
> Goal: Working multi-tenant app with one invitation theme and basic RSVP.

- [ ] Project scaffold (Next.js 14, Supabase, Tailwind, TypeScript)
- [ ] Supabase schema + migrations (all tables above)
- [ ] RLS policies for all tables
- [ ] Auth flow (email/password, Google OAuth)
- [ ] Edge Middleware (tenant resolution, auth guard)
- [ ] Package system + feature flag resolver
- [ ] Free package seeded with feature entitlements
- [ ] Invitation CRUD (create, edit, publish)
- [ ] First theme: "Classic" (hero, couple, event, RSVP sections)
- [ ] Public invitation page (ISR)
- [ ] Basic RSVP form + responses table
- [ ] User dashboard (invitation list, quick stats)
- [ ] Basic admin panel (tenants list, package management)

### Phase 2 — Core Product (Weeks 5–8)
> Goal: Full guest management, all package tiers live, payment integration.

- [ ] All invitation sections (gallery, countdown, music, gift, wishes wall)
- [ ] 3 additional themes (Floral, Modern, Rustic)
- [ ] Guest management (CRUD, CSV import, personalized links)
- [ ] RSVP real-time updates (Supabase Realtime)
- [ ] Export RSVP and guest CSV
- [ ] Package upgrade flow + Midtrans payment integration
- [ ] Email notifications (Resend — RSVP confirmation, payment receipt)
- [ ] Starter and Premium packages fully configured
- [ ] Invitation analytics (view count, RSVP rate, device breakdown)

### Phase 3 — Reseller Program (Weeks 9–12)
> Goal: Reseller portal live, white-label working, commission tracking.

- [ ] Reseller registration + admin approval flow
- [ ] Reseller portal (client management, billing, branding)
- [ ] Custom domain support (Cloudflare + Edge Middleware lookup)
- [ ] Reseller branding injection
- [ ] Commission calculation + reporting
- [ ] Reseller package tier (wholesale pricing)
- [ ] Client impersonation (audit-logged)

### Phase 4 — Growth & Polish (Weeks 13–16)
> Goal: Performance, observability, and monetization optimization.

- [ ] Rate limiting (Upstash Redis on all API routes)
- [ ] Sentry error monitoring
- [ ] PostHog product analytics
- [ ] SEO: OG image generation per invitation (Vercel OG)
- [ ] WhatsApp deep link sharing (pre-filled message with invitation URL)
- [ ] Invitation duplication
- [ ] Team member invitations (Starter+)
- [ ] Admin impersonation
- [ ] Enterprise package + manual billing
- [ ] Performance audit (Core Web Vitals all green)
- [ ] Security audit (RLS coverage, input sanitization, rate limiting)

---

## Appendix A — Trade-Off Log

| Decision | Options Considered | Choice | Reason |
|---|---|---|---|
| Multi-tenancy model | Schema-per-tenant vs RLS | RLS | Cost, simplicity, high tenant count expected |
| Tenant resolution | Path-based vs subdomain | Subdomain | Custom domain support, cleaner invite URLs |
| Feature flags | DB-backed vs env vars | DB-backed | Runtime toggling without redeploy |
| Public page rendering | SSR vs ISR vs SSG | ISR (60s) | Performance + freshness balance |
| Payment provider | Stripe vs Midtrans | Midtrans primary | Indonesian market; Stripe as secondary |
| Admin DB access | RLS bypass vs separate schema | Service role client (server-only) | Simple, secure, auditable |
| Invitation editor | Drag-and-drop vs property panel | Property panel | Performance, mobile UX, simpler codebase |

---

## Appendix B — Security Checklist (Phase 1)

- [ ] All admin routes protected by `role === 'super_admin'` middleware
- [ ] Service role key never exposed to client bundle
- [ ] RLS enabled and tested on all tenant tables
- [ ] RSVP endpoint rate-limited (10 req/min per IP)
- [ ] File upload validation (type, size, virus scan placeholder)
- [ ] SQL injection: use Supabase JS client (parameterized queries only)
- [ ] Personal invitation links are non-guessable UUIDs
- [ ] Audit log written for all destructive actions
- [ ] HTTPS enforced (Vercel default)
- [ ] CORS configured to platform domains only

---

*End of PHASE1_ARCHITECTURE.md*
