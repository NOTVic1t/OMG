# M1_CORE_MULTI_TENANT_FOUNDATION.md
# Wedding Invitation SaaS Platform — Milestone M1: Core Multi-Tenant Foundation

> **Version:** 1.0.0
> **Implementation authority:** BUILD_ORDER.md — Phase B (`= M1` in IMPLEMENTATION_ROADMAP.md)
> **Upstream source documents:** PHASE1_ARCHITECTURE.md (full document — §2 through §11, Appendices A–B), cross-checked for compatibility against PHASE10_PAYMENT_SYSTEM.md §15.1, PHASE11_ANALYTICS.md §15.1, PHASE12_DEPLOYMENT.md §7.6/§9.1
> **Predecessor:** M0_FOUNDATION.md (Phase A) — must be complete before any task below begins.
> **Scope boundary:** This document specifies only what PHASE1_ARCHITECTURE.md already decided. No table, column, role, policy, or feature is introduced beyond what is cited. Where the source documents contain an internal naming inconsistency or an unaddressed gap, it is **flagged explicitly** rather than silently resolved or redesigned. **No application code is included** — schema is specified as structured tables, policies are specified as policy definitions (security configuration, not business logic), and service responsibilities are specified as contracts (purpose/inputs/outputs), not implementations.

---

## 1. Objectives

1. Stand up the complete PHASE1 database schema (15 tables) with all constraints, indexes, and the three RLS patterns PHASE1 defines.
2. Implement JWT custom-claims minting (`tenant_id`, `role`, `reseller_id`, `package_id`) via the Supabase Auth Hook (PHASE1 §5.3).
3. Implement Edge Middleware tenant/auth resolution (PHASE1 §2.2, §2.4).
4. Implement the package/feature resolution contracts (`resolveFeature()`, `checkQuota()`) and the `FEATURES` registry (PHASE1 §6, §7).
5. Seed the Free package with its exact entitlements (PHASE1 §6.1).
6. Scaffold the remaining folder structure from PHASE1 §3 not already created in M0.
7. Prove, end to end, that a registered user lands in an isolated tenant with a working RLS boundary.

## 2. Scope

**In scope:** Everything enumerated in PHASE1_ARCHITECTURE.md. This includes all 15 core tables, the three named RLS patterns, JWT claims, Edge Middleware, the feature-flag/package resolution functions, the `FEATURES` registry, the folder scaffold for every route group, and minimal auth/dashboard pages sufficient to prove the foundation works.

**Out of scope (deferred to later phases per BUILD_ORDER):**
- Any table, view, or function not in PHASE1 §4.2 (PHASE2_DATABASE.md domains — Phase C).
- Full `requireAuth()` permission-string gating (Phase D).
- Functioning admin/reseller portal pages beyond route-group stubs (Phase E).
- The full feature matrix beyond the Free-tier seed, Redis feature cache, `package_feature_snapshot` (Phase F).
- Theme rendering, invitation editor, guest CRUD, RSVP/guestbook logic (Phases G–J).
- Payment gateway integration, analytics ingestion, production hardening (Phases L, M, N).

## 3. Tenant Architecture

The `tenants` table is the **single top-level multi-tenant unit** of the platform (PHASE1 §4.1 ERD comment). Every other tenant-scoped table either carries a `tenant_id` column directly, or is reachable to a `tenant_id` through exactly one foreign-key hop (see §10).

**Tenant resolution strategy (PHASE1 §2.2, Appendix A):** subdomain-based, decided over path-based (`/[tenant]/`) specifically because subdomains "enable future custom domain mapping per reseller" and keep public invitation URLs clean. The routing table, reproduced exactly:

```
app.weddingplatform.com         → Platform main app (auth, dashboard)
[tenant].weddingplatform.com    → Reseller white-label frontend
inv.weddingplatform.com/[slug]  → Public invitation page (tenant-scoped)
admin.weddingplatform.com       → Super admin panel
dashboard.resellerbrand.com     → Reseller custom domain (CNAME + Edge Middleware lookup)
```

**M1-scope clarification:** for the direct (non-reseller) tenant flow used by `app.weddingplatform.com`, tenant context comes from the authenticated user's JWT `tenant_id` claim, not from the subdomain — the subdomain-resolution capability in Edge Middleware exists for the reseller white-label and custom-domain cases, whose full branding rendering is completed in Phase E. M1 implements the lookup mechanism; it does not implement reseller branding pages.

**`tenants` lifecycle:** `status` is one of `active`, `suspended`, `deleted` (PHASE1 §4.2 CHECK constraint). `metadata` (JSONB, default `{}`) holds branding/locale data per the column comment. No additional lifecycle states exist in PHASE1.

## 4. Tenant Isolation Strategy

**Decision (PHASE1 §2.3, Appendix A — not re-litigated here):** Row-Level Security per row, chosen over schema-per-tenant, "for simplicity, cost (one DB instance), and because the platform is B2C-focused with high tenant count but low per-tenant data volume." Schema-per-tenant remains documented as a Phase 3+ reconsideration only if a tenant requires dedicated SLA/data-residency — not built now.

**Mechanism:** every tenant-scoped table carries a `tenant_id UUID` foreign key to `tenants(id)`. Supabase RLS policies enforce that an authenticated user may only read/write rows whose `tenant_id` matches their JWT `tenant_id` claim.

**Tables carrying `tenant_id` directly in M1 scope:** `users`, `tenant_subscriptions`, `feature_flags` (nullable — `NULL` = platform-wide), `invitations`, `guests`, `orders`, `audit_logs` (nullable).

**Tables reachable to a tenant only via FK join (no direct `tenant_id` column):** `invitation_sections` (via `invitation_id → invitations.tenant_id`), `rsvp_responses` (via `invitation_id → invitations.tenant_id`) — see the explicit flag in §12.

**Tables that are not tenant-scoped at all (platform/global or reseller-scoped):** `resellers`, `reseller_tenants`, `packages`, `package_features`, `invitation_themes`.

## 5. Workspace Model

**The approved architecture defines no separate "Workspace" entity.** There is no `workspaces` table anywhere in PHASE1 (or any other source document). The `tenants` table **is** the workspace boundary: one tenant = one workspace. This section exists in this specification only to make that mapping explicit; no new table is introduced.

## 6. Organization Model

**The approved architecture defines no separate "Organization" entity** and no nested-organization/sub-workspace concept. `tenants` is flat — there is no parent-tenant or org-of-tenants relationship anywhere in PHASE1 §4.2. A reseller (`resellers` table) is a distinct, non-nesting concept: it is linked to the tenants it serves via the `reseller_tenants` join table (§13), not by containment. A tenant is never "inside" a reseller in the schema; it is merely associated with one.

## 7. User Membership Model

**Exact model as specified (PHASE1 §4.2 `users` table):** a user belongs to **exactly one tenant**, via a direct, required, singular foreign key — `users.tenant_id UUID NOT NULL REFERENCES tenants(id)`. There is **no membership join table** (no `tenant_users`, no `memberships`) in the approved architecture. Multi-tenant membership for a single user account is not supported by this schema and is not introduced here.

`users.id` is **not** an independently generated primary key — it is `UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE`. The `public.users` row and the `auth.users` row share the same identifier. Deleting the `auth.users` row cascades to delete the `public.users` row.

A user's role within their tenant is stored directly on this same row (`users.role`) — there is no separate role-assignment table. Deactivation (e.g. for team-quota enforcement) is via `users.is_active BOOLEAN NOT NULL DEFAULT TRUE`, not row deletion.

**Note on team quotas:** `packages.max_team_members` is referenced by name in PHASE10 §10.3 (`enforceQuotaLimitsAfterDowngrade`) but is **not** a column in PHASE1 §4.2's literal `packages` table definition. Per BUILD_ORDER Phase F, that column belongs to PHASE5 (Package & Feature System). M1 creates `packages` with exactly the columns listed in §13 below — no `max_team_members` column is added in this milestone.

## 8. Role Architecture

**Conceptual hierarchy (PHASE1 §5.1, verbatim):**
```
SUPER_ADMIN
    └── RESELLER_ADMIN
            └── TENANT_OWNER
                    ├── TENANT_EDITOR
                    └── TENANT_VIEWER
```

**Source compatibility note (required to reconcile two literal spellings used across the approved documents — flagged, not redesigned):** PHASE1 §5.3's JWT claim type and §5.2's permission-matrix headers write the tenant-scoped roles as `tenant_owner` / `tenant_editor` / `tenant_viewer`. PHASE1 §4.2's `users.role` column CHECK constraint stores them unprefixed: `owner` / `editor` / `viewer`. PHASE10 §15.1 and PHASE11 §15.1 — both later, both already approved — independently use the **unprefixed** form (`owner`, `editor`, `viewer`, alongside `super_admin`, `reseller_admin`) in their own permission matrices and in literal code-level role comparisons (e.g. `auth.user.role !== 'super_admin'`). To remain compatible with PHASE10 and PHASE11 as required, **M1 adopts the unprefixed form as the operative literal value for both the `users.role` column and the JWT `role` claim**: `owner`, `editor`, `viewer`, `reseller_admin`, `super_admin`. `tenant_owner`/`tenant_editor`/`tenant_viewer` are treated as display/conceptual labels for the same three values, not separate literal values.

**Role storage:**
- `owner` / `editor` / `viewer` — stored directly in `users.role` (CHECK-constrained, §13).
- `reseller_admin` — **not** a `users.role` value. A user is a reseller admin by virtue of being referenced as `resellers.owner_user_id`. The Auth Hook (§11) must check this relationship when minting the JWT `role`/`reseller_id` claims.
- `super_admin` — **PHASE1 does not specify a column or table that designates a user as a super admin.** No `users.is_super_admin` column, no separate platform-staff table, exists anywhere in the source documents. This is a gap in the approved architecture, not resolved here. M1 implements the Auth Hook's claim-minting contract exactly as PHASE1 §5.3 describes it, without inventing a new designation mechanism; super-admin designation must be supplied by whatever mechanism a future phase specifies.

**JWT claim shape (PHASE1 §5.3, with role values per the compatibility note above):**

| Claim | Type | Notes |
|---|---|---|
| `sub` | string | `user.id` |
| `tenant_id` | string | always present |
| `role` | `'super_admin' \| 'reseller_admin' \| 'owner' \| 'editor' \| 'viewer'` | per compatibility note |
| `reseller_id` | string (optional) | present only when `role = 'reseller_admin'` |
| `package_id` | string | active subscription package |
| `exp` | number | standard JWT expiry |

## 9. Permission Architecture

Reproduced exactly from PHASE1 §5.2, with column headers normalized to the operative role values per §8's compatibility note (`tenant_owner→owner`, `tenant_editor→editor`, `tenant_viewer→viewer`; values unchanged):

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

**M1 responsibility boundary:** M1 implements this matrix as the static boundary table consumed by `lib/auth/permissions.ts` RBAC helpers. The permission-string-based route guard (`requireAuth(request, '<permission>')`) that later phases call is a **Phase D** deliverable (BUILD_ORDER Phase D). M1 does not implement that guard function — it implements the data this matrix represents so Phase D has something correct to enforce.

## 10. Ownership Rules

| Resource | Owning tenant determined by | Creator/actor determined by | Exact rule |
|---|---|---|---|
| `users` row | `users.tenant_id` (direct) | — | A user belongs to exactly one tenant for its entire lifetime in this schema; no transfer mechanism is specified. |
| `invitations` row | `invitations.tenant_id` (direct, denormalized) | `invitations.created_by → users.id` | `tenant_id` and `created_by` are independent columns. PHASE1 does not specify a DB-level CHECK or trigger enforcing that `created_by`'s `users.tenant_id` equals `invitations.tenant_id` — this must be enforced at the application layer (server-side, before insert) and is reinforced by RLS at read time. |
| `guests` row | `guests.tenant_id` (direct, denormalized) **and** `guests.invitation_id → invitations.tenant_id` | — | Both must agree; PHASE1 carries `tenant_id` redundantly on `guests` specifically to avoid a join for RLS evaluation (consistent with the general "every tenant-data table carries `tenant_id`" rule in §2.3). |
| `rsvp_responses` row | Indirect only — `rsvp_responses.invitation_id → invitations.tenant_id` | `rsvp_responses.guest_id → guests.id` (nullable — "null if open RSVP") | No direct `tenant_id` column exists on this table (see flag in §12). |
| `resellers` row | Not tenant-scoped | `resellers.owner_user_id → users.id` (required) | The owning user must already exist as a `users` row, which itself requires a `tenant_id` — there is no reseller identity independent of the tenant/user model. |
| `reseller_tenants` row | Links `reseller_id` and `tenant_id` | — | `UNIQUE(reseller_id, tenant_id)` — a tenant may be linked to a given reseller at most once. |
| `tenant_subscriptions` row | `tenant_subscriptions.tenant_id` (direct) | — | `reseller_id` nullable — "null if direct" (not reseller-acquired). |
| `orders` row | `orders.tenant_id` (direct) | — | `reseller_id` nullable, same convention. |
| `audit_logs` row | `audit_logs.tenant_id` (nullable FK) | `audit_logs.user_id` (nullable FK) | Nullable because some platform-level actions have no tenant or no acting user. |

## 11. Supabase Auth Integration

**Auth methods (PHASE1 §2.4):** email/password and Google OAuth, both via Supabase Auth.

**Flow (PHASE1 §2.4, verbatim sequence):**
```
User visits app → Supabase Auth (email/password + Google OAuth)
                → JWT issued with custom claims: { tenant_id, role, package_id }
                → Next.js middleware validates JWT on every request
                → Role-based routing enforced server-side
```

**Claims minting:** implemented as a Supabase Auth Hook — "a DB Function on user login" (§5.3 comment). The hook must read `users.tenant_id`, `users.role`, and (if applicable) the linked `resellers.id` where `resellers.owner_user_id = users.id`, plus the tenant's active `tenant_subscriptions.package_id`, and assemble the claim shape in §8.

**Specification note (not in PHASE1 §10.2's literal env-var list, but required to implement the already-decided Google OAuth method):** the Google OAuth client credentials must exist somewhere in the secrets vault per the PHASE12 §4.4 governance flow already established in M0. PHASE1 itself does not name these variables. This specification names them only so the already-decided feature is implementable: `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`. These are configured at the Supabase project level (Authentication → Providers) and mirrored into `infra/supabase/config.toml`'s `[auth.external.google]` block, which M0 explicitly deferred to this milestone.

**Middleware responsibility (`app/middleware.ts`):** validates the JWT on every request; on the reseller-subdomain or custom-domain path, resolves `Host` header → `resellers.custom_domain` lookup (PHASE1 §9.2 flow, wiring only — rendering is Phase E); on the direct-tenant path, simply confirms a valid session exists and lets the `(app)` layout's server-side claim read establish tenant context.

## 12. Row Level Security Architecture

**Primitive:** PHASE1 §4.3 defines exactly three reusable RLS patterns and explicitly enables RLS on exactly three tables. This is reproduced precisely below — no additional table is given an explicit policy in PHASE1, and none is invented here.

**Tables with `ENABLE ROW LEVEL SECURITY` in PHASE1 §4.3:** `invitations`, `guests`, `rsvp_responses`. No other table (`tenants`, `users`, `resellers`, `reseller_tenants`, `packages`, `package_features`, `tenant_subscriptions`, `feature_flags`, `invitation_themes`, `invitation_sections`, `orders`, `audit_logs`) is given an explicit RLS policy anywhere in PHASE1.

**Flagged gap (not resolved, surfaced as-is):** because the remaining twelve tables have no RLS policy in the approved architecture, access to them must be mediated exclusively through server-side code (`createServerClient()` for tenant-scoped server actions, `createAdminClient()` for service-role contexts per PHASE1 §8.2) applying an explicit application-layer `tenant_id` filter — the defense-in-depth pattern PHASE7/PHASE10/PHASE11 each independently reaffirm for tables they touch. M1 does not add new RLS policies to close this gap, since doing so would be a new decision not present in PHASE1.

**The three patterns, reproduced exactly:**

*Pattern 1 — tenant isolation via JWT claim:*
```sql
CREATE POLICY "tenant_isolation" ON invitations
  USING (tenant_id = (auth.jwt() ->> 'tenant_id')::UUID);
```

*Pattern 2 — public read for published invitations (no auth required):*
```sql
CREATE POLICY "public_invitation_read" ON invitations
  FOR SELECT
  USING (status = 'published');
```

*Pattern 3 — reseller read of client data:*
```sql
CREATE POLICY "reseller_client_read" ON invitations
  FOR SELECT
  USING (
    tenant_id IN (
      SELECT tenant_id FROM reseller_tenants
      WHERE reseller_id = (auth.jwt() ->> 'reseller_id')::UUID
    )
  );
```

**Required adaptation for `guests` (has a direct `tenant_id` column):** Pattern 1 applies unchanged, substituting the table name.

**Required adaptation for `rsvp_responses` (has NO `tenant_id` column — flagged in §4/§10):** Pattern 1 cannot be applied as a direct column comparison, because the column does not exist on this table. The semantically equivalent policy must instead join through `invitations`:
```sql
CREATE POLICY "tenant_isolation" ON rsvp_responses
  USING (
    invitation_id IN (
      SELECT id FROM invitations WHERE tenant_id = (auth.jwt() ->> 'tenant_id')::UUID
    )
  );
```
This is the literal, necessary implementation of the named "pattern" against this table's actual columns — it is not a new architectural decision, since PHASE1 itself labels these as **patterns** to be applied per table rather than verbatim copy-paste SQL.

**Public/anonymous write paths** (e.g. anonymous RSVP submission) are **not** specified in PHASE1 §4.3 — only the three SELECT-oriented patterns above exist in the source. INSERT policies for guest-facing RSVP submission belong to Phase J (RSVP & Guestbook, external spec) per BUILD_ORDER's own phase boundary.

## 13. Required Database Tables

All fifteen tables, reproduced exactly from PHASE1 §4.2. Types and constraints are listed as given; no column is renamed, added, or removed.

### `tenants`
| Column | Type | Constraints |
|---|---|---|
| id | UUID | PRIMARY KEY DEFAULT gen_random_uuid() |
| slug | TEXT | UNIQUE NOT NULL |
| name | TEXT | NOT NULL |
| status | TEXT | NOT NULL DEFAULT 'active', CHECK IN ('active','suspended','deleted') |
| metadata | JSONB | NOT NULL DEFAULT '{}' |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |
| updated_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |

### `users`
| Column | Type | Constraints |
|---|---|---|
| id | UUID | PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE |
| tenant_id | UUID | NOT NULL REFERENCES tenants(id) |
| email | TEXT | NOT NULL |
| full_name | TEXT | — |
| avatar_url | TEXT | — |
| role | TEXT | NOT NULL DEFAULT 'owner', CHECK IN ('owner','editor','viewer') |
| is_active | BOOLEAN | NOT NULL DEFAULT TRUE |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |
| updated_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |

### `resellers`
| Column | Type | Constraints |
|---|---|---|
| id | UUID | PRIMARY KEY DEFAULT gen_random_uuid() |
| name | TEXT | NOT NULL |
| slug | TEXT | UNIQUE NOT NULL |
| custom_domain | TEXT | UNIQUE |
| owner_user_id | UUID | NOT NULL REFERENCES users(id) |
| commission_pct | NUMERIC(5,2) | NOT NULL DEFAULT 20.00 |
| branding | JSONB | NOT NULL DEFAULT '{}' — shape: `{ logo_url, primary_color, company_name, support_email }` |
| status | TEXT | NOT NULL DEFAULT 'active', CHECK IN ('active','suspended','pending') |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |
| updated_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |

### `reseller_tenants`
| Column | Type | Constraints |
|---|---|---|
| id | UUID | PRIMARY KEY DEFAULT gen_random_uuid() |
| reseller_id | UUID | NOT NULL REFERENCES resellers(id) |
| tenant_id | UUID | NOT NULL REFERENCES tenants(id) |
| invited_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |
| — | — | UNIQUE (reseller_id, tenant_id) |

### `packages`
| Column | Type | Constraints |
|---|---|---|
| id | UUID | PRIMARY KEY DEFAULT gen_random_uuid() |
| name | TEXT | NOT NULL |
| slug | TEXT | UNIQUE NOT NULL |
| price_monthly | NUMERIC(10,2) | NOT NULL DEFAULT 0 |
| price_yearly | NUMERIC(10,2) | NOT NULL DEFAULT 0 |
| currency | TEXT | NOT NULL DEFAULT 'IDR' |
| max_invitations | INTEGER | NOT NULL DEFAULT 1 (-1 = unlimited) |
| max_guests | INTEGER | NOT NULL DEFAULT 50 (per invitation) |
| max_photos | INTEGER | NOT NULL DEFAULT 5 |
| is_active | BOOLEAN | NOT NULL DEFAULT TRUE |
| is_reseller | BOOLEAN | NOT NULL DEFAULT FALSE |
| sort_order | INTEGER | NOT NULL DEFAULT 0 |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |
| updated_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |

### `package_features`
| Column | Type | Constraints |
|---|---|---|
| id | UUID | PRIMARY KEY DEFAULT gen_random_uuid() |
| package_id | UUID | NOT NULL REFERENCES packages(id) |
| feature_key | TEXT | NOT NULL |
| is_enabled | BOOLEAN | NOT NULL DEFAULT TRUE |
| config | JSONB | NOT NULL DEFAULT '{}' |
| — | — | UNIQUE (package_id, feature_key) |

### `tenant_subscriptions`
| Column | Type | Constraints |
|---|---|---|
| id | UUID | PRIMARY KEY DEFAULT gen_random_uuid() |
| tenant_id | UUID | NOT NULL REFERENCES tenants(id) |
| package_id | UUID | NOT NULL REFERENCES packages(id) |
| reseller_id | UUID | REFERENCES resellers(id) — null if direct |
| billing_cycle | TEXT | NOT NULL DEFAULT 'monthly', CHECK IN ('monthly','yearly','lifetime') |
| status | TEXT | NOT NULL DEFAULT 'active', CHECK IN ('active','trialing','past_due','cancelled','paused') |
| current_period_start | TIMESTAMPTZ | NOT NULL |
| current_period_end | TIMESTAMPTZ | NOT NULL |
| payment_provider | TEXT | — |
| payment_ref | TEXT | — |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |
| updated_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |

### `feature_flags`
| Column | Type | Constraints |
|---|---|---|
| id | UUID | PRIMARY KEY DEFAULT gen_random_uuid() |
| tenant_id | UUID | REFERENCES tenants(id) — null = platform-wide |
| feature_key | TEXT | NOT NULL |
| is_enabled | BOOLEAN | NOT NULL DEFAULT TRUE |
| config | JSONB | NOT NULL DEFAULT '{}' |
| reason | TEXT | audit reason for override |
| expires_at | TIMESTAMPTZ | null = permanent |
| created_by | UUID | REFERENCES users(id) |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |
| — | — | UNIQUE (tenant_id, feature_key) |

### `invitation_themes`
| Column | Type | Constraints |
|---|---|---|
| id | UUID | PRIMARY KEY DEFAULT gen_random_uuid() |
| name | TEXT | NOT NULL |
| slug | TEXT | UNIQUE NOT NULL |
| preview_url | TEXT | — |
| category | TEXT | NOT NULL DEFAULT 'general' |
| is_premium | BOOLEAN | NOT NULL DEFAULT FALSE |
| is_active | BOOLEAN | NOT NULL DEFAULT TRUE |
| config_schema | JSONB | NOT NULL DEFAULT '{}' |
| sort_order | INTEGER | NOT NULL DEFAULT 0 |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |

### `invitations`
| Column | Type | Constraints |
|---|---|---|
| id | UUID | PRIMARY KEY DEFAULT gen_random_uuid() |
| tenant_id | UUID | NOT NULL REFERENCES tenants(id) |
| created_by | UUID | NOT NULL REFERENCES users(id) |
| theme_id | UUID | NOT NULL REFERENCES invitation_themes(id) |
| slug | TEXT | UNIQUE NOT NULL — public URL slug |
| title | TEXT | NOT NULL |
| status | TEXT | NOT NULL DEFAULT 'draft', CHECK IN ('draft','published','archived') |
| event_date | DATE | — |
| event_time | TIME | — |
| event_venue | TEXT | — |
| event_address | TEXT | — |
| event_maps_url | TEXT | — |
| couple_data | JSONB | NOT NULL DEFAULT '{}' — shape: `{ groom_name, bride_name, groom_photo, bride_photo, love_story }` |
| customization | JSONB | NOT NULL DEFAULT '{}' |
| music_url | TEXT | — |
| is_rsvp_open | BOOLEAN | NOT NULL DEFAULT TRUE |
| rsvp_deadline | DATE | — |
| meta_title | TEXT | — |
| meta_description | TEXT | — |
| view_count | INTEGER | NOT NULL DEFAULT 0 |
| published_at | TIMESTAMPTZ | — |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |
| updated_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |

### `invitation_sections`
| Column | Type | Constraints |
|---|---|---|
| id | UUID | PRIMARY KEY DEFAULT gen_random_uuid() |
| invitation_id | UUID | NOT NULL REFERENCES invitations(id) ON DELETE CASCADE |
| section_type | TEXT | NOT NULL — hero / couple / event_details / gallery / rsvp / gift / countdown / story |
| sort_order | INTEGER | NOT NULL DEFAULT 0 |
| is_visible | BOOLEAN | NOT NULL DEFAULT TRUE |
| content | JSONB | NOT NULL DEFAULT '{}' |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |
| updated_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |

### `guests`
| Column | Type | Constraints |
|---|---|---|
| id | UUID | PRIMARY KEY DEFAULT gen_random_uuid() |
| invitation_id | UUID | NOT NULL REFERENCES invitations(id) ON DELETE CASCADE |
| tenant_id | UUID | NOT NULL REFERENCES tenants(id) |
| name | TEXT | NOT NULL |
| phone | TEXT | — |
| email | TEXT | — |
| address | TEXT | — |
| group_label | TEXT | — family / friends / colleague |
| personal_link | TEXT | UNIQUE — personalized URL token |
| notes | TEXT | — |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |

### `rsvp_responses`
| Column | Type | Constraints |
|---|---|---|
| id | UUID | PRIMARY KEY DEFAULT gen_random_uuid() |
| invitation_id | UUID | NOT NULL REFERENCES invitations(id) ON DELETE CASCADE |
| guest_id | UUID | REFERENCES guests(id) — null if open RSVP |
| name | TEXT | NOT NULL |
| email | TEXT | — |
| phone | TEXT | — |
| attendance | TEXT | NOT NULL, CHECK IN ('attending','not_attending','maybe') |
| pax_count | INTEGER | NOT NULL DEFAULT 1 |
| message | TEXT | — |
| wishes | TEXT | — |
| submitted_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |
| ip_address | TEXT | — |
| metadata | JSONB | NOT NULL DEFAULT '{}' |

**No `tenant_id` column on this table** — see flags in §4, §10, §12.

### `orders` (PHASE1 baseline shape — superseded by the full PHASE10 shape in Phase L; M1 creates exactly this shape and no more)
| Column | Type | Constraints |
|---|---|---|
| id | UUID | PRIMARY KEY DEFAULT gen_random_uuid() |
| tenant_id | UUID | NOT NULL REFERENCES tenants(id) |
| reseller_id | UUID | REFERENCES resellers(id) |
| package_id | UUID | NOT NULL REFERENCES packages(id) |
| amount | NUMERIC(12,2) | NOT NULL |
| currency | TEXT | NOT NULL DEFAULT 'IDR' |
| billing_cycle | TEXT | NOT NULL |
| status | TEXT | NOT NULL DEFAULT 'pending', CHECK IN ('pending','paid','failed','refunded') |
| payment_provider | TEXT | — |
| payment_ref | TEXT | — |
| payment_data | JSONB | NOT NULL DEFAULT '{}' |
| commission_amount | NUMERIC(12,2) | calculated at time of order |
| paid_at | TIMESTAMPTZ | — |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |

### `audit_logs`
| Column | Type | Constraints |
|---|---|---|
| id | BIGSERIAL | PRIMARY KEY |
| tenant_id | UUID | REFERENCES tenants(id) |
| user_id | UUID | REFERENCES users(id) |
| action | TEXT | NOT NULL |
| resource_type | TEXT | NOT NULL |
| resource_id | TEXT | — |
| old_data | JSONB | — |
| new_data | JSONB | — |
| ip_address | TEXT | — |
| user_agent | TEXT | — |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() |

## 14. Required Database Indexes

Reproduced exactly from PHASE1 §4.2 — no index added or removed:

| Index | Table | Columns |
|---|---|---|
| `idx_users_tenant_id` | users | tenant_id |
| `idx_pf_package_id` | package_features | package_id |
| `idx_ts_tenant_id` | tenant_subscriptions | tenant_id |
| `idx_inv_tenant_id` | invitations | tenant_id |
| `idx_inv_slug` | invitations | slug |
| `idx_inv_status` | invitations | status |
| `idx_is_invitation_id` | invitation_sections | invitation_id |
| `idx_guests_invitation_id` | guests | invitation_id |
| `idx_guests_tenant_id` | guests | tenant_id |
| `idx_rsvp_invitation_id` | rsvp_responses | invitation_id |
| `idx_orders_tenant_id` | orders | tenant_id |
| `idx_al_tenant_id` | audit_logs | tenant_id |
| `idx_al_created_at` | audit_logs | created_at |

**Implicit indexes from UNIQUE constraints** (not separately named in PHASE1, created automatically by Postgres): `tenants.slug`, `resellers.slug`, `resellers.custom_domain`, `reseller_tenants(reseller_id, tenant_id)`, `packages.slug`, `package_features(package_id, feature_key)`, `feature_flags(tenant_id, feature_key)`, `invitation_themes.slug`, `invitations.slug`, `guests.personal_link`.

## 15. Required Constraints

**CHECK constraints (exact, per table):**
- `tenants.status IN ('active', 'suspended', 'deleted')`
- `users.role IN ('owner', 'editor', 'viewer')`
- `resellers.status IN ('active', 'suspended', 'pending')`
- `tenant_subscriptions.billing_cycle IN ('monthly', 'yearly', 'lifetime')`
- `tenant_subscriptions.status IN ('active', 'trialing', 'past_due', 'cancelled', 'paused')`
- `invitations.status IN ('draft', 'published', 'archived')`
- `rsvp_responses.attendance IN ('attending', 'not_attending', 'maybe')`
- `orders.status IN ('pending', 'paid', 'failed', 'refunded')`

**NOT NULL constraints:** as marked in every column table in §13 — not repeated here.

**Foreign key ON DELETE behavior (exact — only these four are specified; all others default to Postgres `NO ACTION`):**
- `users.id → auth.users(id)` **ON DELETE CASCADE**
- `invitation_sections.invitation_id → invitations(id)` **ON DELETE CASCADE**
- `guests.invitation_id → invitations(id)` **ON DELETE CASCADE**
- `rsvp_responses.invitation_id → invitations(id)` **ON DELETE CASCADE**

Every other foreign key listed in §13 (e.g. `users.tenant_id`, `invitations.tenant_id`, `orders.package_id`, `resellers.owner_user_id`, etc.) has **no explicit `ON DELETE` clause** in PHASE1 §4.2 and therefore defaults to `NO ACTION` — deleting a referenced row (e.g. a `tenants` row with existing `users`) will fail unless the dependent rows are removed first. This is not changed here.

**UNIQUE constraints (exact, consolidated):**
- `tenants.slug`
- `resellers.slug`, `resellers.custom_domain`
- `reseller_tenants(reseller_id, tenant_id)`
- `packages.slug`
- `package_features(package_id, feature_key)`
- `feature_flags(tenant_id, feature_key)`
- `invitation_themes.slug`
- `invitations.slug`
- `guests.personal_link`

## 16. Required Policies

| Table | RLS enabled? | Policies (exact) |
|---|---|---|
| `invitations` | ✅ (PHASE1 §4.3) | `tenant_isolation` (direct column), `public_invitation_read` (FOR SELECT, `status = 'published'`), `reseller_client_read` (FOR SELECT, via `reseller_tenants` join) |
| `guests` | ✅ (PHASE1 §4.3) | `tenant_isolation` (direct column, adapted from Pattern 1) |
| `rsvp_responses` | ✅ (PHASE1 §4.3) | `tenant_isolation` (join-adapted via `invitation_id`, per §12) |
| `tenants`, `users`, `resellers`, `reseller_tenants`, `packages`, `package_features`, `tenant_subscriptions`, `feature_flags`, `invitation_themes`, `invitation_sections`, `orders`, `audit_logs` | ❌ Not specified in PHASE1 | No RLS policy exists in the approved architecture for these tables. Access must be server-mediated with explicit application-layer tenant filtering (see flagged gap, §12). |

**Explicitly deferred (not part of M1):** INSERT/UPDATE/DELETE policies for guest-facing RSVP submission and guestbook write paths — Phase J. Additional RLS coverage for `invitation_sections`, if any future phase adds it — not specified here.

## 17. Service Layer Architecture

| File | Responsibility (contract, not implementation) |
|---|---|
| `lib/auth/session.ts` | Session retrieval helper used by server components/routes to obtain the current authenticated user and JWT claims. |
| `lib/auth/permissions.ts` | RBAC helper layer exposing the permission matrix in §9 for role-based checks. Does **not** yet implement permission-string gating (`requireAuth()`) — that is Phase D. |
| `lib/packages/features.ts` | `resolveFeature(tenantId, featureKey)` — resolves a feature's enabled/disabled state and config in this exact priority order (PHASE1 §6.2): (1) platform-wide kill switch (`feature_flags` where `tenant_id IS NULL`), (2) tenant-level override (`feature_flags` where `tenant_id` matches), (3) package-level entitlement (`package_features` via the tenant's active subscription), (4) default: disabled. Returns `{ enabled, config?, source }`. |
| `lib/packages/limits.ts` | `checkQuota(tenantId, resource)` — for `resource ∈ {'invitations','guests','photos','team_members'}`, reads the active subscription's package limit (`max_<resource>`), compares against current usage, and returns `{ allowed, limit, current, remaining }`. A limit value of `-1` means unlimited (PHASE1 §6.3). |
| `lib/tenant/resolver.ts` | Subdomain → `tenant_id` / reseller-context resolution used by Edge Middleware (PHASE1 §3 folder comment: "Subdomain → tenant_id"). |
| `config/features.ts` | The `FEATURES` registry — the complete set of feature key constants, reproduced exactly in the table below. |
| `config/packages.ts` | Package definitions reference point ("source of truth" per PHASE1 §3 folder comment) — consumed by seed data, not redefined here. |
| `config/site.ts` | Platform-wide constants (domain, app name, etc.) — no specific keys are enumerated in PHASE1 beyond the folder comment. |
| `hooks/use-feature-flag.ts` | `useFeatureFlag(key)` — reads from a server-resolved `FeatureFlagProvider` context (§7.3), never a client-side DB call. |
| `hooks/use-quota.ts` | Client-side accessor for quota state resolved server-side. |
| `hooks/use-tenant.ts` | Client-side accessor for the current tenant context. |
| `hooks/use-invitation.ts` | Client-side accessor stub — full invitation data shape is populated starting Phase H. |

**`FEATURES` registry — exact keys and string values (PHASE1 §7.1):**

| Constant | String value |
|---|---|
| MUSIC_PLAYER | `music_player` |
| COUNTDOWN_TIMER | `countdown_timer` |
| GIFT_REGISTRY | `gift_registry` |
| GALLERY_SECTION | `gallery_section` |
| LOVE_STORY_SECTION | `love_story_section` |
| LIVESTREAM_LINK | `livestream_link` |
| MAP_EMBED | `map_embed` |
| RSVP_OPEN | `rsvp_open` |
| RSVP_MEAL_CHOICE | `rsvp_meal_choice` |
| RSVP_PLUS_ONE | `rsvp_plus_one` |
| RSVP_WISHES_WALL | `rsvp_wishes_wall` |
| GUEST_IMPORT_CSV | `guest_import_csv` |
| GUEST_PERSONALIZED_LINK | `guest_personalized_link` |
| GUEST_WHATSAPP_BLAST | `guest_whatsapp_blast` |
| ANALYTICS_BASIC | `analytics_basic` |
| ANALYTICS_ADVANCED | `analytics_advanced` |
| REMOVE_PLATFORM_BADGE | `remove_platform_badge` |
| CUSTOM_DOMAIN | `custom_domain` |
| CUSTOM_FONT | `custom_font` |
| EXPORT_RSVP_CSV | `export_rsvp_csv` |
| EXPORT_GUEST_CSV | `export_guest_csv` |
| PREMIUM_THEMES | `premium_themes` |
| TEAM_MEMBERS | `team_members` |
| MAINTENANCE_MODE | `maintenance_mode` |
| NEW_EDITOR_UI | `new_editor_ui` |

**Server-side resolution rule (PHASE1 §7.3):** feature flags are resolved once per request in the root `(app)` layout server component and injected into a `FeatureFlagProvider` context — never resolved per-component, to avoid N+1 flag queries per render.

## 18. API Architecture

**M1 status:** per BUILD_ORDER Phase B, **no API route has a functioning handler in this milestone.** The following directories are created as scaffolds only, each carrying its eventual responsibility for forward compatibility, fulfilled in the phase noted:

| Route directory | Eventual responsibility | Fulfilled in |
|---|---|---|
| `app/api/auth/` | Auth-adjacent server actions (most auth is handled by Supabase Auth directly, not a custom REST surface) | Phase B/D |
| `app/api/invitations/` | Invitation CRUD | Phase H |
| `app/api/rsvp/` | RSVP submission/summary | Phase J |
| `app/api/guests/` | Guest CRUD, CSV import | Phase I |
| `app/api/packages/` | Package listing/entitlement queries | Phase F |
| `app/api/payments/` | Superseded — real payment endpoints are `app/api/subscription/*` and `app/api/webhooks/*`, both Phase L | Phase L |
| `app/api/resellers/` | Reseller-facing endpoints | Phase E |
| `app/api/webhooks/` | Gateway webhook receivers | Phase L |

**The one real request-layer responsibility implemented in M1** is `app/middleware.ts` (Edge Middleware): tenant/Host resolution + JWT validation on every request (§11). This is not a REST API route; it is the platform's request-interception layer and runs before any route handler.

## 19. Frontend Foundation Requirements

Folder scaffold required by the end of M1 (PHASE1 §3, as enumerated in BUILD_ORDER Phase B "Files to create" — reproduced exactly):

```
app/(marketing)/page.tsx
app/(marketing)/pricing/
app/(marketing)/layout.tsx
app/(auth)/login/
app/(auth)/register/
app/(auth)/layout.tsx
app/(app)/dashboard/
app/(app)/invitations/                 (stub)
app/(app)/invitations/new/             (stub)
app/(app)/packages/                    (stub)
app/(app)/settings/
app/(app)/layout.tsx
app/(admin)/tenants/                   (stub)
app/(admin)/packages/                  (stub)
app/(admin)/resellers/                 (stub)
app/(admin)/feature-flags/             (stub)
app/(admin)/analytics/                 (stub)
app/(admin)/layout.tsx
app/(reseller)/dashboard/              (stub)
app/(reseller)/clients/                (stub)
app/(reseller)/billing/                (stub)
app/(reseller)/branding/               (stub)
app/(reseller)/layout.tsx
app/inv/[slug]/page.tsx                (SSR stub — ISR added Phase H)
app/layout.tsx
app/middleware.ts
components/dashboard/
components/admin/
components/reseller/
components/shared/
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
supabase/seed.sql
supabase/functions/send-rsvp-notification/
supabase/functions/process-payment-webhook/  (stub)
supabase/config.toml
```

**Content requirement (not application logic, structural only):** every `layout.tsx` listed above must exist and render its route group's children; route-group pages other than `(marketing)`, `(auth)`, and `(app)/dashboard` remain empty placeholders until their owning phase. No component beyond the minimal auth pages and an empty dashboard shell (invitation list placeholder, quick-stats placeholder) is built in M1.

## 20. Dashboard Access Flow

1. Browser requests `app.weddingplatform.com/dashboard`.
2. Cloudflare → Vercel Edge Network → `app/middleware.ts`.
3. Middleware inspects the `Host` header. For `app.weddingplatform.com`, no reseller lookup is needed; the request proceeds as the direct-tenant path.
4. Middleware validates the Supabase session JWT. No valid session → redirect to `app/(auth)/login`.
5. Valid session → claims (`tenant_id`, `role`, `reseller_id?`, `package_id`) are available to server components via `lib/auth/session.ts`.
6. `app/(app)/layout.tsx` server component resolves all feature flags once (§17, §7.3) and provides them via `FeatureFlagProvider`.
7. `app/(app)/dashboard` renders using the resolved tenant/role/feature context. Any Supabase query issued from here is automatically scoped by the `tenant_isolation` RLS policy on tables that have it (§16); for tables without RLS, the server code must apply an explicit `tenant_id` filter (§12 flagged gap).

For the reseller white-label/custom-domain path (`[tenant].weddingplatform.com` / `dashboard.resellerbrand.com`), step 3 instead resolves `Host` → `resellers.custom_domain` (or subdomain slug) → `reseller_id`, per the flow in PHASE1 §9.2. Full branded rendering of that path is Phase E's responsibility; M1 only guarantees the lookup succeeds.

## 21. Invitation Ownership Flow

M1 establishes the **ownership data model only** — not invitation creation business logic (Phase H). The contract any later phase must honor:

1. An `invitations` row may only be inserted with a `tenant_id` equal to the acting user's `users.tenant_id` and a `created_by` equal to the acting user's `users.id`. PHASE1 specifies no DB-level trigger enforcing this pairing (§10); it must be enforced in the server-side insert path built in Phase H.
2. `theme_id` must reference an existing, active `invitation_themes` row (`is_active = TRUE`); premium-theme gating against `is_premium` is resolved via `resolveFeature(tenantId, FEATURES.PREMIUM_THEMES)` (§17), not a DB constraint.
3. Once persisted, RLS enforces that only the owning tenant's authenticated users (via `tenant_isolation`) or the public (via `public_invitation_read`, status-gated) or a linked reseller (via `reseller_client_read`) can read the row — per §16.
4. `invitation_sections` and `guests` rows inherit ownership transitively through `invitation_id`; `guests` additionally denormalizes `tenant_id` directly (§10) and must be kept consistent with its parent invitation's `tenant_id` by the application layer, since no DB constraint cross-checks the two.

## 22. Security Requirements

Mapped from PHASE1 Appendix B ("Security Checklist (Phase 1)"), split by M1 applicability:

| Checklist item | M1 status |
|---|---|
| All admin routes protected by `role === 'super_admin'` middleware | Deferred — admin routes don't exist yet beyond stubs (Phase E); the underlying role-check capability (§8/§9) is specified now. |
| Service role key never exposed to client bundle | Applies now — `createAdminClient()` (stub since M0) remains server-only; no client bundle may import it. |
| RLS enabled and tested on all tenant tables | Applies now, exactly to the extent specified in §16 (3 of 15 tables) — the flagged gap on the remaining 12 is not closed in M1. |
| RSVP endpoint rate-limited (10 req/min per IP) | Deferred — no RSVP endpoint exists yet (Phase J). |
| File upload validation (type, size, virus scan placeholder) | Deferred — no file upload path exists yet. |
| SQL injection: use Supabase JS client (parameterized queries only) | Applies now as a standing rule for every service module in §17. |
| Personal invitation links are non-guessable UUIDs | Column (`guests.personal_link`) exists now; generation logic is Phase I. |
| Audit log written for all destructive actions | `audit_logs` table exists now (§13); no destructive action exists yet to log (see §23). |
| HTTPS enforced (Vercel default) | Applies now, inherited from M0's Vercel project setup. |
| CORS configured to platform domains only | Applies now — must be configured alongside `app/middleware.ts`. |

## 23. Audit Requirements

The `audit_logs` table (§13) must exist, be queryable by `tenant_id` and `created_at` (§14 indexes), and be writable only via server-side/service-role code paths. **M1 itself performs no mutating, destructive, or sensitive business action** — it implements authentication, schema, and read-side feature resolution only — so no action-name convention is fixed in this milestone. Concrete `action` string values (e.g. the kind later introduced in PHASE10 Appendix D, such as `subscription.activated`) are established starting with whichever later phase first performs a logged action. M1's responsibility is solely to ensure the table and its access pattern are ready to receive them.

## 24. Testing Requirements

Per BUILD_ORDER §6 (Unit/Integration sections attributed to Phase B/D):

**Unit tests:**
- `resolveFeature()` — all four priority branches (platform kill switch, tenant override, package entitlement, default-disabled).
- `checkQuota()` — allowed/disallowed/unlimited (`-1`) branches for each of `invitations`, `guests`, `photos`, `team_members`.
- RBAC permission-matrix lookups (§9) — correct boolean for every (action, role) pair.

**Integration tests:**
- RLS policy assertions on `invitations`: cross-tenant `SELECT` denied; anonymous `SELECT` of a `published` row succeeds; anonymous `SELECT` of a `draft`/`archived` row denied; a linked reseller's `SELECT` of a client tenant's row succeeds.
- RLS policy assertions on `guests`: cross-tenant `SELECT` denied.
- RLS policy assertions on `rsvp_responses`: cross-tenant `SELECT` denied via the join-adapted policy (§12).
- Auth flow: signup → `users` row created with correct `tenant_id` → JWT contains correct `tenant_id`/`role`/`package_id` (§8, §11).
- Edge Middleware: invalid/missing session redirects to login; valid session passes through; reseller-domain `Host` header resolves to the correct `reseller_id`.

## 25. Migration Plan

**Exact sequence for this milestone.** File numbers are a specification convenience (PHASE1 itself assigns no migration filenames); the sequence below reserves number ranges so that downstream, already-fixed numbering remains correct: PHASE10 Appendix A begins at `091`, and PHASE11 Appendix A begins at `106`.

```
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
016_rls_core_policies.sql        -- tenant_isolation / public_invitation_read / reseller_client_read
                                  -- (applied to invitations, guests, rsvp_responses per §16)
017_seed_free_package.sql        -- packages + package_features rows per §26
```

**Reserved range:** `018`–`090` are reserved for Phases C–J (PHASE2–9, external spec) — not consumed by M1. `091`–`105` remain Phase L's exactly as fixed in PHASE10 Appendix A. `106`–`119` remain Phase M's exactly as fixed in PHASE11 Appendix A.

**Migration ordering rule (table creation must precede dependent FKs):** `tenants` → `users` (FK to `tenants`, and to `auth.users`) → `resellers` (FK to `users`) → `reseller_tenants` (FK to `resellers`, `tenants`) → `packages` → `package_features` (FK to `packages`) → `tenant_subscriptions` (FK to `tenants`, `packages`, `resellers`) → `feature_flags` (FK to `tenants`, `users`) → `invitation_themes` → `invitations` (FK to `tenants`, `users`, `invitation_themes`) → `invitation_sections` (FK to `invitations`) → `guests` (FK to `invitations`, `tenants`) → `rsvp_responses` (FK to `invitations`, `guests`) → `orders` (FK to `tenants`, `resellers`, `packages`) → `audit_logs` (FK to `tenants`, `users`).

## 26. Acceptance Criteria

- [ ] All 15 tables in §13 exist in both staging and production with the exact columns, types, and constraints specified.
- [ ] All indexes in §14 exist.
- [ ] All CHECK/UNIQUE/FK constraints in §15 are enforced (verified by attempting an invalid insert per constraint).
- [ ] RLS is enabled on exactly `invitations`, `guests`, `rsvp_responses` — no more, no less — with the policies in §16.
- [ ] The `rsvp_responses` tenant-isolation policy uses the join-adapted form (§12), not a direct-column form (which would fail to compile, since the column doesn't exist).
- [ ] Free package seeded per §6.1's exact tier values: `max_invitations = 1`, `max_guests = 50`, `max_photos = 5`, `price_monthly = 0`, `is_reseller = FALSE`.
- [ ] Free-tier `package_features` rows seeded matching exactly: `countdown_timer = true`, `rsvp_open = true`; `music_player = false`, `gift_registry = false`, `custom_domain = false`, `guest_import_csv = false`, `export_rsvp_csv = false`, `analytics_basic = false`, `analytics_advanced = false`, `remove_platform_badge = false`, `premium_themes = false`, `team_members = false`.
- [ ] JWT issued at login contains exactly `sub`, `tenant_id`, `role`, `reseller_id` (if applicable), `package_id`, `exp` — no extra claim, no missing claim.
- [ ] `resolveFeature()` and `checkQuota()` pass all unit tests in §24.
- [ ] A registered user can sign up, is assigned a tenant + Free package, logs in, and reaches an empty dashboard.
- [ ] A second tenant's user cannot read the first tenant's `invitations`, `guests`, or `rsvp_responses` rows (RLS-verified).
- [ ] An anonymous (unauthenticated) request can read a `published` invitation but not a `draft` or `archived` one.
- [ ] A reseller-linked user can read their linked client tenants' `invitations` rows and no others.
- [ ] `createAdminClient()` is never imported from any client-bundle-reachable file.
- [ ] Folder/file scaffold in §19 exists in full.

## 27. Completion Checklist

- [ ] §3–§10 (tenant/role/ownership model) match PHASE1 exactly, with all flagged gaps documented and none silently resolved.
- [ ] §13–§16 (schema, indexes, constraints, policies) are applied and pass §26's verification list.
- [ ] §17 service contracts (`resolveFeature`, `checkQuota`, `FEATURES` registry) are implemented and unit-tested.
- [ ] §11 Auth Hook mints correct JWT claims; Google OAuth provider enabled per the specification note in §11.
- [ ] §19 folder scaffold exists; `app/middleware.ts` performs tenant/Host resolution and JWT validation.
- [ ] §24 unit and integration tests are green.
- [ ] §25 migrations `001`–`017` applied cleanly to staging, then production, in the exact order given.
- [ ] Tag `v0.2.0` once every item above is verified.

**Once every box above is checked, Phase C (Database Domain Completion) may begin.**

---

*End of M1_CORE_MULTI_TENANT_FOUNDATION.md*
