# M9_RSVP_GUESTBOOK.md
# Wedding Invitation SaaS Platform — Milestone M9: RSVP & Guestbook

> **Version:** 1.0.0
> **Implementation authority:** BUILD_ORDER.md — Phase J (`= M9` in IMPLEMENTATION_ROADMAP.md)
> **Upstream source documents:** PHASE1_ARCHITECTURE.md (§4.2–§4.3, §5.2, §6.1, §7.1, §11, Appendix B), PHASE11_ANALYTICS.md (§1.3, §2.1, §4.3, §5.3, §8.1, §9.1–§9.4, §14, §15.1, §16.3, §18.5, §19.1), and the prior M-documents.
> **Predecessors:** M0–M8, all complete.
> **Method:** Identical discipline to M5–M8. PHASE9_RSVP_GUESTBOOK.md itself is not in this document set. One column gap is resolved here on direct citation grounds (not invention): PHASE11 §16.3 explicitly groups `rsvp_responses` **and** `guestbook_entries` together as both retaining "raw IP... transiently for spam scoring," yet M2's column citation for `guestbook_entries` never included one — this milestone adds it, citing the exact passage that requires it. Every other open question (the guestbook content column, RSVP resubmission, deadline enforcement, the spam-detection algorithm itself) is flagged, not invented, consistent with the "Define exact X" phrasing the user used throughout this directive (as distinct from the explicit "Resolve X" phrasing used for M4 and M8's gaps). No application code is included.

---

## 1. Objectives

1. Consolidate the complete `rsvp_responses` (M1 §13 base + M2 §5.3 extensions) and `guestbook_entries` (M2 §5.3) data model, resolving one further column gap on direct citation (§7).
2. Specify the exact RSVP submission, attribution, and ownership rules — including the one fully-given SQL view (`rsvp_by_group`, PHASE11 §9.2) that makes the anonymous-vs-attributed distinction completely explicit.
3. Specify the exact moderation state machine for the guestbook (`pending`/`approved`/`rejected`), including the live-feed's approved-only filter (PHASE11 §14.1) and the "verified" concept PHASE11 §9.4's `verified_guest_ratio` metric directly names.
4. Specify the exact, cited spam-protection mechanics (the `is_spam` column's mandatory exclusion from every metric, the rate-limit value, the 90-day raw-IP purge commitment) while flagging that the spam-*detection* algorithm itself is never cited.
5. Specify the exact personalized vs. open/anonymous RSVP and guestbook flows, resolved precisely from `guest_id`'s nullability and the `rsvp_by_group` view's explicit `guest_id IS NOT NULL` filter.

## 2. Scope

**In scope:** `rsvp_responses` and `guestbook_entries`' complete cited schema, submission/attribution/ownership rules, the moderation state machine, spam-protection mechanics to the extent cited, the live real-time feed behavior, and this domain's integration points with Analytics (already largely specified in PHASE11, cross-referenced) and Guest Management (M8).

**Out of scope:** The exact RSVP/guestbook submission API route paths (flagged, not invented, §5/§8 — consistent with M7/M8's identical treatment of core CRUD routes). The deferred views/RPC (`rsvp_daily_trend`, `rsvp_by_category`, `rsvp_response_rate`, `guest_rsvp_status`, `guest_checkin_status`, `get_rsvp_summary()`) — these remain exactly as deferred in M2 §5.3/§20, since this milestone's directives are about ownership, attribution, moderation, spam protection, and personalized/open flow — not about inventing the missing view SQL.

**This milestone's one resolution, stated once:** `guestbook_entries.ip_address` is added (§7), on the strength of a direct citation pairing it with `rsvp_responses.ip_address`'s already-approved column — this is not a new feature, it is completing a column PHASE11 already describes as existing.

## 3. RSVP Domain Architecture

```
invitations
   │  is_rsvp_open (BOOLEAN), rsvp_deadline (DATE)  — owner-level toggle/window, PHASE1 §4.2
   │
   ├──< rsvp_responses
   │       guest_id (nullable — personalized §11 vs open §12)
   │       attendance, pax_count, meal_choice (M2), message, wishes
   │       is_spam (M2), ip_address (raw, transient, §10)
   │
   └──< guestbook_entries
           guest_id (nullable — same personalized/open distinction)
           moderation_status (pending/approved/rejected, §9)
           is_spam, ip_address (resolved, §7), submitted_at
```

`rsvp_responses.wishes` (PHASE1 §4.2, a free-text field bundled with an RSVP submission) and `guestbook_entries` (a standalone entry with its own moderation gate) are **not the same mechanism**, even though both ultimately surface as guest-left text. This milestone's best-grounded reading of the available citations (not itself a separate literal citation, stated as a reasoned synthesis, not a fact): `rsvp_responses.wishes` is low-risk because it can only be written by someone going through the RSVP flow, while `guestbook_entries` is a separate, open-ended posting surface that — precisely because anyone can reach it — needs `moderation_status` as a second gate `rsvp_responses` never needed. This explains, without inventing new structure, why one table has a moderation column and the other does not.

## 4. RSVP Lifecycle

1. **Submission** (§5) — the only state-creating action cited anywhere. `submitted_at` defaults to `NOW()` (M1 §13).
2. **No edit/resubmission/delete flow is cited anywhere** for an already-submitted `rsvp_responses` row. Whether a guest may change their mind after submitting (a new row, an update to the existing row, or no mechanism at all) is not specified. Flagged.
3. **Read** — by the owner-side dashboard (all roles including `viewer`, M3 §9), by analytics rollups (Phase M, filtered `is_spam = FALSE`), and by the live feed (§13).
4. **Purge of the raw `ip_address` field specifically, after 90 days** (§10) — the only cited lifecycle event beyond submission and read.

`rsvp_responses` has **no `tenant_id` column** (M1 §13, M1 §12's flagged gap, unchanged) — every lifecycle action above is reachable only via `invitation_id → invitations.tenant_id`.

## 5. RSVP Submission Flow

**Exact preconditions, consolidated from existing columns (no new structure):**
- The target invitation must be `status = 'published'` and `deleted_at IS NULL` — the same gate already established for public reachability generally (M7 §4/§7).
- `invitations.is_rsvp_open = TRUE` — the owner-level toggle. **Flagged distinction:** this is a *different* gate from the `FEATURES.RSVP_OPEN` (`rsvp_open`) registry key (PHASE1 §7.1) — the feature key governs whether the RSVP *capability* exists for the tenant's package tier at all (and PHASE1 §6.1's tier table shows it `✅` for every tier, so in practice this feature key is never currently a binding restriction), while `invitations.is_rsvp_open` is the **per-invitation** owner-controlled on/off switch, independent of package tier.
- `invitations.rsvp_deadline` — the column exists (PHASE1 §4.2, DATE), but **no citation confirms whether it is actually enforced** (rejecting submissions after the date) or is purely informational/display-only. Flagged, not resolved.
- Rate limit: **10 requests/minute per IP** (PHASE1 Appendix B, exact, cited number) — distinct from the analytics-ingestion endpoint's own separate 60/minute limit (PHASE11 §4.5); the two are not interchangeable.

**Exact write, per the schema (M1 §13, M2 §5.3):** a new `rsvp_responses` row — `invitation_id`, `guest_id` (nullable, §11/§12), `name`, `email`, `phone`, `attendance`, `pax_count` (default 1, gated conceptually by `FEATURES.RSVP_PLUS_ONE` when greater than 1 — PHASE1 §7.1's key exists for this purpose, though no tier table row separately confirms its gating beyond the key's existence), `meal_choice` (gated conceptually by `FEATURES.RSVP_MEAL_CHOICE`, same caveat), `message`, `wishes`, `submitted_at`, `ip_address` (raw, §10), `metadata`.

## 6. RSVP Status Resolution

**Cited, partial:** `guest_rsvp_status` (PHASE8 §10.1, cited via PHASE11 §1.3/§8.4) exposes at minimum `guest_id`, `invitation_id`, and `derived_status` (PHASE11 §8.4's literal selection). The view's full definition is not given anywhere (deferred per M2 §5.3 — unchanged here).

**Flagged, not resolved:** because `rsvp_responses.guest_id` is neither `UNIQUE` nor otherwise constrained to one row per guest, a guest could in principle have more than one `rsvp_responses` row. No citation specifies how `derived_status` resolves this — most-recent-submission-wins, highest-pax-count-wins, or some other rule. This milestone records the ambiguity rather than asserting an answer the view's actual (unavailable) definition might contradict.

## 7. Guestbook Architecture — Column Gap Resolved

**`guestbook_entries`, recapped from M2 §5.3, plus this milestone's addition:**

| Column | Type | Nullable | Default | Source |
|---|---|---|---|---|
| `id`, `invitation_id`, `guest_id`, `moderation_status`, `is_spam`, `submitted_at` | — | — | — | M2 §5.3, unchanged |
| `ip_address` | TEXT | YES | NULL | **New.** PHASE11 §16.3, exact: "`invitation_events` never stores raw IP addresses... — stricter than `rsvp_responses`/`guestbook_entries`, **which retain raw IP transiently for spam scoring** per PHASE9 §13.4's documented policy and 90-day purge commitment." This sentence treats the two tables identically with respect to IP retention; since `rsvp_responses.ip_address` already exists (PHASE1 §4.2), this milestone adds the column PHASE11 already describes `guestbook_entries` as having. |

**Still flagged, not resolved:** the message/content text column itself. No citation anywhere — not a `.select()`, not a `CREATE TABLE`, not a prose description — names it. A guestbook cannot function without one; this remains the most significant open item in this table's specification, exactly as M2 §5.3 first recorded it.

## 8. Guestbook Submission Flow

**Exact preconditions:** mirrors §5's invitation-publication gate. No `is_guestbook_open`-style per-invitation toggle is cited (in contrast to RSVP's `is_rsvp_open`) — flagged as an asymmetry, not resolved.

**Exact initial state:** a new row is **not** immediately public — `moderation_status` must reach `'approved'` before it is eligible for the live feed (§13) or any owner-facing count that distinguishes by status. No citation states the literal default value of `moderation_status` at insert, though `'pending'` is the only value consistent with "moderation" as a concept (an entry must start somewhere before being approved or rejected) — recorded as the reasoned default, not asserted as a verbatim-cited default.

**"Verified" vs. anonymous, exact (PHASE11 §9.4, direct citation):** `verified_guest_ratio` is defined as "% of approved entries where `guest_id IS NOT NULL`" — i.e., an entry is **verified** if it was submitted through a personalized link (§11) and **unverified/anonymous** if `guest_id IS NULL` (§12). This is the one place in the available documents where "verified" is given a precise, operational meaning for this domain.

## 9. Moderation Architecture

**Exact state machine (PHASE11 §9.4, the three values used in literal filter/count logic):**
```
pending ──► approved   (eligible for live feed, §13, and counted in verified_guest_ratio)
pending ──► rejected   (excluded from every owner-facing surface cited)
```
No transition *out* of `approved`/`rejected` back to `pending`, and no transition directly from `pending` to anywhere other than the two named outcomes, is cited.

**Flagged, not resolved:** no API route, admin UI surface, or permission boundary for the moderation *action* itself (who clicks approve/reject, and through what endpoint) is cited anywhere. Only the resulting **state** (the three `moderation_status` values) and its **consumption** (filtering in every metric/feed) are cited. By analogy with the existing permission matrix (M3 §9 — "Manage guests" is `owner`/`editor`-and-above, never `viewer`), moderation is reasonably expected to sit at a similar permission level, but this is not itself asserted as a citation.

## 10. Spam Protection Strategy

**Exact, cited mechanics:**
- `is_spam BOOLEAN NOT NULL DEFAULT FALSE` on both tables (M2 §5.3).
- **Mandatory exclusion rule (PHASE11 §2.1, exact):** "Spam/bot filtering in metrics | Include vs exclude `is_spam` RSVP/guestbook rows | **Exclude** (matches PHASE9 `is_spam = FALSE` filter already used in every PHASE9 index/view) | Analytics must report true engagement, not spam volume; consistency with PHASE9 query patterns is **mandatory**." Every metric, view, or count touching either table must filter `is_spam = FALSE` — this is restated as a binding rule, not a suggestion, per the cited word "mandatory."
- **Raw IP, transient, 90-day purge (PHASE11 §16.3, exact, recapped from §7):** both tables retain `ip_address` "transiently... for spam scoring," with a "90-day purge commitment." This milestone reads "transiently" and "90-day purge" as applying to the `ip_address` field specifically, not the entire row — the rest of a guest's RSVP/guestbook content (their attendance answer, their wishes, their message) has no cited expiry, since it is the actual durable business value of the row, whereas the IP exists only to support spam scoring at submission time.
- **Rate limiting (§5, recapped):** 10 req/min/IP on the RSVP endpoint (PHASE1 Appendix B) is the one concrete, numbered anti-abuse control cited; no separate, distinctly-numbered rate limit is cited for the guestbook endpoint.

**Flagged, not resolved — the detection algorithm itself.** No document anywhere specifies *how* `is_spam` is actually computed (a heuristic, a third-party service, a simple rate-based rule, content matching). Every citation in this document concerns what happens **after** `is_spam` has a value (exclusion from metrics, retention of IP "for spam scoring") — never how that value is first produced.

## 11. Personalized RSVP Flow

**Exact, cited (PHASE9 §11.1, cited via M1 §16/§21 and M8 §9; resolution flow itself cited PHASE8 §7.3):** "Personalized-link resolution flow... populates `invitation_events.guest_id`" — the same resolution mechanism that attributes analytics events also attributes an RSVP submission: when a guest arrives via their `personal_link` (M8 §9), the resulting `rsvp_responses.guest_id` is set to that guest's `id`.

**Cross-invitation validation (PHASE9 §13.3, exact, recapped from M8 §9):** the same "guest must belong to THIS invitation" cross-check that gates analytics attribution applies identically here — a personal link cannot attribute an RSVP to a guest belonging to a different invitation than the one being submitted against.

**Exact downstream consequence (PHASE11 §9.2, direct SQL citation, recapped from M2/M8):** `rsvp_by_group`'s `JOIN guests g ON g.id = r.guest_id` and its `WHERE ... AND r.guest_id IS NOT NULL` clause together mean **only personalized (attributed) RSVP responses are ever included in group-based reporting.** This is the exact, citation-grounded answer to "exact RSVP attribution rules": attribution exists if and only if `guest_id IS NOT NULL`, and every group/category-scoped rollup depends on it.

## 12. Open RSVP Flow

**Exact, cited:** `rsvp_responses.guest_id` is nullable specifically "if open RSVP" (PHASE1 §4.2's own column comment, M1 §13) — confirming open/anonymous RSVP (no personalized link, a guest simply visiting the public page and submitting their own name) is an explicitly approved, first-class submission path, not an edge case.

**Exact consequence, resolved precisely from §11's citation in reverse:** an open RSVP (`guest_id IS NULL`) is **counted** in every aggregate that does not require a guest join (`invitation_analytics.rsvp_attending`/etc., the day-counter in §5/PHASE11 §5.3, which filters only on `attendance`/`is_spam`/date — no `guest_id` condition) but is **excluded** from any guest-attribute-dependent rollup (`rsvp_by_group`, and by the same logic anything a `rsvp_by_category` would need a `guest_id` join for, though that view's own SQL is not cited, M2 §5.3). This is the exact, resolved answer to "exact anonymous/open RSVP behavior": open submissions are real, counted engagement, but invisible to any breakdown that requires knowing *which* guest it was.

**Same open/personalized duality applies to `guestbook_entries`** (§8's "verified" distinction) — the two tables share this exact structural pattern.

## 13. RSVP Analytics Integration

Cross-referenced, not restated: the day-counter (`countRsvpForDay()`, PHASE11 §5.3, exact `is_spam = FALSE` filter), the meal-choice breakdown (§9.3, `attendance = 'attending'` AND `is_spam = FALSE` AND `meal_choice IS NOT NULL`), `rsvp_by_group` (§9.2, fully cited, recapped in §11), and the **live RSVP feed** (PHASE11 §14, exact): realtime channel on `rsvp_responses` INSERT, filtered to the invitation, **prepended** to a feed capped at the **last 20** entries; the initial page-load query filters `is_spam = FALSE`, orders `submitted_at DESC`, limits 20 (PHASE11 §14.3) — note the live feed has **no `moderation_status` filter**, since `rsvp_responses` has no such column; only the spam filter applies, in contrast to the guestbook's live feed (§14).

## 14. Guestbook Analytics Integration

Cross-referenced: `getGuestbookMetrics()` (PHASE11 §9.4, exact) computes `total_entries`/`approved`/`pending`/`rejected`/`verified_guest_ratio`/`daily_trend`, all filtered `is_spam = FALSE` over a date range. The **live guestbook feed is approved-only** (PHASE11 §14.1, exact: "Live guestbook feed (Supabase Realtime on `guestbook_entries` INSERT, **approved only**)") — this is the one place a real-time feed in this entire platform applies a moderation filter in addition to a spam filter, and it is stated here as the explicit, binding behavior, not an inference.

## 15. Guest Ownership Integration

Cross-referenced to M8, not restated: `rsvp_responses.guest_id`/`guestbook_entries.guest_id` both resolve through the same guest-ownership rules M8 §12 already establishes (a guest belongs to exactly one invitation; cross-invitation attribution is rejected, §11). The resolved `guest_groups`/`guest_categories` scoping (M8 §7/§8) is what makes `rsvp_by_group` (§11) and the equivalent category-based rollup actually joinable end-to-end — this milestone's RSVP/guestbook specification depends directly on M8's two resolutions, not on any new structure of its own.

## 16. Public Access Rules

**Exact, cited read access (M1 §16, unchanged):** `tenant_isolation` on `rsvp_responses`, join-adapted (no direct `tenant_id` column, M1 §12) — owner/editor/viewer of the owning tenant may read; no public SELECT policy is cited for `rsvp_responses` (unlike `invitations`' `public_invitation_read`) — the RSVP data itself is never publicly readable, only submittable.

**Flagged, not resolved — the public INSERT path itself.** M1 §12 already recorded that "Public/anonymous write paths... are not specified in PHASE1 §4.3 — only the three SELECT-oriented patterns... INSERT policies for guest-facing RSVP submission belong to Phase J." Now that this milestone **is** Phase J, no new citation has emerged anywhere in PHASE10/11/12 that supplies the actual `CREATE POLICY` for this INSERT path. What **can** be stated precisely, synthesized from columns already approved (not a new decision): any such policy must, at minimum, require the target invitation to be `status = 'published'`, `deleted_at IS NULL`, and `is_rsvp_open = TRUE` (§5) — but the literal RLS policy implementing this is not cited and is not invented here. `guestbook_entries` has the identical gap, with no `is_guestbook_open` equivalent even to anchor the synthesized business rule against (§8).

## 17. Security Requirements

- Rate limiting: 10 req/min/IP on the RSVP endpoint (PHASE1 Appendix B, restated as binding).
- Raw IP retention is **transient and purge-bound** (90 days, §10) on both tables — any implementation must not treat `ip_address` as a permanent field, even though no other column on either table is cited as having an expiry.
- `is_spam` exclusion from metrics is **mandatory**, per PHASE11 §2.1's own wording — not a tunable preference.
- No RLS policy is cited for `guestbook_entries` at all (M2 §26's broader uncovered-table finding, unchanged — this table joins the same flagged-gap category as every other M2-introduced table).
- Guest-identifying data (names) surfaced on the owner-facing RSVP/guestbook dashboards is treated identically in sensitivity to the guest list itself (PHASE11 §16.3, exact) — not a separate privacy surface requiring its own additional protection beyond the tenant-isolation already in place.

## 18. Performance Requirements

- The day-counter, meal-breakdown, and `rsvp_by_group` queries are all invitation-scoped and date/attendance-filtered (§13) — none requires a full-table scan, consistent with the indexing already in place (`idx_rsvp_invitation_id`, M1 §14).
- The live feed's 20-row cap (RSVP) and the engagement-summary's 500-row cap (a different, Guest-Domain query, M8 §11) are the only two cited result-size limits in the broader Guest/RSVP/Guestbook surface — recorded here for completeness, not newly introduced.
- Realtime channel scaling is bounded by "weddings happening today," not total invitation count (PHASE11 §14.4, recapped) — applies identically to the guestbook's live channel as to the RSVP one.

## 19. Testing Requirements

- Open vs. personalized attribution test: a `guest_id IS NULL` RSVP is counted in `invitation_analytics.rsvp_attending`-equivalent aggregates but excluded from `rsvp_by_group` (§11, §12).
- Moderation test: only `moderation_status = 'approved'` guestbook entries appear in the live feed; `pending`/`rejected` never do, regardless of `is_spam` (§9, §14).
- `verified_guest_ratio` test: matches exactly `approved entries with guest_id IS NOT NULL / total approved entries` (§8).
- Spam exclusion test: an `is_spam = TRUE` row is excluded from every cited metric (day-counter, meal-breakdown, `rsvp_by_group`, guestbook metrics) without exception.
- IP purge test: `ip_address` is nulled on both tables after 90 days; no other column is affected.
- Rate-limit test: an 11th RSVP request within one minute from the same IP is rejected.
- Cross-invitation attribution rejection test: a `guest_id` belonging to a different invitation than the one being submitted against is rejected (§11, §15).

## 20. Migration Requirements

**One new migration, resolving the column gap in §7:**

```
037_guestbook_entries_add_ip_address.sql   -- ALTER TABLE guestbook_entries ADD COLUMN ip_address TEXT
```

Consumes the next number after M8's `036` from the range M1 reserved (`018`–`090`); does not collide with any prior milestone's range or the fixed Phase L/M ranges. `038`–`090` remains reserved.

**Not migrated in this milestone (consistent with this milestone's scope, §2):** the guestbook content column, `rsvp_daily_trend`/`rsvp_by_category`/`rsvp_response_rate`, `guest_rsvp_status`/`guest_checkin_status`, `get_rsvp_summary()` — all remain exactly as deferred since M2.

## 21. Acceptance Criteria

- [ ] `guestbook_entries.ip_address` exists, nullable, `TEXT`, per §7.
- [ ] Every metric/view touching `rsvp_responses` or `guestbook_entries` filters `is_spam = FALSE`, with no exception.
- [ ] The live guestbook feed filters `moderation_status = 'approved'`; the live RSVP feed does not apply any moderation filter (it has no such column) and instead filters only `is_spam = FALSE`.
- [ ] `rsvp_by_group` (once Phase M migrates it at its fixed slot) correctly excludes `guest_id IS NULL` rows, confirming the open/personalized distinction is preserved end-to-end.
- [ ] `verified_guest_ratio` is computed exactly as `approved AND guest_id IS NOT NULL` over `approved` total.
- [ ] The 90-day raw-IP purge is implemented as a field-level null-out, not a row deletion.
- [ ] The RSVP endpoint enforces the cited 10 req/min/IP rate limit.
- [ ] Every flagged gap in this document (guestbook content column, RSVP resubmission, deadline enforcement, spam-detection algorithm, the public INSERT RLS policy, moderation-action route/permission) is recorded as an open item in project tracking — none is silently closed.

## 22. Completion Checklist

- [ ] §3–§6 (domain architecture, lifecycle, submission, status resolution) correctly distinguish what is cited from what is reasoned synthesis, and flag what is neither.
- [ ] §7 resolves the one column gap exactly as directed by its citation, with the remaining guestbook-content gap still flagged.
- [ ] §8–§10 (guestbook flow, moderation, spam protection) state the exact state machine and exclusion rule and flag the detection-algorithm and moderation-action gaps precisely.
- [ ] §11–§12 (personalized, open RSVP flows) resolve attribution exactly from the `rsvp_by_group` citation, with no invented mechanism.
- [ ] §13–§15 (analytics, guest-ownership integration) correctly cross-reference PHASE11/M8 without restating their content.
- [ ] §16 (public access rules) states precisely how far the citation goes on the INSERT-policy question and does not invent a `CREATE POLICY` to fill the gap.
- [ ] §20 confirms `037` as the only new migration.
- [ ] Tag `v1.0.0` once every item in §21 is verified.

**Once every box above is checked, the ⭐ MVP Milestone gate (per IMPLEMENTATION_ROADMAP.md) may be evaluated.**

---

*End of M9_RSVP_GUESTBOOK.md*
