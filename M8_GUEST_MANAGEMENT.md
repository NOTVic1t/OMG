# M8_GUEST_MANAGEMENT.md
# Wedding Invitation SaaS Platform — Milestone M8: Guest Management

> **Version:** 1.0.0
> **Implementation authority:** BUILD_ORDER.md — Phase I (`= M8` in IMPLEMENTATION_ROADMAP.md)
> **Upstream source documents:** PHASE1_ARCHITECTURE.md (§4.2, §7.1, Appendix B), PHASE10_PAYMENT_SYSTEM.md (cross-domain pattern only), PHASE11_ANALYTICS.md (§2.1, §4.3, §8, §9.1–§9.2, §13.1, §16.1, §18.3, Appendix D), PHASE12_DEPLOYMENT.md (cross-domain pattern only)
> **Predecessors:** M0–M7, all complete.
> **Method:** Identical discipline to M4's two explicit resolutions. The user has directed this milestone to **resolve** two specific gaps M2 §5.2/§12 explicitly left open — `guest_groups`' missing scoping column and `guests.category_id`'s missing FK target — using the same minimal-additive method established in M4 §4/§9: find the closest already-approved structural precedent, extend it by the smallest possible margin, and never invent something with no grounding. Every other item the user asks to "define exact[ly]" (import/export behavior, filtering, personal-link ownership) is specified to the full extent of citation and flagged, not invented, where citation stops — consistent with M5–M7's treatment of comparable items. No application code is included.

---

## 1. Objectives

1. **Resolve `guest_groups` scoping** (M2 §5.2's flagged gap): add the minimal columns needed, modeled on the exact structural pattern already used by every comparable child-of-invitation table.
2. **Resolve `guests.category_id`'s FK target** (M2 §5.2's flagged gap): determine, from the one citation that actually glosses what "category" means (PHASE11 Appendix D — "RSVP by wedding side"), the correct new table to reference, and create it with the same minimal, structurally-consistent shape as `guest_groups`.
3. Specify the exact ownership boundaries for `guests`, `guest_groups`, `guest_categories`, and `guests.personal_link`, consolidating M1 §10/§21 with this milestone's two resolutions.
4. Specify exactly what is cited about guest import/export behavior (the async/sync split precedent PHASE11 explicitly reuses) and flag precisely where the citation stops (the exact `guest_import_batches` schema) — without asserting an invented resolution for what the user did not direct this milestone to resolve.
5. Specify the exact, limited filtering/search behavior actually cited (PHASE11 §8.3's engagement-summary route) and flag that core guest-list search/filter UI behavior is not cited beyond that one example.

## 2. Scope

**In scope:** `guests` (recapped, unchanged base columns; M2's `group_id`/`category_id`/`deleted_at` additions now fully scoped), the two new/resolved tables `guest_groups` and `guest_categories`, `personal_link` ownership, the import/export behavioral pattern to the extent cited, the one cited filtering example, and the Guest Domain's integration points with Analytics (PHASE11 §8) and RSVP (M1 §13, cross-referenced).

**Out of scope:** RSVP/guestbook content itself — Phase J. The exact `guest_import_batches` schema, exact guest CRUD API route paths, and core guest-list search/filter UI — all flagged, not invented (§5, §10, §11, §13).

**This milestone's two resolutions, stated once, applied consistently:** §7 and §8 each add exactly the columns required to close their respective gap, by direct structural analogy to `guests`' own already-approved scoping pattern and to PHASE11 §16.1's explicit citation that "PHASE8 §12.1" (this very domain) is the *origin* of the denormalized-`tenant_id` convention PHASE11's own tables follow — meaning this milestone is not borrowing a pattern from a sibling domain, it is restoring the pattern PHASE11 itself attributes to this domain in the first place.

## 3. Guest Domain Architecture

```
invitations
   │
   └──< guests  (tenant_id denormalized, invitation_id direct — M1 §10's established rationale)
            │  group_label (TEXT, free-form, PHASE1 original — unchanged, §7)
            │  group_id ──────► guest_groups   (resolved, §7)
            │  category_id ───► guest_categories (resolved, §8)
            │  personal_link (UNIQUE, §9)
            │  deleted_at (M2 §5.1)
            │
            ├──< rsvp_responses.guest_id        (nullable — "null if open RSVP," M1 §13)
            ├──< guestbook_entries.guest_id      (nullable, same convention, M2 §5.3)
            └──< invitation_events.guest_id       (nullable, M2 §5.6 — analytics attribution)
```

## 4. Guest Lifecycle

1. **Creation** — individually, or via import (§5). Requires `checkQuota(tenantId, 'guests')` against `packages.max_guests` (M5 §10 — **per-invitation**, not tenant-wide).
2. **Active** — default state; no `is_active`-style flag is cited for `guests` (unlike `users`, M1 §7) — a guest is simply present or soft-deleted.
3. **Soft-deleted** — `deleted_at` set (M2 §5.1, §5.2), confirmed by two independent literal citations (PHASE11 §4.3's ingestion guest-validation query, PHASE11 §8.1's `guest_engagement_summary` view definition) — both filter `WHERE deleted_at IS NULL`/`.is('deleted_at', null)`. No hard delete is cited.
4. **Exported** (§6) or **attributed** via `personal_link` to RSVP/guestbook/analytics activity (§9, §15, §16) — neither is a lifecycle state change, both are read/cross-reference operations.

## 5. Guest Import Architecture

**Exact, cited:** import is **asynchronous for large files** — this is the precedent PHASE11 explicitly reuses, not invents, for its own export system: "Async export generation only for large datasets (PHASE11 §13.1) avoids paying for long-running serverless function time on the common small-export case" with the design-principle table citing this directly as "Matches PHASE8 §13.4 async-import precedent" (PHASE11 §2.1). The job is tracked in a table named `guest_import_batches` (PHASE8 §13.4, cited by name in PHASE11 §18.3 and in this document set's own BUILD_ORDER Phase I).

**Flagged, not resolved:** no column of `guest_import_batches` is cited anywhere. **A strong circumstantial inference is available but is deliberately not asserted as fact:** PHASE11's own `analytics_export_jobs` table (M2 §5.4, fully specified: `id, tenant_id, requested_by, scope, scope_id, export_format, date_from, date_to, status, file_path, error_message, created_at, completed_at`) is explicitly described as following the precedent this milestone's import table established first. By that logic, `guest_import_batches` likely has an analogous shape (a `tenant_id`, a requesting user, a target `invitation_id`, a `status` enum, a file reference, an error field, timestamps) — but this milestone's directive from the user is to *define exact import behavior*, not to resolve this specific schema (contrast §7/§8, which the user explicitly asked to *resolve*). Asserting specific columns here without a direct citation risks contradicting PHASE8_GUEST_MANAGEMENT.md's actual content. This table is therefore **not created** in this milestone (§20).

**Scaling precedent (PHASE11 §18.3, exact):** "PHASE8 §14.4's async-import scaling pattern" is the cited basis for PHASE11's own shard-fan-out rollup scaling design — confirming that, whatever its exact shape, the import job is expected to scale by sharding work across multiple invocations rather than processing an entire CSV in one serverless lifetime, for large imports.

## 6. Guest Export Architecture

**Exact, cited (by the same precedent relationship as §5, read in the other direction):** no document describes a guest-list CSV export job directly with its own citation — `EXPORT_GUEST_CSV` (`export_guest_csv`, PHASE1 §7.1) is the feature key gating this capability, per the tier table (M5 §6: Premium and Ultimate only — "Export RSVP (CSV)" row in PHASE1 §6.1 names RSVP export specifically as Basic+, but a separate `export_guest_csv` key exists distinctly, and PHASE1 §6.1's table does not give it its own row, so its exact tier gating beyond the key's mere existence is not directly tabulated — flagged).

**What the analogous, fully-specified PHASE11 export system (M2 §5.4/§19, PHASE11 §13) confirms by structural parallel, without this milestone asserting it as guest-export's own citation:** the sync/async split threshold pattern (small exports inline, large exports queued) is the one PHASE11 explicitly attributes to this domain's import precedent (§5) — the converse (guest export following the same split) is a reasonable expectation but is not itself separately cited for export specifically, and is not asserted as resolved here.

## 7. Guest Group Architecture — **Resolved**

**The gap, exactly as previously flagged (M2 §5.2/§12):** `guest_groups` (`id`, `name`, `color` — cited verbatim from PHASE11 §9.2's `rsvp_by_group` view SQL) had no scoping column; M2 flagged that "any guest in any invitation could theoretically be assigned to any group row."

**Resolution (additive, modeled on the exact precedent the architecture itself names for this domain):** PHASE11 §16.1 states its own new tables carry a denormalized `tenant_id` "following the exact rationale given in **PHASE8 §12.1**" — i.e., PHASE11 explicitly attributes this convention's origin to the Guest Management domain this milestone specifies. This milestone therefore restores that convention to `guest_groups`, exactly as `guests` itself already has it (M1 §13):

| Column | Type | Nullable | Default | Constraint | Source |
|---|---|---|---|---|---|
| `guest_groups.invitation_id` | UUID | NO | — | REFERENCES `invitations(id)` | New — the natural ownership unit, matching `guests.invitation_id`'s own direct-FK pattern (M1 §13) |
| `guest_groups.tenant_id` | UUID | NO | — | REFERENCES `tenants(id)` | New — denormalized, matching `guests.tenant_id`'s own pattern, per the PHASE8 §12.1 rationale PHASE11 §16.1 cites |

**Scope, exact:** a `guest_groups` row belongs to exactly one invitation (not reusable across a tenant's multiple invitations) — the minimal scoping consistent with `guests` themselves, which are likewise scoped to exactly one invitation, never shared across invitations.

**Coexistence with `group_label` (not modified, not redesigned):** `guests.group_label` (TEXT, free-form — "family | friends | colleague," PHASE1 §4.2 original) is **unchanged** and continues to exist alongside `group_id` (the FK into this newly-scoped table). They are two independent, coexisting mechanisms — `group_label` is unstructured, has no analytics integration cited anywhere; `group_id` is the structured mechanism that `rsvp_by_group` (PHASE11 §9.2) and `guest_engagement_summary` (PHASE11 §8.1) actually join against. This milestone does not merge, deprecate, or migrate data between the two.

**Recommended, not cited, supplementary constraint:** `UNIQUE (invitation_id, name)` to prevent duplicate group names within one invitation — flagged explicitly as a recommendation, not a citation, consistent with M2 §7's treatment of non-cited indexes.

## 8. Guest Category Architecture — **Resolved**

**The gap, exactly as previously flagged (M2 §5.2):** `guests.category_id` (UUID, cited from PHASE11 §8.1's `guest_engagement_summary` view: `g.category_id`) had no named FK target table anywhere.

**Resolution, step one — determining what "category" means:** PHASE11 Appendix D's metric-reference table glosses `rsvp_by_category` (PHASE9 §9.2) as **"RSVP by wedding side."** This is the one available citation that gives semantic content to "category" anywhere in the document set — it is not a free-form label like a group, but the bride/groom wedding-side distinction.

**Resolution, step two — the new table, by direct structural analogy to §7's resolved `guest_groups`:**

**New table `guest_categories`:**

| Column | Type | Nullable | Default | Constraint | Source |
|---|---|---|---|---|---|
| `id` | UUID | NO | `gen_random_uuid()` | PRIMARY KEY | Standard pattern, matching `guest_groups.id` |
| `name` | TEXT | NO | — | — | Matching `guest_groups.name`'s pattern; expected values are wedding-side labels (e.g. the bride's side, the groom's side) per the Appendix D gloss — actual row content is created per-invitation by the tenant, not platform-seeded, since each wedding's own naming varies |
| `invitation_id` | UUID | NO | — | REFERENCES `invitations(id)` | Same scoping rationale as §7 |
| `tenant_id` | UUID | NO | — | REFERENCES `tenants(id)` | Same denormalization rationale as §7, citing the same PHASE8 §12.1 origin PHASE11 §16.1 attributes to this domain |

**No `color` column is added** — unlike `guest_groups.color`, no citation anywhere selects or references a color value for categories (PHASE11 §9.2's `rsvp_by_group` view selects `gg.color`; no equivalent view or query is cited selecting a category color). Adding one would be inventing structure with zero grounding, which this resolution method does not do.

**`guests.category_id` FK is now resolvable:** `guests.category_id UUID REFERENCES guest_categories(id)` (the table name, previously unspecified, is now fixed).

## 9. Personal Invitation Link Architecture

**Exact ownership (resolved from existing citations, no new structure needed):** `guests.personal_link` (TEXT, `UNIQUE`, PHASE1 §4.2) is a **1:1, immutable association with exactly one `guests` row** — there is no separate "link" entity, no link-sharing across guests, and no reassignment flow cited anywhere. Ownership is transitive through the guest: a personal link belongs to whichever invitation its owning guest belongs to (`guests.invitation_id`), and to whichever tenant denormalized on that same row.

**Security property (PHASE1 Appendix B, exact, unchanged):** "Personal invitation links are non-guessable UUIDs" — in deliberate contrast to invitation `slug`s, which are public-by-design and not required to be non-guessable (M7 §19's explicit contrast).

**Validation at use-time (PHASE11 §4.3, citing the identical constraint from PHASE9 §13.3, exact):** when a personal link/`guest_id` is presented (e.g. to the analytics ingestion endpoint), the system must confirm the guest belongs to **the same invitation** being accessed before trusting the association — "Guest token cross-check (same constraint as PHASE9 §13.3 — guest must belong to THIS invitation)." A personal link cannot be used to attribute activity to a different invitation than the one its owning guest actually belongs to.

**Feature-gating note:** `FEATURES.GUEST_PERSONALIZED_LINK` (`guest_personalized_link`, PHASE1 §7.1) exists as a registry key, confirming this capability is feature-gateable — but PHASE1 §6.1's tier table does not give it its own row, so its exact tier-by-tier availability is not directly cited. Flagged, not resolved.

## 10. Guest Search Architecture

**No core guest-list search (by name, phone, email, etc.) is cited anywhere in the available documents.** The only cited search/lookup behavior in this domain is analytics-adjacent (§11). This is flagged, not invented.

## 11. Guest Filtering Architecture

**The one cited example, exact (PHASE11 §8.3, the guest-engagement-summary route — an analytics-domain consumer of this domain's data, not core guest management itself, but the only citable filtering pattern anywhere in this document set):**
```
sortBy  = url.searchParams.get('sort') ?? 'views'
filter  = url.searchParams.get('filter')   // 'never_opened' | 'engaged' | null

filter === 'never_opened' → query.eq('views', 0)
filter === 'engaged'      → query.gt('views', 0)

query.order(sortBy, { ascending: false }).limit(500)
```
This confirms: a result cap of **500** rows, descending sort by a caller-supplied column, and exactly two named filter values (`never_opened`, `engaged`) — both defined in terms of the `guest_engagement_summary` view's `views` column (PHASE11 §8.1), not a core `guests`-table field. **No filtering by `group_id`, `category_id`, `group_label`, or RSVP status is cited anywhere** for the core guest list. Flagged, not invented.

## 12. Guest Ownership Rules

| Resource | Owning tenant/invitation | Source |
|---|---|---|
| `guests` row | `tenant_id` (denormalized) + `invitation_id` (direct) — must agree, application-enforced, no DB trigger (M1 §10/§21, unchanged) | M1 |
| `guest_groups` row | `tenant_id` + `invitation_id` (both resolved, §7) — must agree with any member guest's own scoping | This milestone |
| `guest_categories` row | `tenant_id` + `invitation_id` (both resolved, §8) — same rule | This milestone |
| `guests.personal_link` | Transitively, via the owning guest (§9) | This milestone (clarified) |
| `guests.group_id`, if set | Must reference a `guest_groups` row scoped to the **same** `invitation_id` as the guest — enforceable now by application-layer check (FK alone does not cross-validate `invitation_id` equality across two tables); no DB-level cross-table CHECK is cited or introduced | This milestone |
| `guests.category_id`, if set | Same rule, against `guest_categories` | This milestone |

**This closes the standing integrity risk M2 §27 recorded** ("`guests.group_id`... not enforceable as specified, because `guest_groups` has no scoping column") to the extent that a scoping column now exists to check against — application-layer enforcement is still required (no DB CHECK across two tables is introduced), but the column that makes such enforcement *possible at all* now exists.

## 13. Guest API Architecture

**Cited:** `app/api/guests/` exists as a scaffold (M1 §19) with CRUD/import as its eventual responsibility (BUILD_ORDER Phase I). The analytics-domain consumer routes (`GET /api/invitations/[id]/guests/[guestId]/engagement`, `GET /api/invitations/[id]/guests/engagement-summary`) are fully specified in PHASE11 §15.2 (recapped M3 §16) and remain that domain's surface, not this one's.

**Flagged, not invented:** exact core CRUD route paths (create/edit/delete a guest, import endpoint, export endpoint) — consistent with M7 §14's identical finding for invitations. No permission string is cited for any guest route.

## 14. Guest Dashboard Architecture

**Cited, minimal:** `app/(app)/invitations/[id]/guests/` exists as a route scaffold (M1 §19). No further structure (list columns, bulk actions, import UI) is cited anywhere. Flagged.

## 15. Guest Analytics Integration

Cross-referenced, not restated: `guest_engagement_summary` view (PHASE11 §8.1, full SQL given, now fully resolvable end-to-end since `group_id`/`category_id`/`deleted_at` are all confirmed columns), `rsvp_by_group` view (PHASE11 §9.2, full SQL given, now fully resolvable since `guest_groups.id/name/color` plus the join through `guests.group_id` are all real, scoped columns after §7's resolution). `guest_rsvp_status`/`guest_checkin_status` remain deferred (M2 §5.3, unchanged — not part of this milestone's resolution directives).

## 16. RSVP Integration

Cross-referenced to M1 §13 and Phase J (not yet specified in full): `rsvp_responses.guest_id` (nullable, "null if open RSVP") is this domain's one direct link into the RSVP Domain. `guestbook_entries.guest_id` (M2 §5.3) is the equivalent link into the guestbook. Neither table's own RLS/business logic is restated here — this milestone only confirms the FK relationship and the guest-ownership rule it depends on (§12).

## 17. Security Requirements

- No RLS policy is cited for `guests` beyond the join-adapted `tenant_isolation` pattern... **correction, exact:** `guests` *does* have a direct-column `tenant_isolation` policy (M1 §16, since it carries `tenant_id` directly) — restated here for this domain's completeness. `guest_groups` and `guest_categories` have **no RLS policy cited anywhere** (consistent with M2 §26's broader finding that every M2-introduced table lacks RLS) — even after this milestone gives them a `tenant_id` column to make such a policy *possible*, no policy is specified or added here, since adding one would be a new decision beyond what the user directed this milestone to resolve.
- `personal_link` non-guessability (§9) remains the standing security requirement for that column, unchanged.
- The cross-invitation validation rule in §9/§12 (a guest/link must belong to the invitation being accessed) is the primary access-control mechanism for personalized-link-driven flows — restated as a requirement on every future consumer of `personal_link`, not only the one cited ingestion-endpoint example.

## 18. Performance Requirements

- The async-for-large-files import pattern (§5) exists specifically to avoid serverless function timeouts on large CSV builds — restated as the binding performance requirement for any import implementation, per the cited precedent.
- The 500-row cap on the one cited filtering/listing query (§11) is recorded as the only cited pagination/limit behavior in this domain; no other list endpoint's limit is cited.
- `idx_guests_invitation_id`, `idx_guests_tenant_id` (M1 §14, unchanged) remain the indexing baseline; the recommended (non-cited) `idx_guests_group_id` from M2 §7 remains a recommendation, now more directly actionable since `guest_groups` has a real scoping column to join against.

## 19. Testing Requirements

- `guest_groups`/`guest_categories` scoping test: a row created under one invitation cannot be assigned (via `group_id`/`category_id`) to a guest belonging to a **different** invitation — confirms §12's closed integrity gap is actually enforced at the application layer.
- `group_label` vs `group_id` independence test: writing one does not affect the other; both can hold values simultaneously with no cited reconciliation (§7).
- Personal-link cross-invitation rejection test: presenting a valid `guest_id`/link against the wrong invitation is rejected, per §9's cited cross-check.
- Soft-delete test: a `guests` row with `deleted_at` set is excluded from `guest_engagement_summary` and from the analytics ingestion guest-validation query, per the two literal citations in §4.
- Quota test (recapped from M5 §10): `guests` quota is checked per-invitation, not tenant-wide.
- Filtering test: the two named filter values (`never_opened`, `engaged`) on the engagement-summary route behave exactly as specified in §11; the 500-row cap is enforced.

## 20. Migration Requirements

**Two new migrations, both resolving previously-flagged gaps (§7, §8) — the explicit purpose of this milestone:**

```
035_guest_groups_add_scoping.sql   -- ALTER TABLE guest_groups
                                    --   ADD COLUMN invitation_id UUID NOT NULL REFERENCES invitations(id),
                                    --   ADD COLUMN tenant_id    UUID NOT NULL REFERENCES tenants(id)
036_create_guest_categories.sql    -- CREATE TABLE guest_categories
                                    --   (id, name, invitation_id, tenant_id) per §8
```

Consumes the next two numbers after M4's `034` from the range M1 reserved (`018`–`090`); does not collide with M2 (`018`–`033`), M4 (`034`), or any fixed Phase L/M range. `037`–`090` remains reserved.

**Not migrated in this milestone (consistent with §5/§6's deliberate non-resolution):** `guest_import_batches` — no column is cited, and resolving it is not among this milestone's explicit directives.

## 21. Acceptance Criteria

- [ ] `guest_groups` has `invitation_id` and `tenant_id`, both `NOT NULL`, both correctly referencing `invitations(id)`/`tenants(id)`.
- [ ] `guest_categories` exists exactly per §8's table, with no `color` column added.
- [ ] `guests.category_id` now has a resolvable, named FK target (`guest_categories`).
- [ ] `guests.group_label` is confirmed unmodified and coexists, unreconciled, with `group_id`.
- [ ] `rsvp_by_group` and `guest_engagement_summary` (Phase M's own fixed migrations, `111`/`112`) are confirmed to compile/resolve correctly now that their underlying joins (`guests.group_id` → `guest_groups.id`, etc.) reference fully-scoped, real tables.
- [ ] No `color` or other uncited column was added to `guest_categories`.
- [ ] `guest_import_batches` remains absent from the schema — not silently created.
- [ ] Migrations `035`–`036` apply cleanly to staging, then production.
- [ ] Every flagged gap in this document (import/export exact schema, core CRUD routes, core search/filter UI, personal-link tier gating) is recorded as an open item, not silently closed.

## 22. Completion Checklist

- [ ] §3–§4 (domain architecture, lifecycle) correctly incorporate both resolutions and the `group_label`/`group_id` coexistence note.
- [ ] §5–§6 (import/export) state exactly what is cited (the async precedent) and flag exactly what is not (the table schema), including the explicit circumstantial-inference note for `guest_import_batches`.
- [ ] §7–§8 (group/category architecture) fully resolve both gaps per the user's explicit directive, using only the structurally-consistent, additive method.
- [ ] §9–§12 (personal link, search, filtering, ownership) state every cited rule exactly and flag every absence precisely.
- [ ] §13–§16 (API, dashboard, analytics/RSVP integration) correctly cross-reference PHASE11 and avoid restating its content.
- [ ] §20 migrations `035`–`036` are the only schema changes in this milestone.
- [ ] Tag `v0.9.0` once every item in §21 is verified.

**Once every box above is checked, Phase J (RSVP & Guestbook) may begin.**

---

*End of M8_GUEST_MANAGEMENT.md*
