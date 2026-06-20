# IMPLEMENTATION_EXECUTION_PLAN.md
# Wedding Invitation SaaS Platform — Implementation Execution Plan (M0–M9)

> **Version:** 1.0.0
> **Status:** M0–M9 approved. This document creates no new architecture, resolves no new gap, and alters no prior decision. It is a pure **sequencing and execution** document — it converts the ten approved milestone specifications into one ordered, file-level, dependency-aware plan a development team can execute in a single pass.
> **Authority:** IMPLEMENTATION_ROADMAP.md, BUILD_ORDER.md, and M0_FOUNDATION.md through M9_RSVP_GUESTBOOK.md, all approved. Every fact below traces to one of those eleven documents; none is restated in full — each item below cites the milestone document and section it comes from.
> **Scope boundary:** This plan covers **only M0–M9** — the approved range. The Payment System, Analytics System, and Production Deployment & Operations milestones (`M10`/`M11`/`M12` in IMPLEMENTATION_ROADMAP.md, `Phase L`/`Phase M`/`Phase N` in BUILD_ORDER.md) are **not** approved yet and are referenced here only where their already-fixed migration numbers (`091`–`105`, `106`–`119`) must not be collided with.

---

## 1. Master Phase Sequence

| Phase | Milestone Document | One-line Goal | Hard Dependency |
|---|---|---|---|
| M0 | M0_FOUNDATION.md | Infrastructure substrate: Terraform, Supabase projects, empty Next.js shell | — |
| M1 | M1_CORE_MULTI_TENANT_FOUNDATION.md | Core schema (15 tables), RLS foundation, JWT claims, feature/quota resolvers | M0 |
| M2 | M2_DATABASE_DOMAIN_COMPLETION.md | Cross-domain schema completion (Guest/RSVP/Package/Theme/Analytics-baseline extensions) | M1 |
| M3 | M3_AUTHENTICATION_AUTHORIZATION.md | `requireAuth()`/`requireSession()` contracts, permission-string system, RBAC consolidation | M1 |
| M4 | M4_ADMIN_ARCHITECTURE.md | Admin/reseller architecture; `super_admin` and impersonation-audit resolutions | M1, M3 |
| M5 | M5_PACKAGE_FEATURE_SYSTEM.md | Full 4-tier package/feature catalog, resolution engine, quota/upgrade/downgrade rules | M1, M2 |
| M6 | M6_THEME_SYSTEM.md | Theme registry, rendering pipeline, asset strategy, package gating | M1, M5 |
| M7 | M7_INVITATION_MANAGEMENT.md | Invitation lifecycle, slug/section rules, render-time feature-gate resolution | M1, M5, M6 |
| M8 | M8_GUEST_MANAGEMENT.md | Guest domain; `guest_groups`/`guest_categories` scoping resolutions | M1, M7 |
| M9 | M9_RSVP_GUESTBOOK.md | RSVP/guestbook lifecycle, attribution, moderation, spam-protection rules | M1, M7, M8 |

**Strict execution order:** M0 → M1 → M2 → M3 → M4 → M5 → M6 → M7 → M8 → M9. M2/M3 may be worked in parallel by separate engineers once M1 is complete (both depend only on M1), but M2 must finish before M5 begins (M5 needs M2's package/feature-table extensions) and M3 must finish before M4 begins (M4 needs M3's `requireAuth()` contract). From M5 onward the chain is strictly linear.

**Gate at the end of this plan:** completing M9 reaches the ⭐ MVP Milestone gate already defined in IMPLEMENTATION_ROADMAP.md — this plan does not redefine that gate, it is simply the last point this plan's scope reaches.

---

## 2. Exact Migration Order

One consolidated ledger, reproducing — not renumbering — every migration each milestone already specified.

```
── M1 (001–017) ──────────────────────────────────────────────────────────
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

── M2 (018–033) ──────────────────────────────────────────────────────────
018_invitations_add_deleted_at.sql
019_guests_add_group_category_deleted_at.sql
020_create_guest_groups.sql
021_create_invitation_events.sql
022_create_invitation_analytics.sql
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

── M3 ─────────────────────────────────────────────────────────────────────
(none — M3_AUTHENTICATION_AUTHORIZATION.md §23 confirms zero schema change)

── M4 (034) ───────────────────────────────────────────────────────────────
034_users_add_is_super_admin.sql

── M5 ─────────────────────────────────────────────────────────────────────
(none — seed data only; see §6 Phase M5 Deliverables. Not migration-numbered,
 delivered via supabase/seed.sql per M5_PACKAGE_FEATURE_SYSTEM.md §19.)

── M6 ─────────────────────────────────────────────────────────────────────
(none — M6_THEME_SYSTEM.md §19 confirms zero schema change)

── M7 ─────────────────────────────────────────────────────────────────────
(none — M7_INVITATION_MANAGEMENT.md §22 confirms zero schema change)

── M8 (035–036) ──────────────────────────────────────────────────────────
035_guest_groups_add_scoping.sql
036_create_guest_categories.sql

── M9 (037) ───────────────────────────────────────────────────────────────
037_guestbook_entries_add_ip_address.sql
```

**Reserved, unconsumed by this plan:** `038`–`090`. **Fixed, not to be touched by anything in this plan:** `091`–`105` (M10 Payment System) and `106`–`119` (M11 Analytics System), per PHASE10/PHASE11's own appendices, restated in M2 §3/§19/§22, M5 §19, M7 §22, M8 §20, M9 §20.

**Ordering rules carried forward (M2 §22, restated):** `020` (`guest_groups` creation) must precede the FK-bearing part of `019` if applied at the SQL-constraint level in that relative order; `023` precedes `024`; `029` precedes `030`; `031` precedes `032`. `035`/`036` (M8) must run **after** `020`/`021` (M2) since they alter/extend tables M2 already created.

---

## 3. Exact Coding Order

A single linear build sequence. Each step names the milestone document and section governing it — no new file path or service responsibility is introduced beyond what that document already specifies.

```
 1. infra/terraform/*, infra/supabase/*, .env.example, package.json/tsconfig/tailwind/next.config
    [M0_FOUNDATION §2–§9]
 2. lib/supabase/client.ts, server.ts, middleware.ts (empty stubs)
    [M0_FOUNDATION §3]
 3. Migrations 001–017 (table creation, in the FK-respecting order M1 §25 specifies)
    [M1 §13, §25]
 4. lib/auth/permissions.ts, lib/packages/features.ts, lib/packages/limits.ts,
    config/features.ts, lib/tenant/resolver.ts
    [M1 §17]
 5. app/middleware.ts (tenant/Host resolution + JWT validation)
    [M1 §11, §19/§20]
 6. Auth Hook: JWT claim minting (initial version — role from users.role only;
    super_admin/reseller_admin override priority completed in step 14)
    [M1 §11]
 7. Folder scaffold: every route group, every stub page/route, hooks/, types/, public/
    [M1 §19]
 8. Migrations 018–033 (M2's domain-completion extensions and new tables)
    [M2 §5, §22]
 9. lib/auth/api-guard.ts (requireAuth()), lib/auth/session.ts extended (requireSession())
    [M3 §4, §17]
10. AuthUser assembly logic: merge JWT claims with users.full_name/users.email lookup
    [M3 §6]
11. Permission-string constant set (subscription:write, subscription:read,
    reseller:billing:read, analytics:read, reseller:analytics:read) wired into
    requireAuth()'s lookup table
    [M3 §8]
12. Migration 034 (users.is_super_admin)
    [M4 §22]
13. Auth Hook: completed priority algorithm
    (is_super_admin → reseller_admin via resellers.owner_user_id → literal users.role)
    [M4 §4.3]
14. Impersonation token issuance logic: sub-retention rule, tenant_id/role/package_id
    override, audit_logs.new_data convention
    [M4 §9]
15. /admin/* and /reseller/* route-group pages (structural shells matching the
    module lists in M4 §3/§10/§11 — content populated by later, not-yet-approved
    milestones where no route path is cited)
    [M4 §10–§11, §16–§17]
16. Seed data: Basic/Premium/Ultimate packages + full package_features matrix
    (including analytics_export, qr_checkin registry additions)
    [M5 §6, §7, §19]
17. Redis feature-cache wiring inside lib/packages/features.ts (60s TTL,
    invalidate-on-subscription-change/add-on-purchase hooks declared, actual
    invalidation call sites added when M10/M11 land)
    [M5 §7]
18. components/invitation/themes/{classic,modern,floral}/, themes/index.ts,
    public/themes/ previews
    [M6 §4, §7, §12]
19. Theme-selection precondition checks (is_active, PREMIUM_THEMES entitlement)
    wired into whatever invitation-creation path step 20 builds
    [M6 §10, M7 §5]
20. app/(app)/invitations/new/, [id]/edit/, components/invitation/editor/,
    components/invitation/sections/ (property-panel pattern, not drag-and-drop)
    [M7 §5–§6, §10]
21. app/inv/[slug]/page.tsx full ISR/SSR implementation; section render-time
    feature-gate checks (useFeatureFlag() per section, PHASE1 §7.2 pattern)
    [M7 §6, §16, M6 §6]
22. Publish/archive transition logic (status + published_at write; downgrade-
    triggered archival query exactly per PHASE10 §10.3's shape, wired for when
    M10 lands)
    [M7 §7–§8]
23. Migrations 035–036 (guest_groups scoping, guest_categories creation)
    [M8 §20]
24. app/(app)/invitations/[id]/guests/, guest CRUD/import scaffolding,
    personal_link generation point
    [M8 §5–§6, §9, §13–§14]
25. Ownership cross-check logic: group_id/category_id must match the guest's own
    invitation_id (application-layer, no DB trigger exists)
    [M8 §12]
26. Migration 037 (guestbook_entries.ip_address)
    [M9 §20]
27. RSVP submission path: precondition checks (published, is_rsvp_open, rate
    limit 10/min/IP), guest_id attribution via personal_link cross-check
    [M9 §5, §11–§12]
28. Guestbook submission path: moderation_status default, is_spam column wiring
    [M9 §8–§9]
29. components/rsvp/RsvpForm.tsx, GuestbookWall.tsx; live-feed realtime channel
    wiring (one channel per invitation, 20-row cap, approved-only filter for
    guestbook) — full live dashboard composition deferred to M11, base channel
    pattern established now per M9 §13–§14
    [M9 §13–§14]
30. 90-day raw-IP purge job stub for rsvp_responses.ip_address/guestbook_entries.
    ip_address (field-level null-out, not row delete) — full cron scheduling is
    an M12 (Production Deployment) concern; the job logic itself belongs here
    [M9 §10]
```

---

## 4. Exact Backend Implementation Order

Service/module build order, consolidated across all ten milestones, in the order each becomes buildable (i.e., after its own dependencies exist):

1. `lib/supabase/server.ts` → `createAdminClient()` signature (M0 §1, stub; M1 §17 first real caller context established).
2. `lib/auth/permissions.ts` → RBAC helper exposing the M3 §9 three-matrix reference table.
3. `lib/packages/features.ts` → `resolveFeature()`, four-tier priority (M1 §17), expiry fall-through precision (M5 §14).
4. `lib/packages/limits.ts` → `checkQuota()`, per-tenant vs. per-invitation scoping split (M5 §10).
5. `lib/tenant/resolver.ts` → subdomain/Host → tenant/reseller context (M1 §17, M4 §5).
6. `lib/auth/api-guard.ts` → `requireAuth(request, permission?)` (M3 §17).
7. `lib/auth/session.ts` (extended) → `requireSession()` (M3 §4, §17).
8. Auth Hook function → full claim-minting priority algorithm (M4 §4.3) — built in two passes (step 6 of §3 above, completed at step 13).
9. Impersonation-issuance service → sub-retention + override rule (M4 §9.2).
10. Package/feature seed-loader (M5 §19) — not a runtime service, a one-time data-loading script.
11. Theme code registry (`components/invitation/themes/index.ts`) → slug-to-component resolution (M6 §4).
12. Invitation lifecycle service (create/edit/publish/archive) — scoped exactly to what M7 §5–§8 specify; no CRUD route path is invented where M7 flags one as uncited.
13. Section render-time gate (per-component `useFeatureFlag()` calls, not a centralized service) — M7 §16's resolved pattern.
14. Guest service (CRUD/import scaffolding, M8 §5/§13) and the ownership cross-check (M8 §12).
15. RSVP submission service (M9 §5/§11/§12) and guestbook submission service (M9 §8) — built last, since both depend on the guest-attribution logic step 14 establishes.

**Explicit non-services (flagged, not built, consistent with each milestone's own deferral):** the exact `guest_import_batches` job processor, the spam-detection algorithm, the moderation-action endpoint, the public RSVP/guestbook INSERT RLS policy. None of these has a citation to build against; building them now would mean inventing behavior no milestone specified.

---

## 5. Exact Frontend Implementation Order

1. Empty route-group shells: `(marketing)`, `(auth)`, `(app)`, `(admin)`, `(reseller)`, `app/inv/[slug]` (M1 §19).
2. Auth pages: login, register (M1 §19).
3. Empty dashboard shell: invitation list placeholder, quick-stats placeholder (M1 §19, IMPLEMENTATION_ROADMAP.md's MVP description).
4. `components/ui/` base design system (M0 §3, shadcn/ui scaffold).
5. Admin/reseller module page shells matching the exact lists in M4 §3/§10/§11 — structural only, no content for routes M4 §16/§17 flags as uncited.
6. Theme renderer components (`classic`/`modern`/`floral`) and the property-panel editor shell (M6 §4, M7 §10).
7. `app/(app)/invitations/new/`, `[id]/edit/` — full property-panel editing surface, `couple_data`/`customization` write paths (M7 §6).
8. `app/inv/[slug]/page.tsx` — full theme-composed public render, ISR (published) / SSR (draft) per the existing PHASE1 §10.5 policy (M6 §6, M7 §6).
9. `app/(app)/invitations/[id]/guests/` — guest list/CRUD/import UI scaffold (M8 §14).
10. `components/rsvp/RsvpForm.tsx` (public submission form) and `components/rsvp/GuestbookWall.tsx` (realtime feed) (M9 §13–§14).
11. `app/(app)/invitations/[id]/rsvp/` — owner-facing RSVP summary shell (consumes `get_rsvp_summary()` once a later milestone resolves it; shell only for now).

**Not built in this plan (flagged, consistent with each milestone):** the moderation-approve/reject UI action, the section-reorder control (no UI mechanism is cited, M7 §11), the guest-list search/filter UI beyond the one analytics-adjacent example M8 §11 cites.

---

## 6. Exact Testing Order

Tests are written and run **in the order their subject becomes buildable**, not batched to the end:

1. **Unit — M1:** `resolveFeature()` four-branch test, `checkQuota()` per-resource test, RBAC matrix lookup test (M1 §24).
2. **Integration — M1:** RLS cross-tenant denial on `invitations`/`guests`/`rsvp_responses`; public-read of published-only invitations; reseller-client-read scoping (M1 §24).
3. **Unit — M3:** permission-string gating for every (role, permission) pair across all three RBAC matrices; `AuthUser.fullName`/`email` assembly correctness (M3 §22).
4. **Integration — M4:** `is_super_admin` priority over `reseller_admin`; `is_super_admin` unsettable via any route; impersonation `sub`-retention and `audit_logs.new_data.impersonated_tenant_id` population; reseller-impersonation boundary (M4 §21).
5. **Unit — M5:** `calculatePrice()` all three billing cycles incl. `price_lifetime` `NULL` fallback; quota scoping (per-invitation vs. per-tenant) (M5 §18).
6. **Integration — M5:** downgrade-triggered archival/deactivation exact ordering (oldest invitations, newest non-owner users) (M5 §18).
7. **Integration — M6:** `PREMIUM_THEMES` gating; rendering-output determinism for ISR cache-safety; `REMOVE_PLATFORM_BADGE` consistency across every theme (M6 §18).
8. **Integration — M7:** ownership-pairing rejection (no DB trigger exists, so this MUST be tested at the application layer); render-time vs. creation-time feature-gate distinction; archive-query exact shape; public-read boundary across `status`/`deleted_at` (M7 §21).
9. **Integration — M8:** `guest_groups`/`guest_categories` cross-invitation rejection; `group_label`/`group_id` independence; personal-link cross-invitation rejection; soft-delete exclusion from `guest_engagement_summary` (M8 §19).
10. **Integration — M9:** open-vs-personalized attribution split exactly per `rsvp_by_group`'s `guest_id IS NOT NULL` clause; moderation-state live-feed filter; spam-exclusion universality; 90-day IP purge field-level scope; rate-limit enforcement (M9 §19).
11. **E2E — end of M9, the MVP smoke path (already named in IMPLEMENTATION_ROADMAP.md, executed here for the first time against this plan's completed scope):** signup → tenant + Free package assigned → create invitation → select theme → publish → guest receives personalized link → submits RSVP → posts to guestbook → owner sees both on the live feed, guestbook entry pending until moderated.

---

## 7. Exact Deployment Preparation Order

1. **Environment setup** — staging + production Supabase projects, `ap-southeast-1`, Pro tier, PgBouncer transaction pooling (M0 §7.1); Vercel staging alias live (M0 §10/§19 acceptance criteria).
2. **Secrets** — vault-first flow established in M0 §5; the five M0-scope app variables (`NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `NEXT_PUBLIC_APP_URL`, `NEXT_PUBLIC_APP_DOMAIN`) plus the five Terraform-tooling credentials (`TF_CLOUD_API_TOKEN`, `CLOUDFLARE_API_TOKEN`, `VERCEL_API_TOKEN`, `UPSTASH_API_KEY`, `DOPPLER_TOKEN`); `GOOGLE_OAUTH_CLIENT_ID`/`SECRET` added at M3 per that milestone's specification note (M3 §4).
3. **Migrations applied to staging, then production, in the exact order in §2** — after each milestone's own migration batch is reviewed (001–017 after M1; 018–033 after M2; 034 after M4; 035–036 after M8; 037 after M9).
4. **Domains** — wildcard `*.weddingplatform.com` confirmed live from M0; reseller custom-domain CNAME lookup capability exercised (not yet rendered with real branding) once M4's middleware Host-resolution logic lands.
5. **Storage** — no invitation-media bucket name is cited anywhere (M7 §13's flagged gap); this plan does **not** provision one, since doing so would require naming something no milestone names. The `public/themes/` static asset path (build-time, not Storage) is provisioned as part of every deploy from M6 onward.
6. **Monitoring** — out of this plan's scope; PHASE12 §10's observability stack is an M12 (Production Deployment) concern. The only monitoring-adjacent fact this plan's scope touches is the `/dashboards/multi-tenant` citation noted in M4 §20, recorded there for forward reference only.
7. **First MVP-scope deploy** — after M9's migration (`037`) and the E2E smoke test in §6 step 11 pass on staging, tag and deploy the MVP-scope build, consistent with IMPLEMENTATION_ROADMAP.md's own `v0.5.0-mvp` tagging convention extended through this plan's `v1.0.0` (M9's own closing tag).

---

## 8. Phase-by-Phase Breakdown

### Phase M0
- **Goal:** Stand up the infrastructure substrate (M0_FOUNDATION.md §1).
- **Files:** `infra/terraform/**`, `infra/supabase/{migrations,seed.sql,config.toml}`, `.env.example`, `next.config.ts`, `tailwind.config.ts`, `tsconfig.json`, `package.json`, `lib/supabase/{client,server,middleware}.ts` (stubs), `components/ui/` (scaffold) — exact contents per M0_FOUNDATION.md §2–§8.
- **Dependencies:** None.
- **Deliverables:** Empty Supabase projects (prod + staging); clean `terraform plan`; empty Next.js app deployed to staging.
- **Acceptance Criteria:** M0_FOUNDATION.md §10, in full.

### Phase M1
- **Goal:** Working multi-tenant skeleton — schema, RLS foundation, JWT claims, feature/quota resolvers (M1_CORE_MULTI_TENANT_FOUNDATION.md §1).
- **Files:** Migrations `001`–`017`; `lib/auth/{session,permissions}.ts`; `lib/packages/{features,limits}.ts`; `lib/tenant/resolver.ts`; `config/{features,packages,site}.ts`; `app/middleware.ts`; full route-group folder scaffold (M1 §19).
- **Dependencies:** M0.
- **Deliverables:** 15 tables; `tenant_isolation`/`public_invitation_read`/`reseller_client_read` on `invitations`/`guests`/`rsvp_responses`; JWT claims minted; Free package seeded.
- **Acceptance Criteria:** M1_CORE_MULTI_TENANT_FOUNDATION.md §26, in full.

### Phase M2
- **Goal:** Complete the cross-domain schema gaps PHASE10/PHASE11 demonstrably require (M2_DATABASE_DOMAIN_COMPLETION.md §1).
- **Files:** Migrations `018`–`033`.
- **Dependencies:** M1.
- **Deliverables:** `invitations.deleted_at`; `guests.{group_id,category_id,deleted_at}`; baseline `invitation_events`/`invitation_analytics`/`qr_codes`/`qr_checkins`; `rsvp_responses.{is_spam,meal_choice}`; `guestbook_entries`; `packages.{status,is_public,price_lifetime,max_team_members}`; `tenant_subscriptions`' six lifecycle columns; `add_ons`/`tenant_add_ons`; `vouchers`/`voucher_redemptions`; `audit_logs.actor_role`.
- **Acceptance Criteria:** M2_DATABASE_DOMAIN_COMPLETION.md §28, in full.

### Phase M3
- **Goal:** Finalize the `requireAuth()`/`requireSession()` contracts and the permission-string system (M3_AUTHENTICATION_AUTHORIZATION.md §1).
- **Files:** `lib/auth/api-guard.ts`; `lib/auth/session.ts` (extended).
- **Dependencies:** M1.
- **Deliverables:** Working `requireAuth(request, permission?)`/`requireSession()`; `AuthUser` shape resolved against `users.full_name`/`users.email`; consolidated three-matrix RBAC reference; consolidated route-protection map.
- **Acceptance Criteria:** M3_AUTHENTICATION_AUTHORIZATION.md §24, in full.

### Phase M4
- **Goal:** Admin/reseller architecture; resolve `super_admin` designation and impersonation audit attribution (M4_ADMIN_ARCHITECTURE.md §1).
- **Files:** Migration `034`; admin/reseller route-group page shells per M4 §3/§10/§11.
- **Dependencies:** M1, M3.
- **Deliverables:** `users.is_super_admin`; completed Auth Hook priority algorithm; impersonation issuance with `sub`-retention; `audit_logs.new_data` impersonation convention.
- **Acceptance Criteria:** M4_ADMIN_ARCHITECTURE.md §23, in full.

### Phase M5
- **Goal:** Full four-tier package/feature catalog and resolution/quota/upgrade/downgrade rules (M5_PACKAGE_FEATURE_SYSTEM.md §1).
- **Files:** Seed-data update to `supabase/seed.sql` (no migration file).
- **Dependencies:** M1, M2.
- **Deliverables:** Basic/Premium/Ultimate `packages` rows; full `package_features` matrix incl. `analytics_export`/`qr_checkin`; Redis feature-cache specification wired into `lib/packages/features.ts`.
- **Acceptance Criteria:** M5_PACKAGE_FEATURE_SYSTEM.md §20, in full.

### Phase M6
- **Goal:** Theme registry, rendering pipeline, asset and package-gating rules (M6_THEME_SYSTEM.md §1).
- **Files:** `components/invitation/themes/{classic,modern,floral}/`, `themes/index.ts`; `public/themes/` previews.
- **Dependencies:** M1, M5.
- **Deliverables:** Theme code/database dual-registry; rendering pipeline; `PREMIUM_THEMES` gate wired to `resolveFeature()`.
- **Acceptance Criteria:** M6_THEME_SYSTEM.md §20, in full.

### Phase M7
- **Goal:** Invitation lifecycle, slug/section rules, resolved render-time feature-gate enforcement (M7_INVITATION_MANAGEMENT.md §1).
- **Files:** `app/(app)/invitations/{new,[id]/edit}/`; `app/inv/[slug]/page.tsx`; `components/invitation/{editor,sections}/`.
- **Dependencies:** M1, M5, M6.
- **Deliverables:** Create/edit/publish/archive flows exactly per M7 §5–§8; section render-time gating resolved and generalized.
- **Acceptance Criteria:** M7_INVITATION_MANAGEMENT.md §23, in full.

### Phase M8
- **Goal:** Guest domain; resolve `guest_groups`/`guest_categories` scoping (M8_GUEST_MANAGEMENT.md §1).
- **Files:** Migrations `035`–`036`; `app/(app)/invitations/[id]/guests/`.
- **Dependencies:** M1, M7.
- **Deliverables:** `guest_groups.{invitation_id,tenant_id}`; `guest_categories` table; closed ownership cross-check capability.
- **Acceptance Criteria:** M8_GUEST_MANAGEMENT.md §21, in full.

### Phase M9
- **Goal:** RSVP/guestbook lifecycle, attribution, moderation, spam protection (M9_RSVP_GUESTBOOK.md §1).
- **Files:** Migration `037`; `app/(app)/invitations/[id]/rsvp/`; `components/rsvp/{RsvpForm,GuestbookWall}.tsx`.
- **Dependencies:** M1, M7, M8.
- **Deliverables:** `guestbook_entries.ip_address`; submission flows; moderation state machine; open-vs-personalized attribution; live-feed channel pattern.
- **Acceptance Criteria:** M9_RSVP_GUESTBOOK.md §21, in full.

---

## 9. Open Items Register (Carried Forward, Not Closed by This Plan)

This plan resolves nothing new. It only sequences what M0–M9 already resolved or already flagged. For execution visibility, the resolved and still-open items are listed once, together:

**Resolved across M0–M9 (implemented per §3/§4 above):**
- `super_admin` designation (`users.is_super_admin`, M4).
- Impersonation audit attribution (`sub`-retention rule, M4).
- `guest_groups` scoping (`invitation_id`/`tenant_id`, M8).
- `guests.category_id`'s FK target (`guest_categories`, M8).
- `guestbook_entries.ip_address` (M9).
- Section-level feature-gate enforcement timing (render-time, M7, resolving a question M6 left open).

**Still open at the end of M9 (none invented, none closed by this plan):**
- Team-member invitation flow (M1 §10).
- Deleted-tenant vs. suspended-tenant behavioral difference (M1 §12).
- RLS coverage gap on twelve M1 tables and every M2-introduced table (M1 §12, M2 §26).
- `guest_import_batches`, `package_feature_snapshot`, `theme_experiments`, `rsvp_daily_trend`/`rsvp_by_category`/`rsvp_response_rate`/`guest_rsvp_status`/`guest_checkin_status`/`get_rsvp_summary()` schemas (M2, carried through M5/M6/M9 unresolved).
- Add-on-to-feature-entitlement mechanism; reseller "platform floor" price enforcement; `packages.is_active`/`status` coexistence (M5).
- Free-tier "3 basic themes" subset mechanism; theme versioning; `config_schema` validation; code/database theme-registry sync (M6).
- Slug generation/format algorithm; photo-quota disambiguation (couple photo vs. gallery); invitation-media storage bucket name; section-reorder UI mechanism; core invitation CRUD route paths; pre-publish validation; unpublish flow (M7).
- Core guest CRUD route paths; core guest search/filter UI; personal-link tier gating; `guest_import_batches` schema (M8, restated).
- Guestbook content/message column; RSVP resubmission flow; `rsvp_deadline` enforcement; spam-detection algorithm; public RSVP/guestbook INSERT RLS policy; moderation-action route and permission (M9).

Every item above remains exactly as flagged in its originating milestone document. None is a blocker for executing this plan through M9's own acceptance criteria; each is recorded here so the team executing this plan does not mistake an absence of citation for an absence of work still to do.

---

## 10. Completion Gate

This plan is complete when:
- [ ] Every migration in §2 has been applied, in order, to staging and then production.
- [ ] Every step in §3 has been implemented in the order given.
- [ ] Every test in §6 passes, culminating in the MVP smoke path (§6, step 11).
- [ ] Every per-phase Acceptance Criteria reference in §8 is satisfied in full, against its originating milestone document.
- [ ] The Open Items Register (§9) has been reviewed and logged in the team's tracking system, with no item silently dropped.

**Once every box above is checked, the ⭐ MVP Milestone gate defined in IMPLEMENTATION_ROADMAP.md is ready for evaluation.**

---

*End of IMPLEMENTATION_EXECUTION_PLAN.md*
