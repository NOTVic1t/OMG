# M5_PACKAGE_FEATURE_SYSTEM.md
# Wedding Invitation SaaS Platform — Milestone M5: Package & Feature System

> **Version:** 1.0.0
> **Implementation authority:** BUILD_ORDER.md — Phase F (`= M5` in IMPLEMENTATION_ROADMAP.md)
> **Upstream source documents:** PHASE1_ARCHITECTURE.md (§4.2, §6, §7), PHASE10_PAYMENT_SYSTEM.md (§3.1, §9–§12, §17–§18), PHASE11_ANALYTICS.md (§1.4, §2.1, §12, §19, Appendix C), PHASE12_DEPLOYMENT.md (§9.1)
> **Predecessors:** M0–M4, all complete.
> **Method:** Identical discipline to M2/M3/M4. PHASE5_PACKAGE_FEATURE_SYSTEM.md itself is not in this document set; everything below is either (a) already specified in M1/M2 and recapped by reference, or (b) a literal citation from PHASE1/10/11/12 of a fact this domain's own later documents (PHASE10, PHASE11) demonstrably depend on. One genuine naming inconsistency between PHASE1 and PHASE11 is resolved explicitly (§6). One previously-deferred gap (`package_feature_snapshot`) is **not** resolved here, consistent with M2's deferral, because the user did not direct its resolution and no citation exists to ground one. No application code is included.

---

## 1. Objectives

1. Consolidate the package/feature data model exactly as PHASE1 §4.2/§6/§7 define it (recapped from M1, not restated wholesale) with every extension M2 already added (`packages.status/is_public/price_lifetime/max_team_members`, `tenant_subscriptions`' six lifecycle columns, `add_ons`, `tenant_add_ons`).
2. Resolve the tier-naming inconsistency between PHASE1 §6.1 ("Starter," "Enterprise") and PHASE11 §1.4/Appendix C ("Basic," "Ultimate") — same four tiers, different labels across documents written at different times.
3. Specify, exactly, the feature-resolution priority order (PHASE1 §6.2), its caching behavior (PHASE5 §12.1, cited by PHASE10/11), and the one precision the cited pseudocode left implicit: how an expired tenant override (`feature_flags.expires_at`) falls through.
4. Specify, exactly, the quota-enforcement contract (PHASE1 §6.3) including the per-invitation vs. per-tenant scoping distinction implied by PHASE1's own column comments but never stated as a rule.
5. Specify, exactly, the upgrade/downgrade state machine and its quota-enforcement consequences (PHASE10 §10), scoped to what belongs to the Package Domain as opposed to what remains Phase L's (Payment System's) responsibility.
6. Add the two feature keys PHASE11 confirms exist but PHASE1's original registry never listed (`analytics_export`, `qr_checkin`), since PHASE11 explicitly attributes both to "PHASE5 §11.2"/"PHASE5 Appendix B" — i.e., to this domain.

## 2. Scope

**In scope:** The package catalog, the feature-flag/resolution system, quota enforcement, add-on entitlements, the subscription state machine, upgrade/downgrade package-and-quota consequences, reseller package eligibility, and pricing fields — exactly as cited.

**Out of scope, with an explicit boundary:** Payment processing, order creation, gateway adapters, webhooks, invoicing, and refunds remain Phase L's (PHASE10's) responsibility in full. Where an upgrade/downgrade flow in PHASE10 §10 mixes package-state logic with order/payment logic, this milestone specifies only the package-state half; the payment half is cross-referenced, not restated, per the same "referenced only" convention M2 §18 already established for the Payment Domain.

**Deferred, not resolved here (consistent with M2 §5.4's existing treatment, not revisited):** `package_feature_snapshot` materialized view. No column or query is cited for it anywhere; the user's explicit resolution directive for this milestone covers hierarchy, resolution order, quotas, upgrade/downgrade, reseller boundaries, and override precedence — not this object. It remains an open item.

## 3. Package System Architecture

```
packages (catalog, platform-level, not tenant-scoped)
   │
   ├──< package_features (per-package feature entitlements + config)
   │
   ├──< tenant_subscriptions >── tenants
   │         │
   │         ├── pending_downgrade_package_id ──> packages (self-referential, future state)
   │         └── reseller_id ──> resellers (nullable — direct vs. reseller-acquired)
   │
   ├──< add_ons (catalog, platform-level)
   │         │
   │         └──< tenant_add_ons >── tenants, orders
   │
feature_flags (tenant_id nullable — platform-wide kill switch, or tenant-specific override)
   │
   └── resolved together with package_features by resolveFeature() (§7)
```

`packages` and `add_ons` are catalog tables (not tenant-scoped, M1 §6/M2 §12). `tenant_subscriptions`, `tenant_add_ons`, and `feature_flags` (when `tenant_id` is non-null) are the tenant-scoped join points into that catalog. This is unchanged from M1/M2 — restated here only as the organizing diagram for this milestone.

## 4. Feature Flag Architecture

`feature_flags` (M1 §13, unchanged):

| Column | Role in resolution |
|---|---|
| `tenant_id` | `NULL` = platform-wide kill switch; non-null = tenant-specific override |
| `feature_key` | Matches a key in the `FEATURES` registry (§7) |
| `is_enabled` | The override's value |
| `config` | Override-specific configuration, same JSONB-config convention as `package_features.config` |
| `reason` | Free-text justification for the override — serves an audit-adjacent purpose without a separate `audit_logs` entry (consistent with M4 §18's note on this table) |
| `expires_at` | `NULL` = permanent; non-null = the override stops applying after this timestamp (precision resolved in §14) |
| `created_by` | `users.id` of whoever created the override |

`UNIQUE (tenant_id, feature_key)` (M1 §15) means a given tenant (or the platform, for `tenant_id IS NULL`) can have at most one override row per feature key — there is no history of overrides, only the current one.

## 5. Package Lifecycle

The `packages` catalog row's own lifecycle, distinct from any tenant's subscription to it (§9):

1. **Created** by `super_admin` via `/admin/packages` (PHASE1 §8.1, M4 §3) with `is_active = TRUE` (PHASE1 §4.2 original), `status` and `is_public` (M2 §5.4 additions — both confirmed required by PHASE10 §3.3/§10.2's literal `.eq('status', 'active').eq('is_public', true)` filter, which is the actual gate used when a tenant attempts to purchase).
2. **Published/purchasable** when `status = 'active'` AND `is_public = TRUE` — both conditions are checked together at purchase time (PHASE10 §3.3); neither alone is cited as sufficient.
3. **Retired** — no explicit retirement flow is cited; setting `is_active = FALSE` and/or `status` to some non-`'active'` value and/or `is_public = FALSE` presumably removes it from new-purchase eligibility while leaving existing `tenant_subscriptions` referencing it intact (the FK has no cited `ON DELETE` override, M2 §6 — `NO ACTION` applies, so a retired package row cannot simply be deleted while subscriptions reference it).
4. **`is_reseller`** (PHASE1 §4.2 original) marks a package as eligible for reseller assignment — independent of `status`/`is_public` (§13).

**Coexistence flag (carried forward from M2 §5.4/§17, restated for this milestone's completeness):** `is_active` (PHASE1 original) and `status` (PHASE10-cited addition) coexist with no cited rule for how they interact if they disagree (e.g. `is_active = TRUE` but `status != 'active'`). Not resolved here — same open item M2 already recorded.

## 6. Package Hierarchy

**Naming compatibility note (resolved here, by the same method M1 §8 used for role naming):** PHASE1 §6.1 names the four tiers **Free, Starter, Premium, Enterprise**. PHASE11 §1.4 and Appendix C name the same four-tier structure **Free, Basic, Premium, Ultimate** — and the underlying entitlement values match exactly between the two documents' tier 2 and tier 4 (e.g. PHASE1's "Analytics: ❌/Basic/Advanced/Advanced" lines up exactly with PHASE11's "`analytics_basic`: ❌/✅/✅/✅" + "`analytics_advanced`: ❌/❌/✅/✅"), confirming these are the same tiers under different labels, not different tiers. This specification adopts PHASE11's labels (**Basic**, **Ultimate**) as the operative names going forward, since PHASE11's feature-key-level matrix is what this milestone's resolution engine (§7) actually gates against; "Starter" and "Enterprise" are retained only as PHASE1's original display synonyms.

**Exact tier table (PHASE1 §6.1 values, PHASE11-aligned names):**

| Attribute | Free | Basic | Premium | Ultimate |
|---|---|---|---|---|
| Price/mo | Rp 0 | Rp 49.000 | Rp 99.000 | Custom |
| `max_invitations` | 1 | 3 | -1 (unlimited) | -1 (unlimited) |
| `max_guests` (per invitation) | 50 | 200 | -1 | -1 |
| `max_photos` (per invitation) | 5 | 20 | -1 | -1 |
| Themes | 3 basic | All free | All + premium | All |
| `custom_domain` | ❌ | ❌ | ✅ | ✅ |
| `music_player` | ❌ | ✅ | ✅ | ✅ |
| `countdown_timer` | ✅ | ✅ | ✅ | ✅ |
| `gift_registry` | ❌ | ❌ | ✅ | ✅ |
| `rsvp_open` | ✅ | ✅ | ✅ | ✅ |
| `guest_import_csv` | ❌ | ❌ | ✅ | ✅ |
| `export_rsvp_csv` | ❌ | ✅ | ✅ | ✅ |
| `analytics_basic` | ❌ | ✅ | ✅ | ✅ |
| `analytics_advanced` | ❌ | ❌ | ✅ | ✅ |
| `analytics_export` | ❌ | ❌ | ✅ | ✅ |
| `qr_checkin` | ❌ | ❌ | ✅ (2 devices) | ✅ (∞ devices) |
| `remove_platform_badge` | ❌ | ❌ | ✅ | ✅ |
| `max_team_members` | 1 | 1 | 3 | -1 (unlimited) |
| Priority support | ❌ | ❌ | ✅ | ✅ — not a `FEATURES` registry key; no feature flag governs this, it is a support/ops commitment outside the gating system |

**Ordering mechanism (resolved — sort_order):** PHASE10 §10.2 determines upgrade-vs-downgrade by direct numeric comparison: `(newPkg.sort_order ?? 0) > currentSortOrder`. This requires `packages.sort_order` (already in PHASE1 §4.2) to be a strictly increasing sequence across the tier ladder. No exact integer values are cited anywhere; only the strictly-increasing property is required for PHASE10's comparison to function. This specification assigns the canonical values **Free = 0, Basic = 1, Premium = 2, Ultimate = 3**, flagged explicitly as an inferred-but-necessary assignment, not a citation — any strictly-increasing sequence would satisfy PHASE10's logic equally; these specific integers are chosen for clarity.

**Reseller packages are not a fifth rung on this ladder.** `is_reseller = TRUE` packages are a parallel, separately-flagged catalog (§13) for wholesale assignment to client tenants — reseller dashboard/portfolio access itself is role-based, not package-tier-based (PHASE11 §10.1 design note, M4 §5).

## 7. Feature Resolution Engine

**`resolveFeature(tenantId, featureKey)` — exact priority order (PHASE1 §6.2, unchanged):**
```
1. Platform-wide kill switch   — feature_flags WHERE tenant_id IS NULL
2. Tenant-level override       — feature_flags WHERE tenant_id = <tenantId>
3. Package-level entitlement   — package_features via the tenant's active tenant_subscriptions.package_id
4. Default                     — disabled
```
Returns `{ enabled, config?, source }` where `source` identifies which of the four tiers produced the result (M1 §17).

**`FEATURES` registry — complete, with this milestone's two additions:**

The 25 keys already specified in M1 §17 are unchanged. This milestone adds the two keys PHASE11 cites as already existing but PHASE1 never listed:

| Constant | String value | Source |
|---|---|---|
| ANALYTICS_EXPORT | `analytics_export` | Cited throughout PHASE11 (§1.4, §12.1, §12.2, Appendix C), explicitly attributed to "PHASE5 Appendix B" by PHASE11 §12.2's own statement that it introduces zero new registry entries. |
| QR_CHECKIN | `qr_checkin` | Cited PHASE11 §1.4, §7.2, §12.1, §12.2, Appendix C, same attribution. |

**Config shapes, exact, as cited:**
- `analytics_advanced.config.retention_days` — Free/Basic: 30 (plan default, implicit), Premium: 90, Ultimate: 365 (PHASE11 §2.1, §19.1).
- `qr_checkin.config` — holds a device-count limit (Premium: 2, Ultimate: unlimited, per §6's table); exact key name within the JSONB is not cited anywhere — flagged, not invented.

**Caching (PHASE5 §12.1, cited by PHASE10 §17.2 and PHASE11 §17.3 as a reused precedent):** Redis-backed, **60-second TTL**, invalidated explicitly on subscription change (`invalidateFeatureCache()`, PHASE10 §9.1) and add-on purchase (PHASE10 §9.1's `activateAddOn()` calls the same invalidation). No other invalidation trigger is cited — a `feature_flags` override write is **not** cited as triggering cache invalidation anywhere, meaning a fresh platform/tenant override may take up to 60 seconds to take effect. This is stated explicitly since it is operationally significant and not previously surfaced.

**Deferred:** `package_feature_snapshot` — the cited purpose ("pre-compute JOIN-heavy resolution once the underlying table grows past the point where on-demand computation is viable," PHASE10 §18.5/PHASE11 §18.4) implies it would sit between the Redis cache and a cold `resolveFeature()` computation as a further optimization, but no column or refresh trigger is cited. Not built here (§2).

## 8. Add-On Architecture

Recapped from M2 §5.4 (unchanged schema), with the entitlement model made explicit:

- `add_ons` is a platform-level catalog (`id`, `name`, `price`, `currency`, `billing_cycle`, `is_active`, `is_stackable`) — structurally parallel to `packages` (§5), not tenant-scoped.
- `tenant_add_ons` is the tenant-scoped join (`tenant_id`, `add_on_id`, `quantity`, `status`, `starts_at`, `expires_at`, `order_id`) recording which add-ons a tenant currently has active — structurally parallel to `tenant_subscriptions`' relationship to `packages`.
- **Stackability rule (PHASE10 §3.4, exact):** if `add_ons.is_stackable = FALSE`, a tenant may hold at most one active `tenant_add_ons` row for that `add_on_id` (checked via `.eq('status', 'active')` before allowing a new purchase) and may not purchase quantity `> 1` in a single transaction.
- **Activation (PHASE10 §9.1):** on payment success, a `tenant_add_ons` row is inserted with `quantity = 1`, `status = 'active'`, `starts_at = now`, `expires_at` computed from `billing_cycle` (`+1 month`, `+1 year`, or `null` for non-expiring cycles) — and the feature cache is invalidated (§7).
- An add-on's relationship to the `FEATURES`/`resolveFeature()` system is **not cited anywhere** — no document shows `resolveFeature()` consulting `tenant_add_ons` as a fifth resolution tier, or any other mechanism by which an active add-on actually unlocks a feature/quota increase. This is a significant flagged gap: add-ons are fully specified as a *purchasable, trackable entitlement record*, but how that record translates into an actual capability change is never specified in any available document.

## 9. Subscription Architecture

`tenant_subscriptions` — base columns (M1 §13) plus the six lifecycle columns M2 §5.4 added (`trial_ends_at`, `grace_ends_at`, `pending_downgrade_package_id`, `auto_renew`, `cancelled_at`, `cancel_reason`), recapped, not restated, here.

**State machine (`status` CHECK, M1 §15, with transition triggers consolidated from PHASE10 §9/§11):**

```
trialing ──────────────────────────► active            (trial ends / payment confirmed)
active ──── period end, auto_renew=TRUE ───► past_due   (renewal order created, grace_ends_at set
                                                          to period_end + 7 days, PHASE10 §11.1)
past_due ──── payment received within grace ───► active (new period starts)
past_due ──── grace_ends_at passed, no payment ───► expired
                                                     (package reset to Free; quota enforcement runs, §10)
active ──── auto_renew=FALSE at period end ───► cancelled (same 7-day grace applies for manual restore)
active (with pending_downgrade_package_id set) ──── period end ───► active
                                                     (package_id swapped to the pending one, quota
                                                      enforcement runs, §12)
```

This state machine is owned by this milestone (the Package Domain) as a specification of *what states exist and what package/quota consequence each transition has*; the payment-driven mechanics that actually fire these transitions (the `process-renewals` cron, webhook-driven activation) remain Phase L's (PHASE10's) implementation responsibility, cross-referenced not restated.

## 10. Quota Enforcement Architecture

**`checkQuota(tenantId, resource)` — exact contract (PHASE1 §6.3), with scoping precision resolved here:**

| Resource | Scope | Limit column | Per-tenant or per-invitation? |
|---|---|---|---|
| `invitations` | Tenant | `packages.max_invitations` | **Per-tenant** — total count across all the tenant's invitations |
| `team_members` | Tenant | `packages.max_team_members` | **Per-tenant** — total count of the tenant's `users` rows |
| `guests` | A single invitation | `packages.max_guests` | **Per-invitation** — PHASE1 §4.2's own column comment ("per invitation") requires `checkQuota()` to be called with an invitation identifier for this resource, comparing that invitation's own guest count, not the tenant's aggregate guest count across all invitations |
| `photos` | A single invitation | `packages.max_photos` | **Per-invitation** — same reasoning; gallery/photo content is invitation-scoped per the folder structure (`components/invitation/sections`, PHASE1 §3) |

**Unlimited convention (PHASE1 §6.3, exact):** `limit === -1` → `{ allowed: true, limit: -1, current }`, no comparison performed.

**Quota check vs. quota enforcement — two distinct mechanisms, both cited:**
1. **Check (preventive, PHASE1 §6.3):** `checkQuota()` is called before allowing a new resource to be created; if `current >= limit` (and `limit !== -1`), creation is refused.
2. **Enforcement (corrective, PHASE10 §10.3, exact):** triggered only by a **downgrade** taking effect (§12) — `enforceQuotaLimitsAfterDowngrade()` does not refuse anything; it retroactively brings existing resource counts back under the new, lower limit by archiving/deactivating the excess:
   - **Invitations:** the oldest-created excess invitations beyond the new `max_invitations`, with status in `('draft','published')`, are set to `status = 'archived'` (never deleted) — newest invitations are preserved.
   - **Team members:** the newest-created excess `users` rows beyond the new `max_team_members`, excluding the row with `role = 'owner'` (never deactivated), are set to `is_active = FALSE` — oldest team members (after the owner) are preserved.
   - No equivalent enforcement is cited for `guests` or `photos` on downgrade — only `invitations` and `team_members` are. This is stated explicitly rather than assumed symmetric.

## 11. Package Upgrade Flow

**Determination (PHASE10 §10.2):** `isUpgrade = newPkg.sort_order > currentSortOrder` (§6).

**Package-state consequence of an upgrade (this milestone's scope):**
- Takes effect **immediately** upon successful payment (cross-referenced to Phase L) — not deferred to period end.
- **Proration (PHASE10 §3.1/§10.1, exact formula):** `dailyRate = currentPkg.price_monthly / 30`; `remainingDays = (current_period_end − now) / 86,400,000 ms`; `prorationCredit = floor(remainingDays × dailyRate)`; the new package's gross price (selected by billing cycle) is reduced by this credit, floored at 0.
- On activation, `tenant_subscriptions` is updated in place (existing row, not a new one) — `package_id`, `billing_cycle`, `status = 'active'`, `current_period_start/end` reset to now/+1 cycle, `trial_ends_at`/`grace_ends_at` cleared, `pending_downgrade_package_id` cleared (PHASE10 §9.1) — and the feature cache is invalidated (§7).
- **No quota enforcement runs on upgrade** — only on downgrade (§12). An upgrade only ever raises or holds limits steady; there is nothing to reconcile.

**Payment side, cross-referenced only:** order creation, invoice generation, gateway charge, and webhook-driven activation are Phase L's responsibility (PHASE10 §3, §7, §8) — not restated here.

## 12. Package Downgrade Flow

**Determination:** `sort_order` decreasing or equal-but-different (PHASE10 §10.2's `else` branch — anything not an upgrade is treated as a downgrade, including a lateral move, since the code path only branches on `isUpgrade`).

**Package-state consequence of a downgrade (exact, PHASE10 §10.2/§11.2):**
- **Never takes effect immediately.** `tenant_subscriptions.pending_downgrade_package_id` is set to the target package's id; the current package remains fully active until `current_period_end` is reached.
- **No charge occurs at downgrade request time** (no order is created) — confirmed by PHASE10 §10.2's downgrade branch returning a `'downgrade_scheduled'` response with no payment step, unlike the upgrade branch.
- At `current_period_end`, the `process-renewals` cron (Phase L) swaps `package_id` to `pending_downgrade_package_id`, clears the pending field, resets the period, and **then** calls `enforceQuotaLimitsAfterDowngrade()` (§10) and invalidates the feature cache.
- **A tenant may have at most one pending downgrade at a time** (single column, not a queue) — requesting a second downgrade before the first takes effect overwrites `pending_downgrade_package_id`, per the column's scalar (not array) type.

## 13. Reseller Package Rules

**Exact boundary (PHASE1 §9.4, recapped from M3 §13/M4 §5, restated for completeness):** a reseller may assign to its client tenants only packages where `is_reseller = TRUE`. Platform `super_admin` controls which packages carry this flag (via `/admin/packages`, M4 §3/§15) — a reseller cannot self-elevate any package into reseller-eligibility.

**Custom pricing (PHASE1 §9.1):** "Resellers set their own prices (above platform floor)." **Flagged gap:** no column, constraint, or validation rule enforcing a minimum ("platform floor") price is cited anywhere. The capability is narratively described; its enforcement mechanism is not specified.

**Reseller-acquired subscriptions (M1 §13, unchanged):** `tenant_subscriptions.reseller_id` is set (non-null) when a tenant's package was assigned through a reseller, `NULL` for direct purchases — this is the only cited linkage between a subscription and the reseller who sold it; commission accrual against it is Phase L's domain (PHASE10 §13), cross-referenced only.

## 14. Feature Override Rules

Zooms into priority tiers 1 and 2 of §7's resolution order — the two `feature_flags`-backed tiers — with the precision this milestone resolves:

- **Tier 1 (platform kill switch, `tenant_id IS NULL`) always wins** over every other tier, including a tenant's own override (tier 2) and its package entitlement (tier 3). If a platform kill switch row exists for a `feature_key` with `is_enabled = FALSE`, no tenant can have that feature enabled by any other means while the kill switch is active (PHASE1 §6.2, exact).
- **Tier 2 (tenant override) wins over tier 3 (package entitlement)** whenever a tenant-specific row exists for that `feature_key` — regardless of whether the override's value agrees or disagrees with what the package would have granted.
- **Expiry precision (resolved here):** a tier-2 row whose `expires_at` has passed must be treated, for resolution purposes only, as if it did not exist — resolution falls through to tier 3. The row itself is not deleted or modified by this fall-through (it remains in the table, e.g. for historical/audit reference); only its effect on a live `resolveFeature()` call is suppressed once expired. This is the direct, necessary reading of the column's documented semantics ("`expires_at` — null = permanent," PHASE1 §4.2) — no available document gives this as explicit pseudocode, so it is resolved here rather than left ambiguous, exactly as the user has directed for this milestone's "exact feature override precedence" requirement.
- **No tier exists between 2 and 3** for a reseller-level override (e.g. a reseller setting a feature for all of its clients at once) — only platform-wide and single-tenant overrides are cited; a reseller-wide override tier is not specified anywhere and is not introduced here.

## 15. Admin Management Architecture

Cross-referenced to M4, not restated: `/admin/packages` (create/edit packages and feature entitlements) and `/admin/feature-flags` (platform-wide and per-tenant overrides) are the two admin surfaces governing this milestone's domain (PHASE1 §8.1, M4 §3/§15). M4 §15 already establishes that the RBAC matrix itself (M3 §9) is **not** admin-editable through any cited surface — only `feature_flags` rows are. This milestone adds no new admin surface.

## 16. Pricing Architecture

**Fields (consolidated, M1 base + M2 addition):** `price_monthly`, `price_yearly` (PHASE1 §4.2 original), `price_lifetime` (M2 §5.4 addition, nullable).

**`calculatePrice()` — exact logic (PHASE10 §3.1):**
```
base_price =
  billingCycle === 'yearly'   → pkg.price_yearly
  billingCycle === 'lifetime' → pkg.price_lifetime ?? pkg.price_monthly * 24
  else (monthly)              → pkg.price_monthly

discount_amount =
  voucher.type === 'percentage' → floor(base_price × value / 100)
  voucher.type === 'fixed'      → min(value, base_price)

final_price = max(0, base_price − discount_amount)

savings_vs_monthly (yearly only) = (price_monthly × 12) − price_yearly
```
**`price_lifetime` fallback rule, exact:** if a package's `price_lifetime` is `NULL`, the effective lifetime price is `price_monthly × 24` (a 24-month-equivalent flat rate) — this is a computed fallback, not a stored value, and only applies at calculation time.

**Voucher/discount mechanics** (`vouchers`, `voucher_redemptions`) are fully specified in M2 §5.5 under the Payment Domain — cross-referenced only, not restated, since vouchers are a transactional/promotional construct layered on top of, not part of, the package catalog itself.

## 17. Security Requirements

- `packages`, `add_ons`, `feature_flags` (platform-wide rows), and `package_features` are platform-level catalogs writable only by `super_admin` via the surfaces in §15 — consistent with the service-role/role-gating rules already established in M3 §18 and M4 §3.
- No RLS policy is cited for any of `packages`, `package_features`, `tenant_subscriptions`, `feature_flags`, `add_ons`, `tenant_add_ons` (M1 §16, M2 §26 — unchanged, this milestone closes none of that gap). Access control for all of them is `requireAuth()`/role-based only (M3 §19's consequence, restated: for tables with no RLS, the permission/role check is the *only* layer).
- Quota and feature-resolution checks must always read the tenant's **current** `tenant_subscriptions.package_id` — never a cached or stale value beyond the 60-second Redis TTL already specified (§7) — to prevent a downgraded tenant from retaining elevated entitlements past the cache window.

## 18. Testing Requirements

- `resolveFeature()` four-tier priority test (recapped from M1 §24), extended with: an expired tier-2 override correctly falls through to tier 3 (§14); a platform kill switch overrides a tenant's own enabled override (§14).
- `checkQuota()` scoping test: `guests`/`photos` checks are correctly scoped to a single invitation, not the tenant aggregate; `invitations`/`team_members` checks are correctly scoped to the tenant aggregate (§10).
- `calculatePrice()` test for all three billing cycles, including the `price_lifetime` `NULL` fallback (§16).
- Upgrade proration test against the exact formula in §11.
- Downgrade scheduling test: `pending_downgrade_package_id` set, no immediate charge, takes effect only at `current_period_end` (§12).
- `enforceQuotaLimitsAfterDowngrade()` exact-behavior test: oldest invitations archived (not deleted), newest non-owner users deactivated (§10).
- Add-on stackability test: a non-stackable add-on cannot be purchased twice while one is active (§8).
- Reseller package-eligibility test: assigning a non-`is_reseller` package to a client tenant is rejected (§13).
- Feature-cache invalidation test: confirm invalidation fires on subscription change and add-on purchase, and confirm a `feature_flags` override is **not** required to invalidate it (i.e., confirm the up-to-60-second propagation delay is the actual, intended behavior, §7).

## 19. Migration Requirements

**No new schema migration.** Every table and column this milestone depends on was already added in M2 (§5.4: `packages` extensions, `tenant_subscriptions` extensions, `add_ons`, `tenant_add_ons`) or M1 (the base catalog tables). This milestone's only data-level work is **seed data**, not schema:

- Seed `packages` rows for **Basic**, **Premium**, **Ultimate** (Free already seeded in M1 §26), with the exact `price_monthly`, `max_invitations`, `max_guests`, `max_photos`, `max_team_members`, `sort_order` (§6's canonical 0/1/2/3), `is_reseller = FALSE`, `status = 'active'`, `is_public = TRUE` values from §6's table.
- Seed `package_features` rows for each of the three new tiers, matching §6's table exactly (including `analytics_export` and `qr_checkin`, the two registry additions in §7) — extending M1's Free-tier-only seed (M1 §26) to the full four-tier matrix.
- This milestone does **not** create `package_feature_snapshot` (§2, §7 — deferred, unchanged from M2).

Since this is seed data, not DDL, it does not consume a migration number from the reserved range; it is delivered as an update to `supabase/seed.sql` (PHASE1 §3) or an idempotent seed migration at the team's discretion — no specific filename is mandated here, consistent with M1 §26 not having mandated one for the Free-tier seed either.

## 20. Acceptance Criteria

- [ ] `packages` contains exactly four public tiers (Free, Basic, Premium, Ultimate) seeded per §6/§19, with `sort_order` strictly increasing.
- [ ] `package_features` contains the complete entitlement matrix from §6 for all four tiers, including `analytics_export` and `qr_checkin`.
- [ ] `resolveFeature()` implements the exact four-tier priority order in §7, including the expiry fall-through resolved in §14.
- [ ] `checkQuota()` correctly scopes `guests`/`photos` per-invitation and `invitations`/`team_members` per-tenant, per §10.
- [ ] `enforceQuotaLimitsAfterDowngrade()` behavior matches §10 exactly: archive oldest invitations, deactivate newest non-owner users.
- [ ] Upgrade proration matches §11's formula exactly; downgrade never charges immediately and never takes effect before `current_period_end`, per §12.
- [ ] Reseller package assignment is rejected for any package where `is_reseller != TRUE`, per §13.
- [ ] No new table or column exists beyond what M1/M2 already specified — confirmed against M2 §22's migration ledger.
- [ ] `package_feature_snapshot` remains undeferred — er, remains **deferred** — and is not silently created.
- [ ] The add-on-to-feature-entitlement gap (§8) is recorded as an open item in project tracking, not silently closed.

## 21. Completion Checklist

- [ ] §3–§6 (system architecture, feature flags, package lifecycle, hierarchy) match PHASE1/PHASE11 exactly, with the tier-naming compatibility note applied consistently everywhere downstream.
- [ ] §7–§8 (resolution engine, add-ons) implement the exact priority order and caching behavior cited, with the add-on entitlement gap flagged, not closed.
- [ ] §9–§12 (subscription, upgrade, downgrade) correctly draw the line between this milestone's package-state scope and Phase L's payment scope.
- [ ] §13–§14 (reseller rules, override precedence) state every boundary exactly, including the two flagged gaps (platform floor price, reseller-wide override tier).
- [ ] §16 pricing formulas are implemented exactly as given, including the `price_lifetime` fallback.
- [ ] §19 confirms zero schema drift from M2's migration ledger; only seed data changes.
- [ ] Tag `v0.6.0` once every item in §20 is verified.

**Once every box above is checked, Phase G (Theme System) may begin.**

---

*End of M5_PACKAGE_FEATURE_SYSTEM.md*
