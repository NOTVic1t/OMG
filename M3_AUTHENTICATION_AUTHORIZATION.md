# M3_AUTHENTICATION_AUTHORIZATION.md
# Wedding Invitation SaaS Platform — Milestone M3: Authentication & Authorization

> **Version:** 1.0.0
> **Implementation authority:** BUILD_ORDER.md — Phase D (`= M3` in IMPLEMENTATION_ROADMAP.md)
> **Upstream source documents:** PHASE1_ARCHITECTURE.md (§2.4, §5, §8, §9, Appendix B), PHASE10_PAYMENT_SYSTEM.md (§15, §16, and every literal `requireAuth`/`auth.user.*` call site), PHASE11_ANALYTICS.md (§15, §16, and every literal `requireAuth`/`requireSession`/`auth.user.*` call site), PHASE12_DEPLOYMENT.md (§7.6, §9.3)
> **Predecessors:** M0_FOUNDATION.md, M1_CORE_MULTI_TENANT_FOUNDATION.md, M2_DATABASE_DOMAIN_COMPLETION.md — all complete.
> **Method:** Identical to M2's. BUILD_ORDER Phase D, taken narrowly, scopes only `requireAuth()`/`requireSession()` (per PHASE3_AUTH.md, not in this document set). Following the same consolidation precedent established in M2_DATABASE_DOMAIN_COMPLETION.md §1, this milestone gathers **every** authorization fact that PHASE10 and PHASE11 demonstrably depend on — permission strings, the `AuthUser` shape, route-protection mappings, service-role boundaries — because those facts are cited concretely (as literal function calls and table column reads) throughout both documents, even though PHASE3_AUTH.md itself is unavailable. Nothing is invented to fill a gap that has no citation; such gaps are flagged, exactly as in M1 and M2. No application code is included — only contracts, matrices, and flow specifications.

---

## 1. Objectives

1. Finalize the `requireAuth(request, permission?)` and `requireSession()` contracts that PHASE10 and PHASE11 already call by these exact names, with a signature precise enough that those documents' call sites are satisfied unmodified.
2. Resolve the gap between the JWT claim shape (PHASE1 §5.3) and the `AuthUser` object shape that PHASE10/11's code actually reads (`auth.user.tenantId`, `auth.user.fullName`, etc.) — these are not identical, and the difference must be specified.
3. Consolidate the complete, three-document permission matrix (PHASE1 §5.2, PHASE10 §15.1, PHASE11 §15.1) into one RBAC reference.
4. Consolidate the complete, two-document route-protection map (PHASE10 §15.2, PHASE11 §15.2) into one route protection reference.
5. State precisely, and only, what is cited regarding service-role containment, RLS/application-layer defense-in-depth, tenant suspension handling, and impersonation — flagging every place those citations stop short of a full specification.

## 2. Scope

**In scope:** Everything PHASE1 §2.4/§5/§8/§9 specifies about auth and roles (recapped by reference to M1, not restated), plus every authorization fact demonstrably required by PHASE10/PHASE11's literal code (permission strings, the `AuthUser` shape, the route-protection map, the service-role rule, the tenant-suspension check from PHASE12 §9.3).

**Out of scope:** Any new database table or column (BUILD_ORDER Phase D states "Database changes: None new" — confirmed and unchanged by this milestone, §23). Functioning admin/reseller UI (Phase E). Team-member invitation flow (flagged gap, §10). Impersonation's missing claim detail (flagged gap, §14).

**Resequencing note (consistent with M2's precedent):** this milestone absorbs the authorization groundwork that would otherwise be implicitly assumed, undocumented, by Phases E, L, and M when they each call `requireAuth()`/`requireSession()` for the first time. Those phases keep their own route-handler implementation work; this milestone only fixes the contract they call into.

## 3. Authentication Architecture

**Method (PHASE1 §2.4, unchanged):** email/password and Google OAuth, both via Supabase Auth.

**End-to-end flow (PHASE1 §2.4, verbatim):**
```
User visits app → Supabase Auth (email/password + Google OAuth)
                → JWT issued with custom claims: { tenant_id, role, package_id }
                → Next.js middleware validates JWT on every request
                → Role-based routing enforced server-side
```

This milestone does not change this flow. It specifies the two layers Phase D is responsible for finishing: (a) the server-side contract functions that turn a validated JWT into something a route handler can act on (§17), and (b) the exact permission/role data those functions must check against (§7–§9).

## 4. Supabase Auth Architecture

Recapped from M1 §11 (unchanged) and extended:

- Auth Hook ("a DB Function on user login," PHASE1 §5.3) mints the JWT claims in §6 by reading `users.tenant_id`, `users.role`, the `resellers.owner_user_id = users.id` relationship (for `reseller_admin`/`reseller_id`), and the tenant's active `tenant_subscriptions.package_id`.
- `users.id` and `auth.users.id` share the same value (M1 §7) — there is no separate identity mapping table.
- Google OAuth client credentials are configured per M1 §11's specification note (`GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`, not named in PHASE1 §10.2 but required to implement the already-decided method).

**New in this milestone — the `requireSession()` contract:** a server-side helper, callable from Server Components (not only route handlers), that resolves the current authenticated user without performing any permission-string check. Cited usage: PHASE11 §14.3, `const user = await requireSession();` inside a page component (`app/(app)/invitations/[id]/live/page.tsx`), used because viewing the live event dashboard is permitted for every role including `viewer` (PHASE11 §15.1) — i.e., `requireSession()` is the "merely authenticated" gate, distinct from `requireAuth()`'s permission-string gate (§17).

## 5. Session Architecture

- Session validation occurs on every request at the Edge Middleware layer (PHASE1 §2.4; M1 §11, §19/§20).
- **JWT staleness rule (cited, important, not previously surfaced in M1):** the `package_id` claim is minted at login/last-refresh time and does **not** automatically re-mint mid-session when a tenant's subscription changes. PHASE10 §9.2 confirms this directly: after a successful purchase, the client must explicitly call `supabase.auth.refreshSession()` (in `app/subscription/complete/page.tsx`) specifically "so the JWT picks up the new `package_id` claim immediately." Any code reading `auth.user.packageId` between a subscription change and the next refresh is reading a stale value. This is a standing behavior, not a defect; it is documented here so later phases do not mistake it for a bug.
- No other claim is cited as having the same staleness behavior; `tenant_id` and `role` are not expected to change within a session under normal operation (no role-change-mid-session flow is specified anywhere).

## 6. JWT Claims Architecture

**Exact, unchanged from M1 §8** (PHASE1 §5.3, with the role-naming compatibility note already established):

| Claim | Type | Notes |
|---|---|---|
| `sub` | string | `user.id` |
| `tenant_id` | string | always present |
| `role` | `'super_admin' \| 'reseller_admin' \| 'owner' \| 'editor' \| 'viewer'` | per M1 §8's compatibility note |
| `reseller_id` | string (optional) | present only when `role = 'reseller_admin'` |
| `package_id` | string | active subscription package; subject to the staleness rule in §5 |
| `exp` | number | standard JWT expiry |

**Gap resolved in this milestone — the `AuthUser` object shape.** PHASE10 and PHASE11's route handlers never read the raw JWT directly; they read an `auth.user` object assembled by `requireAuth()`/`requireSession()`. The fields literally read across both documents:

| Field (as read in code) | Cited at | Source |
|---|---|---|
| `auth.user.id` | PHASE10 §3.3 (`createdBy: auth.user.id`) | derived from `sub` |
| `auth.user.tenantId` | PHASE10 §3.3, §10.2; PHASE11 §6.3, §7.2, §13.2, *passim* | derived from `tenant_id` claim |
| `auth.user.role` | PHASE10 §12.3, §14.2; PHASE11 §11.2 | derived from `role` claim |
| `auth.user.resellerId` | PHASE10 §3.3, §13.3; PHASE11 §10.2 | derived from `reseller_id` claim |
| `auth.user.packageId` | PHASE11 §7.3 | derived from `package_id` claim, subject to §5's staleness rule |
| `auth.user.fullName` | PHASE10 §3.3 (`customerName: auth.user.fullName`) | **not present in the JWT claim shape at all** |
| `auth.user.email` | PHASE10 §3.3 (`customerEmail: auth.user.email`) | **not present in the JWT claim shape at all** |

**Flagged and resolved:** `fullName` and `email` are required by `AuthUser` but are absent from the JWT claim shape in PHASE1 §5.3. The only way to satisfy this without inventing a new claim is for `requireAuth()`/`requireSession()` to perform an additional lookup of the corresponding `users` row's `full_name` and `email` columns (both already present per M1 §13) at request time, and merge them into the returned `AuthUser` object. This is the resolution adopted here — it uses only columns already specified in the approved schema, adds no new claim, and is the minimum change consistent with PHASE10's literal usage.

## 7. Role Model

Recapped from M1 §8 (unchanged, including the role-naming compatibility note) and not restated in full here. Three determination paths, exact:

| Role | Determined by |
|---|---|
| `owner` / `editor` / `viewer` | `users.role` column directly (M1 §13 CHECK constraint) |
| `reseller_admin` | User is referenced as `resellers.owner_user_id` (M1 §8) |
| `super_admin` | **Not specified anywhere in the available documents** — flagged gap, carried forward unresolved from M1 §8. This milestone does not close it; PHASE3_AUTH.md is authoritative. |

## 8. Permission Model

**New in this milestone.** Distinct from the role×action matrix (§9): a separate, namespaced **permission-string** system that `requireAuth()` accepts as its second argument. Every literal permission string cited across PHASE10 and PHASE11:

| Permission string | Used by |
|---|---|
| `subscription:write` | `/api/subscription/purchase`, `/api/subscription/change`, `/api/add-ons/purchase`, `/api/orders/[id]/refund-request` (PHASE10 §15.2) |
| `subscription:read` | `/api/invoices/[id]/pdf` (PHASE10 §15.2) |
| `reseller:billing:read` | `/api/reseller/commission` (PHASE10 §15.2) |
| `analytics:read` | `/api/invitations/[id]/analytics`, `.../analytics/rsvp`, `.../guests/[guestId]/engagement`, `.../guests/engagement-summary`, `/api/analytics/tenant/invitations`, `/api/analytics/export`, `/api/analytics/export/[jobId]` (PHASE11 §15.2) |
| `reseller:analytics:read` | `/api/reseller/analytics`, `/api/reseller/analytics/clients` (PHASE11 §15.2) |

**Naming convention (observed, not separately documented anywhere, inferred only from the five examples above):** `<resource>:<action>` for tenant-facing permissions, with an optional `<scope>:` infix (`reseller:`) when the permission applies to a reseller-scoped surface rather than a tenant-scoped one. No permission string is cited for the Invitation, Guest, or RSVP domains (Phases H/I/J) — those routes' permission strings are not yet defined in any available document and are flagged as an open item for whichever phase first implements them.

**Two distinct enforcement patterns (both cited, both retained as-is):**
1. **Permission-string lookup** — `requireAuth(request, '<permission>')`, used for every tenant/reseller-facing route in the table above.
2. **Direct role comparison** — `requireAuth(request)` (no permission string) followed by a manual `if (auth.user.role !== 'super_admin')` check, used for every `/api/admin/*` route (PHASE10 §12.3, §14.2; PHASE11 §11.2). These two patterns are not interchangeable in the cited code and this specification does not collapse them into one.

**A third, additional, always-present layer — identity/ownership checks beyond the permission string:** reseller-scoped routes additionally require `auth.user.resellerId` to be non-null even after the `reseller:*` permission string passes (PHASE10 §13.3: `if (!auth.user.resellerId) return ... 403`; PHASE11 §10.2, §15.4 same pattern). Export routes additionally validate that the requested `scope_id` belongs to the requesting principal via `validateExportScopeOwnership()` (PHASE11 §13.2). A permission string passing is necessary but never sufficient on its own.

## 9. RBAC Matrix

The complete, three-document, role×action matrix. Column headers use the operative unprefixed role values (M1 §8 compatibility note).

**General platform actions (PHASE1 §5.2):**

| Action | super_admin | reseller_admin | owner | editor | viewer |
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

**Billing actions (PHASE10 §15.1):**

| Action | super_admin | reseller_admin | owner | editor | viewer |
|---|:---:|:---:|:---:|:---:|:---:|
| View own subscription / invoices | ✅ | ✅ | ✅ | ❌ | ❌ |
| Purchase / upgrade / downgrade plan | ✅ | ✅ | ✅ | ❌ | ❌ |
| Purchase add-on | ✅ | ✅ (for clients) | ✅ | ❌ | ❌ |
| Apply voucher | ✅ | ✅ | ✅ | ❌ | ❌ |
| Request refund | ✅ | ✅ | ✅ | ❌ | ❌ |
| View client subscriptions / billing | ✅ | ✅ (own clients) | ❌ | ❌ | ❌ |
| View own commission ledger | ✅ | ✅ | ❌ | ❌ | ❌ |
| Manage reseller voucher codes | ✅ | ✅ | ❌ | ❌ | ❌ |
| View all platform orders/revenue | ✅ | ❌ | ❌ | ❌ | ❌ |
| Mark manual order as paid | ✅ | ❌ | ❌ | ❌ | ❌ |
| Approve / reject refund requests | ✅ | ❌ | ❌ | ❌ | ❌ |
| View webhook logs | ✅ | ❌ | ❌ | ❌ | ❌ |
| Process commission payouts | ✅ | ❌ | ❌ | ❌ | ❌ |
| Manage payment gateway settings | ✅ | ❌ | ❌ | ❌ | ❌ |

**Analytics actions (PHASE11 §15.1):**

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

## 10. User Lifecycle

1. **Creation:** signup (email/password or Google OAuth) → `auth.users` row created by Supabase → corresponding `public.users` row created with the same `id`, a `tenant_id` (new tenant created alongside, per M1's MVP flow), and `role` defaulting to `owner` (M1 §13 default).
2. **Active use:** `users.is_active = TRUE` (default). Role may be `owner`, `editor`, or `viewer` within the tenant.
3. **Deactivation:** `users.is_active = FALSE` — used for team-quota enforcement (cross-referenced from PHASE10 §10.3's downgrade enforcement, M1 §7). No row deletion occurs.
4. **Reseller admin transition:** a `users` row additionally becomes a reseller admin when a `resellers` row is created with `owner_user_id` pointing at it, moving that reseller through `pending → active` (PHASE1 §9.2 steps 1–2, matching the `resellers.status` CHECK values already fixed in M1 §13).
5. **Deletion:** only via `auth.users` deletion, which cascades to `public.users` (M1 §7, `ON DELETE CASCADE`). No soft-delete is cited for `users` itself (distinct from `invitations`/`guests`, which do have `deleted_at` per M2 §10).

**Flagged gap:** "Invite team members" is a named permission (§9) with no supporting invitation-token table, email flow, or acceptance mechanism cited anywhere in the available documents. Not specified further here; governed by PHASE3_AUTH.md or PHASE4_ADMIN_ARCHITECTURE.md.

## 11. Invitation Access Rules

Exact boundaries, derived directly from §9's general matrix and M1 §21:

| Action | Allowed roles |
|---|---|
| Create | `super_admin`, `reseller_admin`, `owner`, `editor` |
| Edit | `super_admin`, `reseller_admin`, `owner`, `editor` |
| Publish | `super_admin`, `reseller_admin`, `owner` **only** — `editor` cannot publish |
| View (owner-side) | All five roles (`viewer` included, read-only) |
| View (public, anonymous) | Anyone, only if `status = 'published'` and (after M2) `deleted_at IS NULL` |

**Ownership constraint (M1 §21, unchanged):** every `invitations` row's `tenant_id` must equal the acting user's `tenant_id`, and `created_by` must equal the acting user's `id`. No DB trigger enforces this; it is an application-layer responsibility at the point of insert, reinforced at read time by RLS (`tenant_isolation`, `public_invitation_read`, `reseller_client_read` — M1 §16).

## 12. Tenant Access Rules

- Every authenticated request is implicitly scoped to `auth.user.tenantId` (§6); a user can never act as a different tenant within a normal session (no transfer/multi-tenant-membership mechanism exists — M1 §7).
- **Tenant suspension (new citation, PHASE12 §9.3):** "RLS-adjacent middleware checks `tenants.status` on every authenticated request and returns a 403 with an explanatory page, while the tenant's data remains intact and un-deleted." This is an additional middleware-layer check, distinct from and additional to the RLS `tenant_isolation` policy itself — it must run for every request, not only ones touching RLS-protected tables, since it also blocks dashboard/API access generally.
- **Flagged gap:** PHASE12 §9.3 describes the `suspended` behavior precisely but no available document describes what, if anything, differs for `status = 'deleted'` versus `'suspended'` at the access-control layer. Not resolved here.
- Reseller-linked read access to a tenant's data is governed by `reseller_client_read` (M1 §16) — read-only, scoped to whatever the reseller's own RLS policy permits; it does not grant write access.

## 13. Reseller Access Rules

- A user is a `reseller_admin` only via `resellers.owner_user_id` (§7) — there is no separate reseller-staff role; one reseller has exactly one owning user in the schema as specified (M1 §10, §13).
- **Package eligibility constraint (PHASE1 §9.4, exact):** "Resellers can only assign packages flagged `is_reseller = TRUE` to their clients. Platform admin controls which packages are reseller-eligible." This is enforced wherever a reseller assigns a package to a client tenant — not cited as a DB CHECK constraint, so it is an application-layer rule.
- **Custom domain / white-label flow (PHASE1 §9.2, exact sequence):** register → pending review → admin approval → active → custom domain CNAME → Edge Middleware `Host` header lookup against `resellers.custom_domain` → branding loaded from `resellers.branding` JSONB → client tenants signing up via the reseller domain get `tenant_id` linked to `reseller_id` (via `reseller_tenants`, M1 §13).
- Reseller dashboard/analytics access is **role-based, not package-based** (PHASE11 §10.1 design note, already cited in M2's domain boundaries): a reseller's own capability is independent of what plan any individual client tenant is on.

## 14. Admin Access Rules

- `super_admin` routes are protected by middleware/route-guard checking `role === 'super_admin'` (PHASE1 §8.2, Appendix B). The exact mechanism, per §8, is the direct role-comparison pattern (`requireAuth(request)` then `auth.user.role !== 'super_admin'`), not a permission string.
- **Service-role data access (PHASE1 §8.2):** super admin operations use `createAdminClient()` (service-role key, bypasses RLS entirely), instantiated only server-side within `/api/admin/*` routes — see §18 for the full, cross-document containment rule.
- **Impersonation (PHASE1 §8.3, exact):** "a signed impersonation token (24h TTL), generating a scoped JWT with the target tenant's `tenant_id` and `role: owner`" (role value normalized per §6's compatibility note). "All impersonated actions are written to `audit_logs` with the admin's `user_id` as the actor."
- **Flagged gap:** no claim is cited that would let the impersonation JWT carry both the impersonated tenant's context (`tenant_id`, `role: owner`) **and** the original admin's identity at the same time, which is what would be required to attribute audit-log entries to "the admin's `user_id`" as stated. No `impersonator_id`-style claim, or equivalent mechanism, appears anywhere in the available documents. This is left unresolved; PHASE3_AUTH.md or PHASE4_ADMIN_ARCHITECTURE.md is authoritative.

## 15. Middleware Architecture

`app/middleware.ts` (created in M1, finalized here) performs, in order, for every request:

1. **Host/subdomain resolution** — direct-tenant path (`app.weddingplatform.com`) vs. reseller white-label/custom-domain path (PHASE1 §2.2, M1 §3/§20).
2. **JWT validation** — invalid/missing session → redirect to `/login` (PHASE1 §2.4).
3. **Tenant suspension check (PHASE12 §9.3)** — for an authenticated request, read `tenants.status`; if `'suspended'`, return 403 with an explanatory page before any route handler runs.
4. **Claim/context attachment** — make the validated JWT claims (§6) available to downstream server components/route handlers, which then call `requireAuth()`/`requireSession()` (§17) as needed.
5. **CORS** — restrict to platform domains only (PHASE1 Appendix B, M1 §22).

No other middleware responsibility is cited anywhere in the available documents. Security headers/CSP are explicitly **not** middleware's responsibility — those are configured in `next.config.ts` at Phase N (PHASE12 §7.5, M0 §8.1's deferral).

## 16. Route Protection Strategy

The complete, two-document, exact route-to-permission map. No route outside these two documents has a defined permission string yet (flagged — Phases H/I/J's routes are not yet specified).

| Route | Method | Protection |
|---|---|---|
| `/api/subscription/purchase` | POST | `subscription:write` |
| `/api/subscription/change` | POST | `subscription:write` |
| `/api/add-ons/purchase` | POST | `subscription:write` |
| `/api/orders/[id]/refund-request` | POST | `subscription:write` (own tenant) |
| `/api/invoices/[id]/pdf` | GET | `subscription:read` |
| `/api/reseller/commission` | GET | `reseller:billing:read` + `resellerId` non-null check |
| `/api/webhooks/[provider]` | POST | Public, signature-verified (no `requireAuth()` call at all) |
| `/api/admin/orders/*` | ALL | Direct role check: `super_admin` |
| `/api/admin/refund-requests/*` | ALL | Direct role check: `super_admin` |
| `/api/admin/webhooks` | GET | Direct role check: `super_admin` |
| `/api/invitations/[id]/analytics` | GET | `analytics:read` (+ `analytics_basic` feature gate) |
| `/api/invitations/[id]/analytics/rsvp` | GET | `analytics:read` (+ `analytics_basic` feature gate) |
| `/api/invitations/[id]/guests/[guestId]/engagement` | GET | `analytics:read` (+ `analytics_advanced` feature gate) |
| `/api/invitations/[id]/guests/engagement-summary` | GET | `analytics:read` (+ `analytics_advanced` feature gate) |
| `/api/analytics/tenant/invitations` | GET | `analytics:read` (+ `analytics_basic` feature gate) |
| `/api/analytics/export` | POST | `analytics:read` (+ `analytics_export` feature gate, tenant/invitation scope only) |
| `/api/analytics/export/[jobId]` | GET | `analytics:read` (+ ownership check, no feature gate) |
| `/api/reseller/analytics` | GET | `reseller:analytics:read` + `resellerId` non-null check |
| `/api/reseller/analytics/clients` | GET | `reseller:analytics:read` + `resellerId` non-null check |
| `/api/admin/analytics` | GET | Direct role check: `super_admin` |
| `/api/admin/analytics/cohort-retention` | GET | Direct role check: `super_admin` |
| `/api/events/track` | POST | Public — no auth at all; rate-limited and gate-checked server-side instead (PHASE11 §15.4) |

**Rule for any future route (stated for forward consistency, not a new decision):** every route must fall into exactly one of the four patterns already evidenced above — (a) permission-string + `requireAuth()`, (b) direct role check via `requireAuth()` with no string, (c) public + signature verification (webhooks), or (d) public + rate limiting (event ingestion). No fifth pattern is cited anywhere.

## 17. API Authorization Strategy

**`requireAuth(request, permission?)` contract:**
- **Input:** the incoming `Request`/`NextRequest`, and an optional permission string (§8).
- **Output:** either an authorization context object exposing `.user` (the `AuthUser` shape, §6) when the request is authenticated and (if a permission string was given) authorized — **or** a `NextResponse` object representing the failure response (401 unauthenticated, 403 unauthorized), to be returned immediately by the caller.
- **Calling convention (cited verbatim across every call site in PHASE10/PHASE11):**
  ```
  const auth = await requireAuth(request, '<permission>');
  if (auth instanceof NextResponse) return auth;
  // auth.user.* is now safe to read
  ```
- When called without a permission string, `requireAuth()` performs authentication only; the caller is responsible for any subsequent role/identity check (§8's second pattern).

**`requireSession()` contract:**
- **Input:** none beyond ambient request context (called from a Server Component, not a route handler — PHASE11 §14.3).
- **Output:** the current authenticated user (or redirects/throws if unauthenticated — exact failure behavior not specified beyond "session" terminology; not resolved further here).
- Used where mere authentication (not a specific permission) is the gate, e.g. the live event dashboard, viewable by every role (§9).

**Authorization flow, exact, consolidating §6–§8 and §15–§16:**
```
Request
  → Edge Middleware (§15): Host resolution, JWT validation, tenant-suspension check, CORS
  → Route handler calls requireAuth(request, permission?) or requireSession()
      → JWT re-validated / session resolved
      → AuthUser assembled: JWT claims (§6) + users.full_name/users.email lookup (§6 gap resolution)
      → If permission string given: permission-string check against the role (§8)
      → If insufficient: return NextResponse(401/403) — caller returns it immediately
  → Route handler performs any additional identity/ownership check (§8's third layer:
      resellerId non-null, scope ownership, tenant_id match)
  → Route handler issues the actual data operation, itself further bounded by RLS (§19)
```

## 18. Service Role Boundaries

**The rule, consolidated exactly across all three citing documents:**
- PHASE1 §8.2: `createAdminClient()` is instantiated "only server-side within `/api/admin/*` routes, protected by middleware that validates `role === 'super_admin'` from JWT."
- PHASE10 §16.5 (expands the allowed-context list): "`createAdminClient()` (service role key) is only instantiated inside: webhook handlers, Edge Functions (cron jobs), and `/api/admin/*` routes after an explicit `role === 'super_admin'` check."
- PHASE11 §16.2 (reaffirms): "The service-role client is instantiated only inside Edge Functions (`supabase/functions/rollup-*`), never inside any `/api/*` route" — for the rollup-job context specifically.

**Consolidated rule adopted here (additive union of all three, no contradiction — webhook handlers are a context PHASE1 didn't mention but PHASE10 adds, and Edge Functions are common to all three):**

| Allowed context | Source |
|---|---|
| `/api/admin/*` routes, after an explicit `role === 'super_admin'` check | PHASE1 §8.2, PHASE10 §16.5 |
| Webhook handlers (`/api/webhooks/[provider]`) | PHASE10 §16.5 |
| Edge Functions / cron jobs (`supabase/functions/*`) | PHASE10 §16.5, PHASE11 §16.2 |

**Never permitted:** any other `/api/*` route, any client-bundle-reachable file, any Server Component rendering path. This is unchanged from M1 §22 and is the rule the automated CI audit (`scripts/audit-service-role-usage.ts`, Phase N) will enforce mechanically once it exists — the rule itself is binding from this milestone forward, ahead of that automation.

## 19. RLS Integration Strategy

- **Defense-in-depth (cited repeatedly, e.g. PHASE10 §16.1, PHASE7 per its own citation, PHASE11 §16.1):** every tenant-scoped query is protected by RLS **and** an explicit application-layer `.eq('tenant_id', auth.user.tenantId)` (or reseller-equivalent) filter. Neither layer is trusted alone.
- **The binding assumption this milestone makes explicit:** `auth.user.tenantId` (assembled by `requireAuth()`/`requireSession()`, §6) and the RLS policy's `(auth.jwt() ->> 'tenant_id')::UUID` (M1 §12) must always agree, because both derive from the same underlying JWT claim. If `requireAuth()` ever derives `tenantId` from anything other than the validated JWT's `tenant_id` claim, the two layers would silently diverge — this must not happen.
- **Coverage carried forward, unchanged:** RLS is enabled on exactly `invitations`, `guests`, `rsvp_responses` (M1 §16); the remaining tables, including every table added in M2, have no RLS policy (M2 §26, flagged gap, not closed here). `requireAuth()`'s permission-string/role check is therefore the **only** access control for every one of those uncovered tables — it is not a redundant second layer for them, it is the only layer, until a future phase closes the RLS gap.

## 20. Audit Logging Requirements

Extends M1 §23 / M2 §11, unchanged in mechanism (`audit_logs`, including the `actor_role` column added in M2 §5.8). What this milestone adds is **which auth-related actions are cited as requiring a log entry:**

| Action | Logged? | Source |
|---|---|---|
| Impersonation (every impersonated action) | ✅ Required, actor = admin's `user_id` | PHASE1 §8.3 (subject to the unresolved claim gap in §14) |
| Login / logout | Not cited anywhere | — |
| Permission denial (401/403) | Not cited anywhere | — |
| Manual order mark-paid (`super_admin`-gated) | ✅ Required | PHASE10 §16.4, §9.1 (`actor_role: 'system'` pattern) |

No blanket "log every authenticated request" rule is cited; only the specific actions above are. This milestone does not expand that list beyond what is cited.

## 21. Security Requirements

Carried forward from M1 §22 and re-stated against this milestone's scope:

| Requirement | Status after M3 |
|---|---|
| Admin routes protected by `role === 'super_admin'` middleware/guard | Now specified exactly (§14, §16) — implementation lands in Phase E. |
| Service role key never exposed to client bundle | Unchanged rule, now with the full three-document allowed-context list (§18). |
| RLS + application-layer filter, both required | Restated precisely (§19); the 12-table gap from M1/M2 is not closed here. |
| `requireAuth()`/`requireSession()` are the sole gate for every table without RLS | New, explicit consequence of §19, not previously stated this directly. |
| CORS to platform domains only | Unchanged (§15). |
| Tenant suspension enforced pre-route | New in this milestone (§12, §15), citing PHASE12 §9.3. |

## 22. Testing Requirements

Per BUILD_ORDER §6 (Phase D-attributed item) plus the additional surface this milestone specifies:

- `requireAuth()` permission-string gating verified for every role in §9's three matrices, for every permission string in §8 — both the "allowed" and "denied" outcome for each (role, permission) pair.
- `requireAuth(request)` (no string) + manual `role !== 'super_admin'` pattern verified for every `/api/admin/*` route in §16.
- `requireSession()` verified to return a valid user for every role (including `viewer`) on the live-event-dashboard-equivalent gate.
- `AuthUser` assembly test: confirm `fullName`/`email` are correctly populated from `users.full_name`/`users.email` (§6 gap resolution) and not left undefined.
- Session-staleness test: confirm `auth.user.packageId` does **not** change mid-session after a simulated subscription update until `refreshSession()` is called (§5).
- Tenant-suspension middleware test: a request from a user in a `'suspended'` tenant receives 403 before reaching any route handler (§12, §15).
- Reseller-route identity test: a request with a valid `reseller:*` permission but a null `resellerId` is rejected (§8's third layer).
- Service-role containment test: confirm `createAdminClient()` is referenced only in the three allowed contexts in §18 (manual review at this milestone; automated at Phase N).

## 23. Migration Requirements

**None.** Confirmed, unchanged from BUILD_ORDER Phase D's explicit statement: "Database changes: None new (uses Supabase-managed `auth.users`)." This milestone adds no table and no column. Every gap resolved in this document (the `AuthUser` field mapping in §6) is satisfied entirely by columns already present after M1/M2 (`users.full_name`, `users.email`) — no new migration file is created.

## 24. Acceptance Criteria

- [ ] `requireAuth(request, permission?)` and `requireSession()` exist with the exact calling convention in §17, and every PHASE10/PHASE11 call site that already invokes them compiles and behaves as those documents describe.
- [ ] Every permission string in §8 is enforced for every route in §16 — no route in that table is left unprotected.
- [ ] Every `/api/admin/*`-pattern route uses the direct role-comparison pattern, not a permission string.
- [ ] `AuthUser.fullName` and `AuthUser.email` are populated from `users.full_name`/`users.email`, not left blank and not sourced from a new, uncited claim.
- [ ] The three RBAC matrices in §9 are reproduced without modification anywhere they are referenced downstream.
- [ ] Tenant-suspension 403 behavior (§12, §15) is verified against a test tenant with `status = 'suspended'`.
- [ ] `createAdminClient()` usage, wherever it already exists (webhook handlers from later phases, Edge Functions), is confirmed to fall within the three contexts in §18 — none elsewhere.
- [ ] No new table, column, or migration file is introduced by this milestone.
- [ ] Every flagged gap in this document (§7 super_admin designation, §10 team-invite flow, §12 deleted-tenant behavior, §14 impersonation identity claim) remains explicitly open in project tracking, not silently closed.

## 25. Completion Checklist

- [ ] §3–§6 (authentication, Supabase Auth, session, JWT/AuthUser) match the cited behavior of every PHASE10/PHASE11 call site exactly.
- [ ] §7–§9 (role, permission, RBAC) carry forward M1 without contradiction and add the permission-string layer M1 did not yet specify.
- [ ] §11–§14 (invitation/tenant/reseller/admin access rules) are each traceable to a specific cited section.
- [ ] §15–§17 (middleware, route protection, API authorization) give a complete, consolidated, exact route map with no route left ambiguous.
- [ ] §18–§19 (service-role boundaries, RLS integration) state the full three-document service-role rule and the RLS coverage status inherited from M2.
- [ ] §22 tests are green.
- [ ] §23 confirms zero new migrations — verified against M2's migration ledger (M2 §22) to ensure no drift.
- [ ] Tag `v0.4.0` once every item in §24 is verified.

**Once every box above is checked, Phase E (Admin Architecture) may begin.**

---

*End of M3_AUTHENTICATION_AUTHORIZATION.md*
