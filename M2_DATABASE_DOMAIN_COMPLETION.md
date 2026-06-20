# M2_DATABASE_DOMAIN_COMPLETION.md
# Wedding Invitation SaaS Platform — Milestone M2: Database Domain Completion

> **Version:** 1.0.0
> **Implementation authority:** BUILD_ORDER.md — Phase C (`= M2` in IMPLEMENTATION_ROADMAP.md), extended per the resequencing decision in §1 below
> **Upstream source documents:** PHASE1_ARCHITECTURE.md, PHASE10_PAYMENT_SYSTEM.md, PHASE11_ANALYTICS.md, PHASE12_DEPLOYMENT.md
> **Predecessors:** M0_FOUNDATION.md (Phase A), M1_CORE_MULTI_TENANT_FOUNDATION.md (Phase B) — both complete.
> **Method:** Every table, column, and constraint below either (a) already exists per M1, recapped by reference only, or (b) is derived from a **literal citation** in PHASE1/10/11/12 — a query, a `CREATE TABLE`/`CREATE VIEW` statement, a column selected in a `.select()`, or an explicit prose reference. Where the available documents describe a table by name or by partial column usage but do not give its full definition, this is **flagged as an open gap and left unresolved** rather than invented. No gap is closed by guessing. All resolutions are **additive only** (new tables, new columns, new indexes) — consistent with PHASE12 §6.1's expand-only migration philosophy, itself an approved decision, applied here as the resolution method. No column, table, or constraint already specified in PHASE1 or M1 is altered, renamed, or removed. **No application code is included** — only schema specification.

---

## 1. Objectives

1. Resolve every database-schema gap left open by PHASE1/M1 that is provably required by PHASE10 or PHASE11's later usage (e.g. `tenant_subscriptions.trial_ends_at`, `audit_logs.actor_role`) — using only what those documents literally cite.
2. Create the PHASE2-cited baseline analytics/QR tables (`qr_codes`, `qr_checkins`, `invitation_events`, `invitation_analytics`) that PHASE11 builds on top of, exactly as BUILD_ORDER Phase C originally scoped.
3. **Resequencing decision (consolidation, not redesign):** BUILD_ORDER originally scattered database-schema work for the Guest, RSVP, Package, and Theme domains across Phases F, G, H, I, and J as each phase's "Database changes" bullet. This milestone consolidates **all** of that schema work into one completion pass, executed before any of those phases' application logic begins. This is a sequencing refinement only — every table and column specified below was already scheduled in one of those phases' "Database changes" bullets; nothing new is being decided. Phases F, G, H, I, and J retain their service/API/frontend responsibilities unchanged; they no longer carry a "Database changes" task because this milestone completes it for them.
4. Leave the Payment Domain (PHASE10) and the Analytics Domain's own new tables (PHASE11) **specified for reference in this document** (§18, §19) but **not re-migrated here** — their migrations remain fixed at `091`–`105` and `106`–`119` respectively, exactly as those documents' own appendices already declare. Moving them would contradict an already-fixed decision.
5. Produce one consolidated Foreign Key Architecture, Index Architecture, and RLS Coverage Matrix spanning the entire schema as it stands after this milestone, so that gaps still open after M2 are visible rather than silently dropped.

## 2. Scope

**In scope (new in this milestone):**
- Extensions to `invitations`, `guests`, `rsvp_responses`, `packages`, `tenant_subscriptions`, `audit_logs` (all additive — see §10 onward).
- New tables: `guest_groups`, `guestbook_entries`, `qr_codes`, `qr_checkins`, `add_ons`, `tenant_add_ons`, `vouchers`, `voucher_redemptions`, `invitation_events` (baseline), `invitation_analytics` (baseline).
- The consolidated, whole-system Foreign Key Architecture, Index Architecture, Constraint set, and RLS Coverage Matrix.

**Explicitly out of scope (unchanged from BUILD_ORDER):**
- `orders` v2, `payment_transactions`, `invoices`, `invoice_sequences`, `webhook_logs`, `refund_requests`, `commission_ledger`, `commission_payouts` — fixed at Phase L, migrations `091`–`105`. Specified for reference in §18 only.
- `invitation_analytics_extended`, `tenant_analytics_daily`, `reseller_analytics_daily`, `platform_analytics_daily`, `analytics_export_jobs`, `rollup_job_runs`, the `invitation_events.event_type` extension, `guest_engagement_summary`, `rsvp_by_group` — fixed at Phase M, migrations `106`–`119`. Specified for reference in §19 only.
- Any business logic, API route, or UI for any table below — those remain the responsibility of Phases F–J as BUILD_ORDER already assigned.

**Explicitly deferred (insufficient citation — not created in this milestone, listed so the gap stays visible):** `guest_import_batches`, `package_feature_snapshot`, `theme_experiments`, `rsvp_daily_trend`, `rsvp_by_category`, `rsvp_response_rate`, `guest_rsvp_status`, `guest_checkin_status`, `get_rsvp_summary()`. See §14–§16, §20 for what each is actually cited to contain.

## 3. Complete Database Domain Model

```
CORE TENANCY & IDENTITY        (M1 — unchanged)
  tenants, users, resellers, reseller_tenants, audit_logs

INVITATION DOMAIN               (M1 base + M2 extension)
  invitations, invitation_sections, invitation_themes

THEME DOMAIN                    (M1 base; one cited-but-unspecified extension)
  invitation_themes (shared with Invitation Domain)
  theme_experiments  [deferred — no column citation]

GUEST DOMAIN                    (M1 base + M2 extension)
  guests, guest_groups
  guest_import_batches [deferred]

RSVP DOMAIN                     (M1 base + M2 extension)
  rsvp_responses, guestbook_entries
  rsvp_daily_trend / rsvp_by_category / rsvp_response_rate /
    guest_rsvp_status / guest_checkin_status / get_rsvp_summary() [all deferred]

PACKAGE DOMAIN                  (M1 base + M2 extension)
  packages, package_features, tenant_subscriptions, feature_flags,
  add_ons, tenant_add_ons
  package_feature_snapshot [deferred]

PAYMENT DOMAIN                  (PHASE10 — fixed at Phase L, referenced only)
  orders (v2), payment_transactions, invoices, invoice_sequences,
  webhook_logs, refund_requests, commission_ledger, commission_payouts,
  vouchers, voucher_redemptions

ANALYTICS DOMAIN                (PHASE2 baseline — M2; PHASE11 new tables — fixed at Phase M, referenced only)
  invitation_events (baseline), invitation_analytics (baseline), qr_codes, qr_checkins   ← M2
  invitation_analytics_extended, tenant_analytics_daily, reseller_analytics_daily,
  platform_analytics_daily, analytics_export_jobs, rollup_job_runs                        ← Phase M

ADMIN DOMAIN                    (M1 — unchanged; no new table cited)
  audit_logs (shared with Core Tenancy)
```

## 4. Entity Relationship Architecture

```
tenants ──< users ──< resellers (owner_user_id)
   │                       │
   │                  reseller_tenants >── tenants
   │
   ├──< invitations ──< invitation_sections
   │        │   └──── invitation_themes (theme_id)
   │        │
   │        ├──< guests >── guest_groups (group_id)
   │        │       └──< rsvp_responses (guest_id, nullable)
   │        │
   │        ├──< guestbook_entries (guest_id, nullable)
   │        │
   │        ├──< invitation_events (baseline) ──< qr_codes ──< qr_checkins
   │        ├──── invitation_analytics (baseline, 1:1 per day)
   │        │
   │        └──< qr_codes (invitation_id)
   │
   ├──< tenant_subscriptions ──── packages ──< package_features
   │        │                         │
   │        │                    add_ons ──< tenant_add_ons >── tenant_subscriptions' tenant
   │        │
   │        └──── resellers (reseller_id, nullable)
   │
   ├──< orders (Payment Domain, referenced only — see §18)
   ├──< feature_flags
   └──< audit_logs
```

`rsvp_responses` and `guestbook_entries` have **no direct `tenant_id` column** (flagged in M1 §4/§10/§12 for `rsvp_responses`; the same gap applies to `guestbook_entries` — see §16). Both are reachable to a tenant only via `invitation_id → invitations.tenant_id`.

## 5. Canonical Table Definitions

Tables already fully specified in M1 (`tenants`, `users`, `resellers`, `reseller_tenants`, `packages` base, `package_features`, `tenant_subscriptions` base, `feature_flags`, `invitation_themes`, `invitations` base, `invitation_sections`, `guests` base, `rsvp_responses` base, `orders` PHASE1-shape, `audit_logs` base) are **not reprinted here** — see M1_CORE_MULTI_TENANT_FOUNDATION.md §13. Only **extensions** and **new tables** are detailed below, organized by domain.

### 5.1 Invitation Domain — extension

**`invitations` — ADD COLUMN:**
| Column | Type | Nullable | Default | Constraint | Source |
|---|---|---|---|---|---|
| `deleted_at` | TIMESTAMPTZ | YES | NULL | — | Cited via literal `.is('deleted_at', null)` filters on `invitations` in PHASE11 §7.3 and PHASE10 §10.3, and named explicitly as a cross-phase convention in PHASE12 §13.5 ("Soft deletes (`deleted_at` columns, already used throughout PHASE7–11)"). |

No other change to `invitations`, `invitation_sections`, or `invitation_themes` is cited.

### 5.2 Guest Domain — extension and new table

**`guests` — ADD COLUMNS:**
| Column | Type | Nullable | Default | Constraint | Source |
|---|---|---|---|---|---|
| `group_id` | UUID | YES | NULL | REFERENCES `guest_groups(id)` | Cited in PHASE11 §8.1 (`guest_engagement_summary` view selects `g.group_id`) and §9.2 (`rsvp_by_group` joins `guest_groups gg ON gg.id = g.group_id`). |
| `category_id` | UUID | YES | NULL | FK target table name **not cited anywhere** | Cited in PHASE11 §8.1 (`guest_engagement_summary` view selects `g.category_id`). The referenced lookup table's name is never given in any available document — flagged, not invented. |
| `deleted_at` | TIMESTAMPTZ | YES | NULL | — | Cited in PHASE11 §8.1 (`guest_engagement_summary` view: `WHERE g.deleted_at IS NULL`) and PHASE11 §4.3 ingestion endpoint (`.is('deleted_at', null)` on `guests`). |

**New table `guest_groups`:**
| Column | Type | Nullable | Default | Constraint | Source |
|---|---|---|---|---|---|
| `id` | UUID | NO | `gen_random_uuid()` | PRIMARY KEY | Standard PK pattern used throughout the schema; implied by `gg.id` in PHASE11 §9.2. |
| `name` | TEXT | NO | — | — | Cited: `gg.name` (PHASE11 §9.2). |
| `color` | TEXT | YES | NULL | — | Cited: `gg.color` (PHASE11 §9.2). |

**Flagged gap:** no scoping column (e.g. `invitation_id` or `tenant_id`) is cited for `guest_groups` anywhere in the available documents, even though every other tenant-data table in this schema carries one. This specification does **not** add one without a citation. PHASE8_GUEST_MANAGEMENT.md must be consulted before this table is considered implementation-ready.

**Deferred (not created):** `guest_import_batches` — referenced by name only (PHASE8 §13.4, cited via PHASE11 §18.3's "async-import scaling pattern" precedent and BUILD_ORDER Phase I). No column is cited anywhere.

### 5.3 RSVP Domain — extension and new table

**`rsvp_responses` — ADD COLUMNS:**
| Column | Type | Nullable | Default | Constraint | Source |
|---|---|---|---|---|---|
| `is_spam` | BOOLEAN | NO | `FALSE` | — | Cited pervasively, e.g. PHASE11 §5.3 (`.eq('is_spam', false)`), §9.2 (`WHERE r.is_spam = FALSE`), §9.3 (`.eq('is_spam', false)`). |
| `meal_choice` | TEXT | YES | NULL | — | Cited PHASE11 §9.3 (`.not('meal_choice', 'is', null)`, `r.meal_choice`). |

**New table `guestbook_entries`:**
| Column | Type | Nullable | Default | Constraint | Source |
|---|---|---|---|---|---|
| `id` | UUID | NO | `gen_random_uuid()` | PRIMARY KEY | Standard PK pattern; not directly selected but implied by row-identity usage. |
| `invitation_id` | UUID | NO | — | REFERENCES `invitations(id)` | Cited: `.eq('invitation_id', invitationId)` (PHASE11 §9.4). |
| `guest_id` | UUID | YES | NULL | REFERENCES `guests(id)` | Cited: `.select('moderation_status, guest_id, submitted_at')` (PHASE11 §9.4). Nullable inferred from the same "open RSVP" convention as `rsvp_responses.guest_id`. |
| `moderation_status` | TEXT | NO | — | Values used in filters: `'pending'`, `'approved'`, `'rejected'` (PHASE11 §9.4) | Cited directly. |
| `is_spam` | BOOLEAN | NO | `FALSE` | — | Cited: `.eq('is_spam', false)` (PHASE11 §9.4). |
| `submitted_at` | TIMESTAMPTZ | NO | `NOW()` | — | Cited: `.gte('submitted_at', dateFrom)` (PHASE11 §9.4). |

**Flagged gap:** no message/wish/content text column is cited for `guestbook_entries` anywhere in the available documents. A guestbook cannot function without one; PHASE9_RSVP_GUESTBOOK.md is authoritative for it. This specification records only the columns literally cited.

**Deferred (not created — referenced by name/output-column only, full definition not given):**
- `rsvp_daily_trend`, `rsvp_by_category` (PHASE9 §9.2, queried with `.select('*')` only — no column names given).
- `rsvp_response_rate` — partially known output columns: `invitation_id`, `total_tracked`, `responded` (PHASE11 §7.2), but no underlying view logic is given.
- `guest_rsvp_status` — partially known: `guest_id`, `invitation_id`, `derived_status` (PHASE11 §8.4).
- `guest_checkin_status` — partially known: `guest_id`, `is_checked_in` (PHASE11 §8.4, §7.2).
- `get_rsvp_summary(p_invitation_id)` RPC — referenced and consumed (PHASE9 §3.2, reused PHASE11 §7.2) but its body and the `RsvpSummary` return type are never given.

### 5.4 Package Domain — extension and new tables

**`packages` — ADD COLUMNS:**
| Column | Type | Nullable | Default | Constraint | Source |
|---|---|---|---|---|---|
| `status` | TEXT | NO | — | At minimum supports `'active'`; full enumeration not cited | Cited: `.eq('status', 'active')` (PHASE10 §3.3, §10.2). **Coexistence note:** PHASE1's original `is_active BOOLEAN` column is preserved unchanged (additive-only rule, §objectives) since no document explicitly retires it; both columns exist side by side until a future phase clarifies. |
| `is_public` | BOOLEAN | NO | `TRUE` | — | Cited: `.eq('is_public', true)` (PHASE10 §3.3, §10.2). |
| `price_lifetime` | NUMERIC(10,2) | YES | NULL | — | Cited: `pkg.price_lifetime ?? pkg.price_monthly * 24` (PHASE10 §3.1). |
| `max_team_members` | INTEGER | NO | — | `-1` = unlimited, per the existing `max_*` column convention | Cited: `pkg.max_team_members` (PHASE10 §10.3). |

**`tenant_subscriptions` — ADD COLUMNS:**
| Column | Type | Nullable | Default | Constraint | Source |
|---|---|---|---|---|---|
| `trial_ends_at` | TIMESTAMPTZ | YES | NULL | — | Cited: set to `null` on activation (PHASE10 §9.1). |
| `grace_ends_at` | TIMESTAMPTZ | YES | NULL | — | Cited: PHASE10 §9.1 (cleared on activation), §11.2 (`grace_ends_at: graceEnd.toISOString()`). |
| `pending_downgrade_package_id` | UUID | YES | NULL | REFERENCES `packages(id)` | Cited: PHASE10 §9.1, §10.2, §11.2. |
| `auto_renew` | BOOLEAN | NO | `TRUE` | — | Cited: `auto_renew: order.billing_cycle !== 'lifetime'` (PHASE10 §9.1); queried `.eq('auto_renew', true)` (§11.2). |
| `cancelled_at` | TIMESTAMPTZ | YES | NULL | — | Cited: PHASE10 §12.3. |
| `cancel_reason` | TEXT | YES | NULL | — | Cited: `cancel_reason: 'refunded'` (PHASE10 §12.3). |

**New table `add_ons`:**
| Column | Type | Nullable | Default | Constraint | Source |
|---|---|---|---|---|---|
| `id` | UUID | NO | `gen_random_uuid()` | PRIMARY KEY | Standard pattern; implied by `addOn.id` usage (PHASE10 §3.4). |
| `name` | TEXT | NO | — | — | Cited: `addOn.name` (PHASE10 §3.4, §6.1). |
| `price` | NUMERIC(10,2) | NO | — | — | Cited: `addOn.price * parsed.data.quantity` (PHASE10 §3.4). |
| `currency` | TEXT | NO | `'IDR'` | — | Cited: `addOn.currency` (PHASE10 §3.4). |
| `billing_cycle` | TEXT | NO | — | — | Cited: `addOn.billing_cycle` (PHASE10 §3.4, §9.1). |
| `is_active` | BOOLEAN | NO | `TRUE` | — | Cited: `.eq('is_active', true)` (PHASE10 §3.4). |
| `is_stackable` | BOOLEAN | NO | `FALSE` | — | Cited: `addOn.is_stackable` (PHASE10 §3.4). |

**New table `tenant_add_ons`:**
| Column | Type | Nullable | Default | Constraint | Source |
|---|---|---|---|---|---|
| `id` | UUID | NO | `gen_random_uuid()` | PRIMARY KEY | Standard pattern. |
| `tenant_id` | UUID | NO | — | REFERENCES `tenants(id)` | Cited: `.eq('tenant_id', auth.user.tenantId)` (PHASE10 §3.4). |
| `add_on_id` | UUID | NO | — | REFERENCES `add_ons(id)` | Cited: `.eq('add_on_id', addOn.id)` (PHASE10 §3.4). |
| `quantity` | INTEGER | NO | `1` | — | Cited: PHASE10 §9.1 insert (`quantity: 1`). |
| `status` | TEXT | NO | `'active'` | At minimum `'active'` is a valid value | Cited: `.eq('status', 'active')` (PHASE10 §3.4). |
| `starts_at` | TIMESTAMPTZ | NO | `NOW()` | — | Cited: PHASE10 §9.1. |
| `expires_at` | TIMESTAMPTZ | YES | NULL | — | Cited: PHASE10 §9.1 (`null` for non-expiring cycles). |
| `order_id` | UUID | NO | — | REFERENCES `orders(id)` | Cited: PHASE10 §9.1. |

**Deferred (not created):** `package_feature_snapshot` — referenced as an existing materialized view (PHASE10 §18.5, PHASE11 §18.4, citing PHASE5 §12.2) with no column given anywhere.

### 5.5 Payment Domain — referenced only (no migration in this milestone)

Full canonical definitions for `orders` (v2), `payment_transactions`, `invoices`, `invoice_sequences`, `webhook_logs`, `refund_requests`, `commission_ledger`, `commission_payouts` are given completely, with no gap, in PHASE10_PAYMENT_SYSTEM.md §2 and §13.1 — see §18 below for the consolidated reference. They are not reproduced again here to avoid contradiction risk; they remain governed verbatim by PHASE10 and are migrated at Phase L (`091`–`105`).

**New tables cited by PHASE10 but governed by the Package Domain conceptually, and by the Payment Domain's own ERD placement — defined here since PHASE10 requires them and no other document does:**

**New table `vouchers`:**
| Column | Type | Nullable | Default | Constraint | Source |
|---|---|---|---|---|---|
| `id` | UUID | NO | `gen_random_uuid()` | PRIMARY KEY | Standard pattern. |
| `code` | TEXT | NO | — | UNIQUE (implied by lookup-by-code usage) | Cited: `.eq('code', code.toUpperCase().trim())` (PHASE10 §3.5). |
| `is_active` | BOOLEAN | NO | `TRUE` | — | Cited: `.eq('is_active', true)` (PHASE10 §3.5). |
| `valid_from` | TIMESTAMPTZ | NO | — | — | Cited: `.lte('valid_from', now)` (PHASE10 §3.5). |
| `valid_until` | TIMESTAMPTZ | YES | NULL | — | Cited: `voucher.valid_until` (PHASE10 §3.5). |
| `max_uses` | INTEGER | YES | NULL | NULL = unlimited | Cited: `voucher.max_uses !== null` (PHASE10 §3.5). |
| `used_count` | INTEGER | NO | `0` | — | Cited: `voucher.used_count` (PHASE10 §3.5), incremented via `increment_voucher_used_count` RPC (§3.3). |
| `applicable_packages` | JSONB or TEXT[] | YES | NULL | — | Cited: `voucher.applicable_packages?.length`, `.includes(pkg?.slug)` (PHASE10 §3.5). |
| `applicable_cycles` | JSONB or TEXT[] | YES | NULL | — | Cited: `voucher.applicable_cycles?.length`, `.includes(billingCycle)` (PHASE10 §3.5). |
| `discount_type` | TEXT | NO | — | Values: `'percentage'`, `'fixed'` | Cited: `voucher.discount_type` (PHASE10 §3.5, §3.1). |
| `discount_value` | NUMERIC | NO | — | — | Cited: `voucher.discount_value` (PHASE10 §3.5). |
| `description` | TEXT | YES | NULL | — | Cited: `.select('code, description')` (PHASE10 §6.1). |

**New table `voucher_redemptions`:**
| Column | Type | Nullable | Default | Constraint | Source |
|---|---|---|---|---|---|
| `id` | UUID | NO | `gen_random_uuid()` | PRIMARY KEY | Standard pattern. |
| `voucher_id` | UUID | NO | — | REFERENCES `vouchers(id)` | Cited: PHASE10 §3.3 insert. |
| `order_id` | UUID | NO | — | REFERENCES `orders(id)` | Cited: PHASE10 §3.3 insert. |
| `tenant_id` | UUID | NO | — | REFERENCES `tenants(id)` | Cited: PHASE10 §3.3 insert, and `.eq('tenant_id', tenantId)` (§3.5 redemption-count check). |
| `discount_applied` | NUMERIC(14,2) | NO | — | — | Cited: PHASE10 §3.3 insert. |
| `created_at` | TIMESTAMPTZ | NO | `NOW()` | — | Standard pattern (used implicitly by redemption-count query). |

### 5.6 Analytics Domain — baseline (M2) and new tables (referenced only, Phase M)

**New table `invitation_events` (baseline — PHASE2 Domain 8, cited PHASE11 PART1 §1.2, §3.1):**
| Column | Type | Nullable | Default | Constraint | Source |
|---|---|---|---|---|---|
| `id` | BIGSERIAL | NO | auto | PRIMARY KEY | "BIGSERIAL, append-only" (PHASE11 PART1 §1.2). |
| `invitation_id` | UUID | NO | — | REFERENCES `invitations(id)` | Cited throughout PHASE11 §4.3, §5.2. |
| `tenant_id` | UUID | NO | — | REFERENCES `tenants(id)` | Cited: insert in PHASE11 §4.3. |
| `event_type` | TEXT | NO | — | CHECK IN baseline set below | PHASE11 §4.1 reproduces PHASE2's baseline CHECK verbatim before extending it. |
| `guest_id` | UUID | YES | NULL | REFERENCES `guests(id)` | Cited PHASE11 §4.3, §8.1. |
| `session_id` | TEXT | NO | — | — | Cited PHASE11 §4.2, §4.3, §5.2. |
| `metadata` | JSONB | NO | `'{}'` | — | Cited PHASE11 §4.3, §5.2. |
| `created_at` | TIMESTAMPTZ | NO | `NOW()` | — | Cited PHASE11 §5.2 (`created_at` filtered by day range). |

**Baseline `event_type` CHECK (PHASE2, reproduced verbatim by PHASE11 §4.1 before its own extension):**
```
CHECK (event_type IN (
  'page_view', 'rsvp_open', 'rsvp_submit',
  'guestbook_submit', 'music_play', 'gallery_view',
  'qr_scan', 'gift_view', 'share_click'
))
```
The three additional values (`section_scroll`, `whatsapp_share_click`, `session_end`) are added by Phase M migration `114`, **not** here.

**New table `invitation_analytics` (baseline daily rollup — PHASE2 Domain 8, cited PHASE11 PART1 §3.1):**
| Column | Type | Nullable | Default | Constraint | Source |
|---|---|---|---|---|---|
| `invitation_id` | UUID | NO | — | REFERENCES `invitations(id)`; part of composite identity with `date` | Cited PHASE11 §5.2 upsert (`onConflict: 'invitation_id,date'`). |
| `tenant_id` | UUID | NO | — | REFERENCES `tenants(id)` | Cited PHASE11 §5.2. |
| `date` | DATE | NO | — | — | Cited PHASE11 §5.2, §6.2, §6.3. |
| `views` | INTEGER | NO | `0` | — | Cited PHASE11 §5.2. |
| `unique_visitors` | INTEGER | NO | `0` | — | Cited PHASE11 §5.2, §6.2. |
| `rsvp_attending` | INTEGER | NO | `0` | — | Cited PHASE11 §5.2, §6.2, §6.3. |
| `rsvp_not_attending` | INTEGER | NO | `0` | — | Cited PHASE11 §5.2, §6.3. |
| `rsvp_maybe` | INTEGER | NO | `0` | — | Cited PHASE11 §5.2, §6.3. |
| `guestbook_count` | INTEGER | NO | `0` | — | Cited PHASE11 §5.2, §6.3. |
| `device_mobile` | INTEGER | NO | `0` | — | Cited PHASE11 §5.2, §13.5. |
| `device_desktop` | INTEGER | NO | `0` | — | Cited PHASE11 §5.2, §13.5. |
| `device_tablet` | INTEGER | NO | `0` | — | Cited PHASE11 §5.2, §13.5. |
| `top_referrers` | JSONB | NO | `'[]'` | Shape: `[{ referrer, count }]` | Cited PHASE11 §3.7 type, §5.2. |
| — | — | — | — | UNIQUE (invitation_id, date) — implied by the upsert `onConflict` target | PHASE11 §5.2. |

**New table `qr_codes` (PHASE2 Domain 7, cited PHASE11 §5.3, §5.4):**
| Column | Type | Nullable | Default | Constraint | Source |
|---|---|---|---|---|---|
| `id` | UUID | NO | `gen_random_uuid()` | PRIMARY KEY | Standard pattern. |
| `invitation_id` | UUID | NO | — | REFERENCES `invitations(id)` | Cited: `.eq('qr_code.invitation_id', invitationId)` (PHASE11 §5.3). |
| `tenant_id` | UUID | NO | — | REFERENCES `tenants(id)` | Cited: `.eq('qr_code.tenant_id', tenantId)` (PHASE11 §5.4). |

**Flagged gap:** the actual scannable code/token value column is not cited anywhere in the available documents. PHASE2_DATABASE.md is authoritative for it.

**New table `qr_checkins` (PHASE2 Domain 7, cited PHASE11 §5.3, §8.4, §14.3):**
| Column | Type | Nullable | Default | Constraint | Source |
|---|---|---|---|---|---|
| `id` | UUID | NO | `gen_random_uuid()` | PRIMARY KEY | Standard pattern. |
| `qr_code_id` | UUID | NO | — | REFERENCES `qr_codes(id)` | Inferred from the PostgREST embed syntax `qr_code:qr_codes!inner(...)` (PHASE11 §5.3, §5.4, §14.3), which requires a real FK column; by the same naming convention used unambiguously elsewhere in these documents, the column is named `qr_code_id`. Flagged as an inference from convention, not a verbatim citation of the column name itself. |
| `checked_in_at` | TIMESTAMPTZ | NO | `NOW()` | — | Cited: `.gte('checked_in_at', dayStart)` (PHASE11 §5.3, §14.3). |

**Referenced only, fixed at Phase M (`106`–`119`), not migrated here:** `invitation_analytics_extended`, `tenant_analytics_daily`, `reseller_analytics_daily`, `platform_analytics_daily`, `analytics_export_jobs`, `rollup_job_runs` — full definitions are given completely in PHASE11_ANALYTICS.md PART1 §3 and PART3 §3.6/§5.6, with no gap. See §19 for the consolidated reference.

### 5.7 Theme Domain

`invitation_themes` is unchanged from M1 (§5.1 cross-reference). **Deferred (not created):** `theme_experiments` — referenced as "already prepared" (PHASE11 §18.6, citing PHASE6 §20.2) with no column given anywhere.

### 5.8 Admin Domain — extension

**`audit_logs` — ADD COLUMN:**
| Column | Type | Nullable | Default | Constraint | Source |
|---|---|---|---|---|---|
| `actor_role` | TEXT | YES | NULL | — | Cited: `actor_role: 'system'` on insert (PHASE10 §9.1 `activateSubscriptionFromOrder`). |

No other admin-domain table is cited in any available document. Impersonation (PHASE1 §8.3) is described as a stateless signed token with no backing table.

## 6. Foreign Key Architecture

Consolidated, whole-schema list. M1's foreign keys are recapped from M1_CORE_MULTI_TENANT_FOUNDATION.md §13/§15 (unchanged); M2 additions are new.

| Table.column | References | ON DELETE | Source |
|---|---|---|---|
| *(M1 — unchanged, recapped)* | | | |
| `users.id` | `auth.users(id)` | CASCADE | M1 |
| `users.tenant_id` | `tenants(id)` | NO ACTION | M1 |
| `resellers.owner_user_id` | `users(id)` | NO ACTION | M1 |
| `reseller_tenants.reseller_id` | `resellers(id)` | NO ACTION | M1 |
| `reseller_tenants.tenant_id` | `tenants(id)` | NO ACTION | M1 |
| `package_features.package_id` | `packages(id)` | NO ACTION | M1 |
| `tenant_subscriptions.tenant_id` | `tenants(id)` | NO ACTION | M1 |
| `tenant_subscriptions.package_id` | `packages(id)` | NO ACTION | M1 |
| `tenant_subscriptions.reseller_id` | `resellers(id)` | NO ACTION | M1 |
| `feature_flags.tenant_id` | `tenants(id)` | NO ACTION | M1 |
| `feature_flags.created_by` | `users(id)` | NO ACTION | M1 |
| `invitations.tenant_id` | `tenants(id)` | NO ACTION | M1 |
| `invitations.created_by` | `users(id)` | NO ACTION | M1 |
| `invitations.theme_id` | `invitation_themes(id)` | NO ACTION | M1 |
| `invitation_sections.invitation_id` | `invitations(id)` | CASCADE | M1 |
| `guests.invitation_id` | `invitations(id)` | CASCADE | M1 |
| `guests.tenant_id` | `tenants(id)` | NO ACTION | M1 |
| `rsvp_responses.invitation_id` | `invitations(id)` | CASCADE | M1 |
| `rsvp_responses.guest_id` | `guests(id)` | NO ACTION | M1 |
| `orders.tenant_id` (PHASE1 shape) | `tenants(id)` | NO ACTION | M1 |
| `orders.reseller_id` (PHASE1 shape) | `resellers(id)` | NO ACTION | M1 |
| `orders.package_id` (PHASE1 shape) | `packages(id)` | NO ACTION | M1 |
| `audit_logs.tenant_id` | `tenants(id)` | NO ACTION | M1 |
| `audit_logs.user_id` | `users(id)` | NO ACTION | M1 |
| *(M2 — new)* | | | |
| `guests.group_id` | `guest_groups(id)` | not specified | §5.2 |
| `guests.category_id` | unspecified table | not specified | §5.2 (flagged) |
| `guestbook_entries.invitation_id` | `invitations(id)` | not specified | §5.3 |
| `guestbook_entries.guest_id` | `guests(id)` | not specified | §5.3 |
| `tenant_subscriptions.pending_downgrade_package_id` | `packages(id)` | not specified | §5.4 |
| `tenant_add_ons.tenant_id` | `tenants(id)` | not specified | §5.4 |
| `tenant_add_ons.add_on_id` | `add_ons(id)` | not specified | §5.4 |
| `tenant_add_ons.order_id` | `orders(id)` | not specified | §5.4 |
| `voucher_redemptions.voucher_id` | `vouchers(id)` | not specified | §5.5 |
| `voucher_redemptions.order_id` | `orders(id)` | not specified | §5.5 |
| `voucher_redemptions.tenant_id` | `tenants(id)` | not specified | §5.5 |
| `invitation_events.invitation_id` | `invitations(id)` | not specified | §5.6 |
| `invitation_events.tenant_id` | `tenants(id)` | not specified | §5.6 |
| `invitation_events.guest_id` | `guests(id)` | not specified | §5.6 |
| `invitation_analytics.invitation_id` | `invitations(id)` | not specified | §5.6 |
| `invitation_analytics.tenant_id` | `tenants(id)` | not specified | §5.6 |
| `qr_codes.invitation_id` | `invitations(id)` | not specified | §5.6 |
| `qr_codes.tenant_id` | `tenants(id)` | not specified | §5.6 |
| `qr_checkins.qr_code_id` | `qr_codes(id)` | not specified | §5.6 (inferred name) |

**No `ON DELETE` behavior is cited for any M2 foreign key.** Per the same rule established in M1 §15, an unspecified `ON DELETE` clause defaults to Postgres `NO ACTION`. This is stated explicitly per row above rather than assumed silently.

## 7. Index Architecture

**Exact, cited indexes (none — no index is explicitly named for any M2 table in any available document).** Unlike PHASE10 §17.1 and PHASE11 §17.1, which give complete, explicit index lists for their own tables (reproduced for reference in §18/§19), no source document names a single index for `guest_groups`, `guestbook_entries`, `qr_codes`, `qr_checkins`, `add_ons`, `tenant_add_ons`, `vouchers`, `voucher_redemptions`, `invitation_events` (baseline), or `invitation_analytics` (baseline).

**Recommended supplementary indexes (explicitly flagged as inference, not citation).** These follow the single consistent indexing convention observed on every other table in this schema (the FK column used in the table's hot-path lookup is indexed):

| Recommended index | Table | Column(s) | Rationale |
|---|---|---|---|
| `idx_guestbook_invitation_id` | guestbook_entries | invitation_id | Matches `idx_rsvp_invitation_id`'s precedent on the sibling RSVP table. |
| `idx_guests_group_id` | guests | group_id | Supports the `rsvp_by_group`/engagement join pattern cited in PHASE11 §8.1, §9.2. |
| `idx_qr_codes_invitation_id` | qr_codes | invitation_id | Matches the query pattern cited in PHASE11 §5.3. |
| `idx_qr_checkins_qr_code_id` | qr_checkins | qr_code_id | Matches the join pattern cited in PHASE11 §5.3, §14.3. |
| `idx_invitation_events_invitation_created` | invitation_events | (invitation_id, created_at DESC) | PHASE11 §17.2 explicitly states this composite index is **already assumed to exist** as `idx_events_invitation` when describing rollup query cost — confirming the index's existence is presupposed even though its creation isn't shown. Recorded here as the closest thing to a citation for this table. |
| `idx_invitation_analytics_inv_date` | invitation_analytics | (invitation_id, date) | Matches the `UNIQUE` target and the per-invitation date-range read pattern used throughout PHASE11 §6, §7. |
| `idx_tenant_add_ons_tenant_id` | tenant_add_ons | tenant_id | Matches the lookup pattern cited in PHASE10 §3.4. |

These are recommendations only; they are not promoted to "exact, required" status because no source document names them.

## 8. Unique Constraints

**Exact, cited:**
- `invitation_analytics(invitation_id, date)` — implied by the `onConflict: 'invitation_id,date'` upsert target (PHASE11 §5.2).
- `vouchers.code` — implied by unique lookup-by-code usage (PHASE10 §3.5); not stated as `UNIQUE` in prose, but functionally required for the lookup pattern shown to be correct.

**No other UNIQUE constraint is cited for any M2 table.** In particular, no source document states whether `guest_groups.name` must be unique per scope, whether `add_ons` has a unique slug/code, or whether `qr_codes` has a unique token. None is added here without a citation.

## 9. Check Constraints

**Exact, cited:**
- `invitation_events.event_type` — baseline CHECK exactly as reproduced in §5.6.
- `guestbook_entries.moderation_status` — values observed in use: `'pending'`, `'approved'`, `'rejected'` (PHASE11 §9.4). Presented as the observed value set, not asserted as the complete enumeration, since no `CREATE TABLE` statement with the literal CHECK is given.

**Inferred-but-flagged (not asserted as a hard CHECK without further confirmation):**
- `packages.status` — only `'active'` is confirmed by citation; other values are unknown.
- `tenant_add_ons.status` — only `'active'` is confirmed by citation; other values are unknown.
- `vouchers.discount_type` — `'percentage'` and `'fixed'` are both cited (PHASE10 §3.1, §3.5), so this one **is** asserted as a two-value CHECK: `discount_type IN ('percentage', 'fixed')`.

No CHECK constraint is added to any column where the available documents show only a single observed value, since asserting a full enumeration from one example would be inventing structure, not resolving a cited gap.

## 10. Soft Delete Strategy

**Confirmed convention (PHASE12 §13.5, citing PHASE7–11):** "Soft deletes (`deleted_at` columns, already used throughout PHASE7–11) mean accidental deletion is recoverable within the retention window without any infrastructure-level restore." This is an approved, cited architectural decision, not introduced here — M2 applies it to the two tables where direct query evidence confirms the column exists:

| Table | `deleted_at` added? | Evidence |
|---|---|---|
| `invitations` | Yes (§5.1) | `.is('deleted_at', null)` cited directly. |
| `guests` | Yes (§5.2) | `.is('deleted_at', null)` and `WHERE g.deleted_at IS NULL` cited directly. |
| `rsvp_responses` | Not cited | No `.is('deleted_at', ...)` filter appears anywhere for this table in the available documents. Not added. |
| `guestbook_entries` | Not cited | Same — not added. |
| All Payment Domain tables | Governed by PHASE10, unchanged here | PHASE10 §10.3 cites `.is('deleted_at', null)` on `invitations` only, not on any billing table. |

**Rule going forward:** a `deleted_at` column is added to a table in this specification only where a literal query filter against it is cited. Tables without such a citation are not assumed to support soft delete.

## 11. Audit Strategy

`audit_logs` (M1 §13) remains the single audit table. This milestone's only change is the addition of `actor_role` (§5.8), confirmed necessary because PHASE10 §9.1 writes a row with that field populated (`'system'`) during automated subscription activation — an action M2 does not itself perform, but whose downstream table shape M2 must accommodate. No new audit table, no new action-naming convention, and no new logging trigger is introduced in this milestone; M1 §23's conclusion stands: concrete `action` string values are established by whichever phase first performs a logged action.

## 12. Tenant Ownership Rules

Extends M1 §10 with the new/changed tables:

| Resource | Owning tenant determined by | Source |
|---|---|---|
| `guest_groups` row | **Not determinable** — no scoping column is cited (§5.2 flagged gap) | §5.2 |
| `guestbook_entries` row | Indirect only — `invitation_id → invitations.tenant_id` | §5.3 |
| `add_ons` row | Not tenant-scoped — platform-level catalog, same pattern as `packages` | §5.4 |
| `tenant_add_ons` row | `tenant_add_ons.tenant_id` (direct) | §5.4 |
| `vouchers` row | Not tenant-scoped — platform-level, same pattern as `packages` | §5.5 |
| `voucher_redemptions` row | `voucher_redemptions.tenant_id` (direct) | §5.5 |
| `invitation_events` row | `invitation_events.tenant_id` (direct, denormalized — same rationale as `guests.tenant_id` in M1 §10) | §5.6 |
| `invitation_analytics` row | `invitation_analytics.tenant_id` (direct, denormalized) | §5.6 |
| `qr_codes` row | `qr_codes.tenant_id` (direct, denormalized) | §5.6 |
| `qr_checkins` row | Indirect only — `qr_code_id → qr_codes.tenant_id` | §5.6 |

**Unresolved ownership question (flagged, not decided here):** because `guest_groups` carries no scoping column, its rows are, as specified, effectively platform-global once created — any guest in any invitation could theoretically be assigned to any group row, since nothing in the schema prevents it. This is almost certainly not the intended behavior, but inventing a scoping column without a citation would violate this document's own method. PHASE8_GUEST_MANAGEMENT.md must resolve this before `guest_groups` is used in production.

## 13. Data Retention Rules

No new retention rule is introduced in this milestone. The retention rules governing the new analytics-baseline tables are already fixed by citation:

- `invitation_events` (baseline): "Events older than 90 days... should be moved to cold storage or deleted" (PHASE2 §9.3, cited PHASE11 PART1 §1.3) — the **package-driven, non-hardcoded** version of this rule (reading `analytics_advanced.config.retention_days`) is implemented by the purge job at Phase M, not here. M2 creates the table; it does not implement the purge job.
- `invitation_analytics` (baseline): "the permanent record" — never purged (PHASE2 §9.3, same citation).
- All other M2 tables: no retention rule is cited. None is invented here.

## 14. Invitation Domain Schema

**Tables:** `invitations` (M1 base + `deleted_at`, §5.1), `invitation_sections` (M1, unchanged), `invitation_themes` (M1, unchanged).

**Relationships:** `invitations.theme_id → invitation_themes.id` (required); `invitation_sections.invitation_id → invitations.id` (CASCADE); both `tenant_id` and `created_by` live directly on `invitations` (M1 §10, §21).

**Ownership rule (unchanged from M1 §21):** an `invitations` row's tenant is fixed at creation via `tenant_id`; `created_by` records the acting user. No transfer-of-ownership mechanism is specified anywhere in the available documents.

**M2 addition's effect on the domain:** soft-deleted invitations (`deleted_at IS NOT NULL`) must be excluded from every owner-facing and public-facing query going forward — this is the operative meaning of the convention cited in §10, and it supersedes a hard `DELETE` as the deletion mechanism for this table from this milestone onward.

## 15. Guest Domain Schema

**Tables:** `guests` (M1 base + `group_id`, `category_id`, `deleted_at`, §5.2), `guest_groups` (new, §5.2).

**Relationships:** `guests.invitation_id → invitations.id` (CASCADE); `guests.tenant_id → tenants.id` (denormalized, must agree with the parent invitation's tenant — application-enforced, no DB trigger, same pattern flagged in M1 §10/§21); `guests.group_id → guest_groups.id` (nullable, optional grouping); `guests.category_id →` an unnamed table (flagged gap, §5.2).

**Ownership rule:** unchanged from M1 §10 — `guests.tenant_id` and `guests.invitation_id`'s tenant must agree; enforcement remains application-layer.

**Domain-specific gap surfaced by this milestone:** `guest_groups` has no owning tenant or invitation (§12). Until PHASE8_GUEST_MANAGEMENT.md resolves this, any UI built against `guest_groups` in a later phase must not assume group rows are naturally scoped by the RLS/ownership machinery already in place for `guests` itself.

## 16. RSVP Domain Schema

**Tables:** `rsvp_responses` (M1 base + `is_spam`, `meal_choice`, §5.3), `guestbook_entries` (new, §5.3). **Deferred:** the six view/RPC objects listed in §5.3.

**Relationships:** `rsvp_responses.invitation_id → invitations.id` (CASCADE); `rsvp_responses.guest_id → guests.id` (nullable — "null if open RSVP," M1 §13); `guestbook_entries.invitation_id → invitations.id`; `guestbook_entries.guest_id → guests.id` (nullable, same open-submission convention).

**Ownership rule:** neither table carries `tenant_id`. Tenant scoping for both is exclusively via `invitation_id → invitations.tenant_id` — this is the same join-adapted pattern M1 §12 already established for `rsvp_responses`, and it now applies identically to `guestbook_entries`.

**Spam-filtering rule (cited convention, not new):** every count/aggregate query against either table must filter `is_spam = FALSE` — this is the consistent pattern cited throughout PHASE11 §5.3, §9.2, §9.3, §9.4 for `rsvp_responses`, and the identical column now exists on `guestbook_entries` for the same purpose.

## 17. Package Domain Schema

**Tables:** `packages` (M1 base + `status`, `is_public`, `price_lifetime`, `max_team_members`, §5.4), `package_features` (M1, unchanged), `tenant_subscriptions` (M1 base + six lifecycle columns, §5.4), `feature_flags` (M1, unchanged), `add_ons` (new, §5.4), `tenant_add_ons` (new, §5.4). **Deferred:** `package_feature_snapshot`.

**Relationships:** `tenant_add_ons.tenant_id → tenants.id`; `tenant_add_ons.add_on_id → add_ons.id`; `tenant_add_ons.order_id → orders.id` (cross-domain link into the Payment Domain, §18); `tenant_subscriptions.pending_downgrade_package_id → packages.id`.

**Ownership rule:** `add_ons` is a platform-level catalog table, not tenant-scoped — identical in nature to `packages` itself (M1 §6 already established that `packages` is not tenant-scoped). `tenant_add_ons` is the tenant-scoped join recording which add-ons a given tenant has active, directly analogous to how `tenant_subscriptions` relates to `packages`.

**Coexistence flag (restated from §5.4):** `packages.is_active` (M1, original) and `packages.status` (M2, cited addition) now coexist. This specification does not decide which one is authoritative for "is this package purchasable" — that decision belongs to whichever phase (PHASE5) fully defines the package domain. Application code built in later phases must be written defensively against both until that is resolved.

## 18. Payment Domain Schema

**Referenced only — not migrated in this milestone.** Full, complete, gap-free definitions exist in PHASE10_PAYMENT_SYSTEM.md and are not restated table-by-table here to avoid any risk of transcription drift from the authoritative source. Consolidated for navigation:

| Table | Defined in | Migration (fixed, Phase L) |
|---|---|---|
| `orders` (v2 shape) | PHASE10 §2.2 | `091_orders_v2.sql` |
| `payment_transactions` | PHASE10 §2.3 | `092_payment_transactions.sql` |
| `invoices` | PHASE10 §2.4 | `093_invoices.sql` |
| `invoice_sequences` | PHASE10 §2.5 | `094_invoice_sequences.sql` |
| `webhook_logs` | PHASE10 §2.6 | `095_webhook_logs.sql` |
| `refund_requests` | PHASE10 §2.7 | `096_refund_requests.sql` |
| `commission_ledger` | PHASE10 §13.1 | `097_commission_ledger.sql` |
| `commission_payouts` | PHASE10 §13.1 | `098_commission_payouts.sql` |

**New in this milestone, placed here per PHASE10's own ERD (§2.1: "orders ── voucher_redemptions ── vouchers"):** `vouchers`, `voucher_redemptions` — fully specified in §5.5 above, migrated in M2 (§22), since PHASE10 requires them to exist but never defines them itself.

**Cross-domain link confirmed:** `orders.add_on_id → add_ons(id)` and `orders.voucher_id → vouchers(id)` are both already present in PHASE10 §2.2's own complete `orders` v2 definition — no further action needed here; they simply confirm that `add_ons` and `vouchers` (both defined in this milestone) are correctly anticipated by PHASE10's existing schema.

## 19. Analytics Domain Schema

**M2 scope (baseline, migrated here):** `invitation_events` (baseline event-type set), `invitation_analytics` (baseline daily rollup), `qr_codes`, `qr_checkins` — all fully specified in §5.6.

**Referenced only — not migrated in this milestone, fixed at Phase M:**

| Table/object | Defined in | Migration (fixed, Phase M) |
|---|---|---|
| `invitation_analytics_extended` | PHASE11 PART1 §3.2 | `106_invitation_analytics_extended.sql` |
| `tenant_analytics_daily` | PHASE11 PART1 §3.3 | `107_tenant_analytics_daily.sql` |
| `reseller_analytics_daily` | PHASE11 PART1 §3.4 | `108_reseller_analytics_daily.sql` |
| `platform_analytics_daily` | PHASE11 PART1 §3.5 | `109_platform_analytics_daily.sql` |
| `increment_view_count()` RPC | PHASE11 PART1 §5.5 | `110_increment_view_count_fn.sql` |
| `guest_engagement_summary` view | PHASE11 §8.1 | `111_guest_engagement_view.sql` |
| `rsvp_by_group` view | PHASE11 §9.2 | `112_rsvp_by_group_view.sql` |
| `get_tenant_cohort_retention()` RPC | PHASE11 §11.3 | `113_tenant_cohort_retention_fn.sql` |
| `invitation_events.event_type` extension (`section_scroll`, `whatsapp_share_click`, `session_end`) | PHASE11 §4.1 | `114_invitation_events_event_type_ext.sql` |
| `idx_events_guest_id` | PHASE11 §17.1 | `115_events_guest_id_index.sql` |
| `analytics_export_jobs` | PHASE11 PART1 §3.6 | `116_analytics_export_jobs.sql` |
| `rollup_job_runs` | PHASE11 PART1 §5.6 | `117_rollup_job_runs.sql` |
| RLS for all of the above | PHASE11 §15.3 | `118_rls_analytics_tables.sql` |
| `analytics-exports` storage bucket | PHASE11 §19.4 | `119_storage_analytics_exports_bucket.sql` |

**Why `guest_engagement_summary` and `rsvp_by_group` depend on M2 but are not built in M2:** both views join against `guests.group_id`/`guests.category_id`/`guests.deleted_at` (§5.2) — columns this milestone creates. The views themselves remain at their already-fixed `111`/`112` slots in Phase M; M2's job is only to ensure the columns they depend on exist first.

## 20. Theme Domain Schema

**Tables:** `invitation_themes` (M1, unchanged — see §14 for the Invitation Domain's joint coverage of this table). **Deferred:** `theme_experiments` (§5.7) — no column is cited anywhere; PHASE11 §18.6 confirms only that it exists and that it would be joined against `invitation_analytics_extended.section_views` by a future, not-yet-built A/B-test reporting feature. No relationship beyond "exists, joinable on some unspecified key" can be asserted.

## 21. Admin Domain Schema

**Tables:** `audit_logs` (M1 base + `actor_role`, §5.8). No other admin-domain table is cited in PHASE1, PHASE10, PHASE11, or PHASE12. Super-admin designation (M1 §8's flagged gap) remains unresolved — no document available to this milestone introduces a mechanism for it, and none is invented here.

## 22. Migration Order

**Numbering context (per M1 §25):** M1 consumed `001`–`017`. M1 reserved `018`–`090` for Phases C–J. This milestone consumes part of that reserved range. `091`–`105` (Phase L) and `106`–`119` (Phase M) remain exactly as fixed by PHASE10/PHASE11's own appendices and are **not** touched by this plan.

```
018_invitations_add_deleted_at.sql
019_guests_add_group_category_deleted_at.sql
020_create_guest_groups.sql
021_create_invitation_events.sql                  -- baseline event_type set
022_create_invitation_analytics.sql               -- baseline daily rollup
023_create_qr_codes.sql
024_create_qr_checkins.sql
025_rsvp_responses_add_is_spam_meal_choice.sql
026_create_guestbook_entries.sql
027_packages_extend_status_public_lifetime_teammembers.sql
028_tenant_subscriptions_extend_lifecycle_columns.sql
029_create_add_ons.sql
030_create_tenant_add_ons.sql
031_create_vouchers.sql
032_create_voucher_redemptions.sql
033_audit_logs_add_actor_role.sql
```

**Not migrated in this range (insufficient citation — see §2's deferred list):** `guest_import_batches`, `package_feature_snapshot`, `theme_experiments`, `rsvp_daily_trend`, `rsvp_by_category`, `rsvp_response_rate`, `guest_rsvp_status`, `guest_checkin_status`, `get_rsvp_summary()`.

**Ordering rule:** `019`–`020` together (guests extension and `guest_groups` creation) may be applied in either order at the SQL level only if the FK on `guests.group_id` is added in a separate `ALTER TABLE ... ADD CONSTRAINT` step after `020`; as written, `020` must run before the FK-bearing part of `019` to satisfy the foreign key. `023` must precede `024` (`qr_checkins.qr_code_id` FK). `029` must precede `030` (`tenant_add_ons.add_on_id` FK). `031` must precede `032` (`voucher_redemptions.voucher_id` FK).

**Remaining reserved range:** `034`–`090` stays reserved, unconsumed, for Phases D/E/G or any future addition prior to Phase L's fixed `091` start.

## 23. Seed Data Requirements

No new seed data is required beyond M1's Free-package seed (M1 §26). The tables introduced in this milestone are either:
- Operational/content tables populated by tenant or admin action in a later phase (`guest_groups`, `add_ons`, `vouchers`, `guestbook_entries`), or
- Append-only event/rollup tables with no seed concept (`invitation_events`, `invitation_analytics`, `qr_codes`, `qr_checkins`).

No source document specifies a default add-on catalog, a default voucher, or a default guest group — none is invented here.

## 24. Performance Requirements

- `invitation_events` must remain partition-pruning-friendly from its first row: every rollup-style query against it should be scoped to a single day's `created_at` range, consistent with the partitioning candidacy already flagged for this table (PHASE2 §9.1, reaffirmed PHASE11 §18.2) even though partitioning itself is not executed in this milestone.
- All M2 tables are eligible for the same read-replica routing policy already cited for analytics/dashboard SELECTs (PHASE2 §9.4, PHASE11 §18.5) once a replica exists (M1 §7.1 provisioning step) — none of the new tables require read-after-write consistency.
- Supabase query P95 < 100ms (PHASE1 §10.4) remains the standing target; the recommended indexes in §7 exist specifically to make that achievable for the new tables' anticipated access patterns.

## 25. Security Requirements

- `vouchers`, `add_ons` are platform-level catalogs; write access must be restricted to `super_admin`-gated routes once those routes exist (Phase E/F), per the existing PHASE1 §8.2 service-role containment rule — no new exception is created.
- `qr_checkins.checked_in_at` and `invitation_events` rows must never be writable by an anonymous client directly against the database; all inserts must flow through server-side code, consistent with the ingestion-endpoint pattern PHASE11 §4.3 establishes (built at Phase M, not M2 — M2 only creates the table).
- The `guestbook_entries.is_spam` and `rsvp_responses.is_spam` columns must be treated identically by any future moderation tooling — both now share the same shape.

## 26. RLS Coverage Matrix

Whole-system view, current as of the end of this milestone.

| Table | RLS enabled? | Policy basis |
|---|---|---|
| `invitations` | ✅ | M1 §16 — `tenant_isolation`, `public_invitation_read`, `reseller_client_read` |
| `guests` | ✅ | M1 §16 — `tenant_isolation` (direct column) |
| `rsvp_responses` | ✅ | M1 §16 — `tenant_isolation` (join-adapted) |
| `tenants`, `users`, `resellers`, `reseller_tenants`, `packages`, `package_features`, `tenant_subscriptions`, `feature_flags`, `invitation_themes`, `invitation_sections`, `orders` (PHASE1 shape), `audit_logs` | ❌ Not specified | M1 §12/§16 flagged gap — unchanged |
| `guest_groups`, `guestbook_entries`, `qr_codes`, `qr_checkins`, `add_ons`, `tenant_add_ons`, `vouchers`, `voucher_redemptions`, `invitation_events` (baseline), `invitation_analytics` (baseline) | ❌ Not specified | No RLS citation exists for any M2 table in any available document — flagged here, not invented |
| `payment_transactions`, `invoices`, `refund_requests`, `commission_ledger`, `commission_payouts` | ✅ (governed by PHASE10, not this milestone) | PHASE10 §15.3 |
| `webhook_logs` | ❌ Explicit default-deny by design (not a gap — a deliberate decision) | PHASE10 §15.3 |
| `invitation_analytics_extended`, `tenant_analytics_daily`, `reseller_analytics_daily`, `analytics_export_jobs` | ✅ (governed by PHASE11, not this milestone) | PHASE11 §15.3 |
| `platform_analytics_daily`, `rollup_job_runs` | ❌ Explicit default-deny by design (not a gap) | PHASE11 §15.3 |

**Net effect of this milestone on RLS coverage:** zero tables move from "not covered" to "covered." This milestone adds ten more tables to the already-flagged "not specified" category rather than closing it, because no citation exists to close it with. This is surfaced explicitly so it is not mistaken for an oversight in a later phase.

## 27. Data Integrity Requirements

- `guests.tenant_id` must equal the `tenant_id` of the `invitations` row referenced by `guests.invitation_id` — application-enforced only (no DB trigger specified anywhere), unchanged from M1 §21.
- `guests.group_id`, if set, should reference a `guest_groups` row meaningfully scoped to the same invitation/tenant as the guest — **not enforceable as specified**, because `guest_groups` has no scoping column (§12). This is a standing integrity risk until PHASE8_GUEST_MANAGEMENT.md resolves it.
- `rsvp_responses.guest_id` and `guestbook_entries.guest_id`, if set, should belong to the same `invitation_id` as the response/entry row itself — not enforced by any DB constraint cited anywhere; flagged as application-layer responsibility, consistent with the same unenforced pairing already flagged for `invitations.created_by` in M1 §21.
- `tenant_subscriptions.pending_downgrade_package_id`, if set, must reference an existing, presumably active `packages` row — no CHECK beyond the FK itself is cited.
- `orders.add_on_id` XOR `orders.package_id` is already enforced by PHASE10 §2.2's `chk_order_item` CHECK constraint on the v2 `orders` shape — this is Phase L's responsibility, not re-stated as a new constraint here, only confirmed compatible with this milestone's `add_ons` table.

## 28. Acceptance Criteria

- [ ] Every table/column in §5 exists in staging and production with exactly the type, nullability, and default specified — no more, no less.
- [ ] No column already specified in PHASE1 or M1 has been renamed, retyped, or dropped.
- [ ] `packages.is_active` (M1) and `packages.status` (M2) both exist simultaneously, per the coexistence flag in §5.4/§17.
- [ ] All foreign keys in §6's "M2 — new" block exist; all default to `NO ACTION` unless stated otherwise (none is).
- [ ] The baseline `invitation_events.event_type` CHECK contains exactly the nine PHASE2 values in §5.6 — not the twelve-value Phase M extension.
- [ ] Migrations `018`–`033` apply cleanly, in order, to staging then production.
- [ ] None of the explicitly deferred tables/views/functions in §2/§5/§22 has been created.
- [ ] §26's RLS Coverage Matrix accurately reflects that zero new tables gained RLS coverage in this milestone.
- [ ] The recommended (non-cited) indexes in §7 are documented as recommendations in code review, not silently treated as a requirement equivalent to a cited index.
- [ ] `guest_groups`'s missing scoping column is documented as an open risk in the team's tracking system, not silently closed.
- [ ] `guestbook_entries`'s missing content column is documented as an open risk, not silently closed.

## 29. Completion Checklist

- [ ] §3–§4 (domain model, ERD) reflect the full post-M2 schema accurately.
- [ ] §5 canonical definitions match what was actually migrated, table for table, column for column.
- [ ] §6–§9 (FK/index/unique/check architecture) are consolidated and internally consistent with M1's equivalents.
- [ ] §10–§13 (soft delete, audit, ownership, retention) carry forward M1's rules unchanged and extend them only where cited.
- [ ] §14–§21 (domain schemas) each correctly cross-reference §5 rather than restate it.
- [ ] §22 migrations are applied in the exact order given, respecting the FK-ordering notes.
- [ ] §26 RLS matrix is reviewed by whoever owns Phase D (Authentication & Authorization) before that phase begins, since it inherits this milestone's coverage gaps.
- [ ] Tag `v0.3.0` once every item in §28 is verified.

**Once every box above is checked, Phase D (Authentication & Authorization) may begin.**

---

*End of M2_DATABASE_DOMAIN_COMPLETION.md*
