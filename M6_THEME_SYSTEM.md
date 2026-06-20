# M6_THEME_SYSTEM.md
# Wedding Invitation SaaS Platform — Milestone M6: Theme System

> **Version:** 1.0.0
> **Implementation authority:** BUILD_ORDER.md — Phase G (`= M6` in IMPLEMENTATION_ROADMAP.md)
> **Upstream source documents:** PHASE1_ARCHITECTURE.md (§3, §4.2, §6.1, §7.1, §10.4–§10.5, §11, Appendix A), PHASE11_ANALYTICS.md (§1.3, §3.2, §18.6), PHASE12_DEPLOYMENT.md (§7.5)
> **Predecessors:** M0–M5, all complete.
> **Method:** Identical discipline to M2–M5. PHASE6_THEME_SYSTEM.md itself is not in this document set. Every fact below is either recapped by reference from M1/M2/M5 (unchanged) or a literal citation. Unlike M4's two explicitly-directed gap resolutions, the gaps surfaced in this milestone (the Free-tier "3 basic themes" subset mechanism, theme versioning, the config-validation step) are **flagged, not resolved**, consistent with M2's and M5's treatment of `package_feature_snapshot` and the add-on-to-feature gap — because no citation exists to ground a resolution and the user's directives for this milestone (boundaries, rendering flow, configuration ownership, package gating, preview, asset management) describe what must be *specified*, not which specific unresolved mechanism must be *invented*. No application code is included.

---

## 1. Objectives

1. Specify the complete theme data model (`invitation_themes`, recapped unchanged from M1 §13) and its exact relationship to `invitations.theme_id`, `invitations.couple_data`, and `invitations.customization`.
2. Specify the exact, end-to-end theme rendering pipeline, consolidating PHASE1 §3/§10.5 with the CSP carve-out PHASE12 §7.5 confirms exists specifically for theme-rendered embeds.
3. Specify the exact package-gating boundary for theme access (`is_premium` / `PREMIUM_THEMES`), and precisely flag where PHASE1's own tier table (§6.1, "3 basic" for Free vs. "All free" for Basic) requires a second gating axis that no cited column supports.
4. Specify the exact asset-management split between build-time theme assets (`public/themes/`) and user-uploaded content rendered inside a theme (Storage, owned by Phase H, cross-referenced only).
5. Specify exact preview behavior, resolving it from the rendering pipeline already approved (draft/SSR path) rather than inventing a separate preview subsystem.

## 2. Scope

**In scope:** The `invitation_themes` catalog, the theme component registry, theme-level package gating, the config/customization ownership model, the rendering pipeline as it pertains to theme selection and composition, theme asset strategy, and the admin theme-management surface already named in PHASE1 §8.1/M4 §3.

**Out of scope, with an explicit boundary:** `invitation_sections` content authoring/CRUD, section-level feature gating enforcement point, file/photo upload mechanics, and the ISR/SSR caching infrastructure's implementation — all remain Phase H's (PHASE7_INVITATION_MANAGEMENT.md's) responsibility. This milestone specifies the *policies* that already exist for these (e.g. PHASE1 §10.5's ISR rule) only insofar as the theme renderer must honor them; it does not own or re-specify their implementation.

**Deferred, not resolved here (consistent with M2/M5's precedent):** `theme_experiments` (PHASE11 §18.6, citing PHASE6 §20.2 — "already prepared," no column cited). The Free-tier theme-subset mechanism (§10). Theme versioning (§8). None of these is named in the user's explicit resolution directives for this milestone, and none has a citation to resolve from.

## 3. Theme System Architecture

```
invitation_themes (catalog, platform-level, not tenant-scoped)
   │  id, name, slug, preview_url, category, is_premium, is_active, config_schema, sort_order
   │
   └──< invitations.theme_id  (required FK, M1 §13)
            │
            ├── invitations.couple_data        (content:  groom/bride names, photos, love_story)
            ├── invitations.customization      (style:    all theme property overrides)
            └──< invitation_sections           (ordered content blocks, owned by Phase H)

components/invitation/themes/{slug}/  ──┐
components/invitation/themes/index.ts ──┴── code-level registry, must stay in sync with
                                              invitation_themes.slug (no sync mechanism cited — flagged)
```

A theme is the **rendering layer**; `invitation_sections` is the **content layer**. The theme composes whatever sections an invitation has, in the order and visibility the invitation's own `invitation_sections` rows specify (PHASE1 §4.2) — the theme does not own section content, only the layout/style each section is rendered within.

## 4. Theme Registry Architecture

**Database registry (`invitation_themes`, M1 §13, unchanged — recapped, not restated column-by-column):** `id`, `name`, `slug` (UNIQUE), `preview_url`, `category` (default `'general'`), `is_premium`, `is_active`, `config_schema` (JSONB), `sort_order`, `created_at`.

**Code registry (PHASE1 §3, exact folder structure):**
```
components/invitation/themes/
├── classic/
├── modern/
├── floral/
└── index.ts
```
PHASE1's own roadmap (§11, Phase 2) additionally names a fourth theme, "Rustic," not shown in the §3 folder illustration — this is not a contradiction, only an incomplete example tree; the actual theme count is whatever `invitation_themes` rows + corresponding code folders exist, not fixed at three.

**Flagged gap — registry synchronization:** no document cites a validation step ensuring every `invitation_themes` row with `is_active = TRUE` has a corresponding folder/export in `components/invitation/themes/index.ts`, or vice versa. A theme published in the database catalog without its code counterpart deployed would have no renderer to resolve to (§6); the inverse (a code-level theme component with no catalog row) would simply never be selectable. This is not resolved here.

## 5. Theme Configuration Model

**Exact ownership split (resolved from the two existing JSONB columns, M1 §13):**

| Column | Owns | Lives on |
|---|---|---|
| `invitation_themes.config_schema` | The **shape/constraints** of what is customizable for a given theme — "customizable fields schema" (PHASE1 §4.2 comment) | The theme (catalog-level, shared by every invitation using that theme) |
| `invitations.customization` | The **actual override values** a specific invitation has set — "all theme property overrides" (PHASE1 §4.2 comment) | The invitation (per-invitation) |
| `invitations.couple_data` | **Content**, not presentation — `groom_name`, `bride_name`, `groom_photo`, `bride_photo`, `love_story` (PHASE1 §4.2 exact shape) | The invitation |

**Exact boundary:** `customization` governs *how* a theme presents (colors, fonts, layout toggles — whatever `config_schema` permits); `couple_data` governs *what* content is rendered into that presentation. A theme renderer must read both, but they are not interchangeable, and neither is validated against the other.

**Flagged gap:** no document cites a runtime validation step checking `invitations.customization` against its theme's `config_schema` (e.g. rejecting an override key the schema doesn't define, or a value outside an allowed range). The two are structurally related by documentation comment only; no enforcement mechanism is specified.

## 6. Theme Rendering Pipeline

Exact, step by step, consolidating PHASE1 §3/§10.5, M1 §21, and PHASE12 §7.5:

```
1. Request arrives at /inv/[slug] (public) or the owner-authenticated editor/preview path.
2. Invitation resolved by slug (public: status='published' AND deleted_at IS NULL per
   public_invitation_read + M2 §5.1's soft-delete extension; owner path: any status,
   tenant-scoped per RLS).
3. invitation.theme_id resolved against invitation_themes; is_active checked (M1 §21 — a
   theme that has been deactivated after an invitation already selected it has no cited
   fallback behavior — flagged).
4. The theme's slug resolves to a renderer component via components/invitation/themes/index.ts
   (the code registry, §4).
5. The renderer receives: invitations.couple_data (content), invitations.customization (style
   overrides, unvalidated per §5), and the invitation's invitation_sections rows, ordered by
   sort_order and filtered to is_visible = TRUE (PHASE1 §4.2).
6. The renderer composes one section component per invitation_sections row, within its own
   theme-specific layout shell.
7. Platform-badge rendering is gated by resolveFeature(tenantId, FEATURES.REMOVE_PLATFORM_BADGE)
   (M5 §7) — the theme must suppress its default attribution badge when this feature is enabled.
8. Whether a given section's content is itself gated at this render step or upstream at
   authoring time (Phase H) is not specified anywhere — flagged, not resolved here.
9. Output caching: ISR with 60-second revalidation for published invitations; SSR (always
   fresh) for drafts (PHASE1 §10.5) — the theme renderer itself has no caching responsibility
   beyond producing deterministic output for a given (theme, couple_data, customization,
   sections) input, since the caching decision is made above it in the request pipeline.
```

**CSP carve-out for theme-rendered embeds (PHASE12 §7.5, exact):** "The public invitation page (`/inv/[slug]`) and reseller white-label subdomains receive a slightly relaxed `frame-src`/`img-src` policy where needed for theme embeds (PHASE6 livestream/map embeds), scoped per-route rather than weakening the platform-wide default." This confirms the renderer must be able to render `LIVESTREAM_LINK`/`MAP_EMBED`-gated section content (PHASE1 §7.1) without the platform-wide CSP (PHASE12 §7.5's own default) blocking it — the relaxation is applied at the route level (Phase N's responsibility), not by the theme itself.

## 7. Theme Asset Strategy

**Exact split, resolved from two different storage mechanisms already cited:**

| Asset | Storage mechanism | Managed by |
|---|---|---|
| Theme preview thumbnail (`invitation_themes.preview_url`) | `public/themes/` — a Next.js static `public/` folder asset (PHASE1 §3), **not** a Supabase Storage bucket | Code deploy — adding a new theme's preview image requires shipping a build, not a database write alone |
| Couple photos, gallery photos rendered *inside* a theme (`couple_data.groom_photo`/`bride_photo`, gallery section content) | Supabase Storage (bucket convention established generically in PHASE2 §7, extended by name only for `invoices` (PHASE10) and `analytics-exports` (PHASE11 §19.4) — no theme-specific bucket is cited) | Phase H (Invitation Management) — the theme renderer only consumes whatever URL is already stored; it has no upload responsibility |

**Exact consequence for "asset management behavior":** publishing a brand-new theme is **not** a database-only operation — it requires, at minimum, (a) a code deploy adding the renderer component and its `public/themes/` preview asset, and (b) a catalog row insert (`/admin/themes`, §12). Editing an *existing* theme's metadata (name, category, `is_premium`, `is_active`, `sort_order`) **is** a database-only operation once the code/asset side already exists.

## 8. Theme Versioning Strategy

**No versioning mechanism is cited anywhere.** There is no version column on `invitation_themes`, no schema-migration path for `config_schema` changes affecting invitations that already have `customization` values set against an older shape, and no compatibility-window concept. This is a significant open gap for a production theme catalog, and it is recorded here precisely because it is absent — not resolved, since no citation exists to ground a resolution and it is not named among this milestone's explicit resolution directives.

## 9. Theme Feature Integration

Exact relationship between theme selection and the `FEATURES` registry (M1 §17, M5 §7), independent gating layers, not substitutes for one another:

| Feature key | Governs | Independent of theme selection? |
|---|---|---|
| `premium_themes` | Whether `is_premium = TRUE` themes are selectable at all (§10) | This *is* the theme-level gate |
| `custom_font` | Whether a `customization` override may set a font outside the theme's default | Independent — applies regardless of which theme is selected |
| `remove_platform_badge` | Whether the theme's default attribution badge renders (§6 step 7) | Independent — every theme must respect this flag identically |
| `music_player`, `countdown_timer`, `gift_registry`, `gallery_section`, `love_story_section`, `livestream_link`, `map_embed` | Whether a given **section type** may exist/render at all (PHASE1 §7.1) | Independent — these are section-level gates, not theme-level; a theme renders whatever sections exist, it does not itself decide whether a section type is entitled |

No theme is cited as bypassing or overriding any section-level feature gate, and no section-level feature is cited as bypassing the theme-level `premium_themes` gate. Both layers apply simultaneously, consistent with the defense-in-depth pattern already established elsewhere (M3 §19).

## 10. Theme Package Restrictions

**Exact, cited gate:** a theme with `is_premium = TRUE` requires `resolveFeature(tenantId, FEATURES.PREMIUM_THEMES).enabled === true` (M1 §21, unchanged) — checked at the application layer, not via a DB constraint.

**Flagged gap — the Free-tier subset:** PHASE1 §6.1's tier table states Free tier gets "3 basic" themes while Basic tier gets "All free" themes — meaning Free-tier access is a **strict subset** of the full non-premium catalog, not simply "every `is_premium = FALSE` theme." `invitation_themes` (M1 §13) has only a single boolean `is_premium` column; no second flag, count limit, or allowlist distinguishes which specific non-premium themes are available to Free tier versus the full non-premium set available to Basic tier and above. No citation anywhere — not PHASE1, not PHASE5/PHASE10/PHASE11's feature-config conventions — specifies this mechanism (e.g. a fixed allowlist, a count-based quota analogous to `max_invitations`, or an ordering rule). **This is not resolved here.** Unlike the `super_admin`/impersonation gaps M4 was explicitly directed to resolve, this milestone's directives ask that package gating behavior be defined *exactly* — which this section does, precisely by stating exactly how far the citation goes and where it stops, rather than inventing a mechanism with no grounding.

## 11. Theme Customization Rules

- `customization` overrides apply per-invitation, never per-tenant or globally (§5) — there is no "tenant default customization" concept cited anywhere.
- The only customization dimension cited as independently feature-gated is font selection (`custom_font`, §9); color, layout, and other `config_schema`-defined dimensions are not cited as separately gated — they are available to any tenant on any theme they are otherwise entitled to select (i.e., gating happens once, at theme selection, not per customization field, except for the one named exception).
- No upper bound on the *number* of customizable fields, nor a size limit on the `customization` JSONB itself, is cited anywhere.

## 12. Theme Publishing Rules

**Exact two-part model (resolved by combining §4's two registries with PHASE1 §8.1's admin module citation):**

1. **Code-level publishing (required first):** the renderer component must exist under `components/invitation/themes/{slug}/` and be registered in `index.ts`. This is a code deploy, not a database operation.
2. **Catalog-level publishing:** once the code side exists, a `super_admin` creates or edits the corresponding `invitation_themes` row via `/admin/themes` — "Upload and manage invitation themes" (PHASE1 §8.1, recapped M4 §3) — setting `is_active = TRUE` to make it selectable.

A theme is genuinely available to tenants only once **both** steps are complete. No API route backing `/admin/themes` is cited anywhere (consistent with M4 §16's finding that PHASE1 §8.1 names UI modules without giving most of their API route paths) — flagged, not invented.

**No publishing approval workflow, draft-theme state, or rollback mechanism is cited** beyond the binary `is_active` flag.

## 13. Theme Preview Architecture

**Exact, resolved from the existing rendering pipeline rather than a separate subsystem:**

- **Catalog-browsing preview:** `invitation_themes.preview_url` — a single static thumbnail per theme (§7), used wherever a theme-selection gallery is presented. No live-rendering preview is cited at this stage.
- **Try-before-commit preview:** no theme-specific "try this theme with my content before saving" mode is cited anywhere. However, because **any draft invitation already renders via SSR, always fresh, regardless of theme** (PHASE1 §10.5, restated in §6), an owner changing `invitations.theme_id` on their own draft invitation and viewing it already produces a true, live, current-content preview through the existing rendering pipeline — no separate preview subsystem needs to exist for this purpose, and none is introduced here. This is the resolved answer to "exact preview behavior": the draft/SSR path **is** the preview mechanism.

## 14. Theme Performance Requirements

- LCP < 1.5s for the public invitation page (PHASE1 §10.4) — this target applies to the page as a whole, which is the theme's rendered output; the theme renderer is therefore the dominant contributor to this budget and must not introduce blocking resource loads.
- The "no-blocking-analytics invariant" (PHASE7's perf posture, cited via PHASE11 §1.3) presupposes the underlying page render — i.e., the theme — is itself fast and non-blocking; the analytics beacon's fire-and-forget design (PHASE11 §4.6) only achieves its purpose if the theme doesn't independently introduce blocking behavior of its own.
- ISR's 60-second revalidation (§6) means a theme's rendered HTML for a published invitation is reused across requests within that window — the theme's output must therefore be safe to cache (deterministic for a given input set), which is implicit in the rendering pipeline's design (§6) but is stated here as an explicit requirement on theme components.

## 15. Theme Security Requirements

- `is_active = TRUE` and (for premium themes) the `PREMIUM_THEMES` feature check (§10) are the only two cited gates on theme selection; both are application-layer checks, not DB constraints (M1 §21).
- **Flagged concern, not resolved by any citation:** `customization` values are tenant-supplied JSONB rendered back out by the theme. No document specifies a sanitization step for these values before render (e.g. preventing arbitrary CSS/HTML injection through a customization field). This is distinct from, and not addressed by, the general "SQL injection: use Supabase JS client" checklist item (PHASE1 Appendix B), which concerns the database layer, not render-time output encoding. Flagged as an open security item.
- No RLS policy is cited for `invitation_themes` (M1 §16/M2 §26 — unchanged; it is a platform-level catalog table, the same uncovered-table category every other catalog table in this schema falls into).

## 16. Theme Storage Architecture

Recapped from §7, restated for completeness against the section heading the user requested: build-time theme assets live in `public/themes/` (Next.js static assets, code-deploy-managed); user-uploaded content rendered inside a theme (couple photos, gallery images) lives in Supabase Storage under Phase H's ownership, cross-referenced only, not re-specified here. No theme-specific Storage bucket is cited anywhere.

## 17. Theme API Architecture

**No `/api/themes/*` route is cited anywhere in any available document.** Theme catalog reads (for the editor's theme picker, or for the public-page renderer's theme lookup) are not shown going through a dedicated REST endpoint in any cited code — consistent with this being a low-write, read-mostly catalog table likely queried directly server-side rather than through a bespoke API surface, though this inference is not itself a citation.

**Admin theme management:** no API route backing `/admin/themes` is cited (§12, consistent with M4 §16). Both are flagged, neither is invented.

## 18. Theme Testing Requirements

- `theme_id` FK validity and `is_active` gating test (recapped from M1 §24): selecting an inactive theme is rejected.
- `PREMIUM_THEMES` gating test: a tenant without the entitlement cannot select an `is_premium = TRUE` theme; one with it can.
- Rendering pipeline test: for a fixed (theme, `couple_data`, `customization`, `invitation_sections`) input, output is deterministic — required by the ISR caching assumption in §14.
- Section-order/visibility test: sections render in `sort_order`, and `is_visible = FALSE` sections are excluded, regardless of theme.
- `REMOVE_PLATFORM_BADGE` test: badge suppressed/shown correctly per entitlement, across every theme (§9).
- Preview-equivalence test (§13): a draft invitation's SSR render after a theme change matches what the same invitation would render as if it were the live preview — i.e., confirm no separate, divergent "preview mode" code path silently exists that could drift from the real render.
- CSP carve-out test (cross-referenced to Phase N): a theme section using `livestream_link`/`map_embed` renders successfully on `/inv/[slug]` under the relaxed CSP, and is still blocked under the platform-wide default elsewhere.

## 19. Migration Requirements

**No new schema migration.** `invitation_themes` was fully specified in M1 §13 and is unchanged by this milestone. `theme_experiments` remains deferred (§2, consistent with M2 §5.7/§20's prior treatment) — not created here, since no citation exists to ground its column set and it is not named among this milestone's explicit resolution directives. This milestone's only deliverables are specification text and (in a later phase, per BUILD_ORDER) the code-level theme components and admin UI — neither of which is schema.

## 20. Acceptance Criteria

- [ ] `invitation_themes` is confirmed unchanged from M1 §13 — no column added, removed, or altered.
- [ ] The theme rendering pipeline in §6 is implemented exactly as sequenced, including the explicit non-resolution of step 8 (section-gating enforcement point).
- [ ] The asset-management split in §7 is honored: a new theme requires a code deploy for its renderer and `public/themes/` preview image, not a database write alone.
- [ ] `PREMIUM_THEMES` gating (§10) is enforced for every `is_premium = TRUE` theme; the Free-tier-subset gap is recorded as an open item in project tracking, not silently resolved by an invented mechanism.
- [ ] The preview behavior in §13 is confirmed to be the existing draft/SSR path — no separate preview subsystem is built.
- [ ] `REMOVE_PLATFORM_BADGE` and `CUSTOM_FONT` gating apply identically across every theme (§9, §11).
- [ ] `theme_experiments` remains absent from the schema (§19).
- [ ] No new migration file exists for this milestone.

## 21. Completion Checklist

- [ ] §3–§5 (architecture, registry, configuration model) match PHASE1's data model exactly, with the code/database dual-registry gap explicitly flagged.
- [ ] §6–§7 (rendering pipeline, asset strategy) give a complete, exact, step-by-step account consistent with PHASE1 §10.5 and PHASE12 §7.5.
- [ ] §8 (versioning) is recorded as entirely unspecified, not silently assumed safe.
- [ ] §9–§11 (feature integration, package restrictions, customization rules) state every gate exactly and flag the one gate (Free-tier subset) that cannot be stated exactly from citation alone.
- [ ] §12–§13 (publishing, preview) resolve cleanly from existing structure with no invented subsystem.
- [ ] §14–§17 (performance, security, storage, API) carry forward the relevant platform-wide requirements and flag theme-specific gaps precisely.
- [ ] §19 confirms zero schema drift.
- [ ] Tag `v0.7.0` once every item in §20 is verified.

**Once every box above is checked, Phase H (Invitation Management) may begin.**

---

*End of M6_THEME_SYSTEM.md*
