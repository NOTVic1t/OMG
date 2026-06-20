# BUILD_ORDER.md
# Wedding Invitation SaaS Platform — Executable Build Order

> **Version:** 1.0.0
> **Source of truth:** PHASE1_ARCHITECTURE.md, PHASE10_PAYMENT_SYSTEM.md, PHASE11_ANALYTICS.md, PHASE12_DEPLOYMENT.md, IMPLEMENTATION_ROADMAP.md
> **Scope note:** This document does not redesign any architectural decision. It converts IMPLEMENTATION_ROADMAP.md's milestones (M0–M12, MVP, Launch) into a literal, file-level build sequence. Every table name, file path, API route, component name, and service name below is reproduced **exactly** as it appears in the source documents. Where a milestone covers a phase whose full specification is not in this document set (PHASE2–9), this document lists only the sub-deliverables explicitly cited by name in PHASE1/10/11/12 — marked **[EXTERNAL SPEC]** — and does not invent file paths for them.
>
> Mapping to IMPLEMENTATION_ROADMAP.md milestones is shown as `(= M_)` next to each phase letter for traceability between the two documents.

---

## 1. Development Phases

| Phase | Name | Roadmap Milestone |
|---|---|---|
| **A** | Program & Infrastructure Bootstrap | `= M0` |
| **B** | Core Multi-Tenant Foundation | `= M1` |
| **C** | Database Domain Completion **[EXTERNAL SPEC]** | `= M2` |
| **D** | Authentication & Authorization **[EXTERNAL SPEC]** | `= M3` |
| **E** | Admin Architecture **[EXTERNAL SPEC]** | `= M4` |
| **F** | Package & Feature System **[EXTERNAL SPEC]** | `= M5` |
| **G** | Theme System **[EXTERNAL SPEC]** | `= M6` |
| **H** | Invitation Management **[EXTERNAL SPEC]** | `= M7` |
| **I** | Guest Management **[EXTERNAL SPEC]** | `= M8` |
| **J** | RSVP & Guestbook **[EXTERNAL SPEC]** | `= M9` |
| **K** | ⭐ MVP Consolidation & Hardening | `= MVP gate` |
| **L** | Payment System | `= M10` |
| **M** | Analytics & Reporting System | `= M11` |
| **N** | Production Deployment & Operations | `= M12` |
| **O** | 🚀 Production Launch | `= LAUNCH gate` |

Strict build order: **A → B → C → D → E → F → G → H → I → J → K → L → M → N → O.**
No phase may begin before all phases listed in its **Dependencies** field are complete.

---

## 2. Build Order

### Phase A — Program & Infrastructure Bootstrap `(= M0)`

**Goal:** Stand up the infrastructure substrate (PHASE12 §3, §4, §5, §8) so every later phase has a real place to deploy to.

**Files to create:**
```
infra/terraform/modules/cloudflare/
infra/terraform/modules/vercel/
infra/terraform/modules/upstash/
infra/terraform/modules/monitoring/
infra/terraform/environments/production/
infra/terraform/environments/staging/
infra/terraform/environments/preview/
infra/terraform/backend.tf
infra/terraform/variables.tf
infra/supabase/migrations/            (empty, ready for Phase B)
infra/supabase/seed.sql
infra/supabase/config.toml
.env.example
wedding-saas/next.config.ts
wedding-saas/tailwind.config.ts
wedding-saas/tsconfig.json
wedding-saas/package.json
lib/supabase/client.ts
lib/supabase/server.ts
lib/supabase/middleware.ts
```

**Database changes:** None. Provision empty Supabase **production** and **staging** projects, region `ap-southeast-1` (PHASE1 §10.1, PHASE12 §18.1).

**API endpoints:** None.

**Components:** `components/ui/` base design system bootstrap (shadcn/ui) (PHASE1 §3).

**Services:** `createAdminClient()` in `lib/supabase/server.ts` (PHASE1 §8.2) — stub only, not yet called from any route.

**Dependencies:** None (first phase).

**Completion criteria:** Empty Next.js app deploys to `staging.weddingplatform.com` via CI Stage 1 (`tsc --noEmit`, `eslint`, `prettier --check`, `npm audit`); `terraform plan` is clean on first apply.

---

### Phase B — Core Multi-Tenant Foundation `(= M1)`

**Goal:** Working multi-tenant skeleton: tenants, users, roles, packages, feature flags, RLS isolation, JWT claims, subdomain tenant resolution (PHASE1, full document).

**Files to create:**
```
app/(marketing)/page.tsx
app/(marketing)/pricing/
app/(marketing)/layout.tsx
app/(auth)/login/
app/(auth)/register/
app/(auth)/layout.tsx
app/(app)/dashboard/
app/(app)/invitations/                 (stub; populated in Phase H)
app/(app)/invitations/new/             (stub; populated in Phase H)
app/(app)/packages/                    (stub; populated in Phase F)
app/(app)/settings/
app/(app)/layout.tsx
app/(admin)/tenants/                   (stub; populated in Phase E)
app/(admin)/packages/                  (stub; populated in Phase E)
app/(admin)/resellers/                 (stub; populated in Phase E)
app/(admin)/feature-flags/             (stub; populated in Phase E)
app/(admin)/analytics/                 (stub; populated in Phase M)
app/(admin)/layout.tsx
app/(reseller)/dashboard/              (stub; populated in Phase E)
app/(reseller)/clients/                (stub; populated in Phase E)
app/(reseller)/billing/                (stub; populated in Phase L)
app/(reseller)/branding/               (stub; populated in Phase E)
app/(reseller)/layout.tsx
app/inv/[slug]/page.tsx                (stub SSR; ISR added in Phase H)
app/api/auth/
app/api/invitations/                   (stub; populated in Phase H)
app/api/rsvp/                          (stub; populated in Phase J)
app/api/guests/                        (stub; populated in Phase I)
app/api/packages/                      (stub; populated in Phase F)
app/api/payments/                      (stub; superseded by Phase L's app/api/subscription, app/api/webhooks)
app/api/resellers/
app/api/webhooks/                      (stub; populated in Phase L)
app/layout.tsx
app/middleware.ts
components/dashboard/
components/admin/
components/reseller/
components/shared/
lib/auth/session.ts
lib/auth/permissions.ts
lib/packages/features.ts
lib/packages/limits.ts
lib/tenant/resolver.ts
lib/payments/index.ts                  (stub; superseded by lib/billing/* in Phase L)
lib/utils/
types/database.ts
types/invitation.ts
types/package.ts
types/tenant.ts
hooks/use-invitation.ts
hooks/use-feature-flag.ts
hooks/use-quota.ts
hooks/use-tenant.ts
config/packages.ts
config/features.ts
config/site.ts
public/themes/
public/fonts/
supabase/migrations/<core-tables>.sql  (see §3 Migration Order)
supabase/seed.sql
supabase/functions/send-rsvp-notification/
supabase/functions/process-payment-webhook/   (stub; superseded by Phase L webhook Edge handling)
supabase/config.toml
```

**Database changes:** Create, in this order: `tenants`, `users`, `resellers`, `reseller_tenants`, `packages`, `package_features`, `tenant_subscriptions`, `feature_flags`, `invitation_themes`, `invitations`, `invitation_sections`, `guests`, `rsvp_responses`, `orders` (PHASE1 §4.2 shape — superseded in Phase L), `audit_logs`. Apply all PHASE1 §4.2 indexes. Apply RLS policies `tenant_isolation`, `public_invitation_read`, `reseller_client_read` (PHASE1 §4.3). Seed Free package with feature entitlements.

**API endpoints:** Auth handled via Supabase Auth (no custom REST surface yet); `app/api/*` directories created as route-group placeholders only, populated in later phases.

**Components:** Layout shells for `(marketing)`, `(auth)`, `(app)`, `(admin)`, `(reseller)` route groups.

**Services:**
- `lib/auth/permissions.ts` — RBAC helpers for `super_admin → reseller_admin → tenant_owner → tenant_editor → tenant_viewer` (PHASE1 §5.1–§5.2).
- `lib/packages/features.ts` — `resolveFeature()` with 4-tier priority (platform kill switch → tenant override → package entitlement → default disabled) (PHASE1 §6.2).
- `lib/packages/limits.ts` — `checkQuota()` (PHASE1 §6.3).
- `config/features.ts` — `FEATURES` registry (PHASE1 §7.1).
- Supabase Auth Hook minting JWT claims: `tenant_id`, `role`, `reseller_id`, `package_id` (PHASE1 §5.3).
- `app/middleware.ts` — Edge Middleware: subdomain tenant resolution + JWT validation (PHASE1 §2.2, §2.4).

**Dependencies:** Phase A.

**Completion criteria:** User can register, receive a tenant + Free package, log in, see an empty dashboard; RLS verifiably blocks cross-tenant reads; `useFeatureFlag()`/`FeatureFlagProvider` resolve correctly server-side (PHASE1 §7.3).

---

### Phase C — Database Domain Completion **[EXTERNAL SPEC]** `(= M2)`

**Goal:** Complete the database domains cited by PHASE1/10/11/12 but fully specified only in PHASE2_DATABASE.md.

**Files to create:** Additional files under `supabase/migrations/` per PHASE2_DATABASE.md (not enumerated here — out of this document set).

**Database changes (only what is cited by name elsewhere):**
- `qr_codes`, `qr_checkins` (cited PHASE2 §3 Domain 7; consumed PHASE11 §5.3, §8.4, §14.3).
- `invitation_events` (BIGSERIAL, append-only) with baseline `event_type` CHECK: `'page_view', 'rsvp_open', 'rsvp_submit', 'guestbook_submit', 'music_play', 'gallery_view', 'qr_scan', 'gift_view', 'share_click'` (cited PHASE2 §3 Domain 8; extended in Phase M).
- `invitation_analytics` (daily grain, one row per `(invitation_id, date)`) (cited PHASE2 §3 Domain 8).
- Partition-candidate marking on `invitation_events` for the >10M row threshold (cited PHASE2 §9.1).
- Read-replica routing policy for analytics/dashboard SELECTs (cited PHASE2 §9.4).
- Retention baseline: events >90 days → cold storage/delete; `invitation_analytics` is the permanent record (cited PHASE2 §9.3).

**API endpoints:** None new.

**Components:** None.

**Services:** None new — wiring points only for Phase M.

**Dependencies:** Phase B.

**Completion criteria:** All cross-referenced PHASE2 objects required by Phases G–M exist in staging and production.

---

### Phase D — Authentication & Authorization **[EXTERNAL SPEC]** `(= M3)`

**Goal:** Finalize session/JWT mechanics beyond the PHASE1 §2.4/§5.3 baseline, per PHASE3_AUTH.md.

**Files to create:**
```
lib/auth/api-guard.ts        (requireAuth())
lib/auth/session.ts          (extended — requireSession())
```

**Database changes:** None new (uses Supabase-managed `auth.users`).

**API endpoints:** None new directly — establishes the `requireAuth(request, '<permission>')` contract used verbatim by every protected route from Phase E onward.

**Components:** None.

**Services:** `requireAuth()`, `requireSession()` — exact signatures consumed unmodified in PHASE10 (`requireAuth(request, 'subscription:write')`) and PHASE11 (`requireAuth(request, 'analytics:read')`).

**Dependencies:** Phase B.

**Completion criteria:** `requireAuth()`/`requireSession()` are exercised by at least one protected route and pass the PHASE1 §5.2 permission matrix for every role.

---

### Phase E — Admin Architecture **[EXTERNAL SPEC]** `(= M4)`

**Goal:** Full Super Admin panel beyond the PHASE1 §8 baseline, per PHASE4_ADMIN_ARCHITECTURE.md.

**Files to create:**
```
app/(admin)/dashboard/
app/(admin)/tenants/[id]/
app/(admin)/resellers/[id]/
app/(admin)/themes/
app/(admin)/orders/                    (stub; populated in Phase L)
app/(admin)/settings/
app/(reseller)/dashboard/
app/(reseller)/clients/
app/(reseller)/branding/
```

**Database changes:** None new.

**API endpoints:** Admin route handlers under `/api/admin/*`, gated by `role === 'super_admin'` (PHASE1 §8.2).

**Components:** `components/admin/*`, `components/reseller/*` populated.

**Services:** Impersonation token issuance (24h TTL, signed, audit-logged) (PHASE1 §8.3). Reuses `createAdminClient()` from Phase A — **never instantiated outside `/api/admin/*` or Edge Functions** (PHASE1 §8.2, enforced later in Phase N §7.6).

**Dependencies:** Phase B, Phase D.

**Completion criteria:** Super admin logs in, views tenant list, impersonates a tenant, and the action is written to `audit_logs` with the admin's `user_id` as actor.

---

### Phase F — Package & Feature System **[EXTERNAL SPEC]** `(= M5)`

**Goal:** Full package/feature engine beyond PHASE1 §6/§7, per PHASE5_PACKAGE_FEATURE_SYSTEM.md.

**Files to create:** Redis feature-cache wiring inside `lib/packages/features.ts`; `package_feature_snapshot` materialized view migration (file path governed by PHASE5_PACKAGE_FEATURE_SYSTEM.md).

**Database changes:**
- Seed full feature matrix: `analytics_basic`, `analytics_advanced`, `analytics_export`, `qr_checkin`, each with `config.retention_days` per tier (Premium 90d, Ultimate 365d) (cited PHASE11 Appendix C — **must exist before Phase M**).
- `package_feature_snapshot` materialized view (cited PHASE5 §12.2, reused PHASE10 §18.5, PHASE11 §18.4).

**API endpoints:** `app/api/packages/*` populated (package listing, entitlement queries).

**Components:** `app/(app)/packages/` pricing/upgrade selection UI populated.

**Services:** Redis feature-resolution cache, 60s TTL, invalidated on subscription change (cited §12.1 — this exact invalidation hook is called by Phase L's `invalidateFeatureCache()`).

**Dependencies:** Phase B, Phase C.

**Completion criteria:** Every feature key consumed later in Phase L (`subscription:write` gating) and Phase M (`analytics_basic`, `analytics_advanced`, `analytics_export`, `qr_checkin`) resolves correctly across all four tiers.

---

### Phase G — Theme System **[EXTERNAL SPEC]** `(= M6)`

**Goal:** Theme rendering engine, per PHASE6_THEME_SYSTEM.md.

**Files to create:**
```
components/invitation/themes/classic/
components/invitation/themes/modern/
components/invitation/themes/floral/
components/invitation/themes/index.ts
```

**Database changes:** `invitation_themes.config_schema` populated per theme; `theme_experiments` table created as the prepared (unused) hook cited in PHASE11 §18.6.

**API endpoints:** None new.

**Components:** Theme renderer components above.

**Services:** None new.

**Dependencies:** Phase B, Phase F.

**Completion criteria:** At least the "Classic" theme renders against a test invitation.

---

### Phase H — Invitation Management **[EXTERNAL SPEC]** `(= M7)`

**Goal:** Invitation CRUD, editor, ISR public page, per PHASE7_INVITATION_MANAGEMENT.md.

**Files to create:**
```
app/(app)/invitations/[id]/edit/
app/(app)/invitations/new/
app/inv/[slug]/page.tsx                (full ISR implementation, 60s revalidation)
components/invitation/sections/
components/invitation/editor/
app/api/invitations/route.ts
app/api/invitations/[id]/route.ts
```

**Database changes:** `inv_public_read` RLS policy (cited PHASE11 §15.4 as the policy `/api/events/track` depends on in Phase M).

**API endpoints:** `app/api/invitations` (CRUD: create, edit, publish, archive).

**Components:** Property-panel editor (not drag-and-drop, per PHASE1 Appendix A trade-off); `invitation_sections`-driven section renderer (hero, couple, event_details, gallery, rsvp, gift, countdown, story).

**Services:** Publish-time quota check against Phase F's `checkQuota()`.

**Dependencies:** Phase B, Phase F, Phase G.

**Completion criteria:** A published invitation is publicly viewable via ISR within the LCP < 1.5s budget (PHASE1 §10.4); drafts remain SSR-only and non-public.

---

### Phase I — Guest Management **[EXTERNAL SPEC]** `(= M8)`

**Goal:** Guest CRUD, CSV import, personalized links, groups/categories, per PHASE8_GUEST_MANAGEMENT.md.

**Files to create:**
```
app/(app)/invitations/[id]/guests/
app/api/guests/route.ts
app/api/guests/[id]/route.ts
app/api/guests/import/route.ts          (async CSV import)
```

**Database changes:**
- `guests` extended with `group_id`, `category_id` (cited PHASE11 §8.1, joined by `guest_engagement_summary`).
- `guest_groups` table (cited PHASE11 §9.2, joined by `rsvp_by_group`).
- `guest_checkin_status` view (cited PHASE8 §10.2, consumed PHASE11 §7.2/§8.4).
- `guest_import_batches` table (cited PHASE8 §13.4 — the async/sync split precedent Phase M's export system reuses).

**API endpoints:** `/api/guests`, CSV import endpoint, personalized-link generation.

**Components:** Guest list table, CSV import UI, personalized-link share UI.

**Services:** Personalized-link resolution flow (cited PHASE8 §7.3 + PHASE9 §11.1) — populates `invitation_events.guest_id`, the join key Phase M's `guest_engagement_summary` view depends on entirely.

**Dependencies:** Phase B, Phase H.

**Completion criteria:** Guests can be imported via CSV, assigned personalized links, and grouped.

---

### Phase J — RSVP & Guestbook **[EXTERNAL SPEC]** `(= M9)`

**Goal:** Full RSVP + guestbook system, spam filtering, realtime feed, per PHASE9_RSVP_GUESTBOOK.md.

**Files to create:**
```
app/(app)/invitations/[id]/rsvp/
app/api/rsvp/route.ts
components/rsvp/RsvpForm.tsx
components/rsvp/GuestbookWall.tsx
```

**Database changes:**
- `rsvp_responses` extended: `is_spam`, `meal_choice`, `pax_count`, `attendance` enum (`attending`/`not_attending`/`maybe`).
- `guestbook_entries` table: `moderation_status`, `is_spam`, `guest_id`.
- Views: `rsvp_daily_trend`, `rsvp_by_category`, `rsvp_response_rate` (cited PHASE9 §9.2 — **directly queried, not reimplemented**, by Phase M).
- `get_rsvp_summary()` RPC (cited PHASE9 §3.2 — **reused directly** by Phase M §7.2).
- `guest_rsvp_status` view (cited PHASE8 §10.1, consumed by Phase M §8.4).

**API endpoints:** `/api/rsvp` (submit RSVP, fetch summary).

**Components:** `RsvpForm`, `GuestbookWall` (realtime, named precedent in PHASE9 §6.4/§15.4).

**Services:** Spam-scoring with transient raw-IP retention + 90-day purge commitment (cited PHASE9 §13.4). Realtime channel pattern: one channel per invitation (reused verbatim by Phase M's Live Event Dashboard).

**Dependencies:** Phase B, Phase H, Phase I.

**Completion criteria:** Guests can RSVP and post to the guestbook with spam filtering; owner sees a live feed; `get_rsvp_summary()` and the three trend views return correct data.

---

### Phase K — ⭐ MVP Consolidation & Hardening `(= MVP gate)`

**Goal:** Verify the composite of Phases A–J as a deployable, demonstrable product on the Free tier, with no real payment gateway and no rollup-driven analytics dashboards.

**Files to create:** None new — integration verification only. (No `app/api/subscription/*`, no `app/api/events/track`, no `lib/billing/*`, no `lib/analytics/*` yet — those belong to Phases L and M.)

**Database changes:** None new — confirm all Phase A–J migrations are applied consistently in staging.

**API endpoints:** None new — confirm all Phase B–J endpoints function together (`/api/invitations`, `/api/guests`, `/api/rsvp`).

**Components:** None new — confirm theme + editor + RSVP + guestbook render together end to end.

**Services:** None new.

**Dependencies:** Phases A–J.

**Completion criteria (MVP exit):** Signup → create invitation → publish → guest RSVP → guestbook post → owner sees live feed, all on the Free package, with RLS cross-tenant isolation verified. Tag `v0.5.0-mvp`, deploy to `staging.weddingplatform.com`.

---

### Phase L — Payment System `(= M10)`

**Goal:** Full gateway-agnostic, database-driven billing: orders, transactions, invoices, webhooks, subscription lifecycle, upgrades/downgrades, renewals, refunds, reseller commissions (PHASE10, full document).

**Files to create:**
```
lib/billing/pricing.ts
lib/billing/orders.ts
lib/billing/vouchers.ts
lib/billing/invoices.ts
lib/billing/transactions.ts
lib/billing/transaction-updater.ts
lib/billing/activation.ts
lib/billing/upgrade.ts
lib/billing/downgrade-enforcer.ts
lib/billing/commission.ts
lib/billing/refund-eligibility.ts
lib/billing/gateway/interface.ts
lib/billing/gateway/index.ts
lib/billing/gateway/midtrans.ts
lib/billing/gateway/xendit.ts
lib/billing/gateway/manual.ts
app/api/subscription/purchase/route.ts
app/api/subscription/change/route.ts
app/api/add-ons/purchase/route.ts
app/api/invoices/[id]/pdf/route.ts
app/api/orders/[id]/refund-request/route.ts
app/api/admin/refund-requests/[id]/process/route.ts
app/api/admin/orders/[id]/mark-paid/route.ts
app/api/admin/webhooks/route.ts
app/api/reseller/commission/route.ts
app/api/webhooks/[provider]/route.ts
app/subscription/complete/page.tsx
components/billing/PaymentMethodSelector.tsx
config/payment-methods.ts
supabase/functions/expire-invoices/index.ts
supabase/functions/reconcile-payments/index.ts
supabase/functions/process-renewals/index.ts
```

**Database changes:** See §3 Migration Order, files `091`–`105`. Tables: `orders` (migrated to full PHASE10 §2.2 shape), `payment_transactions`, `invoices`, `invoice_sequences` (+ `next_invoice_number()`), `webhook_logs`, `refund_requests`, `commission_ledger`, `commission_payouts`. Function `get_platform_billing_summary()`. Full RLS per §15.3. Full indexing per §17.1.

**API endpoints:**
```
POST   /api/subscription/purchase
POST   /api/subscription/change
POST   /api/add-ons/purchase
GET    /api/invoices/[id]/pdf
POST   /api/orders/[id]/refund-request
POST   /api/admin/refund-requests/[id]/process
POST   /api/admin/orders/[id]/mark-paid
GET    /api/admin/webhooks
GET    /api/reseller/commission
POST   /api/webhooks/[provider]
```

**Components:** `PaymentMethodSelector` (grouped by category: QRIS / Virtual Account / E-wallet / Bank Transfer); admin orders list + detail modal under `app/(admin)/orders/`; admin refund-requests queue under `app/(admin)/refund-requests/`; reseller commission dashboard under `app/(reseller)/billing/`.

**Services:** `GatewayAdapter` interface + `MidtransAdapter`, `XenditAdapter`, `ManualAdapter`; `calculatePrice()`, `calculateUpgradePricing()`; `createOrder()`, `generateInvoice()`, `createTransaction()`, `applyTransactionStatus()`; `activateSubscriptionFromOrder()` / `activatePackage()` / `activateAddOn()`; `resolveVoucher()`; `recordCommission()` / `reverseCommissionForRefund()`; `checkRefundEligibility()`.

**Payments integration tasks:**
- Configure `MIDTRANS_SERVER_KEY`, `MIDTRANS_CLIENT_KEY`, `MIDTRANS_IS_PRODUCTION`, `XENDIT_SECRET_KEY`, `XENDIT_WEBHOOK_TOKEN` in the vault.
- Register webhook URLs with Midtrans and Xendit (sandbox first).
- Validate amount-mismatch guard (>Rp 100 tolerance) writes to `audit_logs` without activation.
- Schedule Edge Function crons: `expire-invoices`, `reconcile-payments` (15 min), `process-renewals` (daily 00:05).

**Dependencies:** Phase K (MVP). Also requires Phase D's `requireAuth()`/session-refresh contract for `/subscription/complete`.

**Completion criteria:** A tenant purchases a paid package via at least one live payment method, receives an invoice, gets activated, and can request/receive a refund; reseller commission accrues correctly.

---

### Phase M — Analytics & Reporting System `(= M11)`

**Goal:** Four-audience analytics system (invitation owner, tenant, reseller, super admin) on top of `invitation_events`/`invitation_analytics` (PHASE11, full document).

**Files to create:**
```
lib/analytics/client-tracker.ts
lib/analytics/ua-parser.ts
lib/analytics/referrer-classifier.ts
lib/analytics/rate-limit.ts
lib/analytics/rollup-ledger.ts
lib/analytics/rsvp-day-counter.ts
lib/analytics/rsvp-by-group.ts
lib/analytics/meal-breakdown.ts
lib/analytics/guestbook-metrics.ts
lib/analytics/checkin-detail.ts
lib/analytics/tenant-summary.ts
lib/analytics/invitation-summary.ts
lib/analytics/feature-resolver.ts
lib/analytics/cache.ts
lib/analytics/export-csv.ts
app/api/events/track/route.ts
app/api/invitations/[id]/analytics/route.ts
app/api/invitations/[id]/analytics/rsvp/route.ts
app/api/invitations/[id]/guests/[guestId]/engagement/route.ts
app/api/invitations/[id]/guests/engagement-summary/route.ts
app/api/analytics/tenant/invitations/route.ts
app/api/analytics/export/route.ts
app/api/analytics/export/[jobId]/route.ts
app/api/reseller/analytics/route.ts
app/api/reseller/analytics/clients/route.ts
app/api/admin/analytics/route.ts
app/api/admin/analytics/cohort-retention/route.ts
app/(app)/invitations/[id]/live/page.tsx
components/analytics/TenantDashboard.tsx
components/analytics/SectionEngagementChart.tsx
components/analytics/AnalyticsGate.tsx
components/analytics/LiveEventDashboard.tsx
supabase/functions/flush-view-counts/index.ts
supabase/functions/rollup-invitation-daily/index.ts
supabase/functions/rollup-tenant-daily/index.ts
supabase/functions/rollup-reseller-daily/index.ts
supabase/functions/rollup-platform-daily/index.ts
supabase/functions/generate-analytics-export/index.ts
supabase/functions/purge-old-events/index.ts
supabase/functions/purge-old-exports/index.ts
types/analytics.ts
```

**Database changes:** See §3 Migration Order, files `106`–`119`. Tables: `invitation_analytics_extended`, `tenant_analytics_daily`, `reseller_analytics_daily`, `platform_analytics_daily`, `analytics_export_jobs`, `rollup_job_runs`. `ALTER TABLE invitation_events` event_type CHECK adding `section_scroll`, `whatsapp_share_click`, `session_end`. Views `guest_engagement_summary`, `rsvp_by_group`. Function `get_tenant_cohort_retention()`. Index `idx_events_guest_id`. Full RLS per §15.3 (including default-deny on `platform_analytics_daily`, `rollup_job_runs`). Storage bucket `analytics-exports`.

**API endpoints:**
```
POST   /api/events/track
GET    /api/invitations/[id]/analytics
GET    /api/invitations/[id]/analytics/rsvp
GET    /api/invitations/[id]/guests/[guestId]/engagement
GET    /api/invitations/[id]/guests/engagement-summary
GET    /api/analytics/tenant/invitations
POST   /api/analytics/export
GET    /api/analytics/export/[jobId]
GET    /api/reseller/analytics
GET    /api/reseller/analytics/clients
GET    /api/admin/analytics
GET    /api/admin/analytics/cohort-retention
```

**Components:** `TenantDashboard`, `SectionEngagementChart`, `AnalyticsGate` (lock-state pattern), `LiveEventDashboard`.

**Services:** `resolveAnalyticsFeatures()`; rollup job topology (`flush-view-counts` 60s, `rollup-invitation-daily` 00:30, `rollup-tenant-daily` 01:00, `rollup-reseller-daily` 01:15, `rollup-platform-daily` 01:30); `increment_view_count()` RPC; idempotency ledger helpers `alreadyRolledUp()` / `rollupCompletedFor()` / `recordRollupRun()`.

**Analytics integration tasks:**
- Every metric surfaced anywhere passes through `resolveAnalyticsFeatures()` — zero ungated direct reads.
- Zero new `FEATURE_KEYS` entries introduced — gating maps onto keys seeded in Phase F.
- `rollup-platform-daily` and `rollup-reseller-daily` must compose Phase L's `get_platform_billing_summary()` and `commission_ledger` with no duplicated revenue logic.
- Confirm `/api/events/track` is fire-and-forget and cannot degrade the public invitation page built in Phase H.

**Dependencies:** Phase L.

**Completion criteria:** All four dashboards render real rollup-driven data; sync/async exports work; the live event dashboard updates in real time; raw events purge on schedule per package tier.

---

### Phase N — Production Deployment & Operations `(= M12)`

**Goal:** Harden the now feature-complete platform (Phases A–M) for production: CI/CD, IaC enforcement, security, observability, backup/DR, HA, scaling, incident response, cost, compliance (PHASE12, full document).

**Files to create:**
```
scripts/pre-deploy-check.sh
scripts/post-deploy-watch.ts
scripts/smoke-test.ts
scripts/audit-service-role-usage.ts
scripts/dr-restore.sh
lib/logging/logger.ts
next.config.ts                          (security headers block added)
runbooks/webhook-backlog-growing.md
runbooks/payment-amount-mismatch-spike.md
runbooks/rollup-job-stuck.md
runbooks/replica-lag-high.md
runbooks/service-role-leak-suspected.md
runbooks/tenant-reports-data-loss.md
runbooks/full-region-outage.md
runbooks/auto-rollback-fired.md
```

**Database changes:** None new — formalizes the expand/contract policy (§6.1) retroactively over Phases B–M's migrations; no schema change.

**API endpoints:** `/api/health/db`, `/api/health/redis` (consumed by the smoke test).

**Components:** None new (status page is a separate hosted surface, not part of the app bundle).

**Services:** `scripts/audit-service-role-usage.ts` (CI-enforced `createAdminClient()` containment check, §7.6); `lib/logging/logger.ts` (structured JSON logging with secret redaction, §11.1); request-correlation ID assignment at Edge Middleware (§11.2).

**Payments/Analytics integration tasks:** Wire `webhook-backlog-growing.md` / `payment-amount-mismatch-spike.md` runbooks against Phase L's `webhook_logs`; wire `rollup-job-stuck.md` / `replica-lag-high.md` against Phase M's `rollup_job_runs`; add `/dashboards/analytics-pipeline`, `/dashboards/multi-tenant`, `/dashboards/billing` (§10.3).

**Infrastructure tasks:** Finalize Terraform modules (Cloudflare WAF/rate-limit, Vercel, Upstash, monitoring-as-code); environment parity matrix (production/staging/preview/local); env-var governance flow (vault → Terraform → Vercel/Supabase/Upstash); security headers + CSP (with Phase G's per-route relaxation for `/inv/[slug]` and reseller subdomains); dependency/supply-chain controls; secrets rotation cadences; tenant suspension flag + reseller custom-domain self-service; full observability stack; alert tiers + on-call; backup/DR architecture + `dr-restore.sh` rehearsal; cost anomaly detection; data residency + right-to-deletion path; `security.txt`.

**Dependencies:** Phase L, Phase M.

**Completion criteria:** Every item in the PHASE12 §19 checklist is checked except the final go-live switch (reserved for Phase O).

---

### Phase O — 🚀 Production Launch `(= LAUNCH gate)`

**Goal:** Execute the PHASE12 §19 checklist in full and flip payment gateways from sandbox to live.

**Files to create:** None.

**Database changes:** None.

**API endpoints:** None new.

**Components:** None new.

**Services:** None new.

**Dependencies:** Phases A–N.

**Completion criteria:** Identical, verbatim, to the PHASE12 §19 checklist (Infrastructure / CI-CD / Security / Monitoring / Backup & DR / Launch Readiness). Only once every box is checked do Phase L's gateways move off sandbox keys and the platform opens to real users and real money.

---

## 3. Migration Order

Exact sequence. Numbering is preserved exactly as declared in each source document — not renumbered or merged.

**Phase B (PHASE1 baseline — no file numbers assigned in source; apply in this table-creation order):**
```
tenants
users
resellers
reseller_tenants
packages
package_features
tenant_subscriptions
feature_flags
invitation_themes
invitations
invitation_sections
guests
rsvp_responses
orders                  (PHASE1 §4.2 shape — migrated to full shape in 091_orders_v2.sql)
audit_logs
+ indexes (PHASE1 §4.2)
+ RLS: tenant_isolation, public_invitation_read, reseller_client_read (PHASE1 §4.3)
```

**Phase C (PHASE2 baseline — file numbers governed by PHASE2_DATABASE.md, not specified in this document set):**
```
qr_codes
qr_checkins
invitation_events        (BIGSERIAL, append-only, baseline event_type CHECK)
invitation_analytics     (daily grain)
```

**Phases D–J (PHASE3–9 baseline — file numbers governed by their respective phase documents, not specified in this document set.)**

**Phase L (PHASE10 Appendix A — exact sequence):**
```
091_orders_v2.sql
092_payment_transactions.sql
093_invoices.sql
094_invoice_sequences.sql
095_webhook_logs.sql
096_refund_requests.sql
097_commission_ledger.sql
098_commission_payouts.sql
099_billing_indexes.sql
100_rls_orders_tx_invoices.sql
101_rls_refunds_commission.sql
102_get_rsvp_summary_billing.sql
103_seed_payment_methods.sql      (no-op — payment methods are config-driven)
104_billing_audit_actions.sql
105_billing_email_templates.sql
```

**Phase M (PHASE11 Appendix A — exact sequence):**
```
106_invitation_analytics_extended.sql
107_tenant_analytics_daily.sql
108_reseller_analytics_daily.sql
109_platform_analytics_daily.sql
110_increment_view_count_fn.sql
111_guest_engagement_view.sql
112_rsvp_by_group_view.sql
113_tenant_cohort_retention_fn.sql
114_invitation_events_event_type_ext.sql
115_events_guest_id_index.sql
116_analytics_export_jobs.sql
117_rollup_job_runs.sql
118_rls_analytics_tables.sql
119_storage_analytics_exports_bucket.sql
```

**Phase N (PHASE12):** No new product-data migrations. Only `scripts/pre-deploy-check.sh` (migration safety lint) is added, applied retroactively to confirm `091`–`119` would have passed.

---

## 4. Backend Build Order

### Supabase
1. Provision production + staging projects, `ap-southeast-1` (Phase A).
2. Apply Phase B core schema + RLS (`tenant_isolation`, `public_invitation_read`, `reseller_client_read`).
3. Apply Phase C domain tables (`qr_codes`, `qr_checkins`, `invitation_events`, `invitation_analytics`).
4. Apply Phases D–J schema extensions (auth, admin, package/feature seed, themes, invitation sections, guests, RSVP/guestbook).
5. Apply Phase L migrations `091`–`105`.
6. Apply Phase M migrations `106`–`119`.
7. Configure PgBouncer connection pooling (transaction mode) (PHASE1 §10.1).
8. Provision read replica; confirm replication lag threshold (PHASE2 §9.4, consumed PHASE11 §18.5, PHASE12 §14.2).

### Auth
1. Configure Supabase Auth (email/password + Google OAuth) (Phase B).
2. Implement JWT custom-claims hook: `tenant_id`, `role`, `reseller_id`, `package_id` (Phase B, PHASE1 §5.3).
3. Implement `app/middleware.ts` Edge Middleware: tenant resolution + JWT validation (Phase B).
4. Implement `requireAuth()` / `requireSession()` (Phase D).
5. Implement `lib/auth/permissions.ts` RBAC helpers (Phase B).
6. Implement session refresh on package change: `supabase.auth.refreshSession()` in `app/subscription/complete/page.tsx` (Phase L, depends on step 4).
7. Implement impersonation token issuance (Phase E).

### RLS
1. `tenant_isolation`, `public_invitation_read`, `reseller_client_read` (Phase B).
2. `inv_public_read` (Phase H) — depended on by `/api/events/track` (Phase M).
3. Per-domain extensions for guests/RSVP/guestbook (Phases I, J — external spec).
4. Billing RLS: `orders_read_tenant`, `orders_read_reseller`, `tx_read_tenant`, `invoices_read_tenant`, `refunds_read_tenant`/`refunds_insert_tenant`, `commission_read_own_reseller`, `payouts_read_own_reseller`; `webhook_logs` default-deny (Phase L §15.3).
5. Analytics RLS: `inv_analytics_ext_read_tenant`/`_reseller`, `tenant_analytics_read_own`/`_reseller`, `reseller_analytics_read_own`, `export_jobs_read_own`/`_insert_own`; default-deny on `platform_analytics_daily` and `rollup_job_runs` (Phase M §15.3).

### APIs
1. `app/api/invitations/*` (Phase H).
2. `app/api/guests/*` (Phase I).
3. `app/api/rsvp/*` (Phase J).
4. `app/api/packages/*` (Phase F).
5. `app/api/subscription/purchase`, `app/api/subscription/change`, `app/api/add-ons/purchase`, `app/api/invoices/[id]/pdf`, `app/api/orders/[id]/refund-request`, `app/api/webhooks/[provider]` (Phase L).
6. `app/api/admin/orders/[id]/mark-paid`, `app/api/admin/refund-requests/[id]/process`, `app/api/admin/webhooks` (Phase L, admin-gated).
7. `app/api/reseller/commission` (Phase L).
8. `app/api/events/track` (Phase M) — depends on step 1's invitation publish-state RLS.
9. `app/api/invitations/[id]/analytics`, `.../analytics/rsvp`, `.../guests/[guestId]/engagement`, `.../guests/engagement-summary` (Phase M).
10. `app/api/analytics/tenant/invitations`, `app/api/analytics/export`, `app/api/analytics/export/[jobId]` (Phase M).
11. `app/api/reseller/analytics`, `app/api/reseller/analytics/clients` (Phase M).
12. `app/api/admin/analytics`, `app/api/admin/analytics/cohort-retention` (Phase M, admin-gated).
13. `/api/health/db`, `/api/health/redis` (Phase N).

### Services
1. `lib/packages/features.ts` (`resolveFeature()`), `lib/packages/limits.ts` (`checkQuota()`) (Phase B/F).
2. `lib/tenant/resolver.ts` (Phase B).
3. `lib/billing/gateway/interface.ts` → `index.ts` → `midtrans.ts` → `xendit.ts` → `manual.ts` (Phase L — interface before adapters, registry after adapters).
4. `lib/billing/pricing.ts` → `orders.ts` → `invoices.ts` → `transactions.ts` → `transaction-updater.ts` → `activation.ts` (Phase L — pricing must exist before order creation; order creation before invoice generation; transaction creation before status cascade; status cascade before activation).
5. `lib/billing/upgrade.ts`, `downgrade-enforcer.ts`, `vouchers.ts`, `commission.ts`, `refund-eligibility.ts` (Phase L, after the core chain above).
6. `lib/analytics/client-tracker.ts` → `ua-parser.ts` / `referrer-classifier.ts` → `rate-limit.ts` (Phase M — client beacon first, then the server-side classifiers and limiter the ingestion route calls).
7. `lib/analytics/rollup-ledger.ts` before any rollup Edge Function is written (Phase M — the idempotency contract must exist first).
8. `lib/analytics/rsvp-day-counter.ts`, `rsvp-by-group.ts`, `meal-breakdown.ts`, `guestbook-metrics.ts`, `checkin-detail.ts` (Phase M, consumed by rollup + dashboard queries).
9. `lib/analytics/tenant-summary.ts`, `invitation-summary.ts`, `feature-resolver.ts`, `cache.ts`, `export-csv.ts` (Phase M, dashboard/export layer, last).
10. `lib/logging/logger.ts` (Phase N).

### Payments
1. `GatewayAdapter` interface (Phase L §4.1).
2. `MidtransAdapter`, `XenditAdapter`, `ManualAdapter` implementations (Phase L §4.3–§4.5).
3. Gateway registry + method-to-provider routing table (Phase L §4.2).
4. Pricing/proration (`calculatePrice()`, `calculateUpgradePricing()`).
5. Order → Invoice → Transaction creation chain.
6. Webhook endpoint `/api/webhooks/[provider]` (signature validate → idempotency key → log → amount guard → cascade).
7. `activateSubscriptionFromOrder()` and feature-cache invalidation.
8. Upgrade/downgrade flow + quota enforcement on downgrade.
9. Refund eligibility + request + admin processing.
10. Commission recording + reseller dashboard.
11. Cron jobs: `expire-invoices`, `reconcile-payments`, `process-renewals`.

### Analytics
1. `invitation_events` ingestion contract extension (`section_scroll`, `whatsapp_share_click`, `session_end`).
2. Client beacon → `/api/events/track` ingestion endpoint.
3. Rollup idempotency ledger (`rollup_job_runs`).
4. `flush-view-counts` (60s).
5. `rollup-invitation-daily` (00:30) — writes `invitation_analytics` + `invitation_analytics_extended`.
6. `rollup-tenant-daily` (01:00) — depends on step 5 completing for the date.
7. `rollup-reseller-daily` (01:15) — depends on step 6, joins Phase L's `commission_ledger`.
8. `rollup-platform-daily` (01:30) — depends on step 6, calls Phase L's `get_platform_billing_summary()`.
9. Dashboard query layer (tenant/invitation/guest/RSVP/reseller/platform summaries).
10. Export system (sync CSV, async job + `generate-analytics-export`).
11. Real-time live event dashboard.
12. Purge jobs: `purge-old-events`, `purge-old-exports`.

---

## 5. Frontend Build Order

### Public Pages
1. `app/(marketing)/page.tsx`, `pricing/`, `layout.tsx` (Phase B).
2. `app/(auth)/login/`, `register/`, `layout.tsx` (Phase B).
3. `app/inv/[slug]/page.tsx` — SSR stub (Phase B) → full ISR (60s) implementation with theme rendering and sections (Phase G, Phase H).
4. Public RSVP form + guestbook wall embedded in the public invitation page (Phase J).

### Admin
1. `app/(admin)/layout.tsx` + stub modules (Phase B).
2. `app/(admin)/dashboard/`, `tenants/[id]/`, `packages/`, `resellers/[id]/`, `feature-flags/`, `themes/`, `settings/` (Phase E).
3. `app/(admin)/orders/` (list, detail modal, mark-paid action) (Phase L).
4. `app/(admin)/refund-requests/` (Phase L).
5. `app/(admin)/analytics/` (platform dashboard + cohort retention) (Phase M).

### Dashboard
1. `app/(app)/layout.tsx`, `app/(app)/dashboard/` (invitation list, quick stats) (Phase B).
2. `app/(app)/packages/` (plan selection/upgrade entry point) (Phase F).
3. `app/(app)/settings/` (Phase B).
4. `/analytics` tenant dashboard (`TenantDashboard` component) (Phase M).
5. `app/subscription/complete/page.tsx` (Phase L).

### Invitation Builder
1. `components/invitation/themes/classic|modern|floral/` (Phase G).
2. `components/invitation/sections/` (hero, couple, event_details, gallery, rsvp, gift, countdown, story) (Phase H).
3. `components/invitation/editor/` property panel (Phase H).
4. `app/(app)/invitations/new/`, `app/(app)/invitations/[id]/edit/` (Phase H).
5. `app/(app)/invitations/[id]/analytics/` (invitation-level dashboard, `AnalyticsGate`, `SectionEngagementChart`) (Phase M).
6. `app/(app)/invitations/[id]/live/page.tsx` (`LiveEventDashboard`) (Phase M).

### RSVP
1. `app/(app)/invitations/[id]/rsvp/` owner-facing dashboard stub (Phase B) → full RSVP summary view consuming `get_rsvp_summary()` (Phase J).
2. `components/rsvp/RsvpForm.tsx` (public-facing submission form) (Phase J).
3. `components/rsvp/GuestbookWall.tsx` (realtime feed) (Phase J).
4. RSVP analytics panels (trend/category/group/response-rate/meal-choice/guestbook funnel) (Phase M).

### Guest Management
1. `app/(app)/invitations/[id]/guests/` (list, CRUD) (Phase I).
2. CSV import UI (async job status polling) (Phase I).
3. Personalized-link generation + share UI (Phase I).
4. Guest engagement detail + sortable engagement list UI (Phase M, depends on Phase I's `guest_id` join key).

---

## 6. Testing Order

### Unit Tests
1. `resolveFeature()` — all 4 priority branches (Phase B/F).
2. `checkQuota()` (Phase B).
3. RBAC permission-matrix checks for each role (Phase B/D).
4. Pricing calc, proration calc (Phase L — pure functions, no I/O, the exact category named in PHASE12 §5.1 Stage 2).
5. Rollup aggregation functions: device counting, referrer counting, session-bounce detection, section-scroll aggregation (Phase M).

### Integration Tests
1. RLS policy assertions: cross-tenant denial, public-read of published invitations, reseller client-read (Phase B, re-run after every RLS addition in Phases H/L/M).
2. Webhook signature validation (Midtrans SHA512, Xendit `X-CALLBACK-TOKEN`) against local Supabase (Phase L).
3. Idempotency test: replay an identical webhook payload twice, assert single activation (Phase L).
4. Reconciliation cron test: force a stale `pending` transaction, verify cron resolves it without a webhook (Phase L).
5. Cross-tenant leakage test on rollup jobs (Phase M).
6. RLS default-deny test on `platform_analytics_daily` / `rollup_job_runs` / `webhook_logs` (Phase L/M).
7. Idempotency-ledger test: re-trigger a completed rollup date, confirm skip not double-process (Phase M).
8. Export data-minimization test: export payload never exceeds equivalent dashboard fields (Phase M).
9. Migration safety lint test: deliberately unsafe migration is blocked (Phase N).
10. Service-role containment audit test: a `createAdminClient()` call outside `/api/admin/*` or Edge Functions fails CI (Phase N).

### E2E Tests
1. Signup → create invitation → publish → guest RSVP → guestbook post → live feed (Phase K, MVP smoke path).
2. Accessibility scan (axe-core) on the public invitation page (Phase K, pulled forward informally; CI-enforced in Phase N).
3. Purchase → sandbox checkout → webhook simulation → subscription activation (Phase L).
4. Upgrade with proration → downgrade scheduled at period end → quota enforcement (Phase L).
5. Refund request → admin approval → gateway refund → commission reversal (Phase L).
6. Full critical-path synthetic: signup → invitation → publish → RSVP → payment sandbox checkout → webhook → analytics event (Phase N, formalized as CI Stage 5 Playwright suite per PHASE12 §5.1).
7. Lighthouse CI Core Web Vitals budget on the public invitation page (Phase N, CI-blocking).
8. Live event dashboard realtime update during a test check-in/RSVP (Phase M).
9. Load test at projected Year-1 peak (3–5× steady-state, viral-invitation + concurrent-RSVP burst) (Phase N, pre-launch).
10. Auto-rollback drill against a deliberately-broken staging deploy (Phase N).
11. DR restore drill (PITR test restore) (Phase N).

---

## 7. Deployment Preparation Order

### Environment Setup
1. Define tiers: `production` (`app.weddingplatform.com`, `*.weddingplatform.com`), `staging` (`staging.weddingplatform.com`), `preview` (`preview-<pr-number>.vercel.app`, ephemeral), `local` (Supabase CLI/Docker) (Phase A, formalized Phase N).
2. Confirm staging runs the identical Next.js build and identical Supabase schema version as production, differing only in data volume and external-service credentials (Phase N §4.2).
3. Configure per-PR preview deployments + Supabase branched DBs for migration-touching PRs (Phase N §4.3); nightly force-destroy of preview branches older than 14 days.

### Secrets
1. Stand up the vault (Doppler/1Password) as source of truth (Phase A).
2. Introduce variables in this order:
   - Phase B: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `NEXT_PUBLIC_APP_URL`, `NEXT_PUBLIC_APP_DOMAIN`, `RESEND_API_KEY`, `EMAIL_FROM`, `UPSTASH_REDIS_REST_URL`, `UPSTASH_REDIS_REST_TOKEN`, `SENTRY_DSN`, `NEXT_PUBLIC_POSTHOG_KEY`.
   - Phase L: `MIDTRANS_SERVER_KEY`, `MIDTRANS_CLIENT_KEY`, `MIDTRANS_IS_PRODUCTION`, `XENDIT_SECRET_KEY`, `XENDIT_WEBHOOK_TOKEN`, `INVOICE_PDF_BUCKET`, `INVOICE_DUE_HOURS`, `REFUND_WINDOW_DAYS`.
   - Phase M: `ANALYTICS_IP_SALT`, `ANALYTICS_EXPORT_BUCKET`.
   - Phase N: `TF_CLOUD_API_TOKEN`, `CLOUDFLARE_API_TOKEN`, `VERCEL_API_TOKEN`, `UPSTASH_API_KEY`, `DOPPLER_TOKEN`, `BETTER_STACK_SOURCE_TOKEN`, `PAGERDUTY_INTEGRATION_KEY`, `DR_BACKUP_SECONDARY_PROVIDER_KEY`, `DR_BACKUP_ENCRYPTION_KEY`.
3. Never hand-edit Vercel/Supabase/Upstash dashboards directly for production — all writes flow vault → Terraform → provider (Phase N §4.4).
4. Define rotation cadences per secret class (DB credentials quarterly, payment keys on provider cadence + offboarding, third-party API keys annually, infra credentials quarterly) (Phase N §8.1).

### Domains
1. Provision wildcard `*.weddingplatform.com` on Vercel (Phase A/B).
2. Configure Cloudflare DNS + WAF managed ruleset + coarse rate limits (`api_global`, `events_track_strict`) (Phase N §7.2).
3. Configure TLS: Cloudflare edge termination (1.2 min, 1.3 preferred), Full (Strict) mode to Vercel origin (Phase N §7.3).
4. Enable reseller custom-domain self-service: CNAME → Vercel auto-provisioned certificate → Edge Middleware Host-header resolution (Phase E/Phase N §9.4).

### Storage
1. Supabase Storage buckets for invoices (Phase L, PDF generation, service-role-only writes).
2. `analytics-exports` bucket, 25 MB max, `csv|xlsx|pdf`, 7-day file / 30-day record retention, tenant-scoped read policy (Phase M §19.4).
3. Theme/asset buckets (`public/themes/`, gallery photos) (Phase G/H).
4. Cross-provider nightly object-storage sync for DR (Phase N §13.2).

### Monitoring
1. Sentry (frontend + serverless + Edge Function error capture, performance tracing) (Phase N §10.1).
2. Vercel Analytics (Web Vitals, function invocations/duration/errors) (Phase N §10.1).
3. Supabase built-in DB metrics (connections, query latency, replication lag) (Phase N §10.1, depends on Phase C's replica).
4. Upstash metrics (Redis ops/latency) (Phase N §10.1).
5. Grafana Cloud / Better Stack as the unified dashboard layer + log shipping (structured JSON from `lib/logging/logger.ts`) (Phase N §10.1, §11.1).
6. Synthetic checks every 5 min from 3 probe regions (Singapore, Jakarta, Sydney) + 15-min full critical-path E2E synthetic (Phase N §10.4).
7. Dashboards: `/dashboards/platform-health`, `/dashboards/billing`, `/dashboards/analytics-pipeline`, `/dashboards/multi-tenant`, `/dashboards/infrastructure` (Phase N §10.3).
8. Alert routing to PagerDuty (SEV1/2) and Slack (SEV3/4); on-call rotation staffed; runbooks linked to every alert (Phase N §12).
9. Status page (`status.weddingplatform.com`) live and linked from support surface before Phase O (Phase N §16.3).

---

*End of BUILD_ORDER.md*
