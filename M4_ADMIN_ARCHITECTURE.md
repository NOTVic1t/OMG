# M4_ADMIN_ARCHITECTURE.md
# Wedding Invitation SaaS Platform — Milestone M4: Admin Architecture

> **Version:** 1.0.0
> **Implementation authority:** BUILD_ORDER.md — Phase E (`= M4` in IMPLEMENTATION_ROADMAP.md)
> **Upstream source documents:** PHASE1_ARCHITECTURE.md (§8, §9, Appendix B), PHASE10_PAYMENT_SYSTEM.md (§14, §16.4–§16.5), PHASE11_ANALYTICS.md (§10, §11, §15–§16), PHASE12_DEPLOYMENT.md (§7.6, §9.2–§9.4)
> **Predecessors:** M0_FOUNDATION.md, M1_CORE_MULTI_TENANT_FOUNDATION.md, M2_DATABASE_DOMAIN_COMPLETION.md, M3_AUTHENTICATION_AUTHORIZATION.md — all complete.
> **Method:** Identical discipline to M2/M3. Two items in this milestone — the `super_admin` operational model and the impersonation audit model — were explicitly flagged as unresolved gaps in M1 §8 and M3 §7/§14, with no citation anywhere specifying a mechanism. The user has explicitly directed this milestone to resolve both. They are resolved here using the **smallest possible additive change**, chosen by structural analogy to a mechanism the approved architecture *already* uses for an equivalent problem (`reseller_admin` determination), so that the resolution is a natural extension of an existing pattern rather than a new decision. Every other fact below is a direct citation. No application code is included.

---

## 1. Objectives

1. Specify the complete Admin and Reseller architecture exactly as PHASE1 §8/§9 describe it, consolidated with every admin/reseller-relevant fact cited in PHASE10 §14/§16 and PHASE11 §10/§11/§15/§16.
2. **Resolve the `super_admin` operational model** (flagged open in M1 §8, M3 §7): specify, with the minimum additive schema change, how a user is designated `super_admin` and how that designation flows into the JWT claim already approved in PHASE1 §5.3.
3. **Resolve the impersonation audit model** (flagged open in M3 §14): specify, using only the JWT claim shape and `audit_logs` columns already approved, how an impersonated action is correctly attributed to the impersonating admin/reseller, exactly as PHASE1 §8.3 requires.
4. Define the exact admin and reseller dashboard module structures, API surfaces, and access boundaries, consolidating PHASE1 §8.1/§9.1 with PHASE10's and PHASE11's admin/reseller modules.
5. Surface, rather than silently invent, every remaining gap (user-management module, role-change flow, admin-action audit completeness) that this milestone's two resolutions do not close.

## 2. Scope

**In scope:** The complete admin/reseller/tenant-administration architecture as cited across all four source documents; the two explicit resolutions in §4 and §9; the consolidated admin/reseller dashboard and API specifications.

**Out of scope:** Any table or feature not already cited (e.g., a platform-wide user-search module — flagged, not built). Functioning UI implementation (this is a specification milestone, consistent with every prior M-document). The automated CI service-role audit (`scripts/audit-service-role-usage.ts`) — that remains Phase N.

**Resolution method, stated once, applied twice:** both resolutions in this milestone follow the same rule: (a) use only columns/claims already approved wherever possible, (b) where a new column is unavoidable, add exactly one, additive-only, modeled on an existing precedent, (c) never expose the new mechanism through a self-service or tenant-facing path, since no such path is cited.

## 3. Admin System Architecture

**Module structure (PHASE1 §8.1, exact):**
```
/admin
├── /dashboard          Aggregate metrics: MRR, active tenants, RSVP volume
├── /tenants            List, search, view, suspend, impersonate tenants
│   └── /[id]           Tenant detail: subscription, usage, audit log
├── /packages           Create/edit packages and feature entitlements
├── /resellers           Manage resellers, commission rates, custom domains
│   └── /[id]           Reseller detail, client list, revenue share
├── /feature-flags      Platform-wide and per-tenant flag overrides
├── /themes             Upload and manage invitation themes
├── /orders             Payment history, refunds
├── /analytics           Platform-wide charts: signups, conversions, churn
└── /settings           Platform config: maintenance mode, email templates
```

**Elaborated by later documents (additive, not contradicting the list above):**
- `/orders` is elaborated by PHASE10 §14.1 into three sub-surfaces: `/admin/orders` (list + detail + mark-paid), `/admin/refund-requests` (queue + approve/reject), `/admin/webhooks` (log viewer).
- `/analytics` is elaborated by PHASE11 §11.1 into Growth/Engagement/Revenue/Package-Distribution sections plus cohort retention (§11.3).

**Access boundary (exact, restated from M3 §14, §16):** every `/admin/*` surface is gated by the direct role-comparison pattern — `requireAuth(request)` then `auth.user.role !== 'super_admin'` → 403 — never by a permission string. This is unchanged here.

## 4. Super Admin Architecture

### 4.1 The gap, exactly as previously flagged

M1 §8: "PHASE1 does not specify a column or table that designates a user as a super admin." M3 §7: same, carried forward unresolved. PHASE1 §5.3's JWT type permits `role: 'super_admin'`; PHASE10/PHASE11 code repeatedly checks `auth.user.role === 'super_admin'`; nothing anywhere specifies how a `users` row comes to produce that claim value.

### 4.2 Resolution (additive, structurally modeled on the existing `reseller_admin` mechanism)

`reseller_admin` is already determined **without** a value inside `users.role`'s CHECK constraint — it is determined by a separate relationship (`resellers.owner_user_id = users.id`, M1 §8). This milestone resolves `super_admin` the same way: by a separate marker, not by adding a fourth value to `users.role`'s existing, fixed CHECK constraint (`'owner' | 'editor' | 'viewer'`, M1 §13/§15 — unmodified, preserved exactly).

**New column:**

| Table.column | Type | Nullable | Default | Constraint |
|---|---|---|---|---|
| `users.is_super_admin` | BOOLEAN | NO | `FALSE` | — |

This is the single schema change in this milestone. It does not touch `users.role`'s CHECK constraint, does not add a new table, and does not alter any column specified in M1 or M2.

### 4.3 Auth Hook claim-minting algorithm (resolved, exact priority order)

The Auth Hook (PHASE1 §5.3, "a DB Function on user login") must determine the JWT `role` claim using this exact priority order, now fully specified for the first time:

```
1. IF users.is_super_admin = TRUE              → role = 'super_admin'
2. ELSE IF resellers.owner_user_id = users.id  → role = 'reseller_admin', reseller_id = resellers.id
3. ELSE                                         → role = users.role  (literal 'owner' | 'editor' | 'viewer')
```

This priority order is a direct consequence of the role hierarchy already approved in PHASE1 §5.1 (`SUPER_ADMIN → RESELLER_ADMIN → TENANT_OWNER → ...`) — super-admin status, where present, takes precedence over reseller-admin status, which takes precedence over the tenant-scoped literal role. No new precedence decision is being made; this specifies the mechanical order implied by a hierarchy that was already approved but never reduced to an algorithm.

**A super-admin user still has an ordinary `tenant_id` and `users.role` value** (since `users.tenant_id` remains `NOT NULL`, M1 §7) — exactly as already established for `reseller_admin` users (M1 §8: "even reseller owners must belong to some tenant"). The same structural fact now extends to super admins: they are platform staff who happen to also be a `users` row scoped to some tenant, with their elevated JWT role coming entirely from the override in step 1, not from anything tenant-specific.

### 4.4 Governance of the new column (closing the obvious follow-on risk)

`users.is_super_admin` must **never** be settable through any tenant-facing, reseller-facing, or self-service route. No promotion/self-elevation flow is cited anywhere in the approved architecture, and none is introduced here — inventing one would be a new feature. The only way this column may be set is a direct, out-of-band administrative database operation (e.g. a platform operator executing a manual statement against the production database under existing operational access controls, PHASE12 §8.2's vault-access-review precedent). **No `/api/admin/*` route in this milestone exposes a way to set this column on another user.** This is the deliberate, minimal scope of the resolution — it makes the already-approved capability operationally possible without adding a promotion feature that was never decided.

## 5. Reseller Architecture

**Capabilities (PHASE1 §9.1, exact):**

| Capability | Detail |
|---|---|
| White-label branding | Custom logo, primary color, company name |
| Custom domain | `dashboard.resellerbrand.com` via CNAME |
| Client management | Create clients, assign packages, manage subscriptions |
| Custom pricing | Resellers set their own prices (above platform floor) |
| Commission tracking | Revenue share dashboard |
| Client impersonation | View any client dashboard (audit-logged) — resolved in §9 |

**White-label flow (PHASE1 §9.2, exact sequence, recapped from M3 §13):** register → pending review → admin approval → active → custom domain CNAME → Edge Middleware `Host` lookup against `resellers.custom_domain` → branding from `resellers.branding` JSONB → client signups via reseller domain link `tenant_id` to `reseller_id` via `reseller_tenants`.

**Custom domain isolation (PHASE12 §9.4, exact):** "Reseller adds CNAME → Vercel automatically provisions and renews a TLS certificate → Edge Middleware resolves `resellers.custom_domain` → `reseller_id` → branding + tenant scoping → All downstream RLS/feature-resolution logic is identical to the primary domain path." Onboarding a new reseller custom domain "requires zero infrastructure deploy."

**Commission model (superseded, not redesigned):** PHASE1 §9.3's original trigger-level formula (`commission_amount = amount * (reseller.commission_pct / 100)`, computed at order-insert time) is the conceptual basis already fully built out by PHASE10's `commission_ledger`/`commission_payouts` system (M2 §18). This milestone does not re-specify billing — it confirms the reseller-facing surface (§11, §17) that sits on top of it.

**Package eligibility constraint (PHASE1 §9.4, recapped from M3 §13, exact):** resellers may only assign packages with `is_reseller = TRUE`; platform admin controls reseller eligibility per package.

## 6. Tenant Administration Architecture

**Admin-initiated tenant actions (PHASE1 §8.1):** list, search, view, **suspend**, **impersonate** (resolved in §9).

**Suspension mechanics (PHASE12 §9.3, exact):** "A tenant can be suspended (`tenants.status = 'suspended'`) for billing failure, ToS violation, or abuse investigation, without any infrastructure-level action — RLS-adjacent middleware checks `tenants.status` on every authenticated request and returns a 403 with an explanatory page, while the tenant's data remains intact and un-deleted." This is "a data-layer flag, not an infrastructure provisioning/deprovisioning event — critical for keeping suspension fast (seconds) and reversible." This is the same check M3 §12/§15 already specified at the middleware layer; this section adds the **administrative trigger side** — a `super_admin` action via `/admin/tenants/[id]` sets `tenants.status = 'suspended'` (or back to `'active'` to reverse it).

**Flagged gap:** no document cites whether this status-change write is itself an audit-logged action. See §18.

**Tenant detail surface (PHASE1 §8.1):** "subscription, usage, audit log" — i.e. the `/admin/tenants/[id]` page composes `tenant_subscriptions`, usage figures (against `packages.max_*` limits, PHASE1 §6.3), and a filtered view of `audit_logs` scoped to that `tenant_id`. No further detail is cited.

## 7. User Management Architecture

**Flagged gap, surfaced rather than invented:** PHASE1 §8.1's module list contains no platform-wide, cross-tenant user-management surface (e.g. an `/admin/users` page to search/manage individual users independent of their tenant). Every cited admin capability operates at the **tenant** or **reseller** level (`/admin/tenants`, `/admin/resellers`), never directly at the individual-user level beyond what a tenant detail page shows in passing. This milestone does not invent such a surface. If one is required, it belongs to a future, not-yet-available specification.

## 8. Team Management Architecture

**Within-tenant team management (PHASE1 §5.2, §6.1):** an `owner` may "invite team members," bounded by the package's team-member limit (`packages.max_team_members`, resolved as a gap-fill addition in M2 §5.4, citing PHASE10 §10.3).

**Flagged gap (carried forward from M3 §10, unchanged):** no invitation-token table, email flow, or acceptance mechanism is cited anywhere for how a new team member is actually added to a tenant.

**Deactivation (cited, system-initiated, not an interactive admin flow):** PHASE10 §10.3's `enforceQuotaLimitsAfterDowngrade()` deactivates excess team members (`users.is_active = FALSE`, keeping the owner, deactivating the newest editors/viewers first) when a downgrade reduces the available `max_team_members` slots. No interactive "owner manually removes a team member" action is cited separately from this automatic enforcement path.

## 9. Impersonation Architecture

### 9.1 The gap, exactly as previously flagged

PHASE1 §8.3: "Admins can view any tenant's dashboard via a signed impersonation token (24h TTL), generating a scoped JWT with the target tenant's `tenant_id` and `role: owner`. All impersonated actions are written to `audit_logs` with the admin's `user_id` as the actor." M3 §14 flagged that no claim is cited which would let the token carry both the impersonated context and the impersonator's real identity simultaneously.

### 9.2 Resolution (zero new claims, zero new columns — value-assignment rule only)

The JWT claim shape is **unchanged** from PHASE1 §5.3 (`sub`, `tenant_id`, `role`, `reseller_id`, `package_id`, `exp` — M1 §6, M3 §6). The resolution is a rule about how an **impersonation token's** claims are populated, not a new claim:

| Claim | Value during impersonation |
|---|---|
| `sub` | **Unchanged — remains the impersonator's own `user.id`.** This is the entire resolution: because `sub` is never overwritten, any downstream code that reads `auth.user.id` (§6 of M3) during an impersonated session is, by construction, reading the real admin's or reseller_admin's identity, not a synthetic one. |
| `tenant_id` | Overridden to the **target tenant's** `id`. |
| `role` | Overridden to `'owner'` (per PHASE1 §8.3's literal value, normalized per M1 §8's compatibility note), regardless of whether the impersonator is `super_admin` or `reseller_admin` (§9.4). |
| `package_id` | Overridden to the **target tenant's** active `tenant_subscriptions.package_id` — so that feature-gating during the impersonated session reflects what that tenant would actually see, consistent with the stated purpose ("view any tenant's dashboard"). |
| `reseller_id` | Cleared (not applicable while impersonating in the `owner` role). |
| `exp` | Set to now + 24h, per PHASE1 §8.3's literal TTL. |

Because `sub` is retained, "audit_logs written with the admin's user_id as the actor" (PHASE1 §8.3) is satisfied **exactly as stated**, using only the claim shape already approved — no `impersonator_id` or equivalent new claim is introduced.

**Distinguishing an impersonated action from a normal one, for audit purposes (resolved using an existing column, not a new one):** `audit_logs.new_data` (JSONB, already present per M1 §13 — no schema change) must, by convention established here, include `{ "impersonated_tenant_id": "<target tenant id>" }` for any action taken during an impersonation session. This is a **usage convention** for an already-existing flexible column, not a new column — consistent with the additive-only method (§2).

### 9.3 Intentional, documented exception to the ownership-pairing rule

M1 §21 requires that a row's creator (`created_by`) belong to the same tenant as the row's `tenant_id`. During impersonation, this is **intentionally violated** by design: the admin/reseller_admin's own `users.tenant_id` will, in general, differ from the impersonated tenant's `id`. This is the expected signature of an impersonated write, not a data-integrity defect — and it is precisely why the `audit_logs.new_data` convention in §9.2 exists: to make that divergence traceable rather than silent.

### 9.4 Who may impersonate whom (exact boundary)

| Impersonator | Target | Bound by |
|---|---|---|
| `super_admin` | Any tenant | No restriction cited (PHASE1 §8.1, §8.3) |
| `reseller_admin` | Only tenants linked via `reseller_tenants` to that reseller | PHASE1 §9.1 ("View any **client** dashboard") |

No other role may impersonate (`owner`, `editor`, `viewer` are never cited as impersonation initiators).

## 10. Admin Dashboard Architecture

**`/admin/dashboard` (PHASE1 §8.1):** "Aggregate metrics: MRR, active tenants, RSVP volume." No further breakdown is cited for this specific top-level page; it is superseded in practical detail by `/admin/analytics` (§11.1 below), which PHASE11 specifies completely.

**`/admin/analytics` (PHASE11 §11.1, exact):**
```
/admin/analytics
├── Growth section: New Tenants · Active Tenants · New Invitations · Published Invitations
├── Engagement section: Total Views · Total RSVPs · Total Guestbook Entries
├── Revenue section: Gross/Net Revenue · Paid Orders · Commission Payout Liability
│    (composes get_platform_billing_summary() from PHASE10 §14.3 directly)
├── Package Distribution donut chart
└── [Export Platform Report] — super_admin only, always available, no feature gate
```

**`/admin/analytics/cohort-retention` (PHASE11 §11.3):** tenant retention by signup cohort, `super_admin` only — "a genuinely new platform-level metric not prepared in any prior phase," per PHASE11's own characterization.

**`/admin/orders`, `/admin/refund-requests`, `/admin/webhooks` (PHASE10 §14.1, exact):**
```
/admin/orders
├── List view: filter by status / provider / package / reseller / date range
├── Order detail modal: amounts breakdown, payment_data JSON viewer, refund button
└── /admin/orders/[id]/mark-paid     (manual provider only)

/admin/refund-requests
├── Pending queue (default view)
└── /admin/refund-requests/[id]      (approve/reject)

/admin/webhooks
└── webhook_logs viewer: filter by provider / signature_valid / processed
```

**`/admin/tenants`, `/admin/packages`, `/admin/resellers`, `/admin/feature-flags`, `/admin/themes`, `/admin/settings` (PHASE1 §8.1):** named as modules; no further internal structure is cited for any of them beyond the one-line description already given in §3.

## 11. Reseller Dashboard Architecture

**`/reseller/analytics` (PHASE11 §10.1, exact):**
```
/reseller/analytics
├── Header stat cards: Active Clients · Total Client Invitations · Total Client Views · Commission Accrued (30d)
├── Trend chart: client growth + commission accrual
├── Client comparison table (per-tenant rollup, sortable by engagement)
└── [Export Portfolio Report] (always available to reseller_admin — not package-gated;
     reseller analytics access is a role-based capability, not a tenant package entitlement)
```

**`/reseller/billing` (commission surface, PHASE10 §13.3):** pending payout total, total paid out, and the full commission-ledger entry list for the reseller's own `reseller_id`.

**`/reseller/dashboard`, `/reseller/clients`, `/reseller/branding` (PHASE1 §3 folder structure, PHASE1 §9.1):** named route groups; no further internal structure beyond the capability list in §5 is cited.

## 12. Tenant Dashboard Architecture

No new fact beyond what M1 §19/§20 already specified (`/dashboard` shell, `/analytics` tenant dashboard populated at Phase M, `/packages`, `/settings`). This milestone does not add to the tenant-facing dashboard — it is admin/reseller-scoped by definition. Included as a section heading only to confirm there is nothing further to specify here that M1/M2/M3 have not already covered.

## 13. User Lifecycle Management

Extends M3 §10 with the admin-initiated actions this milestone newly specifies:

| Action | Initiator | Effect | Logged? |
|---|---|---|---|
| Tenant suspend/unsuspend | `super_admin` via `/admin/tenants/[id]` | `tenants.status` toggled between `'active'`/`'suspended'` | Not explicitly cited — flagged (§18) |
| Reseller approval | `super_admin` via `/admin/resellers` | `resellers.status` `'pending'` → `'active'` | Not explicitly cited — flagged (§18) |
| Impersonation session | `super_admin` or `reseller_admin` (§9.4) | Scoped 24h token issued | ✅ Required (§9.2) |
| Manual order mark-paid | `super_admin` via `/admin/orders/[id]/mark-paid` | Order activated | ✅ Required (PHASE10 §16.4) |
| Team-member deactivation | System (downgrade enforcement) | `users.is_active = FALSE` | Not explicitly cited — flagged |

## 14. Role Management

Recapped from M1 §8 and M3 §7, with the `super_admin` gap now closed (§4):

| Role | Determination | Changeable how? |
|---|---|---|
| `owner` / `editor` / `viewer` | `users.role` column | No change flow cited anywhere (flagged — same gap as §8's missing invite flow) |
| `reseller_admin` | `resellers.owner_user_id` relationship | Only by creating/transferring a `resellers` row — no transfer flow cited |
| `super_admin` | `users.is_super_admin` (resolved, §4) | Only by direct, out-of-band database operation (§4.4) — never via any route |

## 15. Permission Management

The only **admin-editable** permission-adjacent surface cited anywhere is `feature_flags` (PHASE1 §4.2, §7) via `/admin/feature-flags` (§3): platform-wide (`tenant_id IS NULL`) or per-tenant overrides, each with an `is_enabled` flag, a `config` JSONB, and a `reason` (audit-adjacent free text already on the table itself, M1 §13). The role×action permission matrices in M3 §9 are **not** admin-editable anywhere — they are a fixed reference table consumed by `lib/auth/permissions.ts` (M1 §17), not a database-backed, admin-configurable system. This is stated explicitly so no future phase mistakes the RBAC matrix for something `/admin/feature-flags` can alter — it cannot.

## 16. Admin API Architecture

Consolidated, exact, from M3 §16 plus PHASE1 §8.1's module list:

| Route | Defined precisely? |
|---|---|
| `/api/admin/orders/*`, `/api/admin/orders/[id]/mark-paid` | ✅ PHASE10 §14, §15.2 |
| `/api/admin/refund-requests/[id]/process` | ✅ PHASE10 §12.3, §15.2 |
| `/api/admin/webhooks` | ✅ PHASE10 §14.4, §15.2 |
| `/api/admin/analytics`, `/api/admin/analytics/cohort-retention` | ✅ PHASE11 §11.2, §11.3, §15.2 |
| API routes backing `/admin/tenants` (suspend, impersonate), `/admin/packages`, `/admin/resellers`, `/admin/feature-flags`, `/admin/themes`, `/admin/settings`, `/admin/dashboard` | ❌ **Not cited.** PHASE1 §8.1 names the UI module only; no API route path is given anywhere in the available documents for any of these. Flagged, not invented. |

Every defined route follows the direct role-comparison pattern from M3 §17 (`requireAuth(request)` then manual `role !== 'super_admin'` check); every cited route uses `createAdminClient()` per the service-role rule in M3 §18, unchanged here.

## 17. Reseller API Architecture

Consolidated, exact:

| Route | Defined precisely? |
|---|---|
| `/api/reseller/commission` | ✅ PHASE10 §13.3, §15.2 — `reseller:billing:read` + `resellerId` non-null check |
| `/api/reseller/analytics`, `/api/reseller/analytics/clients` | ✅ PHASE11 §10.2, §10.3, §15.2 — `reseller:analytics:read` + `resellerId` non-null check |
| API routes backing `/reseller/clients` (client management, package assignment), `/reseller/branding` (set branding) | ❌ **Not cited.** PHASE1 §9.1 names these as capabilities; no API route path is given anywhere. Flagged, not invented. |
| Impersonation issuance route (`POST /api/admin/tenants/[id]/impersonate` or reseller equivalent) | ❌ **Not cited.** PHASE1 §8.3/§9.1 describe the capability and its audit consequence (resolved in §9); no route path is ever named. Flagged, not invented. |

## 18. Audit Logging Requirements

Extends M3 §20 (unchanged mechanism — `audit_logs`, `actor_role` from M2 §5.8) with this milestone's additions and remaining gaps:

| Action | Logged? | Mechanism |
|---|---|---|
| Impersonated action (any) | ✅ Required | `audit_logs.user_id` = impersonator's real id (via `sub` retention, §9.2); `audit_logs.new_data` carries `{ impersonated_tenant_id }` (§9.2 convention) |
| Manual order mark-paid | ✅ Required | PHASE10 §16.4 — `proof_reference`, `verified_by` |
| Tenant suspend/unsuspend | ❌ Not cited — flagged | Recommended, not required by any citation |
| Reseller approval (`pending` → `active`) | ❌ Not cited — flagged | Recommended, not required by any citation |
| Feature-flag override create/edit | ❌ Not cited as a separate audit_logs entry — the table's own `reason`/`created_by` columns serve a similar purpose in place of a separate log row | M1 §13 |

This milestone does not add a new requirement beyond what is cited; the flagged rows above are recorded as open items, not silently resolved by assumption.

## 19. Security Requirements

Carried forward from M1 §22 / M3 §21, with this milestone's additions:

| Requirement | Status after M4 |
|---|---|
| `users.is_super_admin` is never settable via any route | New, explicit (§4.4) — the load-bearing safeguard for the entire resolution in §4. |
| Impersonation tokens carry the impersonator's real `sub` at all times | New, explicit (§9.2) — must never be overridden, or the audit guarantee in PHASE1 §8.3 breaks. |
| Impersonation token TTL is 24h, no longer | Unchanged citation (PHASE1 §8.3), now restated as a hard requirement on the issuing mechanism. |
| `reseller_admin` impersonation is bounded by `reseller_tenants` | New, explicit (§9.4) — a reseller must never be able to impersonate a tenant it is not linked to. |
| Service-role containment (`createAdminClient()`) | Unchanged (M3 §18) — every route in §16 must comply. |
| RLS + application-layer filter | Unchanged (M3 §19) — every admin/reseller route touching a tenant-scoped table must still apply both layers where RLS exists, and the permission/role check alone where it does not (M2 §26's gap, still open). |

## 20. Monitoring Requirements

Citable material is limited. PHASE12 §10.3 names `/dashboards/multi-tenant` ("per-tenant resource usage outliers, noisy-neighbor detection") as the one operational dashboard with direct relevance to the admin/reseller domain — it is an infrastructure-observability surface (Phase N), not a new admin-facing page in this milestone's own scope, and is not re-specified here beyond confirming its existence and citation. No other admin-action-specific monitoring or alerting (e.g. a dedicated alert when a `super_admin` action occurs) is cited anywhere. None is introduced here.

## 21. Testing Requirements

- `is_super_admin = TRUE` correctly produces `role: 'super_admin'` in the minted JWT, taking priority over a simultaneous `resellers.owner_user_id` match (§4.3's priority order, tested in both orders: a user who is both a reseller owner and `is_super_admin = TRUE` must resolve to `super_admin`).
- `is_super_admin` cannot be set via any HTTP route — attempt every existing `/api/admin/*` and tenant-facing route and confirm none accepts it as a writable field.
- Impersonation session test: issue a token, perform a write as the impersonated tenant, confirm the resulting `audit_logs` row has `user_id` = the real impersonator and `new_data.impersonated_tenant_id` = the target tenant.
- Impersonation boundary test: a `reseller_admin` attempting to impersonate a tenant **not** in their `reseller_tenants` set is rejected.
- Impersonation expiry test: a token older than 24h is rejected.
- Tenant suspension test (recapped from M3 §22): a suspended tenant's normal users receive 403 pre-route; confirm the admin action that sets `'suspended'` is itself reachable only by `super_admin`.
- `/admin/feature-flags` write test: confirm only `super_admin` can write `feature_flags`, per §3/§15.

## 22. Migration Requirements

**One new migration, departing from BUILD_ORDER Phase E's original "no DB changes" framing — justified explicitly:** BUILD_ORDER scoped Phase E as UI/route work only. This milestone's explicit, user-directed resolution of the `super_admin` gap (§4) is impossible without one additive column. This is the sole schema change in this milestone.

```
034_users_add_is_super_admin.sql   -- users.is_super_admin BOOLEAN NOT NULL DEFAULT FALSE
```

Consumes the next available number from the range M1 reserved (`018`–`090`) and M2 partially used (`018`–`033`); does not collide with M2's range, M3 (which used none), or Phase L/M's fixed ranges. `035`–`090` remains reserved.

No other table, column, or constraint is added. The impersonation resolution (§9) requires **zero migration** — it is a value-assignment rule for an unchanged JWT shape plus a documented convention for an already-existing JSONB column.

## 23. Acceptance Criteria

- [ ] `users.is_super_admin` exists exactly as specified in §4.2 in both staging and production.
- [ ] The Auth Hook implements the exact priority order in §4.3.
- [ ] No route anywhere accepts `is_super_admin` as a writable input field.
- [ ] Impersonation tokens retain `sub` as the impersonator's real `user.id` in every case (super_admin and reseller_admin alike).
- [ ] Impersonation tokens override `tenant_id`, `role` (`'owner'`), `package_id` (target tenant's), and clear `reseller_id`, exactly per §9.2's table.
- [ ] Every `audit_logs` row written during an impersonation session carries `new_data.impersonated_tenant_id`.
- [ ] `reseller_admin` impersonation is rejected for any tenant outside that reseller's `reseller_tenants` set.
- [ ] The admin/reseller dashboard module lists in §10/§11 match PHASE1 §8.1/§9.1 and PHASE10 §14.1 and PHASE11 §10.1/§11.1 exactly, with no module added or removed.
- [ ] Every route in §16/§17 marked "not cited" remains undocumented as a route path in this milestone's own deliverables — none is invented to fill the gap.
- [ ] Migration `034` is the only schema change in this milestone.

## 24. Completion Checklist

- [ ] §3, §10, §11 (module structures) reproduce PHASE1/PHASE10/PHASE11's cited structures exactly.
- [ ] §4 (super_admin resolution) is implemented and tested per §21/§23.
- [ ] §9 (impersonation resolution) is implemented and tested per §21/§23.
- [ ] §5–§8, §12–§15 (reseller, tenant admin, user/team management, role/permission management) correctly distinguish cited fact from flagged gap throughout.
- [ ] §16–§17 (API architecture) list every cited route and flag every uncited one — no invented route paths.
- [ ] §18–§20 (audit, security, monitoring) carry forward M1/M3 without contradiction and add only what this milestone newly resolves.
- [ ] §22 migration `034` applied cleanly to staging, then production.
- [ ] Tag `v0.5.0` once every item in §23 is verified.

**Once every box above is checked, Phase F (Package & Feature System) may begin.**

---

*End of M4_ADMIN_ARCHITECTURE.md*
