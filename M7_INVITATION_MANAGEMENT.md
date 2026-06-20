# M7_INVITATION_MANAGEMENT.md
# Wedding Invitation SaaS Platform — Milestone M7: Invitation Management

> **Version:** 1.0.0
> **Implementation authority:** BUILD_ORDER.md — Phase H (`= M7` in IMPLEMENTATION_ROADMAP.md)
> **Upstream source documents:** PHASE1_ARCHITECTURE.md (§2.2, §3, §4.2–§4.3, §5.2, §6–§7, §10.4–§10.5, §11, Appendix A–B), PHASE10_PAYMENT_SYSTEM.md (§10.3), PHASE11_ANALYTICS.md (§1.3, §4.3, §5.5, §6–§7, §18.1), PHASE12_DEPLOYMENT.md (§7.5, §9.2, §13.5, §14.2, §15.4, §18.3)
> **Predecessors:** M0–M6, all complete.
> **Method:** Identical discipline to M2–M6. PHASE7_INVITATION_MANAGEMENT.md itself is not in this document set. One genuinely valuable resolution surfaces here: PHASE1 §7.2's own cited example code (`GiftRegistrySection`) directly answers a question M6 §6 explicitly left open — *when* is section-level feature gating enforced. That resolution is presented prominently in §16. Every other open question in this milestone (slug generation, photo-quota disambiguation, section-reorder UI mechanism) is flagged, not invented, consistent with M5's and M6's treatment of comparable gaps. No application code is included.

---

## 1. Objectives

1. Consolidate the complete `invitations`/`invitation_sections` data model (M1 §13, M2 §5.1's `deleted_at` addition) as the fixed foundation this milestone builds process and flow specification on top of — no column is added, removed, or altered here.
2. Specify the exact invitation lifecycle (draft → published → archived, plus the orthogonal soft-delete dimension) and the exact rule for each transition, consolidating M1 §21, M5 §10/§12, and PHASE10 §10.3's literal archival query.
3. **Resolve, using a direct citation, when section-level feature gating is actually enforced** — render time, via `useFeatureFlag()` inside each section component (PHASE1 §7.2) — closing the question M6 §6 step 8 explicitly left open.
4. Specify the exact ownership, slug, section-ordering, and media-ownership rules the user has directed, flagging precisely where citation runs out for each (slug generation algorithm, photo-quota disambiguation, reorder UI mechanism) rather than inventing a resolution.
5. Specify the exact integration points with the Theme System (M6) and the Analytics Domain (PHASE11), since this milestone sits directly between both.

## 2. Scope

**In scope:** `invitations`/`invitation_sections` lifecycle and flows (creation, editing, publishing, archiving), slug rules, section ordering/visibility, media ownership boundaries, the invitation dashboard surface, and the exact enforcement point for section-level feature gates.

**Out of scope, with an explicit boundary:**
- Theme rendering mechanics themselves — fully owned by M6, cross-referenced only (§17).
- Guest/RSVP/guestbook content — Phases I/J.
- Analytics rollup/dashboard logic — Phase M, cross-referenced only (§18).
- Anything named only in PHASE1 §11's **Phase 4 ("Growth & Polish") roadmap** — OG image generation (Vercel OG), WhatsApp deep-link sharing, invitation duplication. These are named in PHASE1's own roadmap as later work, not as part of this milestone's scope; building them now would be working ahead of the approved sequencing, not completing it. They are recorded here as explicitly deferred, not specified further.

**Flagged, not resolved here (consistent with M5/M6's precedent):** the slug generation/format algorithm (§9), whether `max_photos` counts couple-profile photos together with gallery photos (§12), the section-reorder UI mechanism given the property-panel (not drag-and-drop) editor decision (§11), and the core invitation CRUD API route paths (§14).

## 3. Invitation Domain Architecture

Recapped, unchanged, from M1 §13/§14/§15 and M2 §5.1 — not restated column-by-column. The two tables in this domain:

```
invitations
  tenant_id, created_by, theme_id, slug (UNIQUE), title, status, deleted_at (M2),
  event_date/time/venue/address/maps_url, couple_data (JSONB), customization (JSONB),
  music_url, is_rsvp_open, rsvp_deadline, meta_title/description, view_count, published_at
     │
     └──< invitation_sections
            invitation_id, section_type, sort_order, is_visible, content (JSONB)
```

`couple_data` and `invitation_sections.content` are **content**; `customization` is **presentation/style**, owned by the selected theme's `config_schema` (M6 §5) — this boundary is restated here because invitation editing is where both are actually written.

## 4. Invitation Lifecycle

**Two independent dimensions, not one:**

1. **`status`** (CHECK: `'draft' | 'published' | 'archived'`, M1 §15) — the editorial state.
2. **`deleted_at`** (M2 §5.1) — the soft-delete state, orthogonal to `status`. A row can be `status = 'archived'` and `deleted_at IS NULL` (the downgrade-enforcement outcome, §8) or any status with `deleted_at` set (an owner-initiated deletion, not further specified beyond the column's existence and the general convention PHASE12 §13.5 cites).

**State diagram (status dimension):**
```
draft ───────publish (§7)───────► published
  ▲                                   │
  └──────unpublish?  [not cited — flagged]
                                       │
draft/published ───archive (§8, two distinct triggers)───► archived
```

No transition out of `archived` (back to `draft`/`published`) is cited anywhere — archival is not stated as reversible in any available document, in contrast to `tenants.status = 'suspended'` which PHASE12 §9.3 explicitly states is reversible. This asymmetry is recorded, not resolved.

## 5. Invitation Creation Flow

**Exact preconditions (M1 §21, M5 §10, recapped):**
1. `checkQuota(tenantId, 'invitations')` must pass — tenant-wide count against `packages.max_invitations`, `-1` = unlimited (M5 §10).
2. The creating user's `tenant_id` becomes the row's `tenant_id`; the creating user's `id` becomes `created_by` (M1 §21) — no DB trigger enforces this pairing; it is an application-layer responsibility at insert.
3. `theme_id` must reference an `invitation_themes` row with `is_active = TRUE`; if that theme is `is_premium = TRUE`, `resolveFeature(tenantId, FEATURES.PREMIUM_THEMES).enabled` must be `true` (M1 §21, M6 §10).
4. `slug` must be assigned at creation time, not deferred — the column is `NOT NULL` from the moment the row exists (PHASE1 §4.2; §9 below).
5. Initial `status = 'draft'` (column default, M1 §15).

**Permission boundary (M3 §11, recapped):** `super_admin`, `reseller_admin`, `owner`, `editor` may create; `viewer` may not.

## 6. Invitation Editing Flow

**Exact boundary (M3 §11, recapped):** the same four roles that may create may also edit. No field-level permission distinction (e.g. "editor may edit content but not `customization`") is cited anywhere — editing permission is all-or-nothing at the row level for whichever role is otherwise entitled.

**What "editing" touches, exactly:** `title`, `event_date/time/venue/address/maps_url`, `couple_data`, `customization`, `music_url`, `is_rsvp_open`, `rsvp_deadline`, `meta_title/description`, `theme_id` (re-selection, re-checked against §5's preconditions 3), and, transitively, `invitation_sections` rows (§11). `view_count`, `published_at`, `slug` (after creation — §9), `tenant_id`, `created_by` are not cited as editable fields through any normal editing flow.

**No draft-autosave, version history, or concurrent-edit conflict resolution is cited anywhere.** Flagged, not resolved.

## 7. Invitation Publishing Flow

**Permission boundary (M3 §11, exact):** only `super_admin`, `reseller_admin`, `owner` — **not `editor`** — may publish. This is the one action in the entire create/edit/publish/manage-guests cluster where `editor`'s otherwise-equal standing with `owner` breaks.

**Exact effect on the row:** `status` set to `'published'`; `published_at` set to the current timestamp (PHASE1 §4.2 column exists for exactly this purpose).

**Flagged gap — pre-publish validation:** no document specifies any required-field check before allowing the `draft → published` transition (e.g. requiring at least one `invitation_sections` row, a non-empty `couple_data`, or a selected theme beyond the `NOT NULL` FK itself). The only enforced precondition anywhere is the schema-level `NOT NULL`/FK constraints already in place since creation (§5) — nothing additional is checked specifically at publish time.

**Consequence of publishing, cross-domain (cited, not re-specified):** once `status = 'published'` (and `deleted_at IS NULL`), the row becomes reachable through `public_invitation_read` (M1 §16) and through the analytics ingestion endpoint's published-status check (PHASE11 §4.3) — both are pre-existing policies this flow activates, not new behavior introduced here.

## 8. Invitation Archive Flow

**Two distinct triggers, both setting `status = 'archived'`, never deleting the row:**

1. **Owner-initiated archive** — no exact API route or precondition is cited anywhere beyond the status value itself existing. Flagged.
2. **System-initiated archive on downgrade (PHASE10 §10.3, exact, recapped from M5 §10):** when a tenant's `max_invitations` decreases (a downgrade taking effect, M5 §12), the **oldest-created** excess invitations — queried as `status IN ('draft','published')` AND `deleted_at IS NULL`, ordered by `created_at ASCENDING`, beyond the new limit (`range(pkg.max_invitations, 9999)`, PHASE10 §10.3's exact query shape) — are set to `status = 'archived'`. The **newest** invitations are preserved. This is the same pattern PHASE12 §13.5 names as the soft-delete-adjacent convention ("archived, not hard-deleted").

**Effect of archival on visibility:** an `archived` invitation no longer satisfies `public_invitation_read`'s `status = 'published'` condition (M1 §16) — it becomes unreachable publicly, identically to a `draft`, without its data being destroyed.

## 9. Slug Management Architecture

**Exact, cited:** `slug TEXT UNIQUE NOT NULL` (PHASE1 §4.2); indexed (`idx_inv_slug`, M1 §14); assigned at creation, not deferrable to publish time (§5); used as the public routing key — both at the platform level (`inv.weddingplatform.com/[slug]`, PHASE1 §2.2) and in the Next.js route (`app/inv/[slug]/page.tsx`, PHASE1 §3, M1 §19).

**Flagged gap — generation and format:** no document specifies how a slug's value is produced (auto-generated from `title`, user-chosen, random token), what character set or length is permitted, or how a collision against the `UNIQUE` constraint is handled at creation time (retry with a suffix, reject with an error, etc.). No document states whether a slug may be changed after creation, and if so, whether the old slug is preserved as a redirect or simply abandoned. **None of this is resolved here** — it is the most significant open item this milestone surfaces, recorded precisely because the user has asked for "exact slug rules" and the available documents do not supply them beyond uniqueness and routing usage.

## 10. Invitation Builder Architecture

**Exact, cited trade-off (PHASE1 Appendix A):** "Invitation editor | Drag-and-drop vs property panel | Property panel | Performance, mobile UX, simpler codebase." The builder is a property-panel editor (`components/invitation/editor/`, PHASE1 §3) — not a drag-and-drop canvas. This decision is restated here, unmodified, because it directly constrains §11's reorder mechanism.

**Route (M1 §19, recapped):** `app/(app)/invitations/[id]/edit/`.

## 11. Section Management Architecture

**Exact data model (M1 §13, recapped):** `invitation_sections.section_type` (TEXT — `hero | couple | event_details | gallery | rsvp | gift | countdown | story`, per PHASE1 §4.2's comment; PHASE11 §3.2's `section_views` JSONB example additionally shows `love_story` and `guestbook` as keys, which do not appear in PHASE1's literal list — the complete, authoritative `section_type` enumeration is therefore not fully resolved across the available documents and is flagged, not invented, here), `sort_order` (INTEGER, default 0), `is_visible` (BOOLEAN, default TRUE), `content` (JSONB).

**Exact ordering rule:** sections render in ascending `sort_order`; a section with `is_visible = FALSE` is excluded from render entirely, not merely visually hidden (M6 §6, restated as this milestone's authoritative source for the rule). **Tie-breaking behavior for equal `sort_order` values is not cited anywhere** — flagged.

**Flagged gap — the reorder mechanism:** given the property-panel (not drag-and-drop) editor decision (§10), no document specifies how a user actually changes a section's `sort_order` (numeric input field, up/down buttons, or otherwise). The data model (a freely-settable integer column) is clear; the UI mechanism that writes to it is not cited.

## 12. Media Management Architecture

**Exact, cited media fields:** `couple_data.groom_photo`, `couple_data.bride_photo` (PHASE1 §4.2's documented shape), `music_url` (a direct column), and whatever a `gallery`-type `invitation_sections.content` JSONB holds (shape not specified beyond being JSONB).

**Flagged gap — quota scope disambiguation:** `packages.max_photos` is documented as "per invitation" (PHASE1 §4.2 comment, resolved precisely in M5 §10's quota-scoping table) but no document states whether `couple_data.groom_photo`/`bride_photo` count against this same per-invitation limit, or whether the limit applies only to gallery-section photo content. This milestone does not resolve the ambiguity — it is recorded so the eventual implementer does not silently assume one answer.

**Ownership rule, exact:** all invitation media belongs to the invitation (`invitation_id`, transitively `tenant_id` via the invitation), identically to every other content field on the row — there is no separate, independently-owned "media asset" entity; a photo URL is just a value inside `couple_data` or section `content`, not a row in its own right anywhere in the cited schema.

## 13. Storage Architecture

**Cited generically, not specifically:** Supabase Storage is the platform's object-storage primitive (PHASE1 §2.1, §10.1); PHASE2 §7's bucket-structure convention is referenced by name in two *other* domains (`invoices`, PHASE10; `analytics-exports`, PHASE11 §19.4) but **no bucket name is cited anywhere for invitation media** (couple photos, gallery images, music files). This is a flagged gap, not resolved here — the same discipline applied to `guests`/`guestbook_entries`' missing columns in M2 applies to this missing bucket name.

**What is cited, and is sufficient to state as a rule regardless of the bucket-name gap:** uploaded media must be tenant/invitation-scoped in its storage path (consistent with every other bucket this schema does name, e.g. `analytics-exports/{tenant_id}/...`, PHASE11 §19.4) and must be referenced by URL value only inside the JSONB/column fields in §12 — never by a separate ownership table.

## 14. Invitation API Architecture

**Cited:** the `app/api/invitations/` directory exists as a scaffold (M1 §19) with CRUD as its eventual responsibility (BUILD_ORDER Phase H); the cross-domain analytics sub-route `GET /api/invitations/[id]/analytics` and its siblings are fully specified in PHASE11 §15.2 (recapped M3 §16) and are **not** part of this milestone's own surface — they consume this domain's data, they do not belong to it.

**Flagged gap — core CRUD route paths:** no document gives exact paths/methods for creating, editing, publishing, or archiving an invitation (e.g. whether publishing is a dedicated `POST /api/invitations/[id]/publish` or a generic `PATCH /api/invitations/[id]` with a status field). Not invented here.

**Permission strings:** consistent with M3 §8's finding, no permission string (in the `resource:action` namespacing already established for Payment/Analytics) is cited for any invitation route. This milestone does not assign one, since doing so would be inventing a naming decision PHASE7_INVITATION_MANAGEMENT.md is authoritative for.

## 15. Invitation Dashboard Architecture

**Cited, minimal:** the tenant-facing dashboard shell (`app/(app)/dashboard`, M1 §19/§20) shows an "invitation list, quick stats placeholder" (IMPLEMENTATION_ROADMAP.md's MVP description) — no further structure is cited for this list view (sortable columns, filters, search) beyond its existence. `app/(app)/invitations/[id]/analytics/` (full structure given in PHASE11 §7.1) is the per-invitation analytics dashboard, owned by Phase M, cross-referenced only (§18).

## 16. Feature Gate Enforcement

**Resolved — the question M6 §6 step 8 explicitly left open, now answered by direct citation.** PHASE1 §7.2 gives this exact example:
```
function GiftRegistrySection() {
  const flag = useFeatureFlag(FEATURES.GIFT_REGISTRY);
  if (!flag.enabled) return <UpgradePrompt feature="Gift Registry" />;
  return <GiftRegistryContent />;
}
```
This confirms section-level feature gating is enforced **at render time, inside the section component itself**, via `useFeatureFlag()` — not at section-creation/insert time. A tenant without the `gift_registry` entitlement is **not** prevented from having a `gift`-type row in `invitation_sections`; they are prevented only from seeing its real content rendered, receiving an `UpgradePrompt` in its place. This is the resolved, exact answer to "exact feature enforcement behavior" for this milestone: **creation is unrestricted by feature entitlement; rendering is gated.** This stands in direct contrast to **quota** enforcement (§5, M5 §10), which **is** preventive at creation time (`checkQuota()` blocks the insert itself) — the two enforcement mechanisms operate at different points in the lifecycle, and this distinction is the precise, citation-grounded answer this milestone supplies.

**This pattern is generalized, not theme-specific:** the same render-time mechanism applies to every section-level `FEATURES` key cited in M6 §9 (`music_player`, `countdown_timer`, `gallery_section`, `love_story_section`, `livestream_link`, `map_embed`), by direct structural analogy to the one example PHASE1 §7.2 gives — no document shows a second, different pattern for any other section type.

## 17. Theme Integration

Cross-referenced to M6 in full, not restated: theme selection preconditions (§5 precondition 3, M6 §10), the rendering pipeline that composes this domain's `invitation_sections` rows within a theme's layout (M6 §6), the `customization`/`couple_data` ownership split (M6 §5), and the preview-equals-draft-SSR resolution (M6 §13) all govern this domain's output without this milestone re-specifying any of them.

## 18. Analytics Integration

- **`view_count` (PHASE1 §4.2) is a legacy/cached raw counter, superseded for historical reporting by `invitation_analytics.views`** — PHASE11 §5.5's exact note: the authoritative historical view count "comes from `invitation_analytics.views`... not from the Redis-buffered cumulative counter," which "becomes a cached value refreshed nightly rather than a real-time counter" (citing PHASE2 §9.2's own framing). This milestone's `invitations.view_count` column is unchanged; this note simply records which downstream consumer is authoritative.
- **The analytics ingestion endpoint's gate is this domain's own publish state:** `POST /api/events/track` (Phase M) validates `invitations.status = 'published'` before logging any event (PHASE11 §4.3) — this is the direct dependency of the Analytics Domain on this milestone's publishing flow (§7); no event is ever recorded against a draft or archived invitation.
- **Volume baseline (PHASE11 §18.1, citing "PHASE7 §15.1"):** ~25,000 active invitations is the Year-2 planning baseline used throughout the Analytics Domain's scaling sections — recorded here as the figure this milestone's own data model must remain efficient at, though the projection itself originates in PHASE7, not in this document set directly.

## 19. Security Requirements

- RLS coverage is unchanged from M1 §16: `tenant_isolation`, `public_invitation_read`, `reseller_client_read` on `invitations`; the join-adapted `tenant_isolation` on the tables without a direct `tenant_id` column where applicable. `invitation_sections` itself has **no RLS policy cited anywhere** (M1 §16 only names `invitations`, `guests`, `rsvp_responses` as RLS-enabled tables) — access to `invitation_sections` is therefore gated entirely by the parent `invitations` row's own RLS plus application-layer `tenant_id`/`invitation_id` filtering, consistent with M2 §26's broader uncovered-table finding.
- The `slug`'s role as a public, guessable-by-design URL component (in deliberate contrast to `guests.personal_link`, which PHASE1 Appendix B requires to be "non-guessable UUIDs") means no document treats invitation slugs as a security boundary — publication state (`status`/`deleted_at`), not slug obscurity, is the only cited access control for public reachability.
- Media URLs (§12, §13) must not be guessable in a way that defeats `status`/`deleted_at` gating (e.g. a draft invitation's photo should not be publicly fetchable by URL alone if the invitation itself is not yet public) — no document confirms or denies this property for the (unnamed) storage bucket; flagged as an open concern alongside the missing bucket-name citation in §13.

## 20. Performance Requirements

- LCP < 1.5s for the public invitation page (PHASE1 §10.4) — restated here as the rendering-output target this domain's content (sections, media, couple data) must fit within, jointly with the theme renderer (M6 §14).
- ISR with 60-second revalidation for published invitations; SSR (always fresh) for drafts (PHASE1 §10.5) — restated as the caching contract this domain's publish/draft status directly controls (§7).
- "ISR caching means repeat reads never hit a function or DB query — CDN absorbs the spike" for a viral invitation (PHASE12 §9.2) and "scale to effectively unlimited read throughput... the single highest-leverage scaling property" (PHASE12 §15.4) — both citations confirm this milestone's published-invitation read path has no scaling action of its own to take; the leverage comes entirely from the caching policy already fixed in PHASE1 §10.5.
- "Public page serving... survives even a full origin outage for already-cached pages" (PHASE12 §14.2) — a resilience property inherited from the same ISR policy, not a separate requirement this milestone must implement.

## 21. Testing Requirements

- Ownership-pairing test (M1 §21, recapped): an insert with `created_by` belonging to a different tenant than `tenant_id` is rejected at the application layer (no DB trigger exists to catch this, per M1's own flag — the test exists precisely because the constraint doesn't).
- Quota-gate test: invitation creation is blocked once `checkQuota('invitations')` fails; section/feature-gated content creation is **not** blocked by feature entitlement (§16) — both outcomes must be tested explicitly since they differ.
- Publish-permission test: `editor` is rejected; `owner`/`reseller_admin`/`super_admin` succeed (§7).
- Archive test: downgrade-triggered archival selects oldest-`created_at` excess invitations first, among `status IN ('draft','published')` and `deleted_at IS NULL` only (§8, exact PHASE10 §10.3 query shape).
- Render-time gating test: a `gift`-type section with no `gift_registry` entitlement renders an `UpgradePrompt`, not the stored `content` (§16) — and the underlying row is confirmed to still exist in `invitation_sections` regardless.
- Section ordering/visibility test: `sort_order` ascending, `is_visible = FALSE` fully excluded (§11).
- Slug uniqueness test: a duplicate slug insert is rejected by the `UNIQUE` constraint (the only slug behavior that *is* fully specified, §9).
- Public-read boundary test: a `draft`/`archived`/soft-deleted invitation is unreachable via `public_invitation_read`; a `published`, non-deleted one is reachable (§4, §7).

## 22. Migration Requirements

**No new schema migration.** `invitations` and `invitation_sections` were fully specified in M1 §13, with `deleted_at` added to `invitations` in M2 §5.1. This milestone resolves process/flow questions and one enforcement-timing question (§16) entirely through citation and specification — it adds no column, no table, and no constraint. The unresolved gaps in this document (slug generation, photo-quota disambiguation, storage bucket name, reorder mechanism, core CRUD route paths) are process/application-layer or naming gaps, not schema gaps, and none is closed by a migration here.

## 23. Acceptance Criteria

- [ ] `invitations`/`invitation_sections` remain byte-for-byte unchanged from M1 §13/M2 §5.1 — no column added, removed, or altered by this milestone.
- [ ] The lifecycle diagram in §4 is implemented exactly, including the absence of any cited `archived → draft`/`published` reversal.
- [ ] Creation preconditions in §5 (quota, ownership pairing, theme entitlement, slug presence) are all enforced before a row is inserted.
- [ ] Publish permission excludes `editor`, per §7, with no additional pre-publish validation invented beyond what is cited.
- [ ] Downgrade-triggered archival matches PHASE10 §10.3's exact query shape (oldest-first, `draft`/`published` only, `deleted_at IS NULL`).
- [ ] Section-level feature gating is implemented at render time per §16's resolved citation — not at creation time.
- [ ] Section ordering/visibility behavior matches §11 exactly.
- [ ] Every flagged gap in this document (slug algorithm, photo-quota scope, storage bucket name, reorder UI, core CRUD routes, pre-publish validation, unpublish flow) is recorded as an open item in project tracking — none is silently closed by assumption.

## 24. Completion Checklist

- [ ] §3–§4 (domain architecture, lifecycle) correctly separate the `status` and `deleted_at` dimensions and flag the unresolved reversal asymmetry.
- [ ] §5–§8 (creation, editing, publishing, archive flows) each state their exact preconditions/effects and flag what is not cited rather than inventing it.
- [ ] §9–§13 (slug, builder, sections, media, storage) state every cited rule exactly and flag every gap precisely, especially the slug-generation gap, which is this milestone's most significant open item.
- [ ] §14–§15 (API, dashboard) list every cited route/surface and flag every uncited one, consistent with M4's and M6's prior treatment of similar gaps.
- [ ] §16 (feature gate enforcement) is resolved by direct citation and clearly distinguished from quota enforcement's different (preventive) timing.
- [ ] §17–§18 (theme, analytics integration) correctly cross-reference M6 and Phase M without restating their content.
- [ ] §22 confirms zero schema drift from M2's migration ledger.
- [ ] Tag `v0.8.0` once every item in §23 is verified.

**Once every box above is checked, Phase I (Guest Management) may begin.**

---

*End of M7_INVITATION_MANAGEMENT.md*
