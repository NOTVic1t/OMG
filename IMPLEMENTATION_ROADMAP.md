# IMPLEMENTATION_ROADMAP.md
# Wedding Invitation SaaS Platform — Implementation Roadmap

> **Version:** 1.0.0
> **Status:** Derived from Approved Architecture
> **Source of truth:** PHASE1_ARCHITECTURE.md, PHASE10_PAYMENT_SYSTEM.md, PHASE11_ANALYTICS.md, PHASE12_DEPLOYMENT.md
> **Scope note:** This document does not redesign, add, or remove any architectural decision. It sequences the already-approved architecture (tables, RLS policies, adapters, rollup jobs, CI/CD stages, etc.) into executable milestones, dependencies, and workstreams. Every task below maps to a section of one of the four source documents; section references are given in parentheses, e.g. `(PHASE10 §8.1)`.
>
> The four uploaded documents declare their own dependency chain in their headers:
> - PHASE10 depends on PHASE1–9
> - PHASE11 depends on PHASE1–10
> - PHASE12 depends on PHASE1–11
>
> This roadmap honors that declared chain as the master implementation order. PHASE2–9 (Database, Auth, Admin Architecture, Package/Feature System, Theme System, Invitation Management, Guest Management, RSVP/Guestbook) are referenced extensively by name throughout PHASE1/10/11/12 but their full specifications are **not** part of this document set. Where this roadmap must sequence work that belongs to those phases, it lists only the sub-deliverables that are explicitly cited in the four source documents (e.g. `guest_groups`, `qr_checkins`, `rsvp_responses.is_spam`) — it does not invent new structure for them. Those milestones are marked **[EXTERNAL SPEC]**.

---

## Table of Contents

1. [Roadmap Principles](#1-roadmap-principles)
2. [Master Milestone Sequence](#2-master-milestone-sequence)
3. [Dependency Graph](#3-dependency-graph)
4. [Milestone M0 — Program & Infrastructure Bootstrap](#milestone-m0--program--infrastructure-bootstrap)
5. [Milestone M1 — PHASE1 Core Multi-Tenant Foundation](#milestone-m1--phase1-core-multi-tenant-foundation)
6. [Milestone M2 — PHASE2 Database Domain Completion [EXTERNAL SPEC]](#milestone-m2--phase2-database-domain-completion-external-spec)
7. [Milestone M3 — PHASE3 Authentication & Authorization [EXTERNAL SPEC]](#milestone-m3--phase3-authentication--authorization-external-spec)
8. [Milestone M4 — PHASE4 Admin Architecture [EXTERNAL SPEC]](#milestone-m4--phase4-admin-architecture-external-spec)
9. [Milestone M5 — PHASE5 Package & Feature System [EXTERNAL SPEC]](#milestone-m5--phase5-package--feature-system-external-spec)
10. [Milestone M6 — PHASE6 Theme System [EXTERNAL SPEC]](#milestone-m6--phase6-theme-system-external-spec)
11. [Milestone M7 — PHASE7 Invitation Management [EXTERNAL SPEC]](#milestone-m7--phase7-invitation-management-external-spec)
12. [Milestone M8 — PHASE8 Guest Management [EXTERNAL SPEC]](#milestone-m8--phase8-guest-management-external-spec)
13. [Milestone M9 — PHASE9 RSVP & Guestbook [EXTERNAL SPEC]](#milestone-m9--phase9-rsvp--guestbook-external-spec)
14. [⭐ MVP MILESTONE](#-mvp-milestone)
15. [Milestone M10 — PHASE10 Payment System](#milestone-m10--phase10-payment-system)
16. [Milestone M11 — PHASE11 Analytics & Reporting System](#milestone-m11--phase11-analytics--reporting-system)
17. [Milestone M12 — PHASE12 Production Deployment & Operations](#milestone-m12--phase12-production-deployment--operations)
18. [🚀 PRODUCTION LAUNCH MILESTONE](#-production-launch-milestone)
19. [Master Dependency Matrix](#19-master-dependency-matrix)
20. [Consolidated Database Migration Sequence](#20-consolidated-database-migration-sequence)
21. [Cross-Cutting Workstream Summaries](#21-cross-cutting-workstream-summaries)
22. [Environment Variable Master Checklist](#22-environment-variable-master-checklist)

---

## 1. Roadmap Principles

1. **No new architecture.** Every task below is a build/verify/deploy step against a decision already made in PHASE1/10/11/12. Where a prior phase already decided something (e.g. RLS-per-row, expand/contract migrations, gateway adapter interface), this roadmap schedules it — it does not re-litigate it.
2. **Milestones follow the documents' own declared dependency chain** (PHASE10 → needs 1–9; PHASE11 → needs 1–10; PHASE12 → needs 1–11).
3. **Every milestone produces a deployable increment** — not just code, matching PHASE12's CI/CD posture (§5) of "always deployable main branch."
4. **Payment and Analytics are full milestones (M10, M11), not afterthoughts** — consistent with the source documents treating them as complete subsystems with their own data models, RLS, and scaling sections.
5. **Production readiness is a gate, not a date** — the Production Launch Milestone is defined by the checklist in PHASE12 §19, not by a calendar deadline.

---

## 2. Master Milestone Sequence

| # | Milestone | Source Doc | Type |
|---|---|---|---|
| M0 | Program & Infrastructure Bootstrap | PHASE12 §3, §4, §5, §8 (pulled forward) | Cross-cutting |
| M1 | Core Multi-Tenant Foundation | PHASE1 (full) | Full spec |
| M2 | Database Domain Completion | PHASE2 (referenced only) | External spec |
| M3 | Authentication & Authorization | PHASE3 (referenced only) | External spec |
| M4 | Admin Architecture | PHASE4 (referenced only) | External spec |
| M5 | Package & Feature System (full engine) | PHASE5 (referenced only) | External spec |
| M6 | Theme System | PHASE6 (referenced only) | External spec |
| M7 | Invitation Management | PHASE7 (referenced only) | External spec |
| M8 | Guest Management | PHASE8 (referenced only) | External spec |
| M9 | RSVP & Guestbook | PHASE9 (referenced only) | External spec |
| **★ MVP** | **Minimum Viable Product** | M1–M9 composite | **Gate** |
| M10 | Payment System | PHASE10 (full) | Full spec |
| M11 | Analytics & Reporting System | PHASE11 (full) | Full spec |
| M12 | Production Deployment & Operations | PHASE12 (full) | Full spec |
| **🚀 LAUNCH** | **Production Launch** | PHASE12 §19 checklist | **Gate** |

Implementation order is strictly **M0 → M1 → … → M9 → MVP → M10 → M11 → M12 → LAUNCH**, because each later milestone's documents declare the earlier ones as hard dependencies. Within M1–M9 and within M10/M11/M12, sub-tasks may run in parallel across squads as noted per milestone.

---

## 3. Dependency Graph

```
M0 (infra bootstrap)
  │
  ▼
M1 (PHASE1: tenants, users, packages, RLS pattern, auth claims, folder scaffold)
  │
  ├──▶ M2 (DB domain completion)
  ├──▶ M3 (Auth & Authorization)
  │
  ▼ (M2+M3 feed all of the below)
M4 (Admin Architecture) ──▶ M5 (Package & Feature engine) ──▶ M6 (Theme System)
                                                                  │
                                                                  ▼
                                                          M7 (Invitation Management)
                                                                  │
                                                                  ▼
                                                          M8 (Guest Management)
                                                                  │
                                                                  ▼
                                                          M9 (RSVP & Guestbook)
                                                                  │
                                                                  ▼
                                                          ★ MVP GATE
                                                                  │
                                                                  ▼
                                          M10 (Payment System — depends on M1–M9)
                                                                  │
                                                                  ▼
                                M11 (Analytics — depends on M1–M10: rollups read
                                     invitation_events, rsvp_responses, guestbook_entries,
                                     qr_checkins, commission_ledger)
                                                                  │
                                                                  ▼
                          M12 (Production Deployment & Ops — depends on M1–M11:
                               hardens, monitors, and operationalizes everything above)
                                                                  │
                                                                  ▼
                                                    🚀 PRODUCTION LAUNCH GATE
```

---

## Milestone M0 — Program & Infrastructure Bootstrap

**Goal:** Stand up the infrastructure substrate so that M1 onward has somewhere real to deploy to, per PHASE12's environment/CI/CD/IaC design. Pulled forward from PHASE12 because no later milestone can ship without it.

**Depends on:** Nothing (first milestone).

### Database Tasks
- None yet — provision the empty Supabase **production** and **staging** projects, same region `ap-southeast-1` (PHASE12 §18.1, PHASE1 §10.1).
- Initialize `infra/supabase/migrations/`, `seed.sql`, `config.toml` per the IaC layout (PHASE12 §3.3).

### Backend Tasks
- Scaffold the Next.js 14 App Router repo per the exact folder structure in PHASE1 §3 (`app/(marketing)`, `app/(auth)`, `app/(app)`, `app/(admin)`, `app/(reseller)`, `app/inv/[slug]`, `app/api/*`, `lib/supabase/*`, `lib/auth/*`, `lib/packages/*`, `lib/tenant/*`, `lib/payments/*`).
- Implement `lib/supabase/client.ts`, `lib/supabase/server.ts`, `lib/supabase/middleware.ts` stubs (PHASE1 §3).
- Implement `createAdminClient()` per PHASE1 §8.2 — service-role client, server-only.

### Frontend Tasks
- Base design system bootstrap (`components/ui`, shadcn/ui) (PHASE1 §3).
- Empty layout shells for marketing/auth/app/admin/reseller route groups.

### Payment Integration Tasks
- None at this stage. (Full scope in M10.)

### Analytics Integration Tasks
- None at this stage. (Full scope in M11.)

### Infrastructure Tasks
- Stand up Terraform modules: `cloudflare/`, `vercel/`, `upstash/`, `monitoring/` (PHASE12 §3.3).
- Configure remote Terraform state (Terraform Cloud or S3+DynamoDB lock) (PHASE12 §3.3 `backend.tf`).
- Create environment tiers: `production`, `staging`, `preview`, `local` (PHASE12 §4.1).
- Provision Vercel project + wildcard domain `*.weddingplatform.com` (PHASE1 §10.1, PHASE12 §4.1).
- Provision Cloudflare zone: DNS, baseline WAF managed ruleset (PHASE12 §7.2).
- Provision Upstash Redis (production + staging instances) (PHASE12 §4.2).
- Stand up the secrets vault (Doppler or 1Password) as source of truth; wire Terraform to sync into Vercel/Supabase/Upstash env vars (PHASE12 §4.4, §8).
- Create `.env.example` (no real values) committed to git (PHASE12 §4.4).

### Testing Tasks
- Verify `terraform plan` is clean (zero drift) on first apply, per environment (PHASE12 §5.6, §19 checklist item).
- Smoke-test that a placeholder Next.js page deploys and resolves on the wildcard domain.

### Deployment Tasks
- First Vercel deployment of the empty scaffold to `staging.weddingplatform.com` (PHASE12 §4.1).
- Confirm CI pipeline Stage 1 (static validation: `tsc --noEmit`, eslint, prettier, `npm audit`) runs green on an empty repo (PHASE12 §5.1 Stage 1).

**Exit criteria:** Empty app deploys to staging via the pipeline; Terraform plan is clean; secrets vault is the single source of truth for all environments.

---

## Milestone M1 — PHASE1 Core Multi-Tenant Foundation

**Goal:** Working multi-tenant app skeleton: tenants, users, roles, packages, feature flags, RLS isolation, JWT claims, subdomain tenant resolution. This is PHASE1 in full.

**Depends on:** M0.

### Database Tasks
- Create core tables exactly as defined in PHASE1 §4.2: `tenants`, `users`, `resellers`, `reseller_tenants`, `packages`, `package_features`, `tenant_subscriptions`, `feature_flags`, `invitation_themes`, `invitations`, `invitation_sections`, `guests`, `rsvp_responses`, `orders` (initial PHASE1 shape — superseded by PHASE10 in M10), `audit_logs`.
- Apply all indexes listed under each table in PHASE1 §4.2 (`idx_users_tenant_id`, `idx_inv_tenant_id`, `idx_inv_slug`, `idx_inv_status`, `idx_guests_invitation_id`, `idx_guests_tenant_id`, `idx_rsvp_invitation_id`, `idx_orders_tenant_id`, `idx_al_tenant_id`, `idx_al_created_at`, etc.).
- Implement RLS policy patterns (PHASE1 §4.3): `tenant_isolation`, `public_invitation_read`, `reseller_client_read` — applied to `invitations`, `guests`, `rsvp_responses` and extended to every tenant-scoped table going forward.
- Seed the Free package with feature entitlements (PHASE1 roadmap item, §6.1 pricing matrix).

### Backend Tasks
- Implement Supabase Auth Hook for JWT custom claims: `tenant_id`, `role`, `reseller_id`, `package_id` (PHASE1 §5.3).
- Implement Edge Middleware: tenant resolution from subdomain + auth/JWT validation (PHASE1 §2.2, §2.4).
- Implement `lib/auth/permissions.ts` RBAC helpers for the role hierarchy `super_admin → reseller_admin → tenant_owner → tenant_editor → tenant_viewer` (PHASE1 §5.1, §5.2 permission matrix).
- Implement `lib/packages/features.ts` `resolveFeature()` with the 4-tier priority order: platform kill switch → tenant override → package entitlement → default disabled (PHASE1 §6.2).
- Implement `lib/packages/limits.ts` `checkQuota()` (PHASE1 §6.3).
- Implement `config/features.ts` FEATURE_KEYS registry (PHASE1 §7.1).
- Implement feature flag server-side resolution in root layout + `FeatureFlagProvider` context (PHASE1 §7.3).

### Frontend Tasks
- `hooks/use-feature-flag.ts`, `hooks/use-quota.ts`, `hooks/use-tenant.ts`, `hooks/use-invitation.ts` stubs (PHASE1 §3).
- Auth pages: login, register (email/password + Google OAuth) (PHASE1 §2.4, roadmap Phase 1).
- Minimal dashboard shell (invitation list, quick stats placeholder) (PHASE1 roadmap Phase 1).

### Payment Integration Tasks
- None — `orders` table exists only in its PHASE1 minimal shape; full payment system is M10.

### Analytics Integration Tasks
- None — analytics tables don't exist yet; this milestone only emits `invitations.view_count` column (PHASE1 §4.2), consumed later by M11.

### Infrastructure Tasks
- Configure Vercel Edge Middleware deployment region pinning to `ap-southeast-1` proximity (PHASE1 §10.1).
- Configure Supabase connection pooling via PgBouncer (transaction mode) (PHASE1 §10.1).

### Testing Tasks
- Unit tests for `resolveFeature()` priority order (all 4 branches) and `checkQuota()`.
- RLS policy tests: verify cross-tenant read is denied, public read of `published` invitations succeeds for anonymous users, reseller read of client tenant data succeeds.
- Auth flow test: signup → JWT contains correct `tenant_id`/`role`/`package_id`.

### Deployment Tasks
- Migration apply to staging, then production, following expand-only safety (this is the first migration, so no expand/contract concern yet).
- Tag release `v0.1.0`.

**Exit criteria:** A user can register, get a tenant + Free package, log in, and see an empty dashboard; RLS verifiably blocks cross-tenant access.

---

## Milestone M2 — PHASE2 Database Domain Completion **[EXTERNAL SPEC]**

**Goal:** Complete the database domains referenced by later phases but not fully detailed in the documents on hand. Full table-level specification lives in PHASE2_DATABASE.md (not in this document set); this roadmap only schedules the sub-deliverables explicitly cited elsewhere in PHASE1/10/11/12.

**Depends on:** M1.

### Database Tasks (only the sub-deliverables cited by name in PHASE1/10/11/12)
- **Domain 7 (QR):** `qr_codes`, `qr_checkins` tables (cited PHASE2 §3 Domain 7; consumed in PHASE11 §5.3, §8.4, §14.3).
- **Domain 8 (Analytics base):** `invitation_events` (BIGSERIAL, append-only) and `invitation_analytics` (daily grain) tables, with the `event_type` CHECK constraint as the pre-PHASE11 baseline (cited PHASE2 §3 Domain 8; extended later in M11 §4.1).
- Redis-buffered `view_count` strategy wiring point on `invitations.view_count` (cited PHASE2 §9.2, formalized later in M11 §5.5).
- Table partitioning candidate flag on `invitation_events` for the >10M row threshold (cited PHASE2 §9.1, executed later in M11 §18.2).
- Read-replica routing policy for analytics/dashboard SELECT queries (cited PHASE2 §9.4, consumed in M11 §18.5 and M12 §14.2).
- Retention policy baseline ("events older than 90 days → cold storage/delete; daily rollups are the permanent record") (cited PHASE2 §9.3, implemented in M11 §19).

### Backend Tasks
- Coordinate with PHASE2_DATABASE.md for any table/column not already enumerated above. **No new schema is invented here.**

### Frontend / Payment / Analytics Integration Tasks
- None directly — this milestone is purely a database substrate for M6–M11.

### Infrastructure Tasks
- Confirm partition-pruning-friendly query patterns are documented for any team building against `invitation_events` ahead of M11 (cited PHASE11 §18.2).

### Testing Tasks
- Schema migration dry-run against an ephemeral branched DB (this pattern is formalized in M12 §5.1 Stage 3, but should already be in informal use here).

### Deployment Tasks
- Migrations applied additively (expand-only), consistent with the expand/contract policy formalized later in M12 §6.1.

**Exit criteria:** All cross-referenced PHASE2 objects needed by M6–M11 exist in staging and production.

---

## Milestone M3 — PHASE3 Authentication & Authorization **[EXTERNAL SPEC]**

**Goal:** Full auth system beyond the PHASE1 §2.4/§5.3 baseline (session management, OAuth provider configuration, password policies, MFA if specified, JWT refresh mechanics). Full specification lives in PHASE3_AUTH.md.

**Depends on:** M1.

### Backend Tasks
- Implement the full session refresh flow referenced in PHASE10 §9.2 (`supabase.auth.refreshSession()` picking up new `package_id` claim after a plan change) — this exact mechanic is depended upon by M10 and must exist by then.
- Implement `requireAuth()` / `requireSession()` API guards referenced throughout PHASE10 (`lib/auth/api-guard.ts`) and PHASE11 (`requireAuth(request, 'analytics:read')`, etc.) — these guard signatures are used verbatim in M10/M11 backend tasks and must be finalized here.

### Testing Tasks
- Verify `requireAuth()` permission-string gating (e.g. `'subscription:write'`, `'analytics:read'`, `'reseller:analytics:read'`) works for every role in the PHASE1 §5.2 permission matrix, since M10/M11 route guards depend on this contract.

**Exit criteria:** `requireAuth()`/`requireSession()` contracts are stable and exercised by at least one real protected route, since M10 and M11 backend code calls them directly without modification.

---

## Milestone M4 — PHASE4 Admin Architecture **[EXTERNAL SPEC]**

**Goal:** Full Super Admin panel beyond the PHASE1 §8 baseline (module routing, impersonation UX, audit views). Full specification lives in PHASE4_ADMIN_ARCHITECTURE.md.

**Depends on:** M1, M3.

### Backend Tasks
- Finalize the service-role containment rule: `createAdminClient()` instantiated only inside Edge Functions and `/api/admin/*` routes after an explicit `role === 'super_admin'` check (PHASE1 §8.2) — this exact invariant is re-stated and **automated as a CI check** in M12 §7.6, so the convention must be followed consistently from this milestone forward.
- Implement impersonation token issuance (24h TTL signed token, audit-logged) (PHASE1 §8.3).

### Frontend Tasks
- `/admin` module shell: `/dashboard`, `/tenants`, `/packages`, `/resellers`, `/feature-flags`, `/themes`, `/orders`, `/analytics`, `/settings` route stubs (PHASE1 §8.1) — `/orders` and `/analytics` are populated fully in M10/M11.

### Testing Tasks
- Verify impersonation writes to `audit_logs` with the admin's `user_id` as actor (PHASE1 §8.3).

**Exit criteria:** Super admin can log in, view tenant list, and impersonate a tenant with a full audit trail.

---

## Milestone M5 — PHASE5 Package & Feature System **[EXTERNAL SPEC]**

**Goal:** Full package/feature engine beyond the PHASE1 §6/§7 baseline — the complete `FEATURE_KEYS` registry, Redis feature-cache (§12.1 cited in PHASE10/11/12), materialized `package_feature_snapshot` (§12.2 cited in PHASE11 §18.4, PHASE10 §18.5), and the full Free/Basic/Premium/Ultimate seed matrix that PHASE11 Appendix C cross-references. Full specification lives in PHASE5_PACKAGE_FEATURE_SYSTEM.md.

**Depends on:** M1, M2.

### Database Tasks
- Seed the complete feature matrix referenced in PHASE11 Appendix C: `analytics_basic`, `analytics_advanced`, `analytics_export`, `qr_checkin` (with `config.retention_days` per tier: Premium 90d, Ultimate 365d) — **these exact feature keys and configs are read directly by M11's `resolveAnalyticsFeatures()` and purge job, so they must exist before M11 starts.**

### Backend Tasks
- Implement the Redis feature-resolution cache (§12.1, cited as the caching precedent reused in PHASE11 §17.3 and PHASE10 §17.2) — 60s TTL, invalidated on subscription change (PHASE10 §9.1 `invalidateFeatureCache()` depends on this existing).
- Implement `package_feature_snapshot` materialized view (§12.2) as the general denormalization pattern PHASE11 §18.4 explicitly reuses.

### Testing Tasks
- Verify every feature key consumed in M10 (`subscription:write` gating) and M11 (`analytics_basic`, `analytics_advanced`, `analytics_export`, `qr_checkin`) resolves correctly across all four tiers before those milestones begin.

**Exit criteria:** `resolveFeature()`/`resolveAnalyticsFeatures()`-style consumers can read a fully seeded, cached feature matrix; no feature key referenced in M10/M11 is missing from the registry.

---

## Milestone M6 — PHASE6 Theme System **[EXTERNAL SPEC]**

**Goal:** Theme rendering engine, `invitation_themes` content config, livestream/map embed handling referenced by M12's CSP relaxation rules. Full specification lives in PHASE6_THEME_SYSTEM.md.

**Depends on:** M1, M5.

### Backend / Frontend Tasks
- Implement theme renderer components (`components/invitation/themes/classic|modern|floral`) (PHASE1 §3 folder layout).
- Implement the prepared theme A/B experiment hook (`theme_experiments`) cited as already-prepared infrastructure in PHASE11 §18.6 — must exist (even if unused) before M11's future-extension table can join against it.

### Infrastructure Tasks
- Confirm the relaxed per-route CSP (`frame-src`/`img-src`) for livestream/map theme embeds is scoped only to `/inv/[slug]` and reseller subdomains, not the platform-wide default (PHASE12 §7.5) — this CSP carve-out must be coordinated with M12's security headers work.

**Exit criteria:** At least the "Classic" theme renders end-to-end on a published invitation page.

---

## Milestone M7 — PHASE7 Invitation Management **[EXTERNAL SPEC]**

**Goal:** Invitation CRUD, editor, ISR-based public page, and the Core Web Vitals / no-blocking-analytics performance invariant that M11's client tracker must respect. Full specification lives in PHASE7_INVITATION_MANAGEMENT.md.

**Depends on:** M1, M5, M6.

### Backend Tasks
- Implement invitation CRUD (create, edit, publish, archive) against `invitations`/`invitation_sections` (PHASE1 §4.2).
- Implement the public-read RLS policy `inv_public_read` (cited in PHASE11 §15.4 as the policy the public ingestion endpoint relies on) — **must exist before M11's `/api/events/track` ships**, since that endpoint validates publication status against it.

### Frontend Tasks
- Public invitation page at `/inv/[slug]` using **ISR with 60s revalidation** for published invitations, SSR for drafts (PHASE1 §10.5) — this exact caching contract is the basis for M11 §5.5's view-count design and M12 §15.4's scaling argument.
- Property-panel editor (not drag-and-drop) per the explicit trade-off in PHASE1 Appendix A.

### Testing Tasks
- Lighthouse/Core Web Vitals budget established here (LCP < 1.5s per PHASE1 §10.4) — this exact budget becomes a CI-blocking check in M12 §5.1 Stage 5 and a synthetic-monitoring target in M12 §10.4.
- Verify the public page never blocks on any non-critical script (this invariant is what M11 §4.6's fire-and-forget analytics beacon depends on).

**Exit criteria:** A published invitation is publicly viewable via ISR within the LCP budget; draft invitations are never publicly readable.

---

## Milestone M8 — PHASE8 Guest Management **[EXTERNAL SPEC]**

**Goal:** Guest CRUD, CSV import, personalized links, guest groups/categories, and the prepared analytics hooks PHASE11 §8.1 explicitly completes. Full specification lives in PHASE8_GUEST_MANAGEMENT.md.

**Depends on:** M1, M7.

### Database Tasks
- `guests` table extended with `group_id`, `category_id` (cited in PHASE11 §8.1's `guest_engagement_summary` view definition, which joins on these columns).
- `guest_groups` table (cited in PHASE11 §9.2's `rsvp_by_group` view).
- `guest_checkin_status` view (cited PHASE8 §10.2, consumed directly by PHASE11 §7.2/§8.4).
- Async CSV import job pattern (`guest_import_batches`) (cited PHASE8 §13.4 — this exact async/sync split is the precedent PHASE11 §13.1 explicitly reuses for analytics exports).

### Backend Tasks
- Personalized-link resolution flow (cited PHASE8 §7.3, joined with PHASE9 §11.1) — populates `invitation_events.guest_id`, which is the join key M11's `guest_engagement_summary` view depends on entirely.
- Guest WhatsApp blast feature flag wiring (`GUEST_WHATSAPP_BLAST`, PHASE1 §7.1).

**Exit criteria:** Guests can be imported via CSV, assigned personalized links, and grouped — all prerequisites for M9's RSVP attribution and M11's guest engagement analytics.

---

## Milestone M9 — PHASE9 RSVP & Guestbook **[EXTERNAL SPEC]**

**Goal:** Full RSVP + guestbook system, spam filtering, realtime feed, and the prepared SQL views PHASE11 §9.1 explicitly promotes to dashboard surfaces. Full specification lives in PHASE9_RSVP_GUESTBOOK.md.

**Depends on:** M1, M7, M8.

### Database Tasks
- `rsvp_responses` extended with `is_spam`, `meal_choice`, `pax_count`, `attendance` enum (`attending`/`not_attending`/`maybe`) (cited throughout PHASE9 and consumed verbatim by PHASE11 §5.3, §9.3).
- `guestbook_entries` table with `moderation_status`, `is_spam`, `guest_id` (cited PHASE9, consumed by PHASE11 §9.4).
- Prepared views: `rsvp_daily_trend`, `rsvp_by_category`, `rsvp_response_rate` (cited PHASE9 §9.2 — these are **directly queried, not reimplemented**, by M11 §9.1).
- `get_rsvp_summary()` RPC (cited PHASE9 §3.2 — **reused directly** by M11 §7.2, not duplicated).
- `guest_rsvp_status` view (cited PHASE8 §10.1, consumed by M11 §8.4's check-in detail composition).

### Backend Tasks
- Realtime channel pattern: one Supabase Realtime channel per invitation (cited PHASE9 §6.4, §15.4 — **this exact pattern is reused verbatim** by M11 §14 Live Event Dashboard, including the "bounded by weddings happening today, not total invitation count" scaling argument in PHASE12... wait, PHASE11 §14.4).
- Spam-scoring policy with raw-IP transient retention + 90-day purge commitment (cited PHASE9 §13.4 — this is the policy M11 §16.3 explicitly contrasts against `invitation_events`' stricter hash-only-IP policy).

**Exit criteria:** Guests can RSVP and post to the guestbook with spam filtering and a live owner-facing feed; `get_rsvp_summary()` and the three trend views return correct data — all of which M11 consumes without modification.

---

## ⭐ MVP MILESTONE

**Composite of:** M0 → M9 (everything above this line).

**Definition:** The smallest deployable product that proves the full core user journey end-to-end, on the Free package tier, without requiring real payment processing or the full analytics rollup pipeline.

### MVP Scope (explicitly in)
- Tenant signup, login, JWT claims, RLS isolation (M1).
- Free package with seeded feature entitlements; `resolveFeature()`/`checkQuota()` operational (M1, M5).
- Super admin can view tenants and packages (M4).
- At least one working theme rendering a full invitation (M6).
- Invitation create → edit → publish → public ISR page (M7).
- Guest CRUD + CSV import + personalized links (M8).
- RSVP submission + guestbook with spam filtering + live realtime feed (M9).
- `invitations.view_count` increments on page view (PHASE1 §4.2) — raw counter only, no rollup dashboard yet.
- Manual/no-payment package assignment for demo purposes (the PHASE1-shape `orders` table is sufficient; the full PHASE10 gateway is **explicitly out of MVP scope**).

### MVP Scope (explicitly out — deferred to M10/M11/M12)
- Real payment gateway charges (Midtrans/Xendit), invoices, webhooks, refunds, commissions.
- Tenant/reseller/platform analytics dashboards, rollup jobs, exports.
- Production-grade IaC hardening, automated rollback, DR drills, formal SLOs.

### MVP Testing Tasks
- Full E2E smoke path: signup → create invitation → publish → guest RSVP → guestbook post → owner sees live feed.
- RLS cross-tenant isolation regression test.
- Accessibility scan (axe-core) on the public invitation page (pulled forward from PHASE12 §5.1 Stage 5, run manually at MVP stage since the full CI gate isn't built until M12).

### MVP Deployment Tasks
- Deploy to `staging.weddingplatform.com` (PHASE12 §4.1) for internal QA.
- Tag `v0.5.0-mvp`.

**MVP exit criteria:** A real user, end to end, can create a free-tier invitation, publish it, and receive an RSVP and guestbook entry, with the owner seeing it live — with zero payment dependency.

---

## Milestone M10 — PHASE10 Payment System

**Goal:** Full gateway-agnostic, database-driven billing system: orders, transactions, invoices, webhooks, subscription lifecycle, upgrades/downgrades, renewals, refunds, reseller commissions.

**Depends on:** M1–M9 (MVP complete) — PHASE10's own header declares dependency on PHASE1–9.

### Database Tasks
- Migrate `orders` from its PHASE1 minimal shape to the full PHASE10 §2.2 shape (`amount_gross`, `amount_discount`, `amount_proration`, `amount_net`, `commission_amount`, `commission_pct`, full status enum) — an **expand/contract migration** per PHASE12 §6.1 once that policy is formalized, or at minimum additive-only at this stage.
- Create `payment_transactions` (§2.3), `invoices` (§2.4), `invoice_sequences` + `next_invoice_number()` (§2.5), `webhook_logs` (§2.6, append-only, no FK by design), `refund_requests` (§2.7).
- Create `commission_ledger`, `commission_payouts` (§13.1).
- Apply full migration order per **Appendix A** of PHASE10 (`091`–`105`): orders v2 → payment_transactions → invoices → invoice_sequences → webhook_logs → refund_requests → commission_ledger → commission_payouts → indexes → RLS (orders/tx/invoices) → RLS (refunds/commission) → `get_platform_billing_summary()` → payment-methods no-op seed → audit-action reference seed → billing email templates.
- Apply all RLS policies §15.3 (`orders_read_tenant`, `orders_read_reseller`, `tx_read_tenant`, `invoices_read_tenant`, `refunds_read_tenant`/`refunds_insert_tenant`, `commission_read_own_reseller`, `payouts_read_own_reseller`; `webhook_logs` default-deny).
- Apply indexing strategy §17.1 in full.

### Backend Tasks
- Implement `GatewayAdapter` interface (§4.1) and the registry/method-routing table (§4.2).
- Implement `MidtransAdapter` (§4.3): charge payload builder per method, SHA512 webhook signature validation, status mapping, refund call.
- Implement `XenditAdapter` (§4.4): e-wallet + VA payload builders, `X-CALLBACK-TOKEN` validation, status mapping, refund call.
- Implement `ManualAdapter` (§4.5): bank-transfer instructions, 3-day expiry, admin-only mark-paid path.
- Implement pricing calculator `calculatePrice()` (§3.1) and `calculateUpgradePricing()` proration logic (§10.1).
- Implement `createOrder()` (§3.2), `generateInvoice()` (§6.1), `createTransaction()` (§7.2), `applyTransactionStatus()` cascade (§7.3).
- Implement voucher resolution `resolveVoucher()` (§3.5).
- Implement webhook endpoint `/api/webhooks/[provider]` with the exact 6-step contract: validate signature → idempotency key → duplicate check → immutable log → amount-mismatch guard → state-transition cascade, always returning HTTP 200 once logged (§8.1, §16.2).
- Implement subscription activation `activateSubscriptionFromOrder()` / `activatePackage()` / `activateAddOn()` (§9.1) including feature-cache invalidation.
- Implement upgrade/downgrade API `/api/subscription/change` with immediate-charge upgrade vs scheduled-at-period-end downgrade (§10.2).
- Implement `enforceQuotaLimitsAfterDowngrade()` — archive (not delete) excess invitations, deactivate excess team members (§10.3).
- Implement refund eligibility check (§12.1, 7-day window) and refund request/processing APIs (§12.2, §12.3).
- Implement commission recording `recordCommission()` / `reverseCommissionForRefund()` (§13.2).
- Implement admin manual payment verification `/api/admin/orders/[id]/mark-paid` (§14.2).
- Implement `get_platform_billing_summary()` consumption in admin revenue summary (§14.3).
- Enforce **Service Role Containment** (§16.5): `createAdminClient()` only inside webhook handlers, Edge Functions, and `/api/admin/*` after explicit `super_admin` check.

### Frontend Tasks
- Payment method selector grouped by category (QRIS / Virtual Account / E-wallet / Bank Transfer) (§5.1, §5.2).
- Purchase flow UI: package select → pricing display → payment instructions (VA number / QRIS image / redirect) (§1.3 end-to-end flow).
- `/subscription/complete` page: refresh session so JWT picks up new `package_id` claim, then redirect to dashboard (§9.2) — **depends on M3's session-refresh contract**.
- Invoice PDF download UI consuming `/api/invoices/[id]/pdf` signed URL (§6.2).
- Refund request UI (§12.2) and admin refund queue UI (§14.1 `/admin/refund-requests`).
- Reseller commission dashboard UI consuming `/api/reseller/commission` (§13.3).
- Admin orders module UI: list/filter, order detail modal, webhook log viewer (§14.1, §14.4).

### Payment Integration Tasks (full subsystem — this milestone IS the payment integration)
- Wire Edge Function cron jobs: `expire-invoices` (§6.3), `reconcile-payments` every 15 min (§8.3), `process-renewals` daily at 00:05 (§11.2).
- Configure all gateway credentials in the secrets vault: `MIDTRANS_SERVER_KEY`, `MIDTRANS_CLIENT_KEY`, `MIDTRANS_IS_PRODUCTION`, `XENDIT_SECRET_KEY`, `XENDIT_WEBHOOK_TOKEN` (Appendix C).
- Register webhook URLs with both Midtrans and Xendit dashboards (sandbox first, then production).
- Validate the **amount-mismatch guard** (>Rp 100 tolerance) against `audit_logs` without activation (§16.3).
- Validate multi-currency readiness (the `currency` column is already present on all three tables — no schema change needed for a future Stripe adapter) (§18.4).

### Analytics Integration Tasks
- None directly in M10 — but `orders.created_at`, `commission_ledger`, and `get_platform_billing_summary()` are the exact inputs M11's `rollup-platform-daily` and `rollup-reseller-daily` jobs will consume. No M11 work should start until these are stable.

### Infrastructure Tasks
- Configure Cloudflare edge rate limiting ahead of the webhook and purchase endpoints (pulled forward from PHASE12 §7.2, since payment endpoints are the highest-value targets for abuse).
- Confirm TLS 1.2+ enforced on all webhook traffic (pulled forward from PHASE12 §7.3).

### Testing Tasks
- Unit tests: pricing calc, proration calc, feature resolver interaction — pure functions, no I/O (this is explicitly the Stage 2 CI test category named in PHASE12 §5.1).
- Integration tests against local Supabase: RLS policy assertions, webhook signature validation (PHASE12 §5.1 Stage 2).
- Sandbox E2E: purchase → sandbox checkout → webhook simulation → subscription activation (this is the exact Playwright flow named in PHASE12 §5.1 Stage 5 — build it here, formalize it in CI at M12).
- Idempotency test: replay the same webhook payload twice, assert single activation.
- Reconciliation cron test: force a stale `pending` transaction, verify the cron resolves it without a webhook.

### Deployment Tasks
- Apply migrations `091`–`105` to staging, run full sandbox payment round-trip, then promote to production behind a manual gate (this manual-promotion pattern is formalized fully in M12 §5.2, but the gate should already exist informally here).
- Tag `v0.7.0` once payment system is live in production (initially sandbox-only, then flipped to live keys).

**Exit criteria:** A real tenant can purchase a paid package via at least one live payment method, receive an invoice, get activated, and — on failure paths — request and receive a refund; reseller commission accrues correctly.

---

## Milestone M11 — PHASE11 Analytics & Reporting System

**Goal:** Full four-audience analytics system (invitation owner, tenant, reseller, super admin) built on the existing `invitation_events`/`invitation_analytics` stream, with rollups, dashboards, exports, and a real-time live-event view.

**Depends on:** M1–M10 — PHASE11's own header declares dependency on PHASE1–10 (it explicitly composes `get_platform_billing_summary()` from M10 and `commission_ledger` from M10).

### Database Tasks
- Create `invitation_analytics_extended` (PART1 §3.2), `tenant_analytics_daily` (§3.3), `reseller_analytics_daily` (§3.4), `platform_analytics_daily` (§3.5), `analytics_export_jobs` (§3.6).
- Additive `ALTER ... CHECK` on `invitation_events.event_type` adding `section_scroll`, `whatsapp_share_click`, `session_end` (§4.1) — **additive only, per the expand/contract pattern**, no existing event types touched.
- Create `guest_engagement_summary` view (§8.1, completes the PHASE8 §10.3 prepared hook).
- Create `rsvp_by_group` view (§9.2, completes the PHASE8 §10.4 `AttendanceByGroup` prepared type).
- Create `get_tenant_cohort_retention()` RPC (§11.3 — the one genuinely new platform metric not prepared in any prior phase).
- Create `rollup_job_runs` ledger table (§5.6).
- Add `idx_events_guest_id` — the one net-new index on the PHASE2 `invitation_events` table (§17.1).
- Apply full migration order per **Appendix A** of PHASE11 (`106`–`119`).
- Apply all RLS policies §15.3, including the **default-deny, no-policy** stance on `platform_analytics_daily` and `rollup_job_runs` (service-role only).
- Add `analytics-exports` storage bucket + tenant-read policy (§19.4).

### Backend Tasks
- Implement client-side beacon `lib/analytics/client-tracker.ts`: `page_view`, `IntersectionObserver`-driven `section_scroll`, `sendBeacon`-based `session_end` — fire-and-forget, zero analytics SDK weight (§4.2).
- Implement `/api/events/track` ingestion endpoint: zod validation, rate limiting, published-only check against the M7 public-read RLS policy, guest cross-check, device/referrer classification, IP hashing (`hashIp()`), Redis view-count buffer increment (§4.3–§4.5).
- Implement rollup job topology and all five jobs (§5.1–§5.4): `flush-view-counts` (60s), `rollup-invitation-daily` (00:30, also building `invitation_analytics_extended`), `rollup-tenant-daily` (01:00), `rollup-reseller-daily` (01:15, joins M10's `commission_ledger`), `rollup-platform-daily` (01:30, calls M10's `get_platform_billing_summary()`).
- Implement `increment_view_count()` RPC wiring (§5.5) and the rollup idempotency ledger helpers `alreadyRolledUp()`/`rollupCompletedFor()`/`recordRollupRun()` (§5.6).
- Implement `resolveAnalyticsFeatures()` (§12.1) — consumes the M5 feature matrix directly, no new feature keys.
- Implement tenant/invitation/guest/RSVP/reseller/platform summary query functions (PART2 §6–§11), reusing PHASE9 views (`rsvp_daily_trend`, `rsvp_by_category`, `rsvp_response_rate`, `get_rsvp_summary()`) and PHASE8 views (`guest_checkin_status`, `guest_rsvp_status`) **directly, with no reimplementation**.
- Implement export system (PART3 §13): sync CSV (≤1,000 rows) vs async job (`analytics_export_jobs` + `generate-analytics-export` Edge Function + signed URL).
- Implement real-time live event dashboard (§14): Supabase Realtime subscriptions on `qr_checkins`/`rsvp_responses` INSERT, scoped one channel per invitation.
- Implement raw-event purge job `purge-old-events` (§19.2, package-driven `retention_days`, never hardcoded) and export-file purge job `purge-old-exports` (§19.3).
- Implement dashboard query Redis cache (§17.3, 5-minute TTL) and parallel `Promise.all()` loading discipline (§17.4).
- Implement shard-fan-out scaling variant for `rollup-invitation-daily` (§18.3) — build the coordinator/worker pattern even if not yet activated at current volume.

### Frontend Tasks
- Tenant dashboard `/analytics` (PART2 §6): stat cards, trend chart, top-invitation widget, per-invitation comparison table, export button.
- Invitation-level dashboard `/invitations/[id]/analytics` (§7): basic-tier trend + advanced-tier section engagement / traffic source / session metrics behind `AnalyticsGate` lock-state component (§12.3).
- Guest engagement detail + sortable engagement list UI (§8.2, §8.3).
- RSVP/guestbook analytics panels: trend, by-category, by-group, response rate, meal choice breakdown, guestbook funnel (§9).
- Reseller portfolio dashboard `/reseller/analytics` (§10).
- Super admin platform dashboard `/admin/analytics` + cohort retention view (§11).
- Live event dashboard `/invitations/[id]/live` (§14.2, §14.3).

### Payment Integration Tasks
- Confirm `rollup-platform-daily` and `rollup-reseller-daily` correctly compose M10's `get_platform_billing_summary()` RPC and `commission_ledger` table with **no duplicated revenue logic** (§5.4) — this is a direct integration point between M10 and M11, not new payment work.

### Analytics Integration Tasks (full subsystem — this milestone IS the analytics integration)
- Feature-gate every metric surfaced anywhere in the dashboards through `resolveAnalyticsFeatures()` — **zero ungated direct reads** (§12.1).
- Confirm zero new `FEATURE_KEYS` registry entries are introduced (§12.2) — all gating maps onto keys already seeded in M5.
- Confirm public ingestion failure isolation: any analytics pipeline failure (rate limit, DB write failure, malformed payload) must never break, delay, or visibly degrade the public invitation page (§4.6 hard architectural invariant, inherited from M7's performance posture).

### Infrastructure Tasks
- Confirm `invitation_events` partition-pruning-friendly query shape is in place before Year-1/2 volume hits the partitioning threshold (§18.2, inherited from M2).
- Confirm read-replica routing is safe for all analytics SELECT queries (none require read-after-write consistency) (§18.5).

### Testing Tasks
- Unit tests on rollup aggregation functions (device counting, referrer counting, session bounce detection, section-scroll aggregation).
- Cross-tenant leakage test on rollup jobs: confirm no code path lets one tenant's rollup reference another tenant's raw events (§16.2).
- RLS test on `platform_analytics_daily`/`rollup_job_runs`: confirm zero non-service-role access is possible (default-deny).
- Export data-minimization test: confirm export payloads never contain a field not already visible in the equivalent dashboard screen (§16.5).
- Idempotency-ledger test: re-trigger a rollup job for an already-completed date, confirm it skips rather than double-processes.
- Realtime scalability sanity check: confirm live-dashboard channel count is bounded by "weddings happening today" (§14.4).

### Deployment Tasks
- Apply migrations `106`–`119` to staging, validate one full nightly rollup cycle end-to-end (invitation → tenant → reseller → platform) before promoting to production.
- Schedule all Edge Function crons (flush/rollup ×4/purge ×2) in the production Supabase project.
- Tag `v0.9.0` once the analytics system is live in production.

**Exit criteria:** All four dashboards (invitation/tenant/reseller/platform) render real rollup-driven data; exports work synchronously and asynchronously; the live event dashboard updates in real time during a test RSVP/check-in; raw events purge on schedule per package tier.

---

## Milestone M12 — PHASE12 Production Deployment & Operations

**Goal:** Take the now-feature-complete platform (M1–M11) to production-grade: full CI/CD, IaC enforcement, security hardening, observability, backup/DR, HA, scaling readiness, incident response, cost controls, and compliance posture.

**Depends on:** M1–M11 — PHASE12's own header declares dependency on PHASE1–11 and explicitly states it "does not introduce new product features," only formalizes the operational layer underneath.

### Database Tasks
- Formalize the **expand/contract migration pattern** (§6.1) as enforced policy across all future schema work (it was already implicitly followed in M1–M11; this milestone makes it explicit and CI-blocking).
- Implement the migration safety lint script `pre-deploy-check.sh` (§6.4) blocking `DROP TABLE`, `DROP COLUMN`, `RENAME COLUMN`, `RENAME TO`, unsafe `ALTER COLUMN TYPE`, and bare `CREATE INDEX` (non-concurrent) — applied retroactively to confirm M1–M11 migrations would have passed.
- Document the zero-downtime DDL rules table (§6.3) as the team's migration reference going forward.

### Backend Tasks
- Implement the **automated service-role containment audit** `scripts/audit-service-role-usage.ts` (§7.6) — runs in CI Stage 1, scans for `createAdminClient(` usage outside `app/api/admin/` or `supabase/functions/`, converting the M4/M10/M11-stated invariant into a CI-blocking guarantee.
- Implement structured JSON logging `lib/logging/logger.ts` with secret redaction (`SECRET_FIELD_PATTERNS`) (§11.1) and request-correlation IDs assigned at Edge Middleware (§11.2).
- Implement health-check endpoints consumed by the smoke test: `/api/health/db`, `/api/health/redis` (§5.5).

### Frontend Tasks
- No new product-facing UI — this milestone is operational. (Status page is a separate hosted/self-hosted surface, §16.3, not part of the app bundle.)

### Payment Integration Tasks
- Apply the **auto-rollback watch** (§5.4) to all future production deploys touching payment code paths — error-rate threshold 2% or 3× baseline triggers an alias-swap rollback.
- Confirm PCI-DSS scope remains SAQ-A (tokenize-at-gateway only, never touch raw PAN) as a preserved invariant for any future payment method addition (§18.4).
- Wire `webhook-backlog-growing.md` and `payment-amount-mismatch-spike.md` runbooks (§16.2) against M10's `webhook_logs` and amount-mismatch audit logging.

### Analytics Integration Tasks
- Wire `rollup-job-stuck.md` and `replica-lag-high.md` runbooks (§16.2) against M11's `rollup_job_runs` ledger and read-replica metrics.
- Add the four analytics-pipeline dashboards (`/dashboards/analytics-pipeline`, `/dashboards/multi-tenant`) (§10.3) on top of M11's rollup ledger and per-tenant resource metrics.

### Infrastructure Tasks
- Finalize Terraform modules for Cloudflare (DNS/WAF/rate-limit rules per §7.2), Vercel (project/env/domains), Upstash (Redis sizing), and monitoring dashboards-as-code (§3.3) — all changes go through Terraform PR review going forward; nightly `terraform plan` drift detection (§5.6).
- Stand up the full environment parity matrix: production / staging / preview / local, including Supabase branched DBs per-PR (§4.2, §4.3).
- Implement environment variable governance flow: `.env.example` → vault → Terraform → Vercel/Supabase/Upstash, never hand-edited (§4.4).
- Implement security headers (`X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`, CSP, HSTS) platform-wide via `next.config.ts`, with the M6-scoped relaxed CSP carve-out for `/inv/[slug]` and reseller subdomains (§7.5).
- Configure Cloudflare WAF managed ruleset, coarse edge rate limiting (`api_global`, `events_track_strict`) ahead of Upstash's per-IP limiters (§7.2).
- Implement dependency/supply-chain controls: `npm audit` CI gate, Renovate/Dependabot auto-merge for patch-level, lockfile-verified `npm ci`, pinned Terraform provider versions, per-release SBOM (§7.4).
- Stand up secrets management end-to-end: Doppler/1Password as source of truth, quarterly/annual rotation cadences per secret class, allowlist-based log redaction, exposure-response runbook (§8).
- Implement multi-tenant operational controls: tenant suspension via `tenants.status` flag (no infra deprovisioning), reseller custom-domain self-service via Vercel domain API (§9.3, §9.4).
- Stand up observability stack: Vercel Analytics + Supabase metrics + Upstash metrics + Grafana Cloud/Better Stack unified dashboards; Sentry tracing; structured log shipping to Loki; synthetic checks from 3 probe regions every 5 min plus a 15-min full critical-path E2E synthetic (§10).
- Implement alert severity tiers (SEV1–SEV4) and routing table to PagerDuty/Slack (§12.1, §12.2); staff the on-call rotation (§12.3); apply alert-fatigue controls (runbook-linked alerts, quarterly threshold review, SEV3/4 digest batching) (§12.4).
- Implement backup & DR architecture: continuous WAL/PITR (7-day minimum, 35-day target), daily cross-provider logical backup (30 daily + weekly-for-a-year), object storage nightly cross-provider sync, Terraform-state + git as the IaC backup (§13.2); build and rehearse `scripts/dr-restore.sh` (§13.3, §13.4) with quarterly tabletop + annual full DR drill.
- Implement HA posture verification per component table (§14.2) and graceful-degradation behaviors: Redis-down fallback to direct DB + fail-open rate limiting, analytics-ingestion-down isolation (already built in M11 §4.6), webhook-delay reconciliation (already built in M10 §8.3), replica-lag fallback to primary, export-failure isolation (§14.3).
- Implement cost attribution and anomaly detection (nightly spend-vs-7-day-trailing-average, +50% tolerance band) (§17.2, §17.3).
- Confirm data-residency posture (`ap-southeast-1` primary, SEA-consistent backup region) and implement the right-to-deletion operational path (soft-delete cascade → hard purge job extending M11 §19.2 → backups roll off naturally → confirmation to requester) (§18).
- Publish `/.well-known/security.txt` with responsible-disclosure contact and SLA (§7.7).

### Testing Tasks
- Stand up the full 7-stage CI/CD pipeline (§5.1): static validation → unit/integration → migration safety lint → build/preview deploy → E2E smoke on preview (Playwright signup→invitation→publish→RSVP→sandbox checkout→webhook→analytics event, plus axe-core + Lighthouse CI) → staging deploy + full E2E re-run → manually-gated production release.
- Test the auto-rollback script against a deliberately-broken staging deploy (§5.4, §19 checklist item).
- Test the migration safety lint against a deliberately unsafe test migration, confirm it blocks (§6.4, §19 checklist item).
- Run the annual third-party penetration test scope: auth flows, RLS bypass attempts, payment webhook spoofing, cross-tenant probing, reseller impersonation boundaries; quarterly automated DAST (OWASP ZAP) against staging (§7.7).
- Execute the pre-launch load test at projected Year-1 peak (3–5× steady-state, viral-invitation + concurrent-RSVP-burst simulation) (§15.7, §19 checklist item).
- Perform a real PITR test restore (§13.3, §19 checklist item) and confirm cross-provider daily backup is restorable (§19 checklist item).
- Test PagerDuty escalation chain with a real announced test page (§19 checklist item).

### Deployment Tasks
- Finalize branching/release model: `main` always deployable, `feature/*` PRs, `hotfix/*` expedited path, `vN.N.N` release tags (§5.2).
- Walk the `full-region-outage.md` DR runbook in a tabletop exercise (§16.2, §19 checklist item).
- Execute the **full Pre-Production Launch Checklist** verbatim from PHASE12 §19 (Infrastructure / CI-CD / Security / Monitoring / Backup & DR / Launch Readiness blocks) — this checklist **is** the Production Launch Milestone gate, defined below.

**Exit criteria:** Every box in the PHASE12 §19 checklist is checked, verified, and signed off by the release manager.

---

## 🚀 PRODUCTION LAUNCH MILESTONE

**Gate definition:** Identical to the **Pre-Production Launch Checklist in PHASE12 §19** — reproduced here as the literal go/no-go gate for this roadmap, not paraphrased or altered.

### Infrastructure
- [ ] All Terraform modules applied and reconciled (zero drift) across prod/staging
- [ ] DNS, WAF, and rate-limit rules verified against §7.2 configuration
- [ ] TLS certificates verified (primary domain + wildcard + any reseller test domain)
- [ ] Read replica provisioned and replication lag confirmed within threshold

### CI/CD
- [ ] Full pipeline (§5.1) green on a dry-run release
- [ ] Auto-rollback watch script (§5.4) tested against a deliberately-broken staging deploy
- [ ] Migration safety lint (§6.4) confirmed blocking on a deliberately unsafe test migration

### Security
- [ ] Service-role containment audit (§7.6) passing with zero violations
- [ ] Secrets fully migrated to vault; zero secrets in git history (verified via a history-scanning tool, not just current-state check)
- [ ] Security headers (§7.5) verified via an external header-scanning tool
- [ ] security.txt published with a working disclosure contact

### Monitoring
- [ ] All golden-signal dashboards (§10.3) populated with real staging traffic data
- [ ] Synthetic checks (§10.4) running from all 3 probe regions against staging
- [ ] PagerDuty escalation chain tested with a real (announced) test page

### Backup & DR
- [ ] PITR window confirmed active and a test restore performed successfully (§13.3)
- [ ] Cross-provider daily backup confirmed landing and restorable
- [ ] DR runbook (§16.2 `full-region-outage.md`) walked through in a tabletop exercise

### Launch Readiness
- [ ] Load test (§15.7) executed at projected Year-1 peak with all SLOs met
- [ ] Status page live and linked from the support/help surface
- [ ] On-call rotation staffed and runbook index (§16.2) reviewed by every on-call engineer

**Only once every box above is checked does the platform go live on production payment keys and public marketing.** Until then, M10's payment gateways remain in sandbox mode regardless of how complete the feature work is — this mirrors PHASE12 §5.2's stated philosophy that a billing-bearing platform requires a human checkpoint between "tests passed" and "real money moves through this code."

---

## 19. Master Dependency Matrix

| Milestone | Hard Dependency On | Why (cited) |
|---|---|---|
| M0 | — | First milestone |
| M1 | M0 | Needs a Supabase/Vercel project to migrate into and deploy to |
| M2 | M1 | Domain tables extend the core schema from M1 |
| M3 | M1 | Auth claims (`tenant_id`, `role`, `package_id`) are minted in M1 |
| M4 | M1, M3 | Admin routes require `requireAuth()`/role checks from M3 |
| M5 | M1, M2 | Feature/package tables live in the M1/M2 schema |
| M6 | M1, M5 | Themes are feature-gated (`PREMIUM_THEMES`) |
| M7 | M1, M5, M6 | Invitation editor renders against themes; publish gates on package quotas |
| M8 | M1, M7 | Guests belong to invitations |
| M9 | M1, M7, M8 | RSVP/guestbook attach to invitations and guests |
| **MVP** | M0–M9 | Composite gate |
| M10 | M1–M9 | PHASE10 header: "Depends on: PHASE1–9" |
| M11 | M1–M10 | PHASE11 header: "Depends on: PHASE1–10"; explicitly composes `get_platform_billing_summary()` and `commission_ledger` from M10 |
| M12 | M1–M11 | PHASE12 header: "Depends on: PHASE1–11"; explicitly states it formalizes, not redesigns, the prior layers |
| **LAUNCH** | M0–M12 + §19 checklist | Composite gate |

---

## 20. Consolidated Database Migration Sequence

Numbering preserved exactly as declared in each source document's own appendix — **not renumbered or merged** here, to avoid implying a schema change that isn't in the source.

**M1 (PHASE1 baseline):** initial `tenants`, `users`, `resellers`, `reseller_tenants`, `packages`, `package_features`, `tenant_subscriptions`, `feature_flags`, `invitation_themes`, `invitations`, `invitation_sections`, `guests`, `rsvp_responses`, `orders` (PHASE1 shape), `audit_logs` + RLS patterns (PHASE1 §4.2–§4.3).

**M2–M9 (PHASE2–9 baseline):** governed by their own migration files — not enumerated in this document set beyond the cross-references listed per milestone above.

**M10 (PHASE10 Appendix A):**
```
091_orders_v2.sql · 092_payment_transactions.sql · 093_invoices.sql
094_invoice_sequences.sql · 095_webhook_logs.sql · 096_refund_requests.sql
097_commission_ledger.sql · 098_commission_payouts.sql · 099_billing_indexes.sql
100_rls_orders_tx_invoices.sql · 101_rls_refunds_commission.sql
102_get_rsvp_summary_billing.sql · 103_seed_payment_methods.sql (no-op)
104_billing_audit_actions.sql · 105_billing_email_templates.sql
```

**M11 (PHASE11 Appendix A):**
```
106_invitation_analytics_extended.sql · 107_tenant_analytics_daily.sql
108_reseller_analytics_daily.sql · 109_platform_analytics_daily.sql
110_increment_view_count_fn.sql · 111_guest_engagement_view.sql
112_rsvp_by_group_view.sql · 113_tenant_cohort_retention_fn.sql
114_invitation_events_event_type_ext.sql · 115_events_guest_id_index.sql
116_analytics_export_jobs.sql · 117_rollup_job_runs.sql
118_rls_analytics_tables.sql · 119_storage_analytics_exports_bucket.sql
```

**M12 (PHASE12):** No new product-data migrations — only the migration-safety tooling (`scripts/pre-deploy-check.sh`) and the policy formalization (§6) that all of the above migrations must already retroactively satisfy.

---

## 21. Cross-Cutting Workstream Summaries

These are not separate milestones — they are threads that run through M1–M12 and are called out per-milestone above. Listed once here for visibility:

| Workstream | Where it starts | Where it's formalized |
|---|---|---|
| Service-role containment (`createAdminClient()` only in admin/Edge contexts) | M1 §8.2 | CI-enforced in M12 §7.6 |
| Expand/contract migrations | Implicit from M1 onward | Formal policy + lint in M12 §6 |
| Defense-in-depth tenant isolation (RLS + explicit `.eq('tenant_id', …)`) | M1 §4.3 | Reaffirmed in every M10/M11 query |
| Fire-and-forget non-blocking instrumentation | M7 (ISR/perf posture) | M11 §4.6 client tracker |
| Async-for-large, sync-for-small job pattern | M8 §13.4 (CSV import) | Reused in M11 §13.1 (exports) |
| Realtime channel-per-invitation pattern | M9 §6.4/§15.4 | Reused in M11 §14 (live dashboard) |
| Redis caching with short TTL + explicit invalidation | M5 §12.1 | Reused in M10 §17.2, M11 §17.3 |
| Tiered, never-hardcoded retention | M2 §9.3 (raw events) | Formalized package-driven in M11 §19, mirrored in M12 §11.3 logs |

---

## 22. Environment Variable Master Checklist

Consolidated from PHASE1 §10.2, PHASE10 Appendix C, and PHASE12 Appendix A — introduce each at the milestone noted, via the vault-first governance flow (PHASE12 §4.4):

```bash
# Introduced at M1 (PHASE1 §10.2)
NEXT_PUBLIC_SUPABASE_URL=
NEXT_PUBLIC_SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=
NEXT_PUBLIC_APP_URL=
NEXT_PUBLIC_APP_DOMAIN=
RESEND_API_KEY=
EMAIL_FROM=
UPSTASH_REDIS_REST_URL=
UPSTASH_REDIS_REST_TOKEN=
SENTRY_DSN=
NEXT_PUBLIC_POSTHOG_KEY=

# Introduced at M10 (PHASE10 Appendix C)
MIDTRANS_SERVER_KEY=
MIDTRANS_CLIENT_KEY=
MIDTRANS_IS_PRODUCTION=false
XENDIT_SECRET_KEY=
XENDIT_WEBHOOK_TOKEN=
INVOICE_PDF_BUCKET=invoices
INVOICE_DUE_HOURS=24
REFUND_WINDOW_DAYS=7

# Introduced at M11 (PHASE11 Appendix E)
ANALYTICS_IP_SALT=
ANALYTICS_EXPORT_BUCKET=analytics-exports

# Introduced at M12 (PHASE12 Appendix A)
TF_CLOUD_API_TOKEN=
CLOUDFLARE_API_TOKEN=
VERCEL_API_TOKEN=
UPSTASH_API_KEY=
DOPPLER_TOKEN=
BETTER_STACK_SOURCE_TOKEN=
PAGERDUTY_INTEGRATION_KEY=
DR_BACKUP_SECONDARY_PROVIDER_KEY=
DR_BACKUP_ENCRYPTION_KEY=
```

---

*End of IMPLEMENTATION_ROADMAP.md*
