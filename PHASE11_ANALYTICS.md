# PHASE11_ANALYTICS.md — PART 1 OF 3
# Wedding Invitation SaaS Platform — Analytics & Reporting Architecture

> **Version:** 1.0.0
> **Date:** 2026-06-18
> **Status:** Approved for Development
> **Depends on:** PHASE1_ARCHITECTURE.md, PHASE2_DATABASE.md, PHASE3_AUTH.md, PHASE4_ADMIN_ARCHITECTURE.md, PHASE5_PACKAGE_FEATURE_SYSTEM.md, PHASE6_THEME_SYSTEM.md, PHASE7_INVITATION_MANAGEMENT.md, PHASE8_GUEST_MANAGEMENT.md, PHASE9_RSVP_GUESTBOOK.md, PHASE10_PAYMENT_SYSTEM.md

> **This document assembles and formalizes every analytics hook deferred in prior phases**, including: `invitation_analytics` / `invitation_events` (PHASE2 §2, §9), the Redis-buffered `view_count` strategy (PHASE2 §9.2, PHASE7 §13.5), guest engagement tracking (PHASE8 §10.3, §15.6), RSVP analytics views and `get_rsvp_summary()` (PHASE9 §3.2, §9), and the platform billing summary function (PHASE10 §14.3). No new raw-event table is introduced — this phase builds the aggregation, rollup, retention, and reporting layer **on top of** the existing append-only `invitation_events` stream.

---

## Table of Contents (Full Document — spans Part 1–3)

**PART 1 (this file)**
1. [Analytics Architecture Overview](#1-analytics-architecture-overview)
2. [Design Principles & Trade-offs](#2-design-principles--trade-offs)
3. [Analytics Data Model](#3-analytics-data-model)
4. [Event Ingestion Pipeline](#4-event-ingestion-pipeline)
5. [Rollup & Aggregation Engine](#5-rollup--aggregation-engine)

**PART 2**
6. Tenant Analytics Dashboard
7. Invitation-Level Analytics
8. Guest Engagement Analytics
9. RSVP & Guestbook Analytics Integration
10. Reseller Analytics
11. Platform (Super Admin) Analytics
12. Package Feature Integration (Analytics Tiers)

**PART 3**
13. Export System
14. Real-Time Analytics (Live Event Dashboard)
15. Permission Rules & RLS
16. Multi-Tenant Security & Privacy
17. Performance Optimization
18. Scalability Considerations
19. Data Retention & Purge Policy
20. Appendices (Migration Order, API Routes, Metric Reference)

---

## 1. Analytics Architecture Overview

### 1.1 System Purpose

The analytics system answers four distinct audiences with four distinct views over the same underlying event stream:

| Audience | Question Answered | Primary Surface |
|---|---|---|
| Invitation owner (`owner`/`editor`) | "Is my invitation working? Who's engaging, who's coming?" | `/invitations/[id]/analytics` |
| Tenant (multi-invitation) | "Across all my invitations, what's my usage and engagement?" | `/analytics` (tenant dashboard) |
| Reseller admin | "How are my clients performing? What's my portfolio health?" | `/reseller/analytics` |
| Super admin | "How is the platform performing? Revenue, growth, engagement at scale?" | `/admin/analytics` |

All four are powered by the **same three-tier data architecture** already partially declared in PHASE2: raw events → daily rollups → on-demand aggregate queries. PHASE11 completes this by defining the aggregation jobs, the query layer, the dashboards, and the export/reporting surfaces that consume it.

### 1.2 System Layers

```
┌──────────────────────────────────────────────────────────────────────┐
│                      ANALYTICS SYSTEM LAYERS                          │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  1. INGESTION LAYER                                           │   │
│  │     Public page events → invitation_events (BIGSERIAL,        │   │
│  │     append-only, PHASE2 §3 Domain 8)                          │   │
│  │     Redis view-count buffer (PHASE2 §9.2, PHASE7 §13.5)       │   │
│  └──────────────────────────────┬───────────────────────────────┘   │
│                                  │                                    │
│  ┌──────────────────────────────▼───────────────────────────────┐   │
│  │  2. ROLLUP LAYER (Edge Function cron, nightly + hourly)        │   │
│  │     invitation_analytics (daily grain, PHASE2 §3 Domain 8)     │   │
│  │     tenant_analytics_daily (NEW — cross-invitation rollup)     │   │
│  │     reseller_analytics_daily (NEW — cross-tenant rollup)       │   │
│  │     platform_analytics_daily (NEW — platform-wide rollup)      │   │
│  └──────────────────────────────┬───────────────────────────────┘   │
│                                  │                                    │
│  ┌──────────────────────────────▼───────────────────────────────┐   │
│  │  3. QUERY / AGGREGATION LAYER                                  │   │
│  │     Materialized views · RPC functions · Redis query cache    │   │
│  │     Feature-gated metric resolution (PHASE5 feature engine)    │   │
│  └──────────────────────────────┬───────────────────────────────┘   │
│                                  │                                    │
│  ┌──────────────────────────────▼───────────────────────────────┐   │
│  │  4. PRESENTATION LAYER                                         │   │
│  │     Dashboard widgets · CSV/PDF export · Real-time live feed   │   │
│  │     (Supabase Realtime, no polling)                            │   │
│  └──────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

### 1.3 Relationship to Prior Phases — Consistency Map

This phase does **not** redefine any table already created in PHASE2/7/8/9/10. It extends them as follows:

| Existing Object | Defined In | PHASE11 Action |
|---|---|---|
| `invitation_events` (BIGSERIAL, append-only) | PHASE2 §3 Domain 8 | Consumed as-is; ingestion contract formalized in §4 |
| `invitation_analytics` (daily rollup) | PHASE2 §3 Domain 8 | Populated by the rollup job defined in §5; columns unchanged |
| `view_count` Redis buffer | PHASE2 §9.2 / PHASE7 §13.5 | Wired into the rollup job as the canonical view-count source |
| `guest_rsvp_status`, `guest_checkin_status` views | PHASE8 §10.1, §10.2 | Joined into invitation-level analytics queries (§8) |
| `rsvp_daily_trend`, `rsvp_by_category`, `rsvp_response_rate` views | PHASE9 §9.2 | Promoted to first-class dashboard data sources (§9) |
| `get_rsvp_summary()` RPC | PHASE9 §3.2 | Reused directly; not duplicated |
| `get_platform_billing_summary()` RPC | PHASE10 §14.3 | Composed into the platform analytics dashboard (§11) alongside engagement metrics |
| `analytics_basic`, `analytics_advanced`, `analytics_export` feature keys | PHASE5 §2.2, §11.2 Appendix B | Drives all gating in this phase (§12); no new feature keys invented without registration |
| `qr_checkins` / `qr_codes` | PHASE2 §3 Domain 7 | Source for check-in-rate metrics (§8.4) |
| Commission ledger | PHASE10 §13.1 | Source for reseller revenue analytics (§10) |

No existing column is renamed, dropped, or repurposed. All new tables introduced in this phase carry the `analytics_` or `_daily` naming convention to avoid collision.

### 1.4 Audience-to-Tier Mapping

Analytics depth is **package-gated**, consistent with PHASE5's feature resolution engine. There is no separate "Analytics" package — the existing `analytics_basic`, `analytics_advanced`, and `analytics_export` feature keys (already seeded in PHASE5 §11.2) drive all access decisions in this phase. PHASE11 introduces no new feature keys for *tiering* — only for *capability surfacing* where genuinely new functionality is added (see §12).

```
Free        → analytics_basic = FALSE → No analytics dashboard; "Upgrade to see insights" CTA only
Basic       → analytics_basic = TRUE  → Views, RSVP breakdown, device split (read-only, 7-day window)
Premium     → analytics_advanced = TRUE, analytics_export = TRUE → Full history, referrers, exports
Ultimate    → analytics_advanced = TRUE (365-day retention per PHASE5 §11.2 seed), real-time live feed
Reseller    → reseller-scoped dashboard always available to reseller_admin regardless of client's own tier
            (reseller views aggregate counts only — never bypasses a client's own data-row entitlements)
```

---

## 2. Design Principles & Trade-offs

| Decision | Options Considered | Choice | Reason |
|---|---|---|---|
| Rollup grain | Hourly vs daily as base grain | Daily (matches PHASE2 `invitation_analytics.date`) | Already the contract; hourly is layered on top only for the real-time/live tier, not stored long-term |
| Cross-invitation aggregation | Compute on-demand vs pre-aggregate | Pre-aggregate into `tenant_analytics_daily` | Tenants with 50+ invitations would otherwise trigger 50+ row scans per dashboard load |
| Materialized views vs tables | Postgres MATERIALIZED VIEW vs plain rollup tables written by cron | Plain tables for daily rollups; MATERIALIZED VIEW only for the platform summary (refreshed nightly) | Rollup tables support incremental UPSERT; materialized views require full REFRESH which doesn't scale to per-tenant granularity |
| Retention enforcement | Hard delete vs tiered TTL | Tiered: raw events purged per package `analytics_advanced.config.retention_days` (already seeded in PHASE5), daily rollups retained indefinitely (small, append-friendly) | Raw `invitation_events` is the expensive table; daily rollups are cheap and valuable for long-term trend charts even after raw data ages out |
| Real-time updates | Polling vs Supabase Realtime | Realtime channel per invitation (already the pattern in PHASE9 §6.4, §15.4) | Zero additional polling load; consistent with guestbook/RSVP live-feed precedent |
| Export format | Synchronous vs async generation | Async for >5,000 rows (Edge Function + signed URL), synchronous inline for smaller exports | Matches PHASE8 §13.4 async-import precedent; avoids serverless function timeout on large CSV builds |
| Spam/bot filtering in metrics | Include vs exclude `is_spam` RSVP/guestbook rows from analytics counts | Exclude (matches PHASE9 `is_spam = FALSE` filter already used in every PHASE9 index/view) | Analytics must report true engagement, not spam volume; consistency with PHASE9 query patterns is mandatory |
| Device/referrer detection | Client-reported vs server-parsed `user_agent` | Server-parsed at ingestion time, stored as discrete columns (not re-parsed at query time) | Query-time UA parsing does not scale across millions of rollup reads; parse once, store typed |

---

## 3. Analytics Data Model

### 3.1 Recap — Tables Already Defined (PHASE2, not redefined here)

```sql
-- invitation_analytics (PHASE2 §3 Domain 8) — daily grain, one row per (invitation_id, date)
-- Columns: views, unique_visitors, rsvp_attending, rsvp_not_attending, rsvp_maybe,
--          guestbook_count, device_mobile, device_desktop, device_tablet, top_referrers JSONB

-- invitation_events (PHASE2 §3 Domain 8) — BIGSERIAL append-only raw event stream
-- Columns: invitation_id, tenant_id, event_type, guest_id, session_id, metadata JSONB, created_at
```

PHASE11 treats both as **read targets** for dashboards and **write targets** only via the rollup jobs defined in §5 (for `invitation_analytics`) and the ingestion contract in §4 (for `invitation_events`). No schema change to either table is required.

### 3.2 New Table: `invitation_analytics_extended`

Extends per-invitation daily metrics beyond the PHASE2 column set, without altering the original table (avoids a breaking migration on a table that may already carry production data by the time this phase ships).

```sql
CREATE TABLE invitation_analytics_extended (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id       UUID        NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  tenant_id           UUID        NOT NULL REFERENCES tenants(id),
  date                DATE        NOT NULL,

  -- Engagement depth (beyond raw view count)
  avg_session_seconds     INTEGER     NOT NULL DEFAULT 0,
  bounce_count             INTEGER     NOT NULL DEFAULT 0,
  -- A "bounce" = single page_view event with no further interaction event in the session

  -- Section-level engagement (which sections guests actually scroll to / interact with)
  section_views       JSONB       NOT NULL DEFAULT '{}',
  -- Shape: { "gallery": 42, "love_story": 18, "rsvp": 67, "guestbook": 12, ... }

  -- Sharing & virality
  share_clicks         INTEGER     NOT NULL DEFAULT 0,
  whatsapp_share_clicks INTEGER     NOT NULL DEFAULT 0,

  -- Music / gallery interaction (content-level engagement, distinct from RSVP/guestbook)
  music_play_count      INTEGER     NOT NULL DEFAULT 0,
  gallery_view_count     INTEGER     NOT NULL DEFAULT 0,
  gift_view_count        INTEGER     NOT NULL DEFAULT 0,

  -- QR engagement (joins PHASE2 qr_codes/qr_checkins domain)
  qr_scan_count          INTEGER     NOT NULL DEFAULT 0,
  qr_checkin_count        INTEGER     NOT NULL DEFAULT 0,

  -- Traffic source breakdown (parsed once at ingestion; see §4.3)
  source_personalized_link INTEGER  NOT NULL DEFAULT 0,
  source_direct             INTEGER  NOT NULL DEFAULT 0,
  source_whatsapp           INTEGER  NOT NULL DEFAULT 0,
  source_instagram          INTEGER  NOT NULL DEFAULT 0,
  source_other              INTEGER  NOT NULL DEFAULT 0,

  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (invitation_id, date)
);

CREATE TRIGGER trg_inv_analytics_ext_updated_at
  BEFORE UPDATE ON invitation_analytics_extended
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_inv_analytics_ext_inv_date ON invitation_analytics_extended(invitation_id, date DESC);
CREATE INDEX idx_inv_analytics_ext_tenant   ON invitation_analytics_extended(tenant_id, date DESC);
```

**Design note:** This table is 1:1 with `invitation_analytics` on `(invitation_id, date)` by convention (not an FK — both are written by the same rollup transaction, see §5.2) so that the original PHASE2 table remains the canonical "basic" tier dataset (gated by `analytics_basic`) and this extended table is the "advanced" tier dataset (gated by `analytics_advanced`). This mirrors the feature-resolution layering already established in PHASE5 §4.

### 3.3 New Table: `tenant_analytics_daily`

Cross-invitation rollup, one row per `(tenant_id, date)`. Solves the "tenant with N invitations" aggregation problem without forcing a fan-out query across `invitation_analytics` on every dashboard load.

```sql
CREATE TABLE tenant_analytics_daily (
  id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            UUID        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  date                 DATE        NOT NULL,

  active_invitations   INTEGER     NOT NULL DEFAULT 0,
  -- count of invitations with status IN ('draft','published') as of this date

  total_views          INTEGER     NOT NULL DEFAULT 0,
  total_unique_visitors INTEGER    NOT NULL DEFAULT 0,
  total_rsvp_submitted  INTEGER    NOT NULL DEFAULT 0,
  total_rsvp_attending   INTEGER   NOT NULL DEFAULT 0,
  total_guestbook_entries INTEGER  NOT NULL DEFAULT 0,
  total_qr_checkins       INTEGER  NOT NULL DEFAULT 0,
  total_guests_added      INTEGER  NOT NULL DEFAULT 0,

  -- Best/worst performing invitation that day (for "highlight" widgets)
  top_invitation_id     UUID        REFERENCES invitations(id),
  top_invitation_views  INTEGER     NOT NULL DEFAULT 0,

  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (tenant_id, date)
);

CREATE TRIGGER trg_tenant_analytics_daily_updated_at
  BEFORE UPDATE ON tenant_analytics_daily
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_tenant_analytics_daily_tenant ON tenant_analytics_daily(tenant_id, date DESC);
```

### 3.4 New Table: `reseller_analytics_daily`

```sql
CREATE TABLE reseller_analytics_daily (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reseller_id           UUID        NOT NULL REFERENCES resellers(id) ON DELETE CASCADE,
  date                  DATE        NOT NULL,

  active_client_tenants INTEGER     NOT NULL DEFAULT 0,
  total_client_invitations INTEGER  NOT NULL DEFAULT 0,
  total_client_views     INTEGER    NOT NULL DEFAULT 0,
  total_client_rsvp       INTEGER   NOT NULL DEFAULT 0,

  -- Commercial metrics (joins PHASE10 commission_ledger)
  new_client_signups     INTEGER    NOT NULL DEFAULT 0,
  commission_accrued     NUMERIC(12,2) NOT NULL DEFAULT 0,

  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (reseller_id, date)
);

CREATE TRIGGER trg_reseller_analytics_daily_updated_at
  BEFORE UPDATE ON reseller_analytics_daily
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_reseller_analytics_daily_reseller ON reseller_analytics_daily(reseller_id, date DESC);
```

### 3.5 New Table: `platform_analytics_daily`

Platform-wide rollup for the Super Admin dashboard. One row per day — small table, indefinite retention.

```sql
CREATE TABLE platform_analytics_daily (
  date                     DATE        PRIMARY KEY,

  -- Growth
  new_tenants              INTEGER     NOT NULL DEFAULT 0,
  active_tenants           INTEGER     NOT NULL DEFAULT 0,
  -- "active" = had >=1 published invitation with >=1 view that day
  new_invitations          INTEGER     NOT NULL DEFAULT 0,
  published_invitations    INTEGER     NOT NULL DEFAULT 0,

  -- Engagement
  total_views               INTEGER    NOT NULL DEFAULT 0,
  total_rsvp_submitted        INTEGER  NOT NULL DEFAULT 0,
  total_guestbook_entries      INTEGER NOT NULL DEFAULT 0,

  -- Revenue (sourced from get_platform_billing_summary(), PHASE10 §14.3)
  gross_revenue              NUMERIC(14,2) NOT NULL DEFAULT 0,
  net_revenue                NUMERIC(14,2) NOT NULL DEFAULT 0,
  paid_order_count            INTEGER  NOT NULL DEFAULT 0,
  total_commission_accrued     NUMERIC(14,2) NOT NULL DEFAULT 0,

  -- Package distribution snapshot (denormalized for trend charting without re-joining subscriptions)
  package_distribution        JSONB    NOT NULL DEFAULT '{}',
  -- Shape: { "free": 8200, "basic": 1400, "premium": 380, "ultimate": 20 }

  created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_platform_analytics_daily_updated_at
  BEFORE UPDATE ON platform_analytics_daily
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_platform_analytics_date ON platform_analytics_daily(date DESC);
```

### 3.6 New Table: `analytics_export_jobs`

Tracks async export generation (CSV/PDF) for large datasets, following the same job-tracking pattern as `guest_import_batches` (PHASE8 §2.4).

```sql
CREATE TABLE analytics_export_jobs (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID        NOT NULL REFERENCES tenants(id),
  requested_by    UUID        NOT NULL REFERENCES users(id),
  scope           TEXT        NOT NULL
                              CHECK (scope IN ('invitation', 'tenant', 'reseller')),
  scope_id        UUID        NOT NULL,
  -- invitation_id, tenant_id, or reseller_id depending on `scope`
  export_format   TEXT        NOT NULL DEFAULT 'csv'
                              CHECK (export_format IN ('csv', 'pdf', 'xlsx')),
  date_from       DATE        NOT NULL,
  date_to         DATE        NOT NULL,
  status          TEXT        NOT NULL DEFAULT 'pending'
                              CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
  file_path        TEXT,
  -- storage path once completed; signed URL generated on demand (not stored)
  error_message    TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at     TIMESTAMPTZ
);

CREATE INDEX idx_analytics_export_tenant  ON analytics_export_jobs(tenant_id, created_at DESC);
CREATE INDEX idx_analytics_export_pending ON analytics_export_jobs(status)
  WHERE status IN ('pending', 'processing');
```

### 3.7 TypeScript Type Definitions

```typescript
// types/analytics.ts

export interface InvitationAnalyticsDaily {
  // From PHASE2 invitation_analytics (basic tier)
  date:                 string;
  views:                number;
  unique_visitors:      number;
  rsvp_attending:       number;
  rsvp_not_attending:   number;
  rsvp_maybe:           number;
  guestbook_count:      number;
  device_mobile:        number;
  device_desktop:       number;
  device_tablet:        number;
  top_referrers:        Array<{ referrer: string; count: number }>;
}

export interface InvitationAnalyticsExtendedDaily {
  // From invitation_analytics_extended (advanced tier)
  date:                     string;
  avg_session_seconds:      number;
  bounce_count:              number;
  section_views:             Record<string, number>;
  share_clicks:               number;
  whatsapp_share_clicks:       number;
  music_play_count:            number;
  gallery_view_count:           number;
  gift_view_count:               number;
  qr_scan_count:                  number;
  qr_checkin_count:                number;
  source_personalized_link:         number;
  source_direct:                     number;
  source_whatsapp:                    number;
  source_instagram:                    number;
  source_other:                         number;
}

export interface InvitationAnalyticsSummary {
  invitation_id:    string;
  total_views:      number;
  total_unique:     number;
  rsvp_summary:     RsvpSummary; // reused from PHASE9 types/rsvp.ts
  response_rate:    number;
  checkin_rate:     number | null; // null if qr_checkin feature not enabled
  trend:            InvitationAnalyticsDaily[];
  trend_extended?:  InvitationAnalyticsExtendedDaily[]; // present only if analytics_advanced enabled
}

export interface TenantAnalyticsSummary {
  tenant_id:               string;
  date_from:               string;
  date_to:                 string;
  active_invitations:      number;
  total_views:              number;
  total_unique_visitors:     number;
  total_rsvp_submitted:       number;
  total_rsvp_attending:        number;
  total_guestbook_entries:      number;
  total_qr_checkins:             number;
  top_invitation:                 { id: string; title: string; views: number } | null;
  trend:                            TenantAnalyticsDailyPoint[];
}

export interface TenantAnalyticsDailyPoint {
  date:                string;
  total_views:         number;
  total_rsvp_attending: number;
}

export interface ResellerAnalyticsSummary {
  reseller_id:               string;
  active_client_tenants:     number;
  total_client_invitations:   number;
  total_client_views:          number;
  total_client_rsvp:            number;
  new_client_signups_30d:        number;
  commission_accrued_30d:         number;
  trend:                            ResellerAnalyticsDailyPoint[];
}

export interface ResellerAnalyticsDailyPoint {
  date:                  string;
  active_client_tenants: number;
  total_client_views:     number;
  commission_accrued:      number;
}

export interface PlatformAnalyticsSummary {
  date_from:               string;
  date_to:                 string;
  new_tenants:             number;
  active_tenants:          number;
  new_invitations:         number;
  published_invitations:   number;
  total_views:              number;
  total_rsvp_submitted:       number;
  gross_revenue:               number;
  net_revenue:                  number;
  paid_order_count:              number;
  package_distribution:           Record<string, number>;
  trend:                            PlatformAnalyticsDailyPoint[];
}

export interface PlatformAnalyticsDailyPoint {
  date:           string;
  new_tenants:    number;
  total_views:    number;
  net_revenue:    number;
}

export type ExportScope  = 'invitation' | 'tenant' | 'reseller';
export type ExportFormat = 'csv' | 'pdf' | 'xlsx';
export type ExportStatus = 'pending' | 'processing' | 'completed' | 'failed';

export interface AnalyticsExportJob {
  id:             string;
  tenant_id:      string;
  scope:          ExportScope;
  scope_id:       string;
  export_format:  ExportFormat;
  date_from:      string;
  date_to:        string;
  status:         ExportStatus;
  file_path:      string | null;
  error_message:  string | null;
  created_at:     string;
  completed_at:   string | null;
}
```

---

## 4. Event Ingestion Pipeline

### 4.1 Ingestion Contract (Formalizing PHASE2's `invitation_events`)

PHASE2 defined the `event_type` CHECK constraint as:

```sql
event_type IN (
  'page_view', 'rsvp_open', 'rsvp_submit',
  'guestbook_submit', 'music_play', 'gallery_view',
  'qr_scan', 'gift_view', 'share_click'
)
```

PHASE11 adds three event types required for the extended analytics tier (§3.2 columns `bounce_count`, `section_views`, `whatsapp_share_clicks`). This is an additive `ALTER ... CHECK` migration, not a redefinition:

```sql
-- Migration: extend invitation_events.event_type check constraint
ALTER TABLE invitation_events DROP CONSTRAINT IF EXISTS invitation_events_event_type_check;
ALTER TABLE invitation_events ADD CONSTRAINT invitation_events_event_type_check
  CHECK (event_type IN (
    'page_view', 'rsvp_open', 'rsvp_submit',
    'guestbook_submit', 'music_play', 'gallery_view',
    'qr_scan', 'gift_view', 'share_click',
    'section_scroll',      -- NEW: fired once per section when it enters viewport
    'whatsapp_share_click',-- NEW: distinct from generic share_click for source attribution
    'session_end'          -- NEW: fired on page unload/visibility-hidden, carries duration_ms
  ));
```

### 4.2 Client-Side Event Emission

Events are emitted from the public invitation page via a lightweight, dependency-free beacon — no analytics SDK is added to keep the public page's Core Web Vitals untouched (consistent with PHASE7 §13 performance posture).

```typescript
// lib/analytics/client-tracker.ts
// Runs only on /inv/[slug] — never in the authenticated app shell

'use client';

let sessionId: string;
let sectionsSeen = new Set<string>();
let sessionStart = 0;

export function initInvitationTracking(invitationId: string, guestId: string | null) {
  sessionId = crypto.randomUUID();
  sessionStart = Date.now();

  trackEvent('page_view', invitationId, guestId, { referrer: document.referrer });

  // IntersectionObserver fires section_scroll once per section, deduplicated client-side
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const sectionType = entry.target.getAttribute('data-section-type');
        if (!sectionType || sectionsSeen.has(sectionType)) continue;
        sectionsSeen.add(sectionType);
        trackEvent('section_scroll', invitationId, guestId, { section: sectionType });
      }
    },
    { threshold: 0.4 }
  );
  document.querySelectorAll('[data-section-type]').forEach(el => observer.observe(el));

  // Beacon on page exit — uses navigator.sendBeacon for reliability during unload
  window.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') {
      sendBeacon('session_end', invitationId, guestId, {
        duration_ms: Date.now() - sessionStart,
        sections_seen: [...sectionsSeen],
      });
    }
  });
}

function trackEvent(
  eventType: string,
  invitationId: string,
  guestId: string | null,
  metadata: Record<string, unknown>
) {
  fetch('/api/events/track', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ invitation_id: invitationId, event_type: eventType, guest_id: guestId, session_id: sessionId, metadata }),
    keepalive: true,
  }).catch(() => { /* fire-and-forget; analytics must never block or break the page */ });
}

function sendBeacon(
  eventType: string,
  invitationId: string,
  guestId: string | null,
  metadata: Record<string, unknown>
) {
  const payload = JSON.stringify({ invitation_id: invitationId, event_type: eventType, guest_id: guestId, session_id: sessionId, metadata });
  navigator.sendBeacon?.('/api/events/track', payload);
}
```

### 4.3 Server-Side Ingestion Endpoint

```typescript
// app/api/events/track/route.ts
// Public, unauthenticated, rate-limited, no-auth-required by design (matches PHASE9 /api/rsvp posture)

import { z } from 'zod';
import { headers } from 'next/headers';
import { checkEventRateLimit } from '@/lib/analytics/rate-limit';
import { parseUserAgent } from '@/lib/analytics/ua-parser';
import { classifyReferrer } from '@/lib/analytics/referrer-classifier';

const TrackEventSchema = z.object({
  invitation_id: z.string().uuid(),
  event_type:    z.enum([
    'page_view', 'rsvp_open', 'rsvp_submit', 'guestbook_submit',
    'music_play', 'gallery_view', 'qr_scan', 'gift_view',
    'share_click', 'section_scroll', 'whatsapp_share_click', 'session_end',
  ]),
  guest_id:    z.string().uuid().nullable().optional(),
  session_id:  z.string().min(1).max(100),
  metadata:    z.record(z.unknown()).default({}),
});

export async function POST(request: Request) {
  const headersList = headers();
  const ip = headersList.get('x-forwarded-for')?.split(',')[0]?.trim() ?? 'unknown';
  const userAgent = headersList.get('user-agent') ?? '';
  const referrer = headersList.get('referer') ?? '';

  // Rate limit: 60 events / minute / IP — generous, since one page load can emit ~8 events
  const limited = await checkEventRateLimit(ip);
  if (limited) return new Response(null, { status: 429 });

  const parsed = TrackEventSchema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) return new Response(null, { status: 422 });

  const supabase = createServerClient();

  // Verify invitation exists and is published — never log events for draft/archived/deleted
  const { data: invitation } = await supabase
    .from('invitations')
    .select('id, tenant_id, status')
    .eq('id', parsed.data.invitation_id)
    .eq('status', 'published')
    .maybeSingle();

  if (!invitation) return new Response(null, { status: 204 }); // silently drop, no error leak

  // Guest token cross-check (same constraint as PHASE9 §13.3 — guest must belong to THIS invitation)
  let validatedGuestId: string | null = null;
  if (parsed.data.guest_id) {
    const { data: guest } = await supabase
      .from('guests')
      .select('id')
      .eq('id', parsed.data.guest_id)
      .eq('invitation_id', invitation.id)
      .is('deleted_at', null)
      .maybeSingle();
    validatedGuestId = guest?.id ?? null;
  }

  const device = parseUserAgent(userAgent); // 'mobile' | 'desktop' | 'tablet'
  const source = classifyReferrer(referrer, parsed.data.metadata.referrer as string | undefined);

  await supabase.from('invitation_events').insert({
    invitation_id: invitation.id,
    tenant_id:     invitation.tenant_id,
    event_type:    parsed.data.event_type,
    guest_id:       validatedGuestId,
    session_id:      parsed.data.session_id,
    metadata:         { ...parsed.data.metadata, device, source, ip_hash: hashIp(ip) },
  });

  // view_count buffering reuses the exact Redis pattern from PHASE7 §13.5
  if (parsed.data.event_type === 'page_view') {
    await redis.incr(`inv:views:${invitation.id}`);
  }

  return new Response(null, { status: 204 });
}

function hashIp(ip: string): string {
  // One-way hash for unique-visitor counting without retaining raw IP in events table
  // (raw IP already exists transiently in rsvp_responses/guestbook_entries per PHASE9 §13.4 policy;
  //  invitation_events never stores raw IP at all — hash-only by design, stricter than PHASE9)
  return crypto.createHash('sha256').update(ip + process.env.ANALYTICS_IP_SALT).digest('hex').slice(0, 16);
}
```

### 4.4 Device & Referrer Classification

```typescript
// lib/analytics/ua-parser.ts

export function parseUserAgent(ua: string): 'mobile' | 'desktop' | 'tablet' {
  if (/iPad|Tablet/i.test(ua)) return 'tablet';
  if (/Mobile|Android|iPhone/i.test(ua)) return 'mobile';
  return 'desktop';
}

// lib/analytics/referrer-classifier.ts

export function classifyReferrer(referrerHeader: string, clientHintedSource?: string): string {
  if (clientHintedSource === 'personalized_link') return 'personalized_link';
  if (!referrerHeader) return 'direct';
  if (/wa\.me|whatsapp/i.test(referrerHeader))   return 'whatsapp';
  if (/instagram\.com/i.test(referrerHeader))     return 'instagram';
  if (/facebook\.com|fb\.com/i.test(referrerHeader)) return 'facebook';
  if (/t\.co|twitter\.com|x\.com/i.test(referrerHeader)) return 'twitter';
  return 'other';
}
```

### 4.5 Rate Limiting (Reusing PHASE9's Upstash Pattern)

```typescript
// lib/analytics/rate-limit.ts

import { Ratelimit } from '@upstash/ratelimit';
import { Redis } from '@upstash/redis';

const redis = Redis.fromEnv();

export const eventTrackRateLimit = new Ratelimit({
  redis,
  limiter: Ratelimit.slidingWindow(60, '60 s'),
  prefix:  'rl:events',
});

export async function checkEventRateLimit(ip: string): Promise<boolean> {
  const { success } = await eventTrackRateLimit.limit(ip);
  return !success;
}
```

### 4.6 Ingestion Failure Isolation

Per the client-side contract in §4.2, all tracking calls are fire-and-forget (`.catch()` swallows errors, `sendBeacon` has no response handling at all). This guarantees that **any failure in the analytics pipeline — rate limiting, DB write failure, malformed payload — can never break, delay, or visibly degrade the public invitation page.** This is a hard architectural invariant carried over from PHASE7's ISR performance posture and PHASE9's mobile-first guest experience requirements.

---

## 5. Rollup & Aggregation Engine

### 5.1 Rollup Job Topology

```
Every 60s   →  flush-view-counts          (Redis → invitations.view_count, PHASE7 §13.5 contract)
Hourly      →  rollup-invitation-hourly    (invitation_events → in-memory buffer, powers "live" tier only,
                                             not persisted — see PART 3 §14)
Nightly 00:30 →  rollup-invitation-daily    (invitation_events → invitation_analytics +
                                             invitation_analytics_extended)
Nightly 01:00 →  rollup-tenant-daily        (invitation_analytics → tenant_analytics_daily)
Nightly 01:15 →  rollup-reseller-daily      (tenant_analytics_daily + commission_ledger →
                                             reseller_analytics_daily)
Nightly 01:30 →  rollup-platform-daily      (tenant_analytics_daily + get_platform_billing_summary() →
                                             platform_analytics_daily)
```

Each job is strictly downstream of the previous tier's completion (tenant rollup cannot run before invitation rollup for the same day), enforced via a `rollup_job_runs` ledger (§5.6) rather than wall-clock spacing alone — wall-clock offsets are a convenience, not the correctness mechanism.

### 5.2 Nightly Invitation Rollup (Core Job)

```typescript
// supabase/functions/rollup-invitation-daily/index.ts
// Schedule: daily at 00:30 (Asia/Jakarta) — processes the PREVIOUS calendar day

Deno.serve(async () => {
  const admin = createAdminClient();
  const targetDate = getPreviousDateString(); // 'YYYY-MM-DD' in Asia/Jakarta

  if (await alreadyRolledUp(admin, 'invitation_daily', targetDate)) {
    return new Response(JSON.stringify({ skipped: true, reason: 'already processed' }));
  }

  // Find all invitations with ANY event activity on targetDate
  const { data: activeInvitations } = await admin
    .from('invitation_events')
    .select('invitation_id, tenant_id')
    .gte('created_at', `${targetDate}T00:00:00+07:00`)
    .lt('created_at', `${targetDate}T23:59:59.999+07:00`);

  const invitationIds = [...new Set((activeInvitations ?? []).map(r => r.invitation_id))];
  let processed = 0;

  for (const invitationId of invitationIds) {
    const tenantId = activeInvitations!.find(r => r.invitation_id === invitationId)!.tenant_id;
    await rollupSingleInvitation(admin, invitationId, tenantId, targetDate);
    processed++;
  }

  await recordRollupRun(admin, 'invitation_daily', targetDate, processed);
  return new Response(JSON.stringify({ processed, date: targetDate }));
});

async function rollupSingleInvitation(
  admin: SupabaseClient,
  invitationId: string,
  tenantId: string,
  date: string
): Promise<void> {
  const dayStart = `${date}T00:00:00+07:00`;
  const dayEnd   = `${date}T23:59:59.999+07:00`;

  const { data: events } = await admin
    .from('invitation_events')
    .select('event_type, guest_id, session_id, metadata, created_at')
    .eq('invitation_id', invitationId)
    .gte('created_at', dayStart)
    .lt('created_at', dayEnd);

  const rows = events ?? [];

  // ── Basic tier aggregation (→ invitation_analytics) ──────────────────
  const pageViews   = rows.filter(r => r.event_type === 'page_view');
  const uniqueSessions = new Set(pageViews.map(r => r.session_id)).size;
  const deviceCounts   = countByDevice(pageViews);
  const referrers      = countByReferrer(pageViews);

  const { count: rsvpAttending }    = await countRsvpForDay(admin, invitationId, 'attending', dayStart, dayEnd);
  const { count: rsvpNotAttending } = await countRsvpForDay(admin, invitationId, 'not_attending', dayStart, dayEnd);
  const { count: rsvpMaybe }        = await countRsvpForDay(admin, invitationId, 'maybe', dayStart, dayEnd);
  const guestbookCount               = rows.filter(r => r.event_type === 'guestbook_submit').length;

  await admin.from('invitation_analytics').upsert({
    invitation_id:      invitationId,
    tenant_id:           tenantId,
    date,
    views:                pageViews.length,
    unique_visitors:       uniqueSessions,
    rsvp_attending:         rsvpAttending ?? 0,
    rsvp_not_attending:      rsvpNotAttending ?? 0,
    rsvp_maybe:               rsvpMaybe ?? 0,
    guestbook_count:           guestbookCount,
    device_mobile:               deviceCounts.mobile,
    device_desktop:                deviceCounts.desktop,
    device_tablet:                   deviceCounts.tablet,
    top_referrers:                     referrers,
  }, { onConflict: 'invitation_id,date' });

  // ── Extended tier aggregation (→ invitation_analytics_extended) ──────
  const sessionDurations = rows
    .filter(r => r.event_type === 'session_end')
    .map(r => (r.metadata as any)?.duration_ms ?? 0);
  const avgSessionSeconds = sessionDurations.length
    ? Math.round(sessionDurations.reduce((a, b) => a + b, 0) / sessionDurations.length / 1000)
    : 0;

  const sessionsWithOnlyPageView = countBouncedSessions(rows);
  const sectionViews = countSectionScrolls(rows);
  const sourceBreakdown = countBySource(pageViews);

  await admin.from('invitation_analytics_extended').upsert({
    invitation_id:           invitationId,
    tenant_id:                 tenantId,
    date,
    avg_session_seconds:         avgSessionSeconds,
    bounce_count:                  sessionsWithOnlyPageView,
    section_views:                   sectionViews,
    share_clicks:                      rows.filter(r => r.event_type === 'share_click').length,
    whatsapp_share_clicks:                rows.filter(r => r.event_type === 'whatsapp_share_click').length,
    music_play_count:                      rows.filter(r => r.event_type === 'music_play').length,
    gallery_view_count:                      rows.filter(r => r.event_type === 'gallery_view').length,
    gift_view_count:                           rows.filter(r => r.event_type === 'gift_view').length,
    qr_scan_count:                                rows.filter(r => r.event_type === 'qr_scan').length,
    qr_checkin_count:                                await countQrCheckinsForDay(admin, invitationId, dayStart, dayEnd),
    source_personalized_link:                           sourceBreakdown.personalized_link ?? 0,
    source_direct:                                        sourceBreakdown.direct ?? 0,
    source_whatsapp:                                       sourceBreakdown.whatsapp ?? 0,
    source_instagram:                                        sourceBreakdown.instagram ?? 0,
    source_other:                                              sourceBreakdown.other ?? 0,
  }, { onConflict: 'invitation_id,date' });
}
```

### 5.3 RSVP/Guestbook Aggregation Reuses PHASE9 Views Directly

The rollup job does **not** reimplement RSVP counting logic — it queries `rsvp_responses` directly with the same `is_spam = FALSE` filter convention established in PHASE9, ensuring rollup numbers always match what the owner sees in the live RSVP dashboard:

```typescript
// lib/analytics/rsvp-day-counter.ts

async function countRsvpForDay(
  admin: SupabaseClient,
  invitationId: string,
  attendance: 'attending' | 'not_attending' | 'maybe',
  dayStart: string,
  dayEnd: string
): Promise<{ count: number }> {
  const { count } = await admin
    .from('rsvp_responses')
    .select('id', { count: 'exact', head: true })
    .eq('invitation_id', invitationId)
    .eq('attendance', attendance)
    .eq('is_spam', false)                  // consistent with PHASE9 §2.1 indexing convention
    .gte('submitted_at', dayStart)
    .lt('submitted_at', dayEnd);
  return { count: count ?? 0 };
}

async function countQrCheckinsForDay(
  admin: SupabaseClient,
  invitationId: string,
  dayStart: string,
  dayEnd: string
): Promise<number> {
  const { count } = await admin
    .from('qr_checkins')
    .select('id, qr_code:qr_codes!inner(invitation_id)', { count: 'exact', head: true })
    .eq('qr_code.invitation_id', invitationId)
    .gte('checked_in_at', dayStart)
    .lt('checked_in_at', dayEnd);
  return count ?? 0;
}
```

### 5.4 Tenant / Reseller / Platform Rollup Jobs

```typescript
// supabase/functions/rollup-tenant-daily/index.ts
// Schedule: daily at 01:00 — depends on rollup-invitation-daily having completed for targetDate

Deno.serve(async () => {
  const admin = createAdminClient();
  const targetDate = getPreviousDateString();

  if (!(await rollupCompletedFor(admin, 'invitation_daily', targetDate))) {
    return new Response(JSON.stringify({ deferred: true, reason: 'upstream rollup not complete' }), { status: 202 });
  }
  if (await alreadyRolledUp(admin, 'tenant_daily', targetDate)) {
    return new Response(JSON.stringify({ skipped: true }));
  }

  // Group invitation_analytics rows by tenant for targetDate
  const { data: dayRows } = await admin
    .from('invitation_analytics')
    .select('tenant_id, invitation_id, views, unique_visitors, rsvp_attending, guestbook_count')
    .eq('date', targetDate);

  const byTenant = groupBy(dayRows ?? [], r => r.tenant_id);

  for (const [tenantId, rows] of Object.entries(byTenant)) {
    const totalViews   = rows.reduce((s, r) => s + r.views, 0);
    const totalUnique   = rows.reduce((s, r) => s + r.unique_visitors, 0);
    const totalAttending  = rows.reduce((s, r) => s + r.rsvp_attending, 0);
    const totalGuestbook    = rows.reduce((s, r) => s + r.guestbook_count, 0);
    const top = rows.reduce((best, r) => (r.views > (best?.views ?? -1) ? r : best), null as any);

    const { count: activeInvitations } = await admin
      .from('invitations')
      .select('id', { count: 'exact', head: true })
      .eq('tenant_id', tenantId)
      .in('status', ['draft', 'published'])
      .is('deleted_at', null);

    const { count: totalGuestsAdded } = await admin
      .from('guests')
      .select('id', { count: 'exact', head: true })
      .in('invitation_id', rows.map(r => r.invitation_id))
      .gte('created_at', `${targetDate}T00:00:00+07:00`)
      .lt('created_at', `${targetDate}T23:59:59.999+07:00`);

    const { count: totalQrCheckins } = await admin
      .from('qr_checkins')
      .select('id, qr_code:qr_codes!inner(tenant_id)', { count: 'exact', head: true })
      .eq('qr_code.tenant_id', tenantId)
      .gte('checked_in_at', `${targetDate}T00:00:00+07:00`)
      .lt('checked_in_at', `${targetDate}T23:59:59.999+07:00`);

    await admin.from('tenant_analytics_daily').upsert({
      tenant_id:               tenantId,
      date:                     targetDate,
      active_invitations:        activeInvitations ?? 0,
      total_views:                 totalViews,
      total_unique_visitors:         totalUnique,
      total_rsvp_submitted:            rows.length ? totalAttending : 0, // attending-only submit count below
      total_rsvp_attending:              totalAttending,
      total_guestbook_entries:             totalGuestbook,
      total_qr_checkins:                     totalQrCheckins ?? 0,
      total_guests_added:                      totalGuestsAdded ?? 0,
      top_invitation_id:                         top?.invitation_id ?? null,
      top_invitation_views:                        top?.views ?? 0,
    }, { onConflict: 'tenant_id,date' });
  }

  await recordRollupRun(admin, 'tenant_daily', targetDate, Object.keys(byTenant).length);
  return new Response(JSON.stringify({ tenants_processed: Object.keys(byTenant).length }));
});
```

```typescript
// supabase/functions/rollup-reseller-daily/index.ts
// Schedule: daily at 01:15 — depends on rollup-tenant-daily

Deno.serve(async () => {
  const admin = createAdminClient();
  const targetDate = getPreviousDateString();

  if (!(await rollupCompletedFor(admin, 'tenant_daily', targetDate))) {
    return new Response(JSON.stringify({ deferred: true }), { status: 202 });
  }

  const { data: resellers } = await admin.from('resellers').select('id').eq('status', 'active');

  for (const reseller of resellers ?? []) {
    const { data: clientTenantIds } = await admin
      .from('reseller_tenants').select('tenant_id').eq('reseller_id', reseller.id);

    const tenantIds = (clientTenantIds ?? []).map(r => r.tenant_id);
    if (tenantIds.length === 0) continue;

    const { data: tenantDayRows } = await admin
      .from('tenant_analytics_daily')
      .select('total_views, total_rsvp_attending, active_invitations')
      .in('tenant_id', tenantIds)
      .eq('date', targetDate);

    const { data: newSignups } = await admin
      .from('reseller_tenants')
      .select('id', { count: 'exact', head: true })
      .eq('reseller_id', reseller.id)
      .gte('invited_at', `${targetDate}T00:00:00+07:00`)
      .lt('invited_at', `${targetDate}T23:59:59.999+07:00`);

    const { data: commissionRows } = await admin
      .from('commission_ledger')
      .select('commission_amount')
      .eq('reseller_id', reseller.id)
      .eq('status', 'accrued')
      .gte('created_at', `${targetDate}T00:00:00+07:00`)
      .lt('created_at', `${targetDate}T23:59:59.999+07:00`);

    const commissionAccrued = (commissionRows ?? []).reduce((s, r) => s + Number(r.commission_amount), 0);

    await admin.from('reseller_analytics_daily').upsert({
      reseller_id:                  reseller.id,
      date:                          targetDate,
      active_client_tenants:           tenantIds.length,
      total_client_invitations:          (tenantDayRows ?? []).reduce((s, r) => s + r.active_invitations, 0),
      total_client_views:                  (tenantDayRows ?? []).reduce((s, r) => s + r.total_views, 0),
      total_client_rsvp:                     (tenantDayRows ?? []).reduce((s, r) => s + r.total_rsvp_attending, 0),
      new_client_signups:                       (newSignups as any)?.length ?? 0,
      commission_accrued:                          commissionAccrued,
    }, { onConflict: 'reseller_id,date' });
  }

  await recordRollupRun(admin, 'reseller_daily', targetDate, (resellers ?? []).length);
  return new Response(JSON.stringify({ resellers_processed: (resellers ?? []).length }));
});
```

```typescript
// supabase/functions/rollup-platform-daily/index.ts
// Schedule: daily at 01:30 — depends on rollup-tenant-daily; composes PHASE10's billing summary RPC

Deno.serve(async () => {
  const admin = createAdminClient();
  const targetDate = getPreviousDateString();

  if (!(await rollupCompletedFor(admin, 'tenant_daily', targetDate))) {
    return new Response(JSON.stringify({ deferred: true }), { status: 202 });
  }

  const dayStart = `${targetDate}T00:00:00+07:00`;
  const dayEnd   = `${targetDate}T23:59:59.999+07:00`;

  const [{ count: newTenants }, { data: tenantDayRows }, { count: newInvitations }, { count: publishedInvitations }] =
    await Promise.all([
      admin.from('tenants').select('id', { count: 'exact', head: true })
        .gte('created_at', dayStart).lt('created_at', dayEnd),
      admin.from('tenant_analytics_daily')
        .select('total_views, total_rsvp_attending, total_guestbook_entries, tenant_id')
        .eq('date', targetDate),
      admin.from('invitations').select('id', { count: 'exact', head: true })
        .gte('created_at', dayStart).lt('created_at', dayEnd),
      admin.from('invitations').select('id', { count: 'exact', head: true })
        .eq('status', 'published')
        .gte('published_at', dayStart).lt('published_at', dayEnd),
    ]);

  // Reuse PHASE10 §14.3 RPC directly — no duplicated revenue logic
  const { data: billingSummary } = await admin.rpc('get_platform_billing_summary', {
    p_from: dayStart, p_to: dayEnd,
  });

  const { data: packageDist } = await admin
    .from('tenant_subscriptions')
    .select('package:packages(slug)')
    .in('status', ['active', 'trialing']);

  const distribution: Record<string, number> = {};
  for (const row of packageDist ?? []) {
    const slug = (row.package as any)?.slug ?? 'unknown';
    distribution[slug] = (distribution[slug] ?? 0) + 1;
  }

  await admin.from('platform_analytics_daily').upsert({
    date:                       targetDate,
    new_tenants:                  newTenants ?? 0,
    active_tenants:                 (tenantDayRows ?? []).length,
    new_invitations:                  newInvitations ?? 0,
    published_invitations:               publishedInvitations ?? 0,
    total_views:                            (tenantDayRows ?? []).reduce((s, r) => s + r.total_views, 0),
    total_rsvp_submitted:                      (tenantDayRows ?? []).reduce((s, r) => s + r.total_rsvp_attending, 0),
    total_guestbook_entries:                       (tenantDayRows ?? []).reduce((s, r) => s + r.total_guestbook_entries, 0),
    gross_revenue:                                    billingSummary?.gross_revenue ?? 0,
    net_revenue:                                        billingSummary?.net_revenue ?? 0,
    paid_order_count:                                     billingSummary?.paid_order_count ?? 0,
    total_commission_accrued:                                billingSummary?.total_commission ?? 0,
    package_distribution:                                       distribution,
  }, { onConflict: 'date' });

  await recordRollupRun(admin, 'platform_daily', targetDate, 1);
  return new Response(JSON.stringify({ status: 'ok', date: targetDate }));
});
```

### 5.5 View Count Flush (Wiring PHASE7 §13.5 Into the Rollup Contract)

PHASE7 already specified the Redis-buffered `view_count` flush. PHASE11 formalizes its consumer relationship: the flush updates `invitations.view_count` for the live counter shown in the dashboard header, while the **authoritative historical** view count for any given day comes from `invitation_analytics.views` (computed from `invitation_events`, §5.2) — not from the Redis-buffered cumulative counter. This avoids double-counting and matches the PHASE2 §9.2 design note that `view_count` "becomes a cached value refreshed nightly rather than a real-time counter" at scale.

```typescript
// supabase/functions/flush-view-counts/index.ts
// Schedule: every 60 seconds (unchanged contract from PHASE7 §13.5)

Deno.serve(async () => {
  const admin = createAdminClient();
  const redis = Redis.fromEnv();

  const keys = await redis.keys('inv:views:*');
  if (keys.length === 0) return new Response(JSON.stringify({ flushed: 0 }));

  let flushed = 0;
  for (const key of keys) {
    const invitationId = key.replace('inv:views:', '');
    const count = await redis.get<number>(key);
    if (!count) continue;

    await admin.rpc('increment_view_count', { p_invitation_id: invitationId, p_amount: count });
    await redis.del(key);
    flushed++;
  }

  return new Response(JSON.stringify({ flushed }));
});
```

```sql
-- supabase/migrations/110_increment_view_count_fn.sql

CREATE OR REPLACE FUNCTION increment_view_count(p_invitation_id UUID, p_amount INTEGER)
RETURNS VOID AS $$
BEGIN
  UPDATE invitations
  SET view_count = view_count + p_amount
  WHERE id = p_invitation_id;
END;
$$ LANGUAGE plpgsql;
```

### 5.6 Rollup Idempotency Ledger

Every rollup tier checks and records its own completion in a shared ledger table, preventing double-processing on cron retry/overlap and giving downstream tiers a reliable dependency check (used by `rollupCompletedFor()` above).

```sql
CREATE TABLE rollup_job_runs (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  job_name     TEXT        NOT NULL,
  -- 'invitation_daily' | 'tenant_daily' | 'reseller_daily' | 'platform_daily'
  target_date  DATE        NOT NULL,
  rows_processed INTEGER   NOT NULL DEFAULT 0,
  status       TEXT        NOT NULL DEFAULT 'completed'
                           CHECK (status IN ('completed', 'failed')),
  error_message TEXT,
  started_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at TIMESTAMPTZ,
  UNIQUE (job_name, target_date)
);

CREATE INDEX idx_rollup_runs_job_date ON rollup_job_runs(job_name, target_date DESC);
```

```typescript
// lib/analytics/rollup-ledger.ts

export async function alreadyRolledUp(admin: SupabaseClient, jobName: string, date: string): Promise<boolean> {
  const { data } = await admin
    .from('rollup_job_runs')
    .select('id').eq('job_name', jobName).eq('target_date', date).eq('status', 'completed')
    .maybeSingle();
  return !!data;
}

export async function rollupCompletedFor(admin: SupabaseClient, jobName: string, date: string): Promise<boolean> {
  return alreadyRolledUp(admin, jobName, date);
}

export async function recordRollupRun(admin: SupabaseClient, jobName: string, date: string, rowsProcessed: number): Promise<void> {
  await admin.from('rollup_job_runs').upsert({
    job_name: jobName, target_date: date, rows_processed: rowsProcessed,
    status: 'completed', completed_at: new Date().toISOString(),
  }, { onConflict: 'job_name,target_date' });
}
```

---

*End of PART 1 — continued in phase11_part2.md (Tenant/Invitation/Guest/RSVP/Reseller/Platform dashboards and Feature Integration)*
# PHASE11_ANALYTICS.md — PART 2 OF 3
# Wedding Invitation SaaS Platform — Analytics & Reporting Architecture

> Continuation of PART 1. Covers Sections 6–12.
> **Depends on:** PART 1 (architecture overview, data model, ingestion, rollup engine)

---

## 6. Tenant Analytics Dashboard

### 6.1 Dashboard Overview

The tenant dashboard (`/analytics`) is the cross-invitation view for an `owner`/`editor`. It answers "how is my account doing overall" rather than "how is this one invitation doing" (which is covered in §7). It is powered exclusively by `tenant_analytics_daily` (PART 1 §3.3) — never by fanning out across `invitation_analytics` at request time.

```
/analytics
├── Header stat cards: Active Invitations · Total Views (30d) · Total RSVPs · Guestbook Entries
├── Trend chart: views + RSVP attending, daily, selectable range (7d / 30d / 90d / custom)
├── Top Invitation widget (from tenant_analytics_daily.top_invitation_id)
├── Per-invitation comparison table (sortable: views, RSVP rate, guestbook count)
└── [Export Report] button (feature-gated: analytics_export)
```

### 6.2 Tenant Summary Query

```typescript
// lib/analytics/tenant-summary.ts

export async function getTenantAnalyticsSummary(
  supabase: SupabaseClient,
  tenantId: string,
  dateFrom: string,
  dateTo: string
): Promise<TenantAnalyticsSummary> {
  const { data: dayRows } = await supabase
    .from('tenant_analytics_daily')
    .select('*')
    .eq('tenant_id', tenantId)
    .gte('date', dateFrom)
    .lte('date', dateTo)
    .order('date', { ascending: true });

  const rows = dayRows ?? [];

  const totals = rows.reduce(
    (acc, r) => ({
      total_views:              acc.total_views + r.total_views,
      total_unique_visitors:      acc.total_unique_visitors + r.total_unique_visitors,
      total_rsvp_submitted:         acc.total_rsvp_submitted + r.total_rsvp_submitted,
      total_rsvp_attending:           acc.total_rsvp_attending + r.total_rsvp_attending,
      total_guestbook_entries:           acc.total_guestbook_entries + r.total_guestbook_entries,
      total_qr_checkins:                    acc.total_qr_checkins + r.total_qr_checkins,
    }),
    { total_views: 0, total_unique_visitors: 0, total_rsvp_submitted: 0, total_rsvp_attending: 0, total_guestbook_entries: 0, total_qr_checkins: 0 }
  );

  const latestActiveCount = rows.at(-1)?.active_invitations ?? 0;

  const topByViews = rows.reduce(
    (best, r) => (r.top_invitation_views > (best?.top_invitation_views ?? -1) ? r : best),
    null as typeof rows[number] | null
  );

  let topInvitation: TenantAnalyticsSummary['top_invitation'] = null;
  if (topByViews?.top_invitation_id) {
    const { data: inv } = await supabase
      .from('invitations').select('id, title').eq('id', topByViews.top_invitation_id).single();
    if (inv) topInvitation = { id: inv.id, title: inv.title, views: topByViews.top_invitation_views };
  }

  return {
    tenant_id: tenantId,
    date_from: dateFrom,
    date_to:   dateTo,
    active_invitations: latestActiveCount,
    ...totals,
    top_invitation: topInvitation,
    trend: rows.map(r => ({ date: r.date, total_views: r.total_views, total_rsvp_attending: r.total_rsvp_attending })),
  };
}
```

### 6.3 Per-Invitation Comparison Table

```typescript
// app/api/analytics/tenant/invitations/route.ts

export async function GET(request: Request) {
  const auth = await requireAuth(request, 'analytics:read');
  if (auth instanceof NextResponse) return auth;

  const resolution = await resolveFeature(
    { tenantId: auth.user.tenantId, packageId: auth.user.packageId },
    'analytics_basic'
  );
  if (!resolution.enabled) {
    return NextResponse.json({ error: 'Analytics requires a Basic plan or above.' }, { status: 403 });
  }

  const url = new URL(request.url);
  const dateFrom = url.searchParams.get('from') ?? defaultRangeStart(30);
  const dateTo   = url.searchParams.get('to')   ?? todayString();

  const supabase = createServerClient();

  // Aggregate per invitation across the date range from the existing PHASE2 table
  const { data } = await supabase
    .from('invitation_analytics')
    .select(`
      invitation_id,
      invitation:invitations(id, title, status, slug),
      views, rsvp_attending, rsvp_not_attending, rsvp_maybe, guestbook_count
    `)
    .eq('tenant_id', auth.user.tenantId)
    .gte('date', dateFrom)
    .lte('date', dateTo);

  const byInvitation = new Map<string, any>();
  for (const row of data ?? []) {
    const existing = byInvitation.get(row.invitation_id) ?? {
      invitation_id: row.invitation_id,
      title: (row.invitation as any)?.title,
      slug:  (row.invitation as any)?.slug,
      status: (row.invitation as any)?.status,
      views: 0, rsvp_attending: 0, rsvp_not_attending: 0, rsvp_maybe: 0, guestbook_count: 0,
    };
    existing.views               += row.views;
    existing.rsvp_attending        += row.rsvp_attending;
    existing.rsvp_not_attending     += row.rsvp_not_attending;
    existing.rsvp_maybe              += row.rsvp_maybe;
    existing.guestbook_count          += row.guestbook_count;
    byInvitation.set(row.invitation_id, existing);
  }

  const rows = [...byInvitation.values()].sort((a, b) => b.views - a.views);
  return NextResponse.json({ rows, date_from: dateFrom, date_to: dateTo });
}
```

### 6.4 Tenant Dashboard Component

```typescript
// components/analytics/TenantDashboard.tsx
'use client';

interface TenantDashboardProps {
  summary:          TenantAnalyticsSummary;
  invitationRows:   InvitationComparisonRow[];
  canExport:        boolean;
}

export function TenantDashboard({ summary, invitationRows, canExport }: TenantDashboardProps) {
  return (
    <div className="space-y-6">
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
        <StatCard label="Active Invitations" value={summary.active_invitations} />
        <StatCard label="Total Views"         value={summary.total_views.toLocaleString()} />
        <StatCard label="RSVP Attending"       value={summary.total_rsvp_attending.toLocaleString()} />
        <StatCard label="Guestbook Entries"     value={summary.total_guestbook_entries.toLocaleString()} />
      </div>

      <TrendChart
        title="Views & RSVPs Over Time"
        series={[
          { name: 'Views',          data: summary.trend.map(t => ({ x: t.date, y: t.total_views })) },
          { name: 'RSVP Attending', data: summary.trend.map(t => ({ x: t.date, y: t.total_rsvp_attending })) },
        ]}
      />

      {summary.top_invitation && (
        <TopInvitationCard
          title={summary.top_invitation.title}
          views={summary.top_invitation.views}
          href={`/invitations/${summary.top_invitation.id}/analytics`}
        />
      )}

      <InvitationComparisonTable rows={invitationRows} />

      {canExport ? (
        <ExportReportButton scope="tenant" scopeId={summary.tenant_id} dateFrom={summary.date_from} dateTo={summary.date_to} />
      ) : (
        <LockedButton label="Export Report" featureKey="analytics_export" requiredPlan="Premium" />
      )}
    </div>
  );
}
```

---

## 7. Invitation-Level Analytics

### 7.1 Dashboard Overview

```
/invitations/[id]/analytics
├── Header stat cards: Views · Unique Visitors · RSVP Rate · Check-In Rate
├── Trend chart: daily views (basic tier) + session duration / bounce rate (advanced tier, locked badge if not entitled)
├── Device split donut (mobile/desktop/tablet)
├── Top Referrers list (basic tier)
├── Traffic Source breakdown (advanced tier — personalized link vs WhatsApp vs Instagram vs direct)
├── Section Engagement bar chart (advanced tier — which sections guests actually viewed)
├── RSVP & Guestbook summary cards (always visible — these are core, not analytics-gated; reuses PHASE9 get_rsvp_summary())
└── [Export] (feature-gated: analytics_export)
```

### 7.2 Invitation Summary Query (Composing Basic + Advanced Tiers)

```typescript
// lib/analytics/invitation-summary.ts

export async function getInvitationAnalyticsSummary(
  supabase: SupabaseClient,
  invitationId: string,
  tenantId: string,
  packageId: string,
  dateFrom: string,
  dateTo: string
): Promise<InvitationAnalyticsSummary> {
  const features = await resolveAnalyticsFeatures(tenantId, packageId); // §12.1

  if (!features.analytics_basic) {
    throw new AnalyticsAccessError('analytics_basic feature not enabled for this package.');
  }

  const { data: trend } = await supabase
    .from('invitation_analytics')
    .select('*')
    .eq('invitation_id', invitationId)
    .gte('date', dateFrom)
    .lte('date', dateTo)
    .order('date', { ascending: true });

  const trendRows = trend ?? [];
  const totalViews  = trendRows.reduce((s, r) => s + r.views, 0);
  const totalUnique  = trendRows.reduce((s, r) => s + r.unique_visitors, 0);

  // RSVP summary reuses PHASE9's get_rsvp_summary() RPC directly — no reimplementation
  const { data: rsvpSummary } = await supabase.rpc('get_rsvp_summary', { p_invitation_id: invitationId });

  // Response rate reuses PHASE9's rsvp_response_rate view directly
  const { data: responseRate } = await supabase
    .from('rsvp_response_rate')
    .select('total_tracked, responded')
    .eq('invitation_id', invitationId)
    .maybeSingle();

  const respRatePct = responseRate?.total_tracked
    ? Math.round((responseRate.responded / responseRate.total_tracked) * 100)
    : 0;

  let checkinRate: number | null = null;
  if (features.qr_checkin) {
    const checkinStats = await getCheckinRate(supabase, invitationId);
    checkinRate = checkinStats;
  }

  let trendExtended: InvitationAnalyticsExtendedDaily[] | undefined;
  if (features.analytics_advanced) {
    const { data: ext } = await supabase
      .from('invitation_analytics_extended')
      .select('*')
      .eq('invitation_id', invitationId)
      .gte('date', dateFrom)
      .lte('date', dateTo)
      .order('date', { ascending: true });
    trendExtended = ext ?? [];
  }

  return {
    invitation_id: invitationId,
    total_views: totalViews,
    total_unique: totalUnique,
    rsvp_summary: rsvpSummary,
    response_rate: respRatePct,
    checkin_rate: checkinRate,
    trend: trendRows,
    trend_extended: trendExtended,
  };
}

async function getCheckinRate(supabase: SupabaseClient, invitationId: string): Promise<number> {
  // Reuses PHASE8 §10.2 guest_checkin_status view directly
  const { data } = await supabase
    .from('guest_checkin_status')
    .select('is_checked_in')
    .eq('invitation_id', invitationId);

  const rows = data ?? [];
  if (rows.length === 0) return 0;
  return Math.round((rows.filter(r => r.is_checked_in).length / rows.length) * 100);
}
```

### 7.3 API Route

```typescript
// app/api/invitations/[id]/analytics/route.ts

export async function GET(request: Request, { params }: { params: { id: string } }) {
  const auth = await requireAuth(request, 'analytics:read');
  if (auth instanceof NextResponse) return auth;

  const supabase = createServerClient();

  const { data: invitation } = await supabase
    .from('invitations')
    .select('id, tenant_id')
    .eq('id', params.id)
    .eq('tenant_id', auth.user.tenantId)
    .is('deleted_at', null)
    .single();

  if (!invitation) return NextResponse.json({ error: 'Not found' }, { status: 404 });

  const url = new URL(request.url);
  const dateFrom = url.searchParams.get('from') ?? defaultRangeStart(30);
  const dateTo   = url.searchParams.get('to')   ?? todayString();

  try {
    const summary = await getInvitationAnalyticsSummary(
      supabase, params.id, auth.user.tenantId, auth.user.packageId, dateFrom, dateTo
    );
    return NextResponse.json(summary);
  } catch (err) {
    if (err instanceof AnalyticsAccessError) {
      return NextResponse.json({ error: err.message, locked: true }, { status: 403 });
    }
    throw err;
  }
}
```

### 7.4 Section Engagement Visualization

```typescript
// components/analytics/SectionEngagementChart.tsx
'use client';

interface SectionEngagementChartProps {
  trendExtended: InvitationAnalyticsExtendedDaily[];
}

export function SectionEngagementChart({ trendExtended }: SectionEngagementChartProps) {
  // Aggregate section_views JSONB across the date range into a single bar chart
  const aggregated: Record<string, number> = {};
  for (const day of trendExtended) {
    for (const [section, count] of Object.entries(day.section_views)) {
      aggregated[section] = (aggregated[section] ?? 0) + count;
    }
  }

  const sorted = Object.entries(aggregated).sort((a, b) => b[1] - a[1]);

  return (
    <div className="rounded-xl border border-gray-200 p-4">
      <h3 className="mb-3 text-sm font-semibold text-gray-700">Section Engagement</h3>
      <div className="space-y-2">
        {sorted.map(([section, count]) => (
          <div key={section} className="flex items-center gap-3">
            <span className="w-28 shrink-0 text-xs capitalize text-gray-500">{section.replace('_', ' ')}</span>
            <div className="h-2 flex-1 rounded-full bg-gray-100">
              <div
                className="h-2 rounded-full bg-purple-500"
                style={{ width: `${(count / sorted[0][1]) * 100}%` }}
              />
            </div>
            <span className="w-10 shrink-0 text-right text-xs font-medium text-gray-700">{count}</span>
          </div>
        ))}
      </div>
    </div>
  );
}
```

---

## 8. Guest Engagement Analytics

### 8.1 Formalizing PHASE8's Prepared Hooks

PHASE8 §10.3 and §15.6 explicitly deferred guest-level engagement analytics to "the analytics phase." This section delivers that implementation, consuming `invitation_events.guest_id` (populated since the personalized-link resolution flow defined in PHASE8 §7.3 and PHASE9 §11.1).

```sql
-- supabase/migrations/111_guest_engagement_view.sql
-- Materializes the prepared query pattern from PHASE8 §10.3 as a reusable view

CREATE OR REPLACE VIEW guest_engagement_summary AS
SELECT
  g.id                                                       AS guest_id,
  g.invitation_id,
  g.tenant_id,
  g.name,
  g.group_id,
  g.category_id,
  COUNT(e.id) FILTER (WHERE e.event_type = 'page_view')      AS views,
  COUNT(e.id) FILTER (WHERE e.event_type = 'rsvp_open')      AS rsvp_opens,
  COUNT(e.id) FILTER (WHERE e.event_type = 'guestbook_submit') AS guestbook_submissions,
  COUNT(e.id) FILTER (WHERE e.event_type = 'share_click'
                        OR e.event_type = 'whatsapp_share_click') AS share_clicks,
  MAX(e.created_at)                                            AS last_seen_at,
  MIN(e.created_at)                                              AS first_seen_at
FROM guests g
LEFT JOIN invitation_events e ON e.guest_id = g.id
WHERE g.deleted_at IS NULL
GROUP BY g.id, g.invitation_id, g.tenant_id, g.name, g.group_id, g.category_id;
```

### 8.2 Guest Engagement API

```typescript
// app/api/invitations/[id]/guests/[guestId]/engagement/route.ts

export async function GET(
  request: Request,
  { params }: { params: { id: string; guestId: string } }
) {
  const auth = await requireAuth(request, 'analytics:read');
  if (auth instanceof NextResponse) return auth;

  const resolution = await resolveFeature(
    { tenantId: auth.user.tenantId, packageId: auth.user.packageId }, 'analytics_advanced'
  );
  if (!resolution.enabled) {
    return NextResponse.json({ error: 'Guest engagement detail requires Premium plan or above.' }, { status: 403 });
  }

  const supabase = createServerClient();

  const { data } = await supabase
    .from('guest_engagement_summary')
    .select('*')
    .eq('guest_id', params.guestId)
    .eq('invitation_id', params.id)
    .eq('tenant_id', auth.user.tenantId)
    .single();

  if (!data) return NextResponse.json({ error: 'Not found' }, { status: 404 });

  // Compose with RSVP and check-in status (joins PHASE8/PHASE9 views)
  const [{ data: rsvpStatus }, { data: checkinStatus }] = await Promise.all([
    supabase.from('guest_rsvp_status').select('*').eq('guest_id', params.guestId).maybeSingle(),
    supabase.from('guest_checkin_status').select('*').eq('guest_id', params.guestId).maybeSingle(),
  ]);

  return NextResponse.json({ engagement: data, rsvp: rsvpStatus, checkin: checkinStatus });
}
```

### 8.3 Invitation-Wide Guest Engagement List

```typescript
// app/api/invitations/[id]/guests/engagement-summary/route.ts
// Powers a sortable "most/least engaged guests" table in the dashboard

export async function GET(request: Request, { params }: { params: { id: string } }) {
  const auth = await requireAuth(request, 'analytics:read');
  if (auth instanceof NextResponse) return auth;

  const resolution = await resolveFeature(
    { tenantId: auth.user.tenantId, packageId: auth.user.packageId }, 'analytics_advanced'
  );
  if (!resolution.enabled) {
    return NextResponse.json({ error: 'Requires Premium plan or above.' }, { status: 403 });
  }

  const supabase = createServerClient();
  const url = new URL(request.url);
  const sortBy = url.searchParams.get('sort') ?? 'views';
  const filter = url.searchParams.get('filter'); // 'never_opened' | 'engaged' | null

  let query = supabase
    .from('guest_engagement_summary')
    .select('*')
    .eq('invitation_id', params.id)
    .eq('tenant_id', auth.user.tenantId);

  if (filter === 'never_opened') query = query.eq('views', 0);
  if (filter === 'engaged')      query = query.gt('views', 0);

  query = query.order(sortBy as any, { ascending: false }).limit(500);

  const { data, error } = await query;
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  return NextResponse.json({ guests: data ?? [] });
}
```

### 8.4 Check-In Rate Detail Widget

```typescript
// lib/analytics/checkin-detail.ts
// Composes PHASE2 qr_checkins + PHASE8 guest_checkin_status for a full check-in breakdown

export interface CheckinDetail {
  total_guests:         number;
  rsvp_attending:       number;
  checked_in:           number;
  checked_in_pct_of_rsvp: number;
  no_show_count:         number; // rsvp_attending but not checked in
  walk_in_count:           number; // checked in but no rsvp / not_attending rsvp
}

export async function getCheckinDetail(
  supabase: SupabaseClient,
  invitationId: string
): Promise<CheckinDetail> {
  const { data: rows } = await supabase
    .from('guest_rsvp_status')
    .select(`
      guest_id, derived_status,
      checkin:guest_checkin_status(is_checked_in)
    `)
    .eq('invitation_id', invitationId);

  const all = rows ?? [];
  const attending = all.filter(r => r.derived_status === 'attending');
  const checkedIn = all.filter(r => (r.checkin as any)?.is_checked_in);
  const noShow    = attending.filter(r => !(r.checkin as any)?.is_checked_in);
  const walkIns   = checkedIn.filter(r => r.derived_status !== 'attending');

  return {
    total_guests: all.length,
    rsvp_attending: attending.length,
    checked_in: checkedIn.length,
    checked_in_pct_of_rsvp: attending.length ? Math.round((checkedIn.length / attending.length) * 100) : 0,
    no_show_count: noShow.length,
    walk_in_count: walkIns.length,
  };
}
```

---

## 9. RSVP & Guestbook Analytics Integration

### 9.1 Promoting PHASE9's Prepared Views to Dashboard Surfaces

PHASE9 §9.2 created `rsvp_daily_trend`, `rsvp_by_category`, and `rsvp_response_rate` explicitly as "prepared SQL views" for this phase. PHASE11 wires them directly into the dashboard — no logic duplication.

```typescript
// app/api/invitations/[id]/analytics/rsvp/route.ts

export async function GET(request: Request, { params }: { params: { id: string } }) {
  const auth = await requireAuth(request, 'analytics:read');
  if (auth instanceof NextResponse) return auth;

  const supabase = createServerClient();

  const [{ data: trend }, { data: byCategory }, { data: responseRate }, { data: byGroup }] = await Promise.all([
    supabase.from('rsvp_daily_trend').select('*').eq('invitation_id', params.id).order('date'),
    supabase.from('rsvp_by_category').select('*').eq('invitation_id', params.id),
    supabase.from('rsvp_response_rate').select('*').eq('invitation_id', params.id).maybeSingle(),
    getRsvpByGroup(supabase, params.id), // §9.2 — group breakdown, new in this phase
  ]);

  return NextResponse.json({
    trend: trend ?? [],
    by_category: byCategory ?? [],
    by_group: byGroup,
    response_rate: responseRate,
  });
}
```

### 9.2 New View: `rsvp_by_group` (Mirroring `rsvp_by_category`)

PHASE9 built `rsvp_by_category` but not the group-level equivalent referenced in PHASE8's `AttendanceByGroup` interface (PHASE8 §10.4) — this was a prepared type with no backing query. PHASE11 completes it:

```sql
-- supabase/migrations/112_rsvp_by_group_view.sql

CREATE OR REPLACE VIEW rsvp_by_group AS
SELECT
  r.invitation_id,
  gg.id                                                        AS group_id,
  gg.name                                                       AS group_name,
  gg.color,
  COUNT(r.id) FILTER (WHERE r.attendance = 'attending')        AS attending,
  COUNT(r.id) FILTER (WHERE r.attendance = 'not_attending')     AS not_attending,
  COUNT(r.id) FILTER (WHERE r.attendance = 'maybe')              AS maybe,
  COALESCE(SUM(r.pax_count) FILTER (WHERE r.attendance = 'attending'), 0) AS total_pax
FROM rsvp_responses r
JOIN guests g ON g.id = r.guest_id
JOIN guest_groups gg ON gg.id = g.group_id
WHERE r.is_spam = FALSE
  AND r.guest_id IS NOT NULL
GROUP BY r.invitation_id, gg.id, gg.name, gg.color;
```

```typescript
// lib/analytics/rsvp-by-group.ts

export async function getRsvpByGroup(
  supabase: SupabaseClient,
  invitationId: string
): Promise<AttendanceByGroup[]> {
  const { data } = await supabase.from('rsvp_by_group').select('*').eq('invitation_id', invitationId);
  return (data ?? []).map(r => ({
    group_id: r.group_id, group_name: r.group_name,
    attending: r.attending, declining: r.not_attending, pending: 0, // pending computed client-side from guest_groups total - responded
    total_pax: r.total_pax,
  }));
}
```

### 9.3 Meal Choice Breakdown (Completing PHASE9's `MealChoiceBreakdown` Interface)

```typescript
// lib/analytics/meal-breakdown.ts

export async function getMealChoiceBreakdown(
  supabase: SupabaseClient,
  invitationId: string
): Promise<MealChoiceBreakdown[]> {
  const { data } = await supabase
    .from('rsvp_responses')
    .select('meal_choice')
    .eq('invitation_id', invitationId)
    .eq('is_spam', false)
    .eq('attendance', 'attending')
    .not('meal_choice', 'is', null);

  const rows = data ?? [];
  const total = rows.length;
  const counts = new Map<string, number>();
  for (const r of rows) counts.set(r.meal_choice!, (counts.get(r.meal_choice!) ?? 0) + 1);

  return [...counts.entries()]
    .map(([meal_choice, count]) => ({ meal_choice, count, percentage: total ? Math.round((count / total) * 100) : 0 }))
    .sort((a, b) => b.count - a.count);
}
```

### 9.4 Guestbook Engagement Metrics

```typescript
// lib/analytics/guestbook-metrics.ts

export interface GuestbookMetrics {
  total_entries:        number;
  approved:             number;
  pending:              number;
  rejected:             number;
  verified_guest_ratio: number; // % of approved entries where guest_id IS NOT NULL
  daily_trend:          Array<{ date: string; count: number }>;
}

export async function getGuestbookMetrics(
  supabase: SupabaseClient,
  invitationId: string,
  dateFrom: string,
  dateTo: string
): Promise<GuestbookMetrics> {
  const { data } = await supabase
    .from('guestbook_entries')
    .select('moderation_status, guest_id, submitted_at')
    .eq('invitation_id', invitationId)
    .eq('is_spam', false)
    .gte('submitted_at', dateFrom)
    .lte('submitted_at', dateTo);

  const rows = data ?? [];
  const approved = rows.filter(r => r.moderation_status === 'approved');
  const verifiedCount = approved.filter(r => r.guest_id !== null).length;

  const byDate = new Map<string, number>();
  for (const r of rows) {
    const day = r.submitted_at.slice(0, 10);
    byDate.set(day, (byDate.get(day) ?? 0) + 1);
  }

  return {
    total_entries: rows.length,
    approved: approved.length,
    pending: rows.filter(r => r.moderation_status === 'pending').length,
    rejected: rows.filter(r => r.moderation_status === 'rejected').length,
    verified_guest_ratio: approved.length ? Math.round((verifiedCount / approved.length) * 100) : 0,
    daily_trend: [...byDate.entries()].sort().map(([date, count]) => ({ date, count })),
  };
}
```

---

## 10. Reseller Analytics

### 10.1 Dashboard Overview

```
/reseller/analytics
├── Header stat cards: Active Clients · Total Client Invitations · Total Client Views · Commission Accrued (30d)
├── Trend chart: client growth + commission accrual
├── Client comparison table (per-tenant rollup, sortable by engagement)
└── [Export Portfolio Report] (always available to reseller_admin — not package-gated;
     reseller analytics access is a role-based capability, not a tenant package entitlement)
```

**Design note:** Reseller analytics access is gated by `auth_role() = 'reseller_admin'`, not by any tenant's package features — a reseller's own dashboard capability is independent of what plan their individual clients are on. This matches PHASE5 §10.1's permission matrix, where reseller actions are role-gated, and PHASE2 §6.3's `reseller_read_clients` RLS pattern.

### 10.2 Reseller Summary Query

```typescript
// app/api/reseller/analytics/route.ts

export async function GET(request: Request) {
  const auth = await requireAuth(request, 'reseller:analytics:read');
  if (auth instanceof NextResponse) return auth;
  if (!auth.user.resellerId) return NextResponse.json({ error: 'Forbidden' }, { status: 403 });

  const supabase = createServerClient();
  const url = new URL(request.url);
  const dateFrom = url.searchParams.get('from') ?? defaultRangeStart(30);
  const dateTo   = url.searchParams.get('to')   ?? todayString();

  const { data: dayRows } = await supabase
    .from('reseller_analytics_daily')
    .select('*')
    .eq('reseller_id', auth.user.resellerId)
    .gte('date', dateFrom)
    .lte('date', dateTo)
    .order('date', { ascending: true });

  const rows = dayRows ?? [];
  const latest = rows.at(-1);

  const summary: ResellerAnalyticsSummary = {
    reseller_id: auth.user.resellerId,
    active_client_tenants: latest?.active_client_tenants ?? 0,
    total_client_invitations: latest?.total_client_invitations ?? 0,
    total_client_views: rows.reduce((s, r) => s + r.total_client_views, 0),
    total_client_rsvp: rows.reduce((s, r) => s + r.total_client_rsvp, 0),
    new_client_signups_30d: rows.reduce((s, r) => s + r.new_client_signups, 0),
    commission_accrued_30d: rows.reduce((s, r) => s + Number(r.commission_accrued), 0),
    trend: rows.map(r => ({
      date: r.date, active_client_tenants: r.active_client_tenants,
      total_client_views: r.total_client_views, commission_accrued: Number(r.commission_accrued),
    })),
  };

  return NextResponse.json(summary);
}
```

### 10.3 Client Comparison Table

```typescript
// app/api/reseller/analytics/clients/route.ts

export async function GET(request: Request) {
  const auth = await requireAuth(request, 'reseller:analytics:read');
  if (auth instanceof NextResponse) return auth;
  if (!auth.user.resellerId) return NextResponse.json({ error: 'Forbidden' }, { status: 403 });

  const supabase = createServerClient();

  const { data: clientTenants } = await supabase
    .from('reseller_tenants')
    .select('tenant_id, tenant:tenants(id, name)')
    .eq('reseller_id', auth.user.resellerId);

  const tenantIds = (clientTenants ?? []).map(c => c.tenant_id);
  if (tenantIds.length === 0) return NextResponse.json({ clients: [] });

  const thirtyDaysAgo = defaultRangeStart(30);
  const { data: rollups } = await supabase
    .from('tenant_analytics_daily')
    .select('tenant_id, total_views, total_rsvp_attending, active_invitations')
    .in('tenant_id', tenantIds)
    .gte('date', thirtyDaysAgo);

  const byTenant = groupBy(rollups ?? [], r => r.tenant_id);

  const clients = (clientTenants ?? []).map(c => {
    const rows = byTenant[c.tenant_id] ?? [];
    return {
      tenant_id: c.tenant_id,
      tenant_name: (c.tenant as any)?.name,
      total_views_30d: rows.reduce((s, r) => s + r.total_views, 0),
      total_rsvp_30d: rows.reduce((s, r) => s + r.total_rsvp_attending, 0),
      active_invitations: rows.at(-1)?.active_invitations ?? 0,
    };
  }).sort((a, b) => b.total_views_30d - a.total_views_30d);

  return NextResponse.json({ clients });
}
```

---

## 11. Platform (Super Admin) Analytics

### 11.1 Dashboard Overview

```
/admin/analytics
├── Growth section: New Tenants · Active Tenants · New Invitations · Published Invitations (trend charts)
├── Engagement section: Total Views · Total RSVPs · Total Guestbook Entries (platform-wide)
├── Revenue section: Gross/Net Revenue · Paid Orders · Commission Payout Liability
│    (composes get_platform_billing_summary() from PHASE10 §14.3 directly)
├── Package Distribution donut chart (from platform_analytics_daily.package_distribution)
└── [Export Platform Report] — super_admin only, always available (no feature gate; platform
     reporting is an operational admin capability, not a monetized tenant feature)
```

### 11.2 Platform Summary Query

```typescript
// app/api/admin/analytics/route.ts

export async function GET(request: Request) {
  const auth = await requireAuth(request);
  if (auth instanceof NextResponse) return auth;
  if (auth.user.role !== 'super_admin') return NextResponse.json({ error: 'Forbidden' }, { status: 403 });

  const admin = createAdminClient();
  const url = new URL(request.url);
  const dateFrom = url.searchParams.get('from') ?? defaultRangeStart(30);
  const dateTo   = url.searchParams.get('to')   ?? todayString();

  const { data: dayRows } = await admin
    .from('platform_analytics_daily')
    .select('*')
    .gte('date', dateFrom)
    .lte('date', dateTo)
    .order('date', { ascending: true });

  const rows = dayRows ?? [];
  const latest = rows.at(-1);

  const summary: PlatformAnalyticsSummary = {
    date_from: dateFrom,
    date_to: dateTo,
    new_tenants: rows.reduce((s, r) => s + r.new_tenants, 0),
    active_tenants: latest?.active_tenants ?? 0,
    new_invitations: rows.reduce((s, r) => s + r.new_invitations, 0),
    published_invitations: rows.reduce((s, r) => s + r.published_invitations, 0),
    total_views: rows.reduce((s, r) => s + r.total_views, 0),
    total_rsvp_submitted: rows.reduce((s, r) => s + r.total_rsvp_submitted, 0),
    gross_revenue: rows.reduce((s, r) => s + Number(r.gross_revenue), 0),
    net_revenue: rows.reduce((s, r) => s + Number(r.net_revenue), 0),
    paid_order_count: rows.reduce((s, r) => s + r.paid_order_count, 0),
    package_distribution: latest?.package_distribution ?? {},
    trend: rows.map(r => ({
      date: r.date, new_tenants: r.new_tenants, total_views: r.total_views, net_revenue: Number(r.net_revenue),
    })),
  };

  return NextResponse.json(summary);
}
```

### 11.3 Cohort Retention Query (New Capability)

A genuinely new platform-level metric not prepared in any prior phase: tenant retention by signup cohort, needed for SaaS health monitoring (churn analysis).

```sql
-- supabase/migrations/113_tenant_cohort_retention_fn.sql

CREATE OR REPLACE FUNCTION get_tenant_cohort_retention(p_cohort_month TEXT)
RETURNS JSONB AS $$
DECLARE
  v_result JSONB;
BEGIN
  WITH cohort AS (
    SELECT id, created_at
    FROM tenants
    WHERE TO_CHAR(created_at, 'YYYY-MM') = p_cohort_month
  ),
  monthly_activity AS (
    SELECT
      c.id AS tenant_id,
      TO_CHAR(ts.current_period_start, 'YYYY-MM') AS active_month
    FROM cohort c
    JOIN tenant_subscriptions ts ON ts.tenant_id = c.id
    WHERE ts.status IN ('active', 'trialing', 'past_due')
  )
  SELECT jsonb_object_agg(active_month, tenant_count)
  INTO v_result
  FROM (
    SELECT active_month, COUNT(DISTINCT tenant_id) AS tenant_count
    FROM monthly_activity
    GROUP BY active_month
    ORDER BY active_month
  ) sub;

  RETURN COALESCE(v_result, '{}'::JSONB);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;
```

```typescript
// app/api/admin/analytics/cohort-retention/route.ts

export async function GET(request: Request) {
  const auth = await requireAuth(request);
  if (auth instanceof NextResponse) return auth;
  if (auth.user.role !== 'super_admin') return NextResponse.json({ error: 'Forbidden' }, { status: 403 });

  const url = new URL(request.url);
  const cohortMonth = url.searchParams.get('cohort') ?? new Date().toISOString().slice(0, 7);

  const admin = createAdminClient();
  const { data } = await admin.rpc('get_tenant_cohort_retention', { p_cohort_month: cohortMonth });

  return NextResponse.json({ cohort: cohortMonth, retention: data });
}
```

---

## 12. Package Feature Integration (Analytics Tiers)

### 12.1 Resolving the Full Analytics Feature Set

Extends PHASE9 §8.1's `resolveRsvpFeatures()` pattern with an analytics-specific resolver. Every metric surfaced anywhere in this phase passes through this function before being shown — there is no direct, ungated read of analytics tables from any client-facing route.

```typescript
// lib/analytics/feature-resolver.ts

export interface AnalyticsFeatureSet {
  analytics_basic:     boolean;
  analytics_advanced:  boolean;
  analytics_export:    boolean;
  retention_days:       number;  // from analytics_advanced.config, PHASE5 §11.2 seed
  qr_checkin:           boolean; // needed to decide whether check-in rate widget renders
}

export async function resolveAnalyticsFeatures(
  tenantId: string,
  packageId: string
): Promise<AnalyticsFeatureSet> {
  const [basic, advanced, exportFeature, qrCheckin] = await Promise.all([
    resolveFeature({ tenantId, packageId }, 'analytics_basic'),
    resolveFeature({ tenantId, packageId }, 'analytics_advanced'),
    resolveFeature({ tenantId, packageId }, 'analytics_export'),
    resolveFeature({ tenantId, packageId }, 'qr_checkin'),
  ]);

  return {
    analytics_basic:    basic.enabled,
    analytics_advanced: advanced.enabled,
    analytics_export:   exportFeature.enabled,
    retention_days:      (advanced.config as any)?.retention_days ?? 30,
    qr_checkin:           qrCheckin.enabled,
  };
}

export class AnalyticsAccessError extends Error {}
```

### 12.2 Feature Matrix Reference (No New Feature Keys Beyond PHASE5)

| Capability in this phase | Backing feature key | Already seeded in PHASE5? |
|---|---|---|
| Basic views/RSVP/device trend | `analytics_basic` | Yes (§11.2) |
| Section engagement, traffic source, session duration, bounce rate, guest-level engagement | `analytics_advanced` | Yes (§11.2) |
| CSV/PDF export | `analytics_export` | Yes (§11.2) |
| Check-in rate widget | `qr_checkin` | Yes (§11.2) |
| Reseller portfolio dashboard | role: `reseller_admin` | N/A — role-based, not feature-based |
| Platform dashboard | role: `super_admin` | N/A — role-based, not feature-based |
| Cohort retention | role: `super_admin` | N/A — role-based, not feature-based |

This phase introduces **zero new entries to the `FEATURE_KEYS` registry** (PHASE5 §2.2). Every tenant-facing capability maps onto a feature key that was already defined and seeded across the Free/Basic/Premium/Ultimate matrix in PHASE5 Appendix B. This is a deliberate constraint to avoid feature-key sprawl and to keep the package pricing page (PHASE5 §11.1) accurate without requiring a pricing-page content update alongside this phase's ship.

### 12.3 UI Lock State Pattern (Reused from PHASE7/PHASE9)

```typescript
// components/analytics/AnalyticsGate.tsx
'use client';

interface AnalyticsGateProps {
  enabled:        boolean;
  requiredPlan:   string;
  featureKey:     string;
  children:       React.ReactNode;
}

export function AnalyticsGate({ enabled, requiredPlan, featureKey, children }: AnalyticsGateProps) {
  if (enabled) return <>{children}</>;
  return (
    <div className="relative">
      <div className="pointer-events-none select-none opacity-30 blur-sm">{children}</div>
      <div className="absolute inset-0 flex items-center justify-center">
        <div className="rounded-xl bg-white/95 px-6 py-4 text-center shadow-lg">
          <LockClosedIcon className="mx-auto mb-2 h-6 w-6 text-gray-400" />
          <p className="text-sm font-medium text-gray-700">Available on {requiredPlan}+</p>
          <Link href="/subscription" className="mt-1 text-xs font-medium text-purple-600 hover:underline">
            Upgrade to unlock
          </Link>
        </div>
      </div>
    </div>
  );
}
```

---

*End of PART 2 — continued in phase11_part3.md (Export System, Real-Time Analytics, Permissions, Security, Performance, Scalability, Retention, Appendices)*
# PHASE11_ANALYTICS.md — PART 3 OF 3
# Wedding Invitation SaaS Platform — Analytics & Reporting Architecture

> Continuation of PART 1 and PART 2. Covers Sections 13–20 (final).
> **Depends on:** PART 1 (architecture, data model, ingestion, rollup engine), PART 2 (dashboards, feature integration)

---

## 13. Export System

### 13.1 Export Architecture

Exports follow the same sync/async split established in PHASE8 §13.4 (guest import) and PHASE9's CSV export pattern: small ranges render inline, large ranges or PDF generation are queued through `analytics_export_jobs` (PART 1 §3.6) and delivered via signed URL — never a blocking serverless request.

```
User clicks "Export Report" on tenant/invitation/reseller dashboard
  │
  ▼
POST /api/analytics/export
  - Feature gate: analytics_export
  - Estimate row count for the requested date range + scope
  │
  ├─ Estimated rows ≤ 1,000 AND format = 'csv'
  │     → Generate synchronously, return CSV body directly (Content-Disposition: attachment)
  │
  └─ Estimated rows > 1,000 OR format IN ('pdf','xlsx')
        → Insert analytics_export_jobs row (status='pending')
        → Invoke Edge Function generate-analytics-export (async)
        → Return { job_id, status: 'processing' }
        → Client polls GET /api/analytics/export/[jobId] until status='completed'
        → Signed URL returned, valid 1 hour (matches PHASE10 §6.2 invoice PDF pattern)
```

### 13.2 Export Request API

```typescript
// app/api/analytics/export/route.ts

import { z } from 'zod';
import { requireAuth } from '@/lib/auth/api-guard';
import { resolveAnalyticsFeatures } from '@/lib/analytics/feature-resolver';
import { createServerClient } from '@/lib/supabase/server';

const ExportRequestSchema = z.object({
  scope:         z.enum(['invitation', 'tenant', 'reseller']),
  scope_id:      z.string().uuid(),
  export_format: z.enum(['csv', 'pdf', 'xlsx']).default('csv'),
  date_from:     z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  date_to:       z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
});

const SYNC_ROW_THRESHOLD = 1000;

export async function POST(request: Request) {
  const auth = await requireAuth(request, 'analytics:read');
  if (auth instanceof NextResponse) return auth;

  const parsed = ExportRequestSchema.safeParse(await request.json());
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.flatten() }, { status: 422 });
  }

  const { scope, scope_id, export_format, date_from, date_to } = parsed.data;

  // Feature gate (reseller/platform scope bypass tenant feature-gating; see §13.6)
  if (scope !== 'reseller') {
    const features = await resolveAnalyticsFeatures(auth.user.tenantId, auth.user.packageId);
    if (!features.analytics_export) {
      return NextResponse.json({ error: 'Export requires a Premium plan or above.' }, { status: 403 });
    }
  } else if (!auth.user.resellerId) {
    return NextResponse.json({ error: 'Forbidden' }, { status: 403 });
  }

  // Ownership validation — scope_id must belong to the requesting principal
  const ownershipValid = await validateExportScopeOwnership(auth.user, scope, scope_id);
  if (!ownershipValid) {
    return NextResponse.json({ error: 'Not found or access denied.' }, { status: 404 });
  }

  const supabase = createServerClient();
  const estimatedRows = await estimateExportRowCount(supabase, scope, scope_id, date_from, date_to);

  if (estimatedRows <= SYNC_ROW_THRESHOLD && export_format === 'csv') {
    const csv = await generateAnalyticsCsv(supabase, scope, scope_id, date_from, date_to);
    return new Response(csv, {
      headers: {
        'Content-Type': 'text/csv; charset=utf-8',
        'Content-Disposition': `attachment; filename="analytics-${scope}-${date_from}_${date_to}.csv"`,
      },
    });
  }

  const { data: job, error } = await supabase
    .from('analytics_export_jobs')
    .insert({
      tenant_id:    auth.user.tenantId,
      requested_by: auth.user.id,
      scope, scope_id, export_format,
      date_from, date_to,
      status: 'pending',
    })
    .select('id')
    .single();

  if (error || !job) return NextResponse.json({ error: 'Failed to queue export.' }, { status: 500 });

  await supabase.functions.invoke('generate-analytics-export', { body: { job_id: job.id } });

  return NextResponse.json({ job_id: job.id, status: 'processing' }, { status: 202 });
}

async function validateExportScopeOwnership(
  user: AuthUser, scope: 'invitation' | 'tenant' | 'reseller', scopeId: string
): Promise<boolean> {
  const supabase = createServerClient();
  switch (scope) {
    case 'invitation': {
      const { data } = await supabase.from('invitations').select('id')
        .eq('id', scopeId).eq('tenant_id', user.tenantId).is('deleted_at', null).maybeSingle();
      return !!data;
    }
    case 'tenant':
      return scopeId === user.tenantId;
    case 'reseller':
      return scopeId === user.resellerId;
  }
}
```

### 13.3 Export Job Status Polling

```typescript
// app/api/analytics/export/[jobId]/route.ts

export async function GET(request: Request, { params }: { params: { jobId: string } }) {
  const auth = await requireAuth(request, 'analytics:read');
  if (auth instanceof NextResponse) return auth;

  const supabase = createServerClient();
  const { data: job } = await supabase
    .from('analytics_export_jobs')
    .select('*')
    .eq('id', params.jobId)
    .eq('tenant_id', auth.user.tenantId)
    .single();

  if (!job) return NextResponse.json({ error: 'Not found' }, { status: 404 });

  if (job.status !== 'completed') {
    return NextResponse.json({ status: job.status, error_message: job.error_message ?? null });
  }

  const { data: signed } = await supabase.storage
    .from('analytics-exports')
    .createSignedUrl(job.file_path!, 3600);

  return NextResponse.json({ status: 'completed', download_url: signed?.signedUrl ?? null });
}
```

### 13.4 Async Export Generation Edge Function

```typescript
// supabase/functions/generate-analytics-export/index.ts

Deno.serve(async (req) => {
  const { job_id } = await req.json();
  const admin = createAdminClient();

  const { data: job } = await admin.from('analytics_export_jobs').select('*').eq('id', job_id).single();
  if (!job) return new Response('Job not found', { status: 404 });

  await admin.from('analytics_export_jobs').update({ status: 'processing' }).eq('id', job_id);

  try {
    let fileBuffer: Uint8Array;
    let extension: string;

    if (job.export_format === 'csv') {
      const csv = await generateAnalyticsCsv(admin, job.scope, job.scope_id, job.date_from, job.date_to);
      fileBuffer = new TextEncoder().encode(csv);
      extension = 'csv';
    } else if (job.export_format === 'xlsx') {
      fileBuffer = await generateAnalyticsXlsx(admin, job.scope, job.scope_id, job.date_from, job.date_to);
      extension = 'xlsx';
    } else {
      fileBuffer = await generateAnalyticsPdf(admin, job.scope, job.scope_id, job.date_from, job.date_to);
      extension = 'pdf';
    }

    const filePath = `${job.tenant_id}/${job.id}.${extension}`;
    await admin.storage.from('analytics-exports').upload(filePath, fileBuffer, {
      contentType: contentTypeFor(extension),
      upsert: true,
    });

    await admin.from('analytics_export_jobs').update({
      status: 'completed', file_path: filePath, completed_at: new Date().toISOString(),
    }).eq('id', job_id);
  } catch (err) {
    await admin.from('analytics_export_jobs').update({
      status: 'failed', error_message: err instanceof Error ? err.message : String(err),
    }).eq('id', job_id);
  }

  return new Response(JSON.stringify({ status: 'done' }));
});

function contentTypeFor(ext: string): string {
  return ext === 'csv' ? 'text/csv'
    : ext === 'xlsx' ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
    : 'application/pdf';
}
```

### 13.5 CSV Generation by Scope

```typescript
// lib/analytics/export-csv.ts

export async function generateAnalyticsCsv(
  supabase: SupabaseClient,
  scope: 'invitation' | 'tenant' | 'reseller',
  scopeId: string,
  dateFrom: string,
  dateTo: string
): Promise<string> {
  switch (scope) {
    case 'invitation': return exportInvitationCsv(supabase, scopeId, dateFrom, dateTo);
    case 'tenant':      return exportTenantCsv(supabase, scopeId, dateFrom, dateTo);
    case 'reseller':    return exportResellerCsv(supabase, scopeId, dateFrom, dateTo);
  }
}

async function exportInvitationCsv(
  supabase: SupabaseClient, invitationId: string, dateFrom: string, dateTo: string
): Promise<string> {
  const { data } = await supabase
    .from('invitation_analytics')
    .select('date, views, unique_visitors, rsvp_attending, rsvp_not_attending, rsvp_maybe, guestbook_count, device_mobile, device_desktop, device_tablet')
    .eq('invitation_id', invitationId)
    .gte('date', dateFrom).lte('date', dateTo)
    .order('date');

  const headers = ['Date', 'Views', 'Unique Visitors', 'RSVP Attending', 'RSVP Not Attending', 'RSVP Maybe', 'Guestbook Entries', 'Mobile', 'Desktop', 'Tablet'];
  const rows = (data ?? []).map(r => [
    r.date, r.views, r.unique_visitors, r.rsvp_attending, r.rsvp_not_attending, r.rsvp_maybe, r.guestbook_count, r.device_mobile, r.device_desktop, r.device_tablet,
  ]);

  return toCsv(headers, rows);
}

async function exportTenantCsv(
  supabase: SupabaseClient, tenantId: string, dateFrom: string, dateTo: string
): Promise<string> {
  const { data } = await supabase
    .from('tenant_analytics_daily')
    .select('date, active_invitations, total_views, total_unique_visitors, total_rsvp_attending, total_guestbook_entries, total_qr_checkins')
    .eq('tenant_id', tenantId)
    .gte('date', dateFrom).lte('date', dateTo)
    .order('date');

  const headers = ['Date', 'Active Invitations', 'Total Views', 'Unique Visitors', 'RSVP Attending', 'Guestbook Entries', 'QR Check-Ins'];
  const rows = (data ?? []).map(r => [
    r.date, r.active_invitations, r.total_views, r.total_unique_visitors, r.total_rsvp_attending, r.total_guestbook_entries, r.total_qr_checkins,
  ]);

  return toCsv(headers, rows);
}

async function exportResellerCsv(
  supabase: SupabaseClient, resellerId: string, dateFrom: string, dateTo: string
): Promise<string> {
  const { data } = await supabase
    .from('reseller_analytics_daily')
    .select('date, active_client_tenants, total_client_invitations, total_client_views, total_client_rsvp, new_client_signups, commission_accrued')
    .eq('reseller_id', resellerId)
    .gte('date', dateFrom).lte('date', dateTo)
    .order('date');

  const headers = ['Date', 'Active Clients', 'Total Invitations', 'Total Views', 'Total RSVP', 'New Signups', 'Commission Accrued'];
  const rows = (data ?? []).map(r => [
    r.date, r.active_client_tenants, r.total_client_invitations, r.total_client_views, r.total_client_rsvp, r.new_client_signups, r.commission_accrued,
  ]);

  return toCsv(headers, rows);
}

function toCsv(headers: string[], rows: unknown[][]): string {
  const escape = (v: unknown) => `"${String(v ?? '').replace(/"/g, '""')}"`;
  return [headers, ...rows].map(row => row.map(escape).join(',')).join('\n');
}
```

### 13.6 Export Scope Permission Note

Reseller-scope exports are role-gated (any active `reseller_admin` can export their own portfolio), consistent with §10.1's design note that reseller dashboard access is not a tenant-package entitlement. Invitation and tenant scope exports remain gated by the requesting tenant's own `analytics_export` feature, regardless of whether that tenant was acquired through a reseller.

---

## 14. Real-Time Analytics (Live Event Dashboard)

### 14.1 Purpose & Scope

A genuinely real-time view exists for exactly one operational scenario: **day-of-event monitoring** — the owner or an usher watching check-ins and RSVP arrivals live during the wedding itself. This is distinct from the historical dashboards in §6–11, which are rollup-driven and intentionally not real-time (rollups run nightly; same-day data is incomplete by design until the nightly job runs).

```
/invitations/[id]/live
├── Live check-in counter (Supabase Realtime on qr_checkins INSERT)
├── Live RSVP feed (Supabase Realtime on rsvp_responses INSERT) — last 20, newest first
├── Live guestbook feed (Supabase Realtime on guestbook_entries INSERT, approved only)
└── Manual refresh fallback (for ushers on venues with unstable WiFi)
```

This page is **not** backed by any rollup table — it queries live tables directly with tight scopes (today's date, single invitation), and subscribes to the same Realtime channel pattern already established in PHASE9 §6.4 (`GuestbookWall`) and §15.4.

### 14.2 Live Dashboard Component

```typescript
// components/analytics/LiveEventDashboard.tsx
'use client';

import { useEffect, useState } from 'react';
import { createBrowserClient } from '@/lib/supabase/client';

interface LiveEventDashboardProps {
  invitationId: string;
  initialCheckinCount: number;
  initialRsvpFeed: RsvpResponse[];
}

export function LiveEventDashboard({
  invitationId, initialCheckinCount, initialRsvpFeed,
}: LiveEventDashboardProps) {
  const [checkinCount, setCheckinCount] = useState(initialCheckinCount);
  const [rsvpFeed, setRsvpFeed] = useState(initialRsvpFeed);
  const supabase = createBrowserClient();

  useEffect(() => {
    const channel = supabase
      .channel(`live-event:${invitationId}`)
      .on('postgres_changes', {
        event: 'INSERT', schema: 'public', table: 'qr_checkins',
      }, () => setCheckinCount(c => c + 1))
      .on('postgres_changes', {
        event: 'INSERT', schema: 'public', table: 'rsvp_responses',
        filter: `invitation_id=eq.${invitationId}`,
      }, (payload) => setRsvpFeed(feed => [payload.new as RsvpResponse, ...feed].slice(0, 20)))
      .subscribe();

    return () => { supabase.removeChannel(channel); };
  }, [invitationId, supabase]);

  return (
    <div className="space-y-6">
      <div className="rounded-2xl bg-gradient-to-br from-purple-600 to-purple-800 p-8 text-center text-white">
        <p className="text-sm uppercase tracking-wider opacity-80">Guests Checked In</p>
        <p className="mt-2 text-5xl font-bold">{checkinCount}</p>
      </div>

      <div>
        <h3 className="mb-3 text-sm font-semibold text-gray-700">Live RSVP Feed</h3>
        <div className="space-y-2">
          {rsvpFeed.map(r => (
            <div key={r.id} className="flex items-center justify-between rounded-lg border border-gray-100 px-4 py-2">
              <span className="text-sm font-medium">{r.name}</span>
              <AttendanceBadge status={r.attendance} />
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
```

### 14.3 Live Dashboard Data Loader

```typescript
// app/(app)/invitations/[id]/live/page.tsx

export default async function LiveEventPage({ params }: { params: { id: string } }) {
  const user = await requireSession();
  const supabase = createServerClient();

  const todayStart = `${new Date().toISOString().slice(0, 10)}T00:00:00+07:00`;

  const [{ count: checkinCount }, { data: rsvpFeed }] = await Promise.all([
    supabase.from('qr_checkins')
      .select('id, qr_code:qr_codes!inner(invitation_id)', { count: 'exact', head: true })
      .eq('qr_code.invitation_id', params.id)
      .gte('checked_in_at', todayStart),
    supabase.from('rsvp_responses')
      .select('*')
      .eq('invitation_id', params.id)
      .eq('is_spam', false)
      .order('submitted_at', { ascending: false })
      .limit(20),
  ]);

  return (
    <LiveEventDashboard
      invitationId={params.id}
      initialCheckinCount={checkinCount ?? 0}
      initialRsvpFeed={rsvpFeed ?? []}
    />
  );
}
```

### 14.4 Realtime Connection Scalability

Following the exact precedent set in PHASE9 §15.4: one channel per invitation, connected only while the live page is open (minutes to hours, day-of-event only), never a global channel. At projected scale (PHASE9 §15.1: 25,000 active invitations), the number of *simultaneous* live-dashboard connections is bounded by "weddings happening today," not total invitation count — a self-limiting concurrency profile that requires no additional scaling work beyond what PHASE9 already provisioned.

---

## 15. Permission Rules & RLS

### 15.1 Analytics Permission Matrix

| Action | super_admin | reseller_admin | owner | editor | viewer |
|---|:---:|:---:|:---:|:---:|:---:|
| View invitation analytics (basic tier) | ✅ | ✅ (clients) | ✅ | ✅ | ✅ |
| View invitation analytics (advanced tier) | ✅ | ✅ (clients) | ✅ | ✅ | ❌ |
| View guest-level engagement detail | ✅ | ✅ (clients) | ✅ | ✅ | ❌ |
| View tenant cross-invitation dashboard | ✅ | ✅ (clients) | ✅ | ✅ | ❌ |
| Export analytics report | ✅ | ✅ (clients) | ✅ | ❌ | ❌ |
| View live event dashboard | ✅ | ✅ | ✅ | ✅ | ✅ |
| View reseller portfolio dashboard | ✅ | ✅ (own) | ❌ | ❌ | ❌ |
| View platform dashboard | ✅ | ❌ | ❌ | ❌ | ❌ |
| View cohort retention | ✅ | ❌ | ❌ | ❌ | ❌ |
| Trigger manual rollup re-run | ✅ | ❌ | ❌ | ❌ | ❌ |

**Note on viewer role:** `viewer` retains read access to basic metrics and the live event dashboard (consistent with PHASE7 §11.1, where `viewer` can always preview/view published content) but is excluded from advanced/guest-level/export capabilities, matching the general pattern that `viewer` has no write-adjacent or data-extraction capabilities anywhere in the platform (PHASE8 §11.1, PHASE9 §12.1).

### 15.2 API Route Permission Map

| Route | Method | Permission | Feature Gate |
|---|---|---|---|
| `/api/invitations/[id]/analytics` | GET | `analytics:read` | `analytics_basic` |
| `/api/invitations/[id]/analytics/rsvp` | GET | `analytics:read` | `analytics_basic` |
| `/api/invitations/[id]/guests/[guestId]/engagement` | GET | `analytics:read` | `analytics_advanced` |
| `/api/invitations/[id]/guests/engagement-summary` | GET | `analytics:read` | `analytics_advanced` |
| `/api/analytics/tenant/invitations` | GET | `analytics:read` | `analytics_basic` |
| `/api/analytics/export` | POST | `analytics:read` | `analytics_export` (tenant/invitation scope only) |
| `/api/analytics/export/[jobId]` | GET | `analytics:read` | — (ownership-checked) |
| `/api/reseller/analytics` | GET | `reseller:analytics:read` | role: `reseller_admin` |
| `/api/reseller/analytics/clients` | GET | `reseller:analytics:read` | role: `reseller_admin` |
| `/api/admin/analytics` | GET | — | role: `super_admin` |
| `/api/admin/analytics/cohort-retention` | GET | — | role: `super_admin` |
| `/api/events/track` | POST | ❌ Public | — (rate-limited, gate-checked server-side) |

### 15.3 RLS Policies

```sql
-- invitation_analytics_extended
ALTER TABLE invitation_analytics_extended ENABLE ROW LEVEL SECURITY;

CREATE POLICY "inv_analytics_ext_read_tenant" ON invitation_analytics_extended
  FOR SELECT USING (tenant_id = auth_tenant_id());

CREATE POLICY "inv_analytics_ext_read_reseller" ON invitation_analytics_extended
  FOR SELECT USING (
    tenant_id IN (SELECT tenant_id FROM reseller_tenants WHERE reseller_id = auth_reseller_id())
  );
-- No public/anon policy — this table is never read by the public invitation page.
-- No INSERT/UPDATE policy for authenticated roles — writes occur only via service-role rollup jobs.

-- tenant_analytics_daily
ALTER TABLE tenant_analytics_daily ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tenant_analytics_read_own" ON tenant_analytics_daily
  FOR SELECT USING (tenant_id = auth_tenant_id());

CREATE POLICY "tenant_analytics_read_reseller" ON tenant_analytics_daily
  FOR SELECT USING (
    tenant_id IN (SELECT tenant_id FROM reseller_tenants WHERE reseller_id = auth_reseller_id())
  );

-- reseller_analytics_daily
ALTER TABLE reseller_analytics_daily ENABLE ROW LEVEL SECURITY;

CREATE POLICY "reseller_analytics_read_own" ON reseller_analytics_daily
  FOR SELECT USING (reseller_id = auth_reseller_id());
-- No tenant-level read policy — a tenant must never see reseller commercial/portfolio data.

-- platform_analytics_daily
ALTER TABLE platform_analytics_daily ENABLE ROW LEVEL SECURITY;
-- No policies defined at all — default-deny. Only the service_role client (used exclusively
-- in /api/admin/* routes after an explicit super_admin role check) can read this table.
-- This mirrors PHASE10 §16.5's "Service Role Containment" principle exactly.

-- analytics_export_jobs
ALTER TABLE analytics_export_jobs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "export_jobs_read_own" ON analytics_export_jobs
  FOR SELECT USING (tenant_id = auth_tenant_id());

CREATE POLICY "export_jobs_insert_own" ON analytics_export_jobs
  FOR INSERT WITH CHECK (tenant_id = auth_tenant_id());

-- rollup_job_runs: service-role only, no policy (default deny) — internal operational table
ALTER TABLE rollup_job_runs ENABLE ROW LEVEL SECURITY;

-- guest_engagement_summary (view) inherits RLS from underlying `guests` table (PHASE8 §11.4);
-- no separate policy needed since Postgres views run with the querying role's permissions
-- against the base tables by default in this project's view definitions (SECURITY INVOKER, the
-- Postgres default — none of these views are declared SECURITY DEFINER).
```

### 15.4 Public Ingestion Endpoint Security Boundary

`/api/events/track` is the only analytics-adjacent endpoint reachable without authentication. Its security posture, by design:
- Never reads or writes any table governed by a "tenant data" RLS policy directly from request input — it validates the invitation is `published` first (§4.3), which is itself gated by the existing public-read RLS policy (`inv_public_read`, PHASE7 §11.3).
- Writes only to `invitation_events`, an append-only table with no sensitive PII (raw IP is hashed before storage, §4.3 `hashIp()`).
- Cannot be used to enumerate non-published invitations (a non-existent or non-published `invitation_id` returns an identical `204` to a successful write — no information leakage via response-code branching).

---

## 16. Multi-Tenant Security & Privacy

### 16.1 Tenant Isolation Pattern (Consistent with All Prior Phases)

Every new table in this phase carries a denormalized `tenant_id` (or `reseller_id` for reseller-scoped tables), following the exact rationale given in PHASE8 §12.1 and PHASE9 §13.1: avoids subquery joins to `invitations` for RLS evaluation, and supports efficient partial indexing. Every query in §6–14 includes an explicit `.eq('tenant_id', ...)` (or reseller-equivalent) filter in application code in addition to the RLS policy — the same defense-in-depth pattern mandated in PHASE7 §12.4 and reaffirmed in PHASE10 §16.1.

### 16.2 Cross-Tenant Leakage Prevention in Rollup Jobs

The rollup jobs in PART 1 §5 run under the service-role client (`createAdminClient()`), which bypasses RLS by design — this is necessary because a single job run aggregates data across many tenants. To prevent this elevated-privilege code path from becoming a leakage vector:

- Rollup jobs **only ever write** to the `*_daily` / `*_extended` analytics tables — they never expose cross-tenant joined data back to any client-facing response.
- Each rollup function operates on one `tenant_id` (or `reseller_id`) at a time, in a loop, writing one row per iteration — there is no code path where one tenant's rollup computation reads or references another tenant's raw events.
- The service-role client is instantiated only inside Edge Functions (`supabase/functions/rollup-*`), never inside any `/api/*` route — matching PHASE10 §16.5's containment rule exactly.

### 16.3 Guest & Respondent Privacy in Analytics

- `invitation_events` never stores raw IP addresses (§4.3) — stricter than `rsvp_responses`/`guestbook_entries`, which retain raw IP transiently for spam scoring per PHASE9 §13.4's documented policy and 90-day purge commitment.
- Guest names are surfaced in the **owner's own** guest engagement table (§8) and live RSVP feed (§14) — this is owner-facing operational data, identical in sensitivity to the guest list itself (PHASE8) and the RSVP dashboard (PHASE9), not a new privacy surface.
- No analytics surface in this phase exposes one guest's data to another guest, or one tenant's guest data to another tenant. Reseller dashboards (§10) are aggregate-only (counts and sums) — a reseller admin querying `/api/reseller/analytics/clients` never receives individual guest names, RSVP messages, or guestbook content; only rollup numbers.

### 16.4 IP Hash Salt Management

`ANALYTICS_IP_SALT` (§4.3) is a server-only environment variable, rotated independently of any other secret. Because the hash is used only for unique-visitor deduplication within a single day's rollup window (not for long-term user tracking or re-identification), salt rotation has no correctness impact on historical `invitation_analytics.unique_visitors` figures — those are already permanently aggregated by the time any rotation would occur.

### 16.5 Data Minimization in Exports

CSV/PDF/XLSX exports (§13) include only the same fields already visible in-dashboard to the requesting role — no export path exposes a field that the equivalent screen view would not. This avoids a class of vulnerability where export endpoints become unintended "richer" data-access surfaces than their corresponding UI.

---

## 17. Performance Optimization

### 17.1 Indexing Strategy

```sql
-- ── invitation_analytics_extended ──────────────────────────────────
CREATE INDEX idx_inv_analytics_ext_inv_date ON invitation_analytics_extended(invitation_id, date DESC);
CREATE INDEX idx_inv_analytics_ext_tenant   ON invitation_analytics_extended(tenant_id, date DESC);

-- ── tenant_analytics_daily ──────────────────────────────────────────
CREATE INDEX idx_tenant_analytics_daily_tenant ON tenant_analytics_daily(tenant_id, date DESC);
-- Hot path: dashboard date-range scan, always tenant_id + date together — composite covers it.

-- ── reseller_analytics_daily ────────────────────────────────────────
CREATE INDEX idx_reseller_analytics_daily_reseller ON reseller_analytics_daily(reseller_id, date DESC);

-- ── platform_analytics_daily ────────────────────────────────────────
CREATE INDEX idx_platform_analytics_date ON platform_analytics_daily(date DESC);
-- Single-tenant-equivalent table (one row/day); B-tree on date alone is sufficient at any scale.

-- ── analytics_export_jobs ───────────────────────────────────────────
CREATE INDEX idx_analytics_export_tenant  ON analytics_export_jobs(tenant_id, created_at DESC);
CREATE INDEX idx_analytics_export_pending ON analytics_export_jobs(status) WHERE status IN ('pending', 'processing');

-- ── rollup_job_runs ──────────────────────────────────────────────────
CREATE INDEX idx_rollup_runs_job_date ON rollup_job_runs(job_name, target_date DESC);

-- ── guest_engagement_summary (view performance depends on base table indexes) ──
-- Relies on existing PHASE8 idx_guests_invitation and a new index on invitation_events.guest_id:
CREATE INDEX idx_events_guest_id ON invitation_events(guest_id, event_type) WHERE guest_id IS NOT NULL;
-- This is the one net-new index on the PHASE2 invitation_events table required by this phase;
-- it does not alter that table's existing idx_events_invitation / idx_events_type / idx_events_pageview.
```

### 17.2 Rollup Query Cost Containment

The nightly invitation rollup (PART 1 §5.2) scans `invitation_events` filtered by `invitation_id` + a one-day `created_at` range — covered by the existing PHASE2 `idx_events_invitation(invitation_id, created_at DESC)` index, so no new index is needed on the hot scan path itself. The job processes one invitation at a time rather than a single platform-wide aggregate query, which trades a larger number of small, index-covered queries for the elimination of any single multi-tenant table scan — consistent with the "no full-table scan, ever" posture implied by PHASE7 §15.7's tenant-isolation-at-scale argument.

### 17.3 Dashboard Query Caching

```typescript
// lib/analytics/cache.ts
// Mirrors the Redis caching pattern from PHASE5 §12.1 (feature resolution) and
// PHASE9 §14.2 (RSVP summary cache) — same TTL philosophy, different keys.

const DASHBOARD_CACHE_TTL = 300; // 5 minutes — dashboards are rollup-driven, not live, so a short
                                   // cache window is safe and meaningfully reduces read load.

export async function getCachedAnalyticsSummary<T>(cacheKey: string): Promise<T | null> {
  return redis.get<T>(cacheKey);
}

export async function setCachedAnalyticsSummary<T>(cacheKey: string, data: T): Promise<void> {
  await redis.setex(cacheKey, DASHBOARD_CACHE_TTL, JSON.stringify(data));
}

export function invitationSummaryCacheKey(invitationId: string, from: string, to: string): string {
  return `analytics:inv:${invitationId}:${from}:${to}`;
}

export function tenantSummaryCacheKey(tenantId: string, from: string, to: string): string {
  return `analytics:tenant:${tenantId}:${from}:${to}`;
}

// Invalidation: rollup jobs call this after writing each day's data, scoped to ranges that
// could include the newly-written date. Since dashboards default to rolling "last 30 days"
// windows, a coarse per-entity invalidation (delete all keys matching the entity prefix) is
// simpler and sufficiently cheap given the 5-minute TTL ceiling already bounds staleness.
export async function invalidateInvitationAnalyticsCache(invitationId: string): Promise<void> {
  const keys = await redis.keys(`analytics:inv:${invitationId}:*`);
  if (keys.length) await redis.del(...keys);
}
```

### 17.4 Parallel Data Loading

Every multi-source dashboard query in §6–11 uses `Promise.all()` for independent reads — never sequential `await` chains — matching the explicit performance rule already stated in PHASE10 §17.3 ("never sequential awaits for independent queries").

### 17.5 Export Generation Latency Targets

| Stage | Target |
|---|---|
| Row-count estimation | < 50ms (uses indexed `COUNT` on rollup tables, never raw events) |
| Synchronous CSV (≤1,000 rows) | < 800ms end-to-end |
| Async job pickup (Edge Function invocation) | < 2s |
| Async CSV/XLSX generation (≤50,000 rows) | < 15s |
| Async PDF generation (chart rendering included) | < 25s |
| Signed URL issuance | < 100ms |

---

## 18. Scalability Considerations

### 18.1 Volume Projections

Building directly on the projections already established in PHASE7 §15.1, PHASE8 §14.1, and PHASE9 §15.1:

```
Year 2 (from PHASE7/9 baseline):
  Active invitations:        25,000
  invitation_events rows:    ~3M RSVP-adjacent events (PHASE9) + page_view/section_scroll/etc.
                              estimated 15-20× the RSVP row count → ~50-60M raw events/year

  invitation_analytics rows:  25,000 invitations × ~180 active days avg ≈ 4.5M rows/year (small, indexed)
  invitation_analytics_extended rows: same grain, same volume profile
  tenant_analytics_daily rows: 10,000 tenants × 365 days ≈ 3.65M rows/year (trivial)
  reseller_analytics_daily rows: low hundreds of resellers × 365 ≈ negligible
  platform_analytics_daily rows: 365 rows/year (trivial, permanent)

Year 3:
  invitation_events: ~250-300M cumulative raw rows (before purge — see §19)
  invitation_analytics / extended: ~18M rows cumulative (retained indefinitely — see §19.2)
```

### 18.2 Raw Event Table Partitioning (Reaffirming PHASE2 §9.1)

`invitation_events` was already identified in PHASE2 §9.1 as a partitioning candidate at >10M rows. This phase's event volume (§18.1) makes that threshold a near-certainty within Year 1–2. PHASE11 does not re-specify the partitioning DDL (already given in PHASE2 §9.1) but confirms the rollup jobs in PART 1 §5 are **partition-pruning-friendly by construction**: every rollup query filters on a `created_at` range scoped to exactly one day, which aligns naturally with monthly range partitions — the query touches at most one (or, at a month boundary, two) partitions regardless of total table size.

### 18.3 Rollup Job Horizontal Scaling

At Year 3 volume (~25,000+ active invitations needing nightly rollup), a single Edge Function invocation iterating sequentially risks exceeding execution time limits. The mitigation path, consistent with PHASE8 §14.4's async-import scaling pattern:

```typescript
// supabase/functions/rollup-invitation-daily/index.ts (Year 3 scaling variant)
// Splits the invitation list into shards and invokes itself N times in parallel via
// Edge Function fan-out, rather than processing all invitations in one cold-start lifetime.

const SHARD_COUNT = 10;

Deno.serve(async (req) => {
  const { shard } = await req.json().catch(() => ({ shard: null }));
  if (shard === null) {
    // Coordinator invocation: fan out, do not process directly
    const targetDate = getPreviousDateString();
    await Promise.all(
      Array.from({ length: SHARD_COUNT }, (_, i) =>
        fetch(Deno.env.get('SUPABASE_FUNCTION_URL') + '/rollup-invitation-daily', {
          method: 'POST',
          headers: { Authorization: `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}` },
          body: JSON.stringify({ shard: i, target_date: targetDate }),
        })
      )
    );
    return new Response(JSON.stringify({ dispatched_shards: SHARD_COUNT }));
  }

  // Worker invocation: process only invitations where hashtext(id::text) % SHARD_COUNT = shard
  // (deterministic, even distribution, no coordination needed between shards)
  // ... rollupSingleInvitation() loop scoped to this shard's invitation set ...
});
```

This shard-fan-out pattern requires no schema change and activates only once invitation volume warrants it — it is documented here as the prepared scaling path, matching the deferred-extension documentation style used throughout PHASE2 §9.6, PHASE7 §15.6, and PHASE8 §14.6.

### 18.4 Materialized View Consideration (Deferred, Not Adopted)

A platform-wide materialized view joining all tenant rollups was considered for the Super Admin dashboard (§11) but rejected in favor of the `platform_analytics_daily` plain table (PART 1 §3.5), because the nightly rollup job already produces exactly the rows such a view would compute, at lower operational complexity (no `REFRESH MATERIALIZED VIEW` scheduling, no concurrent-refresh lock consideration). This decision is consistent with PHASE5 §12.2's reasoning, which reserved materialized views specifically for cases requiring JOIN-heavy real-time resolution — not applicable here, since platform analytics are explicitly day-old by design (§14.1).

### 18.5 Read Replica Routing

Per PHASE2 §9.4's existing read-replica policy, all analytics dashboard SELECT queries (§6–11) are safe to route to a Supabase read replica once provisioned — none of them require strict read-after-write consistency (the most recent data they ever show is "yesterday," via the nightly rollup), making them ideal replica-routing candidates alongside the public invitation page reads already specified in PHASE2 §9.4.

### 18.6 Future Schema Extensions

| Future Feature | Extension Required |
|---|---|
| Hourly (not just daily) historical retention for Ultimate tier | New `invitation_analytics_hourly` table, same upsert pattern, gated by a new `analytics_advanced.config.grain` value |
| A/B theme experiment analytics | Joins `theme_experiments` (PHASE6 §20.2, already prepared) against `invitation_analytics_extended.section_views` |
| Predictive RSVP forecasting | New `rsvp_forecast_snapshots` table fed by a scheduled model-scoring job, reading `rsvp_daily_trend` (PHASE9) as its only input |
| Heatmap (scroll-depth) visualization | `section_views` JSONB already captures the needed granularity (PART 1 §3.2); only a new chart component, no schema change |
| Custom report builder (drag-drop metrics) | New `saved_report_definitions` table storing a JSONB query spec resolved against the existing rollup tables — no raw-event access needed |

---

## 19. Data Retention & Purge Policy

### 19.1 Retention Tiers

| Data | Retention | Enforced By |
|---|---|---|
| `invitation_events` (raw) | Per-package `analytics_advanced.config.retention_days` (PHASE5 seed: Free/Basic implicit 30d via plan default, Premium 90d, Ultimate 365d) | Nightly purge job (§19.2) |
| `invitation_analytics` / `invitation_analytics_extended` (daily rollups) | Indefinite | Never purged — rollups are small and are the permanent historical record, exactly as PHASE2 §9.3 specifies for the base table |
| `tenant_analytics_daily` / `reseller_analytics_daily` / `platform_analytics_daily` | Indefinite | Never purged — trend charts depend on long-horizon history |
| `analytics_export_jobs` | 30 days for the job record; underlying file purged from storage after 7 days | Nightly purge job (§19.3) |
| Guest-identifying fields inside `invitation_events.metadata` (e.g., `ip_hash`) | Same as parent row (`retention_days`) | Purged together with the row; no independent field-level TTL |

This directly fulfills PHASE2 §9.3's stated policy ("Events older than 90 days... should be moved to cold storage or deleted... The `invitation_analytics` daily roll-ups are the permanent record") while making the retention window package-driven rather than a single hardcoded 90-day constant — required by this project's "no hardcoded limits" mandate.

### 19.2 Raw Event Purge Job

```typescript
// supabase/functions/purge-old-events/index.ts
// Schedule: nightly, after all rollup tiers have completed for the relevant date

Deno.serve(async () => {
  const admin = createAdminClient();

  // Resolve retention_days per package (never hardcoded — always read from package_features.config)
  const { data: packages } = await admin
    .from('packages')
    .select(`
      id, slug,
      package_features!inner(feature:features!inner(key), config)
    `)
    .eq('package_features.feature.key', 'analytics_advanced');

  let totalPurged = 0;

  for (const pkg of packages ?? []) {
    const retentionDays = (pkg.package_features as any)?.[0]?.config?.retention_days ?? 30;
    const cutoff = new Date(Date.now() - retentionDays * 86_400_000).toISOString();

    const { data: tenantIds } = await admin
      .from('tenant_subscriptions')
      .select('tenant_id')
      .eq('package_id', pkg.id)
      .in('status', ['active', 'trialing', 'past_due']);

    const ids = (tenantIds ?? []).map(t => t.tenant_id);
    if (ids.length === 0) continue;

    const { count } = await admin
      .from('invitation_events')
      .delete({ count: 'exact' })
      .in('tenant_id', ids)
      .lt('created_at', cutoff);

    totalPurged += count ?? 0;
  }

  // Tenants with no active subscription at all fall back to the Free package's retention window
  const { data: freePkg } = await admin.from('packages').select('id').eq('slug', 'free').single();
  if (freePkg) {
    const { data: freeFeature } = await admin
      .from('package_features')
      .select('config, feature:features!inner(key)')
      .eq('package_id', freePkg.id)
      .eq('feature.key', 'analytics_advanced')
      .maybeSingle();
    const freeRetentionDays = (freeFeature?.config as any)?.retention_days ?? 30;
    const freeCutoff = new Date(Date.now() - freeRetentionDays * 86_400_000).toISOString();

    const { data: noSubTenants } = await admin
      .from('tenants')
      .select('id')
      .not('id', 'in', `(SELECT tenant_id FROM tenant_subscriptions WHERE status IN ('active','trialing','past_due'))`);

    const ids = (noSubTenants ?? []).map(t => t.id);
    if (ids.length > 0) {
      const { count } = await admin
        .from('invitation_events')
        .delete({ count: 'exact' })
        .in('tenant_id', ids)
        .lt('created_at', freeCutoff);
      totalPurged += count ?? 0;
    }
  }

  return new Response(JSON.stringify({ purged: totalPurged }));
});
```

### 19.3 Export File Purge Job

```typescript
// supabase/functions/purge-old-exports/index.ts
// Schedule: nightly

Deno.serve(async () => {
  const admin = createAdminClient();
  const fileCutoff = new Date(Date.now() - 7 * 86_400_000).toISOString();
  const recordCutoff = new Date(Date.now() - 30 * 86_400_000).toISOString();

  const { data: staleFiles } = await admin
    .from('analytics_export_jobs')
    .select('id, file_path')
    .eq('status', 'completed')
    .lt('completed_at', fileCutoff)
    .not('file_path', 'is', null);

  for (const job of staleFiles ?? []) {
    await admin.storage.from('analytics-exports').remove([job.file_path!]);
    await admin.from('analytics_export_jobs').update({ file_path: null }).eq('id', job.id);
  }

  const { count: recordsPurged } = await admin
    .from('analytics_export_jobs')
    .delete({ count: 'exact' })
    .lt('created_at', recordCutoff);

  return new Response(JSON.stringify({ files_removed: staleFiles?.length ?? 0, records_purged: recordsPurged ?? 0 }));
});
```

### 19.4 Storage Bucket Addition

```sql
-- Extends PHASE2 §7 storage bucket structure with one new bucket for this phase

-- analytics-exports/                Public: false
--   └── {tenant_id}/
--       └── {job_id}.{csv|xlsx|pdf}

CREATE POLICY "analytics_exports_tenant_read" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'analytics-exports' AND
    (storage.foldername(name))[1] = auth_tenant_id()::TEXT
  );
-- Writes occur exclusively via the service-role client inside the Edge Function (§13.4);
-- no authenticated-role INSERT policy is defined, matching the "invoices" bucket precedent
-- in PHASE10 where PDF generation is also service-role-only.
```

| Bucket | Max size | Allowed types | Retention |
|---|---|---|---|
| `analytics-exports` | 25 MB | csv, xlsx, pdf | 7 days (file), 30 days (job record) |

---

## 20. Appendices

### Appendix A — Migration Order (Phase 11 Additions)

```
Previously from PHASE1–10:
  001–105: Core tables, packages, features, themes, invitations, guests, RSVP, guestbook, billing

New migrations (PHASE11 additions):
  106_invitation_analytics_extended.sql   -- invitation_analytics_extended table + indexes
  107_tenant_analytics_daily.sql          -- tenant_analytics_daily table + indexes
  108_reseller_analytics_daily.sql        -- reseller_analytics_daily table + indexes
  109_platform_analytics_daily.sql        -- platform_analytics_daily table + indexes
  110_increment_view_count_fn.sql         -- increment_view_count() RPC (wires PHASE7 §13.5 buffer)
  111_guest_engagement_view.sql           -- guest_engagement_summary view (completes PHASE8 §10.3)
  112_rsvp_by_group_view.sql              -- rsvp_by_group view (completes PHASE8 §10.4 AttendanceByGroup)
  113_tenant_cohort_retention_fn.sql      -- get_tenant_cohort_retention() RPC
  114_invitation_events_event_type_ext.sql-- ALTER CHECK: + section_scroll, whatsapp_share_click, session_end
  115_events_guest_id_index.sql           -- idx_events_guest_id (supports guest_engagement_summary)
  116_analytics_export_jobs.sql           -- analytics_export_jobs table + indexes
  117_rollup_job_runs.sql                 -- rollup_job_runs ledger table + indexes
  118_rls_analytics_tables.sql            -- RLS policies for all new tables (§15.3)
  119_storage_analytics_exports_bucket.sql-- analytics-exports bucket + policy (§19.4)
```

### Appendix B — API Route Summary

```
── INVITATION ANALYTICS ────────────────────────────────────────────────
GET    /api/invitations/[id]/analytics                       Summary (basic + advanced tier composition)
GET    /api/invitations/[id]/analytics/rsvp                  RSVP trend/category/group/response-rate
GET    /api/invitations/[id]/guests/[guestId]/engagement      Single guest engagement detail
GET    /api/invitations/[id]/guests/engagement-summary        Sortable guest engagement list

── TENANT ANALYTICS ─────────────────────────────────────────────────────
GET    /api/analytics/tenant/invitations                      Per-invitation comparison table
        (tenant summary itself is rendered server-side via getTenantAnalyticsSummary(), no separate
         REST route required since it is consumed only by the /analytics server component)

── EXPORT ────────────────────────────────────────────────────────────────
POST   /api/analytics/export                                  Request export (sync or queued)
GET    /api/analytics/export/[jobId]                          Poll export job status / get signed URL

── RESELLER ANALYTICS ────────────────────────────────────────────────────
GET    /api/reseller/analytics                                 Portfolio summary
GET    /api/reseller/analytics/clients                          Per-client comparison table

── PLATFORM (SUPER ADMIN) ────────────────────────────────────────────────
GET    /api/admin/analytics                                     Platform-wide summary
GET    /api/admin/analytics/cohort-retention                     Tenant cohort retention

── LIVE / REAL-TIME ───────────────────────────────────────────────────────
        (no dedicated REST route — /invitations/[id]/live loads initial state server-side,
         then subscribes directly to Supabase Realtime channels; see §14.3)

── INGESTION ────────────────────────────────────────────────────────────
POST   /api/events/track                                        Public event beacon (rate-limited)
```

### Appendix C — Feature Flag Reference (No New Keys — Cross-Reference to PHASE5)

| Feature Key | Free | Basic | Premium | Ultimate | Governs in PHASE11 |
|---|:---:|:---:|:---:|:---:|---|
| `analytics_basic` | ❌ | ✅ | ✅ | ✅ | §6, §7 basic trend/device/referrer |
| `analytics_advanced` | ❌ | ❌ | ✅ | ✅ | §7 section/source/session, §8 guest engagement |
| `analytics_export` | ❌ | ❌ | ✅ | ✅ | §13 CSV/PDF/XLSX export |
| `qr_checkin` | ❌ | ❌ | ✅ (2 devices) | ✅ (∞) | §7.2, §8.4 check-in rate widgets |

### Appendix D — Metric-to-Source Reference

| Dashboard Metric | Computed From | Defined In |
|---|---|---|
| Views, unique visitors, device split | `invitation_analytics` | PHASE2 (table), PART1 §5.2 (rollup logic) |
| RSVP attending/declining/maybe trend | `rsvp_daily_trend` view | PHASE9 §9.2 |
| RSVP by wedding side | `rsvp_by_category` view | PHASE9 §9.2 |
| RSVP by social group | `rsvp_by_group` view | PHASE11 §9.2 (new) |
| Response rate (tracked guests) | `rsvp_response_rate` view | PHASE9 §9.2 |
| Meal choice breakdown | Direct query on `rsvp_responses.meal_choice` | PHASE11 §9.3 (new) |
| Guestbook moderation funnel | Direct query on `guestbook_entries` | PHASE11 §9.4 (new) |
| Section engagement | `invitation_analytics_extended.section_views` | PHASE11 PART1 §3.2 / §5.2 |
| Guest-level engagement | `guest_engagement_summary` view | PHASE11 §8.1 (new; completes PHASE8 §10.3 prep) |
| Check-in rate | `guest_checkin_status` view + `qr_checkins` | PHASE8 §10.2 (view), PHASE11 §7.2/§8.4 (consumption) |
| Tenant cross-invitation rollup | `tenant_analytics_daily` | PHASE11 PART1 §3.3 (new) |
| Reseller portfolio rollup | `reseller_analytics_daily` | PHASE11 PART1 §3.4 (new) |
| Platform revenue figures | `get_platform_billing_summary()` RPC | PHASE10 §14.3 (reused, not duplicated) |
| Platform engagement + growth | `platform_analytics_daily` | PHASE11 PART1 §3.5 (new) |
| Commission accrual (reseller view) | `commission_ledger` | PHASE10 §13.1 (reused) |

### Appendix E — Environment Variables Introduced

```bash
# Analytics ingestion
ANALYTICS_IP_SALT=                  # server-only; rotatable; used for one-way IP hashing (§4.3, §16.4)

# Export storage
ANALYTICS_EXPORT_BUCKET=analytics-exports
```

---

*End of PHASE11_ANALYTICS.md — PART 3 OF 3*
*Parts 1, 2, and 3 together constitute the complete PHASE11_ANALYTICS.md. Assembly into a single file is pending, per instruction.*
