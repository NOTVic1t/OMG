# PHASE9_RSVP_GUESTBOOK.md
# Wedding Invitation SaaS Platform — RSVP & Guestbook Architecture

> **Version:** 1.0.0
> **Date:** 2026-06-14
> **Status:** Approved for Development
> **Depends on:** PHASE1_ARCHITECTURE.md, PHASE2_DATABASE.md, PHASE3_AUTH.md, PHASE4_ADMIN_ARCHITECTURE.md, PHASE5_PACKAGE_FEATURE_SYSTEM.md, PHASE6_THEME_SYSTEM.md, PHASE7_INVITATION_MANAGEMENT.md, PHASE8_GUEST_MANAGEMENT.md

---

## Table of Contents

1. [RSVP Architecture](#1-rsvp-architecture)
2. [RSVP Data Model](#2-rsvp-data-model)
3. [Attendance Management](#3-attendance-management)
4. [RSVP Form System](#4-rsvp-form-system)
5. [Guestbook Architecture](#5-guestbook-architecture)
6. [Guestbook Moderation System](#6-guestbook-moderation-system)
7. [Anti-Spam Protection](#7-anti-spam-protection)
8. [Package Feature Integration](#8-package-feature-integration)
9. [RSVP Analytics Preparation](#9-rsvp-analytics-preparation)
10. [Notification Preparation](#10-notification-preparation)
11. [Public Guest Experience](#11-public-guest-experience)
12. [Permissions](#12-permissions)
13. [Multi-Tenant Security](#13-multi-tenant-security)
14. [Performance Optimization](#14-performance-optimization)
15. [Scalability Design](#15-scalability-design)
16. [Future Integrations](#16-future-integrations)

---

## 1. RSVP Architecture

### 1.1 System Overview

The RSVP system is a public-facing write endpoint layered on top of the invitation and guest management systems. It accepts attendance submissions from guests (authenticated via personal token or open link), stores them as immutable append-only records, and feeds real-time and analytical views for the invitation owner.

```
┌─────────────────────────────────────────────────────────────────────┐
│                        RSVP SYSTEM LAYERS                            │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  1. PUBLIC SUBMISSION LAYER                                  │   │
│  │     /api/rsvp · Rate-limited · No auth required             │   │
│  │     Token resolution · Validation · Spam protection         │   │
│  └──────────────────────────────┬──────────────────────────────┘   │
│                                 │                                   │
│  ┌──────────────────────────────▼──────────────────────────────┐   │
│  │  2. GATE LAYER                                               │   │
│  │     Invitation status = published                            │   │
│  │     is_rsvp_open = TRUE                                     │   │
│  │     rsvp_deadline not passed                                │   │
│  │     Feature: rsvp enabled for tenant package                │   │
│  └──────────────────────────────┬──────────────────────────────┘   │
│                                 │                                   │
│  ┌──────────────────────────────▼──────────────────────────────┐   │
│  │  3. DATA LAYER                                               │   │
│  │     rsvp_responses (append-only, immutable submissions)      │   │
│  │     Correlated to guests via guest_id (nullable)            │   │
│  └──────────────────────────────┬──────────────────────────────┘   │
│                                 │                                   │
│  ┌──────────────────────────────▼──────────────────────────────┐   │
│  │  4. OWNER DASHBOARD LAYER (auth-required)                    │   │
│  │     Real-time feed · Analytics · Export · Moderation        │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 RSVP Lifecycle

```
Guest receives personalized link or visits public invitation
  │
  ▼
GATE CHECK (all must pass):
  ├── invitation.status = 'published'
  ├── invitation.is_rsvp_open = TRUE
  ├── invitation.rsvp_deadline IS NULL OR >= TODAY
  └── feature 'rsvp' enabled for tenant's package
  │
  ├─ GATE FAILED → Show "RSVP Closed" message (no form rendered)
  │
  └─ GATE PASSED
       │
       ▼
  RSVP FORM rendered
  (personalized with guest name if token present)
       │
       ▼
  Guest fills form and submits
       │
       ▼
  Rate limit check (10 submissions / minute / IP)
  Duplicate check (guest_id already responded?)
       │
       ├─ DUPLICATE (tracked guest) → UPDATE latest response
       │  (not INSERT — one canonical response per tracked guest)
       │
       └─ NEW (open RSVP or first submission)
            │
            ▼
        INSERT into rsvp_responses
        Emit invitation_events row (event_type='rsvp_submit')
        Queue owner notification (email_notifications table)
        Broadcast via Supabase Realtime
            │
            ▼
        Guest sees confirmation message
```

### 1.3 RSVP States

```typescript
// types/rsvp.ts

export type AttendanceStatus =
  | 'attending'      // Guest confirmed attendance
  | 'not_attending'  // Guest declined
  | 'maybe';         // Guest is uncertain

export type RsvpGateStatus =
  | 'open'           // RSVP form is accepting submissions
  | 'closed'         // is_rsvp_open = FALSE (owner manually closed)
  | 'deadline_passed'// rsvp_deadline < TODAY
  | 'not_published'  // invitation.status != 'published'
  | 'feature_disabled'; // 'rsvp' feature not enabled for package

export function resolveRsvpGateStatus(
  invitation: InvitationGateData,
  rsvpFeatureEnabled: boolean
): RsvpGateStatus {
  if (invitation.status !== 'published')  return 'not_published';
  if (!rsvpFeatureEnabled)                return 'feature_disabled';
  if (!invitation.is_rsvp_open)           return 'closed';
  if (
    invitation.rsvp_deadline &&
    new Date(invitation.rsvp_deadline) < new Date()
  ) return 'deadline_passed';
  return 'open';
}
```

### 1.4 Duplicate Handling Strategy

**Tracked guests** (submitted via `?t=[personal_token]`) have `guest_id` on their response. Only one canonical response is kept — subsequent submissions from the same tracked guest **overwrite** the previous response.

**Open guests** (no token, public RSVP form) always produce new rows. Deduplication is the owner's responsibility via the dashboard (they can filter by phone/email).

```
guest_id IS NOT NULL (tracked):
  → Upsert: UPDATE rsvp_responses SET ... WHERE guest_id = $id AND invitation_id = $inv
  → Only one response per tracked guest per invitation

guest_id IS NULL (open):
  → Always INSERT
  → Multiple rows allowed for same name/phone (family members using same phone)
```

### 1.5 RSVP Workflow — Owner Side

```
Owner Dashboard /invitations/[id]/rsvp
  │
  ├── Summary Cards (total, attending, not_attending, maybe, total_pax)
  │
  ├── Controls
  │   ├── Toggle: is_rsvp_open
  │   ├── DatePicker: rsvp_deadline
  │   └── Button: Export CSV (feature-gated)
  │
  ├── Response Table (real-time via Supabase Realtime)
  │   ├── Name · Attendance · Pax · Meal · Message · Submitted At
  │   └── New rows animate in at top
  │
  └── Per-Category breakdown (Bride Side / Groom Side / Mutual)
```

---

## 2. RSVP Data Model

### 2.1 Extended `rsvp_responses` Table

The base table from PHASE2 is extended with fields to support meal choice, plus-one, custom question answers, and spam scoring.

```sql
-- Extended from PHASE2 Domain 6

CREATE TABLE rsvp_responses (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Ownership
  invitation_id   UUID        NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  guest_id        UUID        REFERENCES guests(id) ON DELETE SET NULL,
  -- null = open RSVP (no personalized link)
  tenant_id       UUID        NOT NULL REFERENCES tenants(id),
  -- Denormalized for RLS performance

  -- Respondent identity
  name            TEXT        NOT NULL,
  email           TEXT,
  phone           TEXT,

  -- Core RSVP
  attendance      TEXT        NOT NULL
                              CHECK (attendance IN ('attending', 'not_attending', 'maybe')),
  pax_count       INTEGER     NOT NULL DEFAULT 1
                              CHECK (pax_count >= 1 AND pax_count <= 50),

  -- Extended fields (feature-gated)
  meal_choice     TEXT,
  -- populated when rsvp_meal_choice feature enabled
  -- free-text or enum value; owner defines options in section content JSONB

  has_plus_one    BOOLEAN     NOT NULL DEFAULT FALSE,
  -- populated when rsvp_plus_one feature enabled

  plus_one_name   TEXT,
  -- name of the plus-one guest (optional)

  -- Message / wishes
  message         TEXT,
  -- Short personal message to couple (shown in dashboard, not public)

  wishes          TEXT,
  -- Public wish displayed on guestbook wall (if rsvp_wishes_wall feature enabled)

  -- Custom question answers (feature-gated, stored as JSONB)
  custom_answers  JSONB       NOT NULL DEFAULT '{}',
  -- Shape: { "question_id": "answer_value", ... }
  -- Question definitions live in invitation_sections.content for 'rsvp' section

  -- Submission metadata
  submitted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ip_address      INET,
  user_agent      TEXT,
  referrer        TEXT,
  -- 'personalized_link' | 'direct' | 'whatsapp' | 'instagram' | etc.

  -- Spam / quality scoring
  spam_score      SMALLINT    NOT NULL DEFAULT 0,
  -- 0 = clean, 100 = confirmed spam; computed by anti-spam checks
  is_spam         BOOLEAN     NOT NULL DEFAULT FALSE,
  -- TRUE = hidden from owner dashboard by default

  -- Audit
  metadata        JSONB       NOT NULL DEFAULT '{}'
  -- { user_agent_parsed, screen_width, timezone, locale }
);

-- Indexes
CREATE INDEX idx_rsvp_invitation      ON rsvp_responses(invitation_id);
CREATE INDEX idx_rsvp_tenant          ON rsvp_responses(tenant_id);
CREATE INDEX idx_rsvp_guest           ON rsvp_responses(guest_id) WHERE guest_id IS NOT NULL;
CREATE INDEX idx_rsvp_attendance      ON rsvp_responses(invitation_id, attendance)
  WHERE is_spam = FALSE;
CREATE INDEX idx_rsvp_submitted       ON rsvp_responses(invitation_id, submitted_at DESC)
  WHERE is_spam = FALSE;
CREATE INDEX idx_rsvp_ip              ON rsvp_responses(ip_address, submitted_at DESC);
-- For spam/rate-limit analysis:
CREATE INDEX idx_rsvp_ip_inv          ON rsvp_responses(invitation_id, ip_address, submitted_at DESC);
```

### 2.2 RSVP Custom Questions Schema

Custom questions are defined in `invitation_sections.content` for the `rsvp` section type. This keeps question definitions close to the invitation without a separate table.

```typescript
// Content shape for rsvp section (extended)
interface RsvpSectionContent {
  form_title:          string;
  attending_label:     string;
  not_attending_label: string;
  maybe_label:         string;
  submit_label:        string;
  success_message:     string;

  // Feature-gated fields
  meal_choice_enabled: boolean;
  meal_options:        string[];   // e.g. ["Beef", "Chicken", "Vegetarian"]
  plus_one_enabled:    boolean;
  wishes_enabled:      boolean;   // rsvp_wishes_wall feature

  // Custom questions (feature-gated: custom_rsvp_questions — Phase 3+)
  custom_questions: Array<{
    id:       string;  // UUID
    label:    string;
    type:     'text' | 'select' | 'checkbox';
    options?: string[];
    required: boolean;
  }>;
}
```

### 2.3 RSVP TypeScript Types

```typescript
// types/rsvp.ts

export interface RsvpResponse {
  id:             string;
  invitation_id:  string;
  guest_id:       string | null;
  tenant_id:      string;
  name:           string;
  email:          string | null;
  phone:          string | null;
  attendance:     AttendanceStatus;
  pax_count:      number;
  meal_choice:    string | null;
  has_plus_one:   boolean;
  plus_one_name:  string | null;
  message:        string | null;
  wishes:         string | null;
  custom_answers: Record<string, unknown>;
  submitted_at:   string;
  ip_address:     string | null;
  is_spam:        boolean;
  spam_score:     number;
  metadata:       Record<string, unknown>;
}

export interface RsvpSubmissionInput {
  name:           string;
  attendance:     AttendanceStatus;
  pax_count?:     number;
  email?:         string;
  phone?:         string;
  meal_choice?:   string;
  has_plus_one?:  boolean;
  plus_one_name?: string;
  message?:       string;
  wishes?:        string;
  custom_answers?: Record<string, unknown>;
  // Honeypot field — must be empty
  website?:       string;
}

export interface RsvpSummary {
  total:           number;
  attending:       number;
  not_attending:   number;
  maybe:           number;
  pending:         number;   // guests with no response (tracked guests only)
  total_pax:       number;   // sum of pax_count for attending responses
  response_rate:   number;   // (total / total_tracked_guests) * 100
}
```

### 2.4 Entity Relationships

```
invitations ──────────────────────────────────────────────────────────
  │ 1                                          │ 1
  ▼ ∞                                          ▼ ∞
rsvp_responses                          guestbook_entries
  │ (guest_id nullable)                   (guest_id nullable)
  │
  ▼
guests (tracked respondents)

tenants ──► rsvp_responses.tenant_id    (denormalized, RLS)
tenants ──► guestbook_entries.tenant_id (denormalized, RLS)

rsvp_responses.invitation_id ──► invitations.id (CASCADE DELETE)
rsvp_responses.guest_id      ──► guests.id      (SET NULL on delete)
rsvp_responses.tenant_id     ──► tenants.id
```

---

## 3. Attendance Management

### 3.1 Individual Attendance

Each `rsvp_responses` row represents one submission. For tracked guests (`guest_id IS NOT NULL`), only the most recent row is the canonical response — older rows are historical audit entries.

```typescript
// lib/rsvp/attendance.ts

// Get canonical attendance for a tracked guest
export async function getGuestAttendance(
  supabase: SupabaseClient,
  guestId: string
): Promise<RsvpResponse | null> {
  const { data } = await supabase
    .from('rsvp_responses')
    .select('*')
    .eq('guest_id', guestId)
    .eq('is_spam', false)
    .order('submitted_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  return data;
}
```

### 3.2 Family / Group Attendance

Families are represented in two ways:

**Option A — Single entry with `pax_count`:** One RSVP response with `pax_count = 4` represents "The Ahmad Family, 4 people attending." This is the simplest and most common pattern.

**Option B — Multiple guests with same group:** The Ahmad family is entered as 4 separate `guests` rows in the same `group_id`. Each submits their own RSVP response. This enables per-person meal choices.

```typescript
// Attendance summary aggregation respects pax_count
export async function getAttendanceSummary(
  supabase: SupabaseClient,
  invitationId: string
): Promise<RsvpSummary> {
  // Use a single aggregate query to avoid N+1
  const { data } = await supabase.rpc('get_rsvp_summary', {
    p_invitation_id: invitationId,
  });
  return data;
}
```

```sql
-- supabase/migrations/081_rsvp_summary_fn.sql

CREATE OR REPLACE FUNCTION get_rsvp_summary(p_invitation_id UUID)
RETURNS JSONB AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'total',         COUNT(*),
    'attending',     COUNT(*) FILTER (WHERE attendance = 'attending'),
    'not_attending', COUNT(*) FILTER (WHERE attendance = 'not_attending'),
    'maybe',         COUNT(*) FILTER (WHERE attendance = 'maybe'),
    'total_pax',     COALESCE(SUM(pax_count) FILTER (WHERE attendance = 'attending'), 0)
  )
  INTO v_result
  FROM rsvp_responses
  WHERE invitation_id = p_invitation_id
    AND is_spam = FALSE;

  RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;
```

### 3.3 Multiple Guest Attendance (Plus-One)

When the `rsvp_plus_one` feature is enabled, the RSVP form shows a "Bringing a guest?" toggle.

```typescript
// Pax count computation when plus_one is enabled:
// pax_count = 1 (self) + 1 (plus_one) = 2
// This is surfaced as "Attending for 2" in the dashboard

// Plus-one data stored on rsvp_responses:
// has_plus_one = true
// plus_one_name = "Siti Rahayu" (optional)
// pax_count = 2 (automatically set when has_plus_one = true)
```

### 3.4 Seat Reservation Preparation

The current schema does not implement seat reservation. The data structures are prepared for Phase 3+:

```sql
-- Phase 3+: seat_reservations table (not implemented in Phase 1-2)
-- Connects rsvp_responses → seating plan

-- Prepared FK hook: rsvp_responses.id is UUID (referenceable)
-- Prepared column: rsvp_responses.pax_count (seats needed)
-- Prepared column: guests.expected_pax (pre-event seat estimate)

-- Future migration pattern:
-- CREATE TABLE seat_reservations (
--   id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
--   invitation_id   UUID NOT NULL REFERENCES invitations(id),
--   rsvp_response_id UUID REFERENCES rsvp_responses(id),
--   table_number    TEXT,
--   seat_numbers    TEXT[],
--   assigned_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
-- );
```

---

## 4. RSVP Form System

### 4.1 Form Architecture

The RSVP form is rendered as part of the public invitation page's `rsvp` section. It is a **server-rendered form with client-side progressive enhancement** — it must work without JavaScript on slow connections.

```
Public invitation page (/inv/[slug])
  │
  ▼
RSVP Section rendered by theme (RsvpSection.tsx)
  │
  ├── Gate check (server-side, in page data load):
  │   resolveRsvpGateStatus() → 'open' | 'closed' | ...
  │
  ├── If gate = 'open':
  │   Render <RsvpForm> (shared component across all themes)
  │
  └── If gate != 'open':
      Render <RsvpClosedNotice> with appropriate message
```

### 4.2 Shared RsvpForm Component

```typescript
// components/invitation/shared/RsvpForm.tsx

'use client';

import { useState, useTransition } from 'react';
import { z } from 'zod';
import { submitRsvpAction } from '@/app/inv/[slug]/actions';

interface RsvpFormProps {
  invitationId:    string;
  slug:            string;
  guestToken?:     string;    // from ?t= query param
  guestName?:      string;    // pre-filled from guest record
  sectionContent:  RsvpSectionContent;
  features: {
    meal_choice:   boolean;
    plus_one:      boolean;
    wishes_wall:   boolean;
  };
}

export function RsvpForm({
  invitationId,
  slug,
  guestToken,
  guestName,
  sectionContent,
  features,
}: RsvpFormProps) {
  const [isPending, startTransition] = useTransition();
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [attendance, setAttendance] = useState<AttendanceStatus | null>(null);

  const handleSubmit = (formData: FormData) => {
    startTransition(async () => {
      const result = await submitRsvpAction(slug, guestToken ?? null, formData);
      if (result.success) {
        setSubmitted(true);
      } else {
        setError(result.error ?? 'Submission failed. Please try again.');
      }
    });
  };

  if (submitted) {
    return (
      <div className="text-center py-8">
        <CheckCircleIcon className="h-12 w-12 mx-auto text-green-500 mb-4" />
        <p className="text-lg font-medium" style={{ color: 'var(--color-primary)' }}>
          {sectionContent.success_message}
        </p>
      </div>
    );
  }

  return (
    <form action={handleSubmit} className="space-y-6 mx-auto max-w-md px-4">
      {/* Honeypot — hidden from real users, triggers spam flag if filled */}
      <input type="text" name="website" className="sr-only" tabIndex={-1} aria-hidden="true" />

      {/* Name */}
      <div>
        <label className="block text-sm font-medium mb-1" style={{ color: 'var(--color-text-primary)' }}>
          Your Name <span className="text-red-500">*</span>
        </label>
        <input
          type="text"
          name="name"
          defaultValue={guestName ?? ''}
          required
          maxLength={150}
          className="w-full rounded-lg border px-4 py-3 text-base focus:outline-none focus:ring-2"
          style={{ borderColor: 'var(--color-secondary)', color: 'var(--color-text-primary)' }}
        />
      </div>

      {/* Attendance */}
      <fieldset>
        <legend className="block text-sm font-medium mb-2" style={{ color: 'var(--color-text-primary)' }}>
          Attendance <span className="text-red-500">*</span>
        </legend>
        <div className="space-y-2">
          {(['attending', 'not_attending', 'maybe'] as AttendanceStatus[]).map(status => {
            const label = status === 'attending'
              ? sectionContent.attending_label
              : status === 'not_attending'
                ? sectionContent.not_attending_label
                : sectionContent.maybe_label;
            return (
              <label
                key={status}
                className={`flex cursor-pointer items-center gap-3 rounded-xl border-2 p-4 transition
                  ${attendance === status ? 'border-[var(--color-primary)]' : 'border-[var(--color-secondary)]'}`}
              >
                <input
                  type="radio"
                  name="attendance"
                  value={status}
                  required
                  className="sr-only"
                  onChange={() => setAttendance(status)}
                />
                <span className={`h-5 w-5 flex-shrink-0 rounded-full border-2 flex items-center justify-center
                  ${attendance === status ? 'border-[var(--color-primary)]' : 'border-gray-300'}`}>
                  {attendance === status && (
                    <span className="h-2.5 w-2.5 rounded-full bg-[var(--color-primary)]" />
                  )}
                </span>
                <span className="text-base" style={{ color: 'var(--color-text-primary)' }}>{label}</span>
              </label>
            );
          })}
        </div>
      </fieldset>

      {/* Pax count — shown only when attending */}
      {attendance === 'attending' && (
        <div>
          <label className="block text-sm font-medium mb-1" style={{ color: 'var(--color-text-primary)' }}>
            Number of Attendees
          </label>
          <select
            name="pax_count"
            className="w-full rounded-lg border px-4 py-3 text-base"
            style={{ borderColor: 'var(--color-secondary)' }}
          >
            {Array.from({ length: 10 }, (_, i) => i + 1).map(n => (
              <option key={n} value={n}>{n} {n === 1 ? 'person' : 'people'}</option>
            ))}
          </select>
        </div>
      )}

      {/* Meal Choice (feature-gated) */}
      {features.meal_choice && attendance === 'attending' && sectionContent.meal_options.length > 0 && (
        <div>
          <label className="block text-sm font-medium mb-1" style={{ color: 'var(--color-text-primary)' }}>
            Meal Preference
          </label>
          <select name="meal_choice" className="w-full rounded-lg border px-4 py-3 text-base" style={{ borderColor: 'var(--color-secondary)' }}>
            <option value="">Select meal...</option>
            {sectionContent.meal_options.map(opt => (
              <option key={opt} value={opt}>{opt}</option>
            ))}
          </select>
        </div>
      )}

      {/* Plus One (feature-gated) */}
      {features.plus_one && attendance === 'attending' && (
        <div className="space-y-3">
          <label className="flex items-center gap-3 cursor-pointer">
            <input type="checkbox" name="has_plus_one" value="true" className="h-4 w-4 rounded" />
            <span className="text-sm" style={{ color: 'var(--color-text-primary)' }}>
              I am bringing a plus-one
            </span>
          </label>
          <input
            type="text"
            name="plus_one_name"
            placeholder="Plus-one name (optional)"
            maxLength={150}
            className="w-full rounded-lg border px-4 py-3 text-base"
            style={{ borderColor: 'var(--color-secondary)' }}
          />
        </div>
      )}

      {/* Message */}
      <div>
        <label className="block text-sm font-medium mb-1" style={{ color: 'var(--color-text-primary)' }}>
          Message for the Couple <span className="text-gray-400 font-normal">(optional)</span>
        </label>
        <textarea
          name="message"
          rows={3}
          maxLength={500}
          className="w-full rounded-lg border px-4 py-3 text-base resize-none"
          style={{ borderColor: 'var(--color-secondary)' }}
        />
      </div>

      {/* Wishes Wall (feature-gated) */}
      {features.wishes_wall && (
        <div>
          <label className="block text-sm font-medium mb-1" style={{ color: 'var(--color-text-primary)' }}>
            Public Wishes <span className="text-gray-400 font-normal">(shown on wishes wall)</span>
          </label>
          <textarea
            name="wishes"
            rows={3}
            maxLength={300}
            className="w-full rounded-lg border px-4 py-3 text-base resize-none"
            style={{ borderColor: 'var(--color-secondary)' }}
          />
        </div>
      )}

      {error && (
        <p className="text-sm text-red-600 text-center">{error}</p>
      )}

      <button
        type="submit"
        disabled={isPending || !attendance}
        className="w-full rounded-xl py-4 text-base font-semibold text-white transition disabled:opacity-50"
        style={{ backgroundColor: 'var(--color-primary)' }}
      >
        {isPending ? 'Sending...' : sectionContent.submit_label}
      </button>
    </form>
  );
}
```

### 4.3 RSVP Submission Server Action

```typescript
// app/inv/[slug]/actions.ts
'use server';

import { z } from 'zod';
import { createServerClient } from '@/lib/supabase/server';
import { resolveFeature } from '@/lib/packages/feature-resolver';
import { checkRsvpRateLimit } from '@/lib/rsvp/rate-limit';
import { computeSpamScore } from '@/lib/rsvp/spam-detector';
import { resolveRsvpGateStatus } from '@/lib/rsvp/gate';
import { headers } from 'next/headers';

const RsvpSubmissionSchema = z.object({
  name:          z.string().min(1).max(150).trim(),
  attendance:    z.enum(['attending', 'not_attending', 'maybe']),
  pax_count:     z.coerce.number().int().min(1).max(50).default(1),
  email:         z.string().email().max(254).optional().or(z.literal('')),
  phone:         z.string().max(20).optional().or(z.literal('')),
  meal_choice:   z.string().max(100).optional().or(z.literal('')),
  has_plus_one:  z.coerce.boolean().default(false),
  plus_one_name: z.string().max(150).optional().or(z.literal('')),
  message:       z.string().max(500).optional().or(z.literal('')),
  wishes:        z.string().max(300).optional().or(z.literal('')),
  website:       z.string().optional(), // honeypot
});

export async function submitRsvpAction(
  slug: string,
  guestToken: string | null,
  formData: FormData
): Promise<{ success: boolean; error?: string }> {
  const headersList = headers();
  const ip = headersList.get('x-forwarded-for')?.split(',')[0]?.trim() ?? 'unknown';
  const userAgent = headersList.get('user-agent') ?? '';

  // Parse + validate
  const parsed = RsvpSubmissionSchema.safeParse(Object.fromEntries(formData));
  if (!parsed.success) {
    return { success: false, error: 'Please fill in all required fields correctly.' };
  }

  // Honeypot trap — bots fill all fields including hidden ones
  if (parsed.data.website) {
    // Silently succeed (don't tell bots they were caught)
    return { success: true };
  }

  // Rate limiting: 10 submissions per minute per IP
  const rateLimited = await checkRsvpRateLimit(ip);
  if (rateLimited) {
    return { success: false, error: 'Too many submissions. Please wait a moment and try again.' };
  }

  const supabase = createServerClient();

  // Fetch invitation with gate data
  const { data: invitation } = await supabase
    .from('invitations')
    .select('id, tenant_id, is_rsvp_open, rsvp_deadline, status')
    .eq('slug', slug)
    .single();

  if (!invitation) return { success: false, error: 'Invitation not found.' };

  // Resolve package features for this tenant
  const { data: sub } = await supabase
    .from('tenant_subscriptions')
    .select('package_id')
    .eq('tenant_id', invitation.tenant_id)
    .in('status', ['active', 'trialing'])
    .single();

  const rsvpFeature = await resolveFeature(
    { tenantId: invitation.tenant_id, packageId: sub?.package_id ?? '' },
    'rsvp'
  );

  // Gate check
  const gateStatus = resolveRsvpGateStatus(invitation, rsvpFeature.enabled);
  if (gateStatus !== 'open') {
    return { success: false, error: 'RSVP is currently not available for this invitation.' };
  }

  // Resolve guest from token (if provided)
  let guestId: string | null = null;
  if (guestToken) {
    const { data: guest } = await supabase
      .from('guests')
      .select('id')
      .eq('personal_token', guestToken)
      .eq('invitation_id', invitation.id)
      .is('deleted_at', null)
      .maybeSingle();
    guestId = guest?.id ?? null;
  }

  // Compute spam score
  const spamScore = await computeSpamScore({
    ip,
    invitationId: invitation.id,
    name: parsed.data.name,
    email: parsed.data.email || null,
    message: parsed.data.message || null,
  });

  const payload = {
    invitation_id:  invitation.id,
    tenant_id:      invitation.tenant_id,
    guest_id:       guestId,
    name:           parsed.data.name,
    email:          parsed.data.email || null,
    phone:          parsed.data.phone || null,
    attendance:     parsed.data.attendance,
    pax_count:      parsed.data.pax_count,
    meal_choice:    parsed.data.meal_choice || null,
    has_plus_one:   parsed.data.has_plus_one,
    plus_one_name:  parsed.data.plus_one_name || null,
    message:        parsed.data.message || null,
    wishes:         parsed.data.wishes || null,
    ip_address:     ip,
    user_agent:     userAgent,
    spam_score:     spamScore,
    is_spam:        spamScore >= 70,
    metadata:       { referrer: guestToken ? 'personalized_link' : 'direct' },
  };

  if (guestId) {
    // Tracked guest: upsert (update if exists, insert if first time)
    const { error } = await supabase
      .from('rsvp_responses')
      .upsert(payload, {
        onConflict: 'guest_id,invitation_id',
        ignoreDuplicates: false,
      });
    if (error) return { success: false, error: 'Failed to save your response. Please try again.' };
  } else {
    // Open RSVP: always insert
    const { error } = await supabase
      .from('rsvp_responses')
      .insert(payload);
    if (error) return { success: false, error: 'Failed to save your response. Please try again.' };
  }

  // Emit analytics event
  await supabase.from('invitation_events').insert({
    invitation_id: invitation.id,
    tenant_id:     invitation.tenant_id,
    event_type:    'rsvp_submit',
    guest_id:      guestId,
    metadata:      { attendance: parsed.data.attendance, pax: parsed.data.pax_count },
  });

  // Queue owner notification
  await supabase.from('email_notifications').insert({
    tenant_id:      invitation.tenant_id,
    invitation_id:  invitation.id,
    template_key:   'rsvp_received',
    status:         'pending',
    metadata:       {
      respondent_name: parsed.data.name,
      attendance:      parsed.data.attendance,
      pax_count:       parsed.data.pax_count,
    },
  });

  return { success: true };
}
```

### 4.4 UPSERT Constraint for Tracked Guests

To support the upsert pattern for tracked guests, a unique partial index is required:

```sql
-- supabase/migrations/082_rsvp_tracked_unique.sql

-- Only one canonical response per tracked guest per invitation
-- (open RSVP responses have guest_id IS NULL, so they bypass this constraint)
CREATE UNIQUE INDEX idx_rsvp_guest_inv_unique
  ON rsvp_responses(guest_id, invitation_id)
  WHERE guest_id IS NOT NULL;
```

---

## 5. Guestbook Architecture

### 5.1 System Overview

The Guestbook is a public **wishes wall** where guests can post short messages of congratulation. Unlike RSVP responses (which are private to the owner), guestbook entries are publicly displayed on the invitation page (subject to moderation). Guestbook is a separate feature from RSVP — it has its own feature flag and can be enabled/disabled independently.

```
┌─────────────────────────────────────────────────────────────────────┐
│                     GUESTBOOK SYSTEM LAYERS                          │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  1. PUBLIC SUBMISSION LAYER                                  │   │
│  │     /api/guestbook · Rate-limited · No auth required        │   │
│  └──────────────────────────────┬──────────────────────────────┘   │
│                                 │                                   │
│  ┌──────────────────────────────▼──────────────────────────────┐   │
│  │  2. MODERATION LAYER                                         │   │
│  │     Auto-approve (default) or Manual-approve (feature-gated) │   │
│  │     Spam scoring → auto-reject if score ≥ 70                │   │
│  └──────────────────────────────┬──────────────────────────────┘   │
│                                 │                                   │
│  ┌──────────────────────────────▼──────────────────────────────┐   │
│  │  3. DISPLAY LAYER (public, append-only scroll)               │   │
│  │     Shows approved entries · Real-time via Realtime          │   │
│  └──────────────────────────────┬──────────────────────────────┘   │
│                                 │                                   │
│  ┌──────────────────────────────▼──────────────────────────────┐   │
│  │  4. OWNER MODERATION LAYER (auth-required)                   │   │
│  │     Approve / Reject / Hide / Delete entries                 │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### 5.2 Extended `guestbook_entries` Table

```sql
-- Extended from PHASE2 Domain 6

CREATE TABLE guestbook_entries (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Ownership
  invitation_id   UUID        NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  tenant_id       UUID        NOT NULL REFERENCES tenants(id),

  -- Author
  guest_id        UUID        REFERENCES guests(id) ON DELETE SET NULL,
  -- null = anonymous / non-tracked submitter
  name            TEXT        NOT NULL,
  -- Verified if guest_id IS NOT NULL, unverified otherwise

  -- Content
  message         TEXT        NOT NULL,

  -- Moderation
  moderation_status TEXT      NOT NULL DEFAULT 'approved'
                              CHECK (moderation_status IN ('pending', 'approved', 'rejected', 'hidden')),
  -- 'pending'  = awaiting manual review (when moderation feature enabled)
  -- 'approved' = visible on public guestbook wall
  -- 'rejected' = not shown; owner decided to reject
  -- 'hidden'   = owner hid after initial approval (soft hide, reversible)

  moderated_by    UUID        REFERENCES users(id),
  moderated_at    TIMESTAMPTZ,
  moderation_note TEXT,
  -- Private note from owner explaining decision

  -- Spam
  is_spam         BOOLEAN     NOT NULL DEFAULT FALSE,
  spam_score      SMALLINT    NOT NULL DEFAULT 0,

  -- Submission metadata
  submitted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ip_address      INET,
  user_agent      TEXT
);

-- Indexes
CREATE INDEX idx_guestbook_inv_approved
  ON guestbook_entries(invitation_id, submitted_at DESC)
  WHERE moderation_status = 'approved' AND is_spam = FALSE;

CREATE INDEX idx_guestbook_inv_pending
  ON guestbook_entries(invitation_id, submitted_at DESC)
  WHERE moderation_status = 'pending';

CREATE INDEX idx_guestbook_tenant
  ON guestbook_entries(tenant_id, submitted_at DESC);

CREATE INDEX idx_guestbook_guest
  ON guestbook_entries(guest_id)
  WHERE guest_id IS NOT NULL;

CREATE INDEX idx_guestbook_ip
  ON guestbook_entries(ip_address, submitted_at DESC);
```

### 5.3 Guestbook TypeScript Types

```typescript
// types/guestbook.ts

export type ModerationStatus = 'pending' | 'approved' | 'rejected' | 'hidden';

export interface GuestbookEntry {
  id:                string;
  invitation_id:     string;
  tenant_id:         string;
  guest_id:          string | null;
  name:              string;
  message:           string;
  moderation_status: ModerationStatus;
  moderated_by:      string | null;
  moderated_at:      string | null;
  moderation_note:   string | null;
  is_spam:           boolean;
  spam_score:        number;
  submitted_at:      string;
  ip_address:        string | null;
  // Derived: guest_id IS NOT NULL → verified badge
  is_verified:       boolean;
}

export interface GuestbookSubmissionInput {
  name:     string;
  message:  string;
  website?: string;  // honeypot
}
```

### 5.4 Author Tracking

When a guest submits the guestbook form via their personalized link, the `guest_id` is populated and the entry is marked as **verified**. This allows the guestbook wall to display a verified badge.

```typescript
// Public guestbook wall display:
// [✓ Verified]  Andi Prasetyo: "Cannot wait for your big day! 💕"
// [  Public]    Anonymous: "Best wishes to the happy couple!"

// The verified badge comes from:
// guestbook_entries.guest_id IS NOT NULL
```

### 5.5 Guestbook Submission Server Action

```typescript
// app/inv/[slug]/guestbook-actions.ts
'use server';

import { z } from 'zod';

const GuestbookSchema = z.object({
  name:    z.string().min(1).max(150).trim(),
  message: z.string().min(1).max(500).trim(),
  website: z.string().optional(), // honeypot
});

export async function submitGuestbookAction(
  slug: string,
  guestToken: string | null,
  formData: FormData
): Promise<{ success: boolean; error?: string }> {
  const headersList = headers();
  const ip = headersList.get('x-forwarded-for')?.split(',')[0]?.trim() ?? 'unknown';

  const parsed = GuestbookSchema.safeParse(Object.fromEntries(formData));
  if (!parsed.success) {
    return { success: false, error: 'Please fill in your name and message.' };
  }

  // Honeypot check
  if (parsed.data.website) return { success: true };

  // Rate limit: 5 submissions per minute per IP
  const rateLimited = await checkGuestbookRateLimit(ip);
  if (rateLimited) {
    return { success: false, error: 'Please wait before submitting again.' };
  }

  const supabase = createServerClient();

  // Fetch invitation and check guestbook feature
  const { data: invitation } = await supabase
    .from('invitations')
    .select('id, tenant_id, status')
    .eq('slug', slug)
    .single();

  if (!invitation || invitation.status !== 'published') {
    return { success: false, error: 'Invitation not found.' };
  }

  // Check guestbook feature enabled
  const { data: sub } = await supabase
    .from('tenant_subscriptions')
    .select('package_id')
    .eq('tenant_id', invitation.tenant_id)
    .in('status', ['active', 'trialing'])
    .single();

  const guestbookFeature = await resolveFeature(
    { tenantId: invitation.tenant_id, packageId: sub?.package_id ?? '' },
    'guestbook'
  );
  if (!guestbookFeature.enabled) {
    return { success: false, error: 'Guestbook is not enabled for this invitation.' };
  }

  // Check moderation mode
  const moderationFeature = await resolveFeature(
    { tenantId: invitation.tenant_id, packageId: sub?.package_id ?? '' },
    'guestbook_moderation'
  );

  // Resolve guest from token
  let guestId: string | null = null;
  if (guestToken) {
    const { data: guest } = await supabase
      .from('guests')
      .select('id')
      .eq('personal_token', guestToken)
      .eq('invitation_id', invitation.id)
      .is('deleted_at', null)
      .maybeSingle();
    guestId = guest?.id ?? null;
  }

  // Spam score
  const spamScore = await computeSpamScore({
    ip,
    invitationId: invitation.id,
    name: parsed.data.name,
    message: parsed.data.message,
  });

  // Moderation status:
  // - If guestbook_moderation feature enabled → 'pending'
  // - If spam score >= 70 → is_spam = true, moderation_status = 'rejected'
  // - Otherwise → 'approved'
  let moderationStatus: ModerationStatus = 'approved';
  if (spamScore >= 70) {
    moderationStatus = 'rejected';
  } else if (moderationFeature.enabled) {
    moderationStatus = 'pending';
  }

  const { error } = await supabase.from('guestbook_entries').insert({
    invitation_id:     invitation.id,
    tenant_id:         invitation.tenant_id,
    guest_id:          guestId,
    name:              parsed.data.name,
    message:           parsed.data.message,
    moderation_status: moderationStatus,
    is_spam:           spamScore >= 70,
    spam_score:        spamScore,
    ip_address:        ip,
    user_agent:        headers().get('user-agent') ?? '',
  });

  if (error) return { success: false, error: 'Failed to save your message. Please try again.' };

  // Emit analytics event
  await supabase.from('invitation_events').insert({
    invitation_id: invitation.id,
    tenant_id:     invitation.tenant_id,
    event_type:    'guestbook_submit',
    guest_id:      guestId,
    metadata:      { moderation_status: moderationStatus },
  });

  return { success: true };
}
```

---

## 6. Guestbook Moderation System

### 6.1 Moderation States

```
SUBMITTED
  │
  ▼
SPAM SCORE CHECK
  ├── score >= 70 → moderation_status = 'rejected', is_spam = true
  │                 (never shown publicly; owner can override)
  │
  └── score < 70
        │
        ├── guestbook_moderation feature OFF → moderation_status = 'approved'
        │   (immediately visible on public guestbook wall)
        │
        └── guestbook_moderation feature ON → moderation_status = 'pending'
            (not visible until owner approves)
            │
            ▼
            OWNER REVIEWS
              ├── APPROVE → moderation_status = 'approved'
              ├── REJECT  → moderation_status = 'rejected'
              └── IGNORE  → stays 'pending' (hidden from public)

APPROVED entries can later be HIDDEN:
  approved → hidden (soft hide, reversible by owner)
```

### 6.2 Moderation API

```typescript
// app/api/invitations/[id]/guestbook/[entryId]/route.ts

const ModerationSchema = z.object({
  moderation_status: z.enum(['approved', 'rejected', 'hidden']),
  moderation_note:   z.string().max(500).optional(),
});

export async function PATCH(
  request: Request,
  { params }: { params: { id: string; entryId: string } }
) {
  const auth = await requireAuth(request, 'rsvp:read');
  // rsvp:read covers guestbook moderation (owner/editor)
  if (auth instanceof NextResponse) return auth;

  const parsed = ModerationSchema.safeParse(await request.json());
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.flatten() }, { status: 422 });
  }

  const supabase = createServerClient();

  const { error } = await supabase
    .from('guestbook_entries')
    .update({
      moderation_status: parsed.data.moderation_status,
      moderation_note:   parsed.data.moderation_note ?? null,
      moderated_by:      auth.user.id,
      moderated_at:      new Date().toISOString(),
    })
    .eq('id', params.entryId)
    .eq('invitation_id', params.id)
    .eq('tenant_id', auth.user.tenantId);

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  return NextResponse.json({ success: true });
}
```

### 6.3 Bulk Moderation

```typescript
// app/api/invitations/[id]/guestbook/bulk-moderate/route.ts

const BulkModerateSchema = z.object({
  entry_ids:         z.array(z.string().uuid()).min(1).max(100),
  moderation_status: z.enum(['approved', 'rejected', 'hidden']),
});

export async function POST(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'rsvp:read');
  if (auth instanceof NextResponse) return auth;

  const parsed = BulkModerateSchema.safeParse(await request.json());
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.flatten() }, { status: 422 });
  }

  const supabase = createServerClient();

  const { count, error } = await supabase
    .from('guestbook_entries')
    .update({
      moderation_status: parsed.data.moderation_status,
      moderated_by:      auth.user.id,
      moderated_at:      new Date().toISOString(),
    })
    .in('id', parsed.data.entry_ids)
    .eq('invitation_id', params.id)
    .eq('tenant_id', auth.user.tenantId);

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  return NextResponse.json({ moderated: count });
}
```

### 6.4 Guestbook Wall Component (Public)

```typescript
// components/invitation/shared/GuestbookWall.tsx

'use client';

import { useEffect, useState } from 'react';
import { createBrowserClient } from '@/lib/supabase/client';

interface GuestbookWallProps {
  invitationId:     string;
  initialEntries:   GuestbookEntry[];
  sectionContent:   GuestbookSectionContent;
}

export function GuestbookWall({
  invitationId,
  initialEntries,
  sectionContent,
}: GuestbookWallProps) {
  const [entries, setEntries] = useState<GuestbookEntry[]>(initialEntries);
  const supabase = createBrowserClient();

  // Real-time subscription for new approved entries
  useEffect(() => {
    const channel = supabase
      .channel(`guestbook:${invitationId}`)
      .on(
        'postgres_changes',
        {
          event:  'INSERT',
          schema: 'public',
          table:  'guestbook_entries',
          filter: `invitation_id=eq.${invitationId}`,
        },
        (payload) => {
          const newEntry = payload.new as GuestbookEntry;
          // Only show if approved (moderation may have already run server-side)
          if (newEntry.moderation_status === 'approved' && !newEntry.is_spam) {
            setEntries(prev => [newEntry, ...prev]);
          }
        }
      )
      .subscribe();

    return () => { supabase.removeChannel(channel); };
  }, [invitationId, supabase]);

  return (
    <section className="py-16 px-4" style={{ backgroundColor: 'var(--color-background)' }}>
      <h2
        className="text-center text-3xl mb-8"
        style={{ fontFamily: 'var(--font-heading)', color: 'var(--color-primary)' }}
      >
        {sectionContent.title}
      </h2>

      <div className="mx-auto max-w-2xl space-y-4">
        {entries.map(entry => (
          <div
            key={entry.id}
            className="rounded-xl p-5 shadow-sm"
            style={{ backgroundColor: 'var(--color-surface)' }}
          >
            <div className="flex items-center gap-2 mb-2">
              <span
                className="font-semibold text-sm"
                style={{ color: 'var(--color-primary)' }}
              >
                {entry.name}
              </span>
              {entry.is_verified && (
                <span className="rounded-full bg-green-100 px-2 py-0.5 text-[10px] font-medium text-green-700">
                  ✓ Verified Guest
                </span>
              )}
              <span className="text-xs text-gray-400 ml-auto">
                {formatRelativeTime(entry.submitted_at)}
              </span>
            </div>
            <p className="text-sm leading-relaxed" style={{ color: 'var(--color-text-primary)' }}>
              {entry.message}
            </p>
          </div>
        ))}

        {entries.length === 0 && (
          <p className="text-center text-sm text-gray-400">
            {sectionContent.placeholder_text}
          </p>
        )}
      </div>
    </section>
  );
}
```

### 6.5 Owner Moderation Dashboard

```typescript
// app/(app)/invitations/[id]/guestbook/page.tsx — server component

// Renders:
// TabGroup: All | Pending | Approved | Rejected | Spam

// DataTable columns:
// Name | Verified? | Message (truncated) | Status | Submitted | Actions

// Pending entries badge in nav if moderation is enabled

// Actions per row:
// ✅ Approve | ❌ Reject | 🙈 Hide | 🗑 Delete

// Bulk actions:
// Approve Selected | Reject Selected | Mark as Spam
```

---

## 7. Anti-Spam Protection

### 7.1 Defense-in-Depth Strategy

Spam protection operates at four layers, none of which requires third-party CAPTCHA (which hurts mobile UX):

```
LAYER 1: Honeypot field
  → Hidden input named "website" that real users never fill
  → Bots filling all fields → silent discard

LAYER 2: Rate limiting (Upstash Redis sliding window)
  → RSVP:    10 submissions / 60 seconds / IP
  → Guestbook: 5 submissions / 60 seconds / IP
  → Per-invitation flood: 100 submissions / 10 minutes / IP

LAYER 3: Spam scoring (server-side heuristics)
  → Score 0–100; threshold 70 = auto-reject
  → Multiple signals combined

LAYER 4: Duplicate detection
  → Tracked guests: upsert prevents duplicate rows
  → Open guests: phone/email deduplication warning in owner dashboard
```

### 7.2 Rate Limiter Implementation

```typescript
// lib/rsvp/rate-limit.ts

import { Ratelimit } from '@upstash/ratelimit';
import { Redis } from '@upstash/redis';

const redis = Redis.fromEnv();

// Per-IP global rate limits
export const rsvpRateLimit = new Ratelimit({
  redis,
  limiter: Ratelimit.slidingWindow(10, '60 s'),
  prefix:  'rl:rsvp',
  analytics: true,
});

export const guestbookRateLimit = new Ratelimit({
  redis,
  limiter: Ratelimit.slidingWindow(5, '60 s'),
  prefix:  'rl:guestbook',
  analytics: true,
});

// Per-invitation flood protection (separate limit)
export const rsvpFloodLimit = new Ratelimit({
  redis,
  limiter: Ratelimit.slidingWindow(100, '10 m'),
  prefix:  'rl:rsvp_flood',
});

export async function checkRsvpRateLimit(ip: string): Promise<boolean> {
  const { success } = await rsvpRateLimit.limit(ip);
  return !success; // returns true if rate-limited
}

export async function checkRsvpFlood(
  ip: string,
  invitationId: string
): Promise<boolean> {
  const key = `${ip}:${invitationId}`;
  const { success } = await rsvpFloodLimit.limit(key);
  return !success;
}

export async function checkGuestbookRateLimit(ip: string): Promise<boolean> {
  const { success } = await guestbookRateLimit.limit(ip);
  return !success;
}
```

### 7.3 Spam Scoring Engine

```typescript
// lib/rsvp/spam-detector.ts

interface SpamCheckInput {
  ip:           string;
  invitationId: string;
  name:         string;
  email?:       string | null;
  message?:     string | null;
  phone?:       string | null;
}

interface SpamSignal {
  signal:  string;
  score:   number;
  reason:  string;
}

export async function computeSpamScore(input: SpamCheckInput): Promise<number> {
  const signals: SpamSignal[] = [];

  // Signal 1: Repeated submissions from same IP to same invitation (last 5 min)
  const recentFromIp = await countRecentFromIp(input.ip, input.invitationId, 300);
  if (recentFromIp >= 5)  signals.push({ signal: 'ip_flood',        score: 40, reason: `${recentFromIp} recent from this IP` });
  if (recentFromIp >= 10) signals.push({ signal: 'ip_flood_severe', score: 30, reason: 'severe IP flood' });

  // Signal 2: Name contains URL
  if (/https?:\/\/|www\./i.test(input.name)) {
    signals.push({ signal: 'name_url', score: 50, reason: 'URL in name field' });
  }

  // Signal 3: Message contains multiple URLs
  const urlCount = (input.message ?? '').match(/https?:\/\//gi)?.length ?? 0;
  if (urlCount >= 1) signals.push({ signal: 'msg_url',      score: 30, reason: 'URL in message' });
  if (urlCount >= 3) signals.push({ signal: 'msg_multi_url',score: 40, reason: 'multiple URLs in message' });

  // Signal 4: Very short name (single char or only special chars)
  if (input.name.trim().length < 2) {
    signals.push({ signal: 'short_name', score: 20, reason: 'name too short' });
  }

  // Signal 5: Message contains known spam phrases
  const spamPhrases = ['click here', 'buy now', 'free offer', 'limited time', 'casino', 'crypto'];
  const msgLower = (input.message ?? '').toLowerCase();
  const matchedPhrases = spamPhrases.filter(p => msgLower.includes(p));
  if (matchedPhrases.length > 0) {
    signals.push({ signal: 'spam_phrase', score: matchedPhrases.length * 15, reason: `spam phrases: ${matchedPhrases.join(', ')}` });
  }

  // Signal 6: All-caps name or message
  if (input.name === input.name.toUpperCase() && input.name.length > 3) {
    signals.push({ signal: 'all_caps_name', score: 10, reason: 'all-caps name' });
  }

  // Signal 7: Known disposable email domains
  if (input.email) {
    const domain = input.email.split('@')[1]?.toLowerCase();
    const disposableDomains = ['guerrillamail.com', 'mailinator.com', 'tempmail.com', 'throwaway.email'];
    if (disposableDomains.includes(domain ?? '')) {
      signals.push({ signal: 'disposable_email', score: 25, reason: 'disposable email domain' });
    }
  }

  const totalScore = Math.min(100, signals.reduce((acc, s) => acc + s.score, 0));
  return totalScore;
}

async function countRecentFromIp(
  ip: string,
  invitationId: string,
  seconds: number
): Promise<number> {
  const key = `spam:count:${invitationId}:${ip}`;
  const count = await redis.incr(key);
  if (count === 1) await redis.expire(key, seconds);
  return count;
}
```

### 7.4 Bot Protection via Cloudflare

At the infrastructure level, Cloudflare WAF rules provide a first line of defense before requests reach the Next.js origin:

```
Cloudflare Rules (configured in CF dashboard):
  - Block known bad IPs (CF IP reputation list)
  - Challenge requests with bot score < 30 on /api/rsvp and /api/guestbook
  - Rate limit at CF edge: 30 requests / minute / IP on /api/rsvp
  - Turnstile (CAPTCHA-alternative) on /api/rsvp for suspicious traffic only
    (transparent to legitimate mobile users)
```

### 7.5 Spam Management Dashboard

```typescript
// Owner dashboard: /invitations/[id]/rsvp

// Spam tab:
// - Shows responses with is_spam = true
// - Actions: "Not Spam" (set is_spam = false, restore to normal) | "Delete"
// - Spam count badge on nav item

// API: PATCH /api/invitations/[id]/rsvp/[responseId]/spam
// Body: { is_spam: false }
// Effect: restores response to normal (shows in dashboard)
```

---

## 8. Package Feature Integration

### 8.1 Feature Flag Resolution

RSVP and Guestbook features are resolved via the PHASE5 feature resolution engine. All limits are database-driven — no hardcoded values in application code.

```typescript
// lib/rsvp/features.ts

export interface RsvpFeatureSet {
  rsvp_enabled:          boolean;
  rsvp_open_link:        boolean;  // Allow RSVP without personalized token
  rsvp_meal_choice:      boolean;
  rsvp_meal_max_options: number;   // from config
  rsvp_plus_one:         boolean;
  rsvp_wishes_wall:      boolean;
  export_rsvp_csv:       boolean;
  guestbook:             boolean;
  guestbook_moderation:  boolean;
}

export async function resolveRsvpFeatures(
  tenantId: string,
  packageId: string
): Promise<RsvpFeatureSet> {
  const [
    rsvp, rsvpOpenLink, mealChoice, plusOne,
    wishesWall, exportCsv, guestbook, guestbookMod
  ] = await Promise.all([
    resolveFeature({ tenantId, packageId }, 'rsvp'),
    resolveFeature({ tenantId, packageId }, 'rsvp_open_link'),
    resolveFeature({ tenantId, packageId }, 'rsvp_meal_choice'),
    resolveFeature({ tenantId, packageId }, 'rsvp_plus_one'),
    resolveFeature({ tenantId, packageId }, 'rsvp_wishes_wall'),
    resolveFeature({ tenantId, packageId }, 'export_rsvp_csv'),
    resolveFeature({ tenantId, packageId }, 'guestbook'),
    resolveFeature({ tenantId, packageId }, 'guestbook_moderation'),
  ]);

  return {
    rsvp_enabled:          rsvp.enabled,
    rsvp_open_link:        rsvpOpenLink.enabled,
    rsvp_meal_choice:      mealChoice.enabled,
    rsvp_meal_max_options: (mealChoice.config as any)?.max_options ?? 5,
    rsvp_plus_one:         plusOne.enabled,
    rsvp_wishes_wall:      wishesWall.enabled,
    export_rsvp_csv:       exportCsv.enabled,
    guestbook:             guestbook.enabled,
    guestbook_moderation:  guestbookMod.enabled,
  };
}
```

### 8.2 Package Feature Matrix

| Feature | Free | Basic | Premium | Ultimate |
|---|:---:|:---:|:---:|:---:|
| **RSVP** | | | | |
| RSVP form enabled | ✅ | ✅ | ✅ | ✅ |
| Open RSVP (no token) | ✅ | ✅ | ✅ | ✅ |
| Meal choice | ❌ | ✅ | ✅ | ✅ |
| Plus-one | ❌ | ❌ | ✅ | ✅ |
| Wishes wall (via RSVP) | ❌ | ✅ | ✅ | ✅ |
| Export RSVP CSV | ❌ | ✅ | ✅ | ✅ |
| Open/close RSVP toggle | ✅ | ✅ | ✅ | ✅ |
| RSVP deadline | ✅ | ✅ | ✅ | ✅ |
| **GUESTBOOK** | | | | |
| Guestbook wall | ✅ | ✅ | ✅ | ✅ |
| Guestbook moderation | ❌ | ✅ | ✅ | ✅ |
| Bulk moderation | ❌ | ❌ | ✅ | ✅ |

All values sourced from `package_features` table — no hardcoded tier checks in application code.

### 8.3 Feature Gate Enforcement in Public Page

```typescript
// app/inv/[slug]/page.tsx — SSR data load

const rsvpFeatures = await resolveRsvpFeatures(
  invitation.tenant_id,
  sub?.package_id ?? ''
);

// Passed as props to RsvpSection and GuestbookSection:
// - If rsvpFeatures.rsvp_enabled = false → section hidden entirely
// - If rsvpFeatures.guestbook = false → guestbook section hidden
// - Individual form fields conditionally rendered based on feature flags
```

### 8.4 Owner Dashboard Feature Gates

```typescript
// components/rsvp/RsvpDashboard.tsx

// Export button:
{rsvpFeatures.export_rsvp_csv ? (
  <ExportButton onClick={handleExport} />
) : (
  <LockedButton
    label="Export CSV"
    featureKey="export_rsvp_csv"
    requiredPlan="Basic"
  />
)}

// Guestbook moderation tab:
{rsvpFeatures.guestbook_moderation ? (
  <Tab label="Pending Review" count={pendingCount} />
) : (
  <Tab label="Pending Review" count={0} locked lockedPlan="Basic" />
)}
```

---

## 9. RSVP Analytics Preparation

### 9.1 Data Structures for Analytics

Analytics are not built in this phase, but the data layer is fully prepared. All necessary raw data lives in `rsvp_responses` and `invitation_events`.

```typescript
// types/rsvp-analytics.ts

// Prepared interfaces for the analytics phase

export interface RsvpTrendPoint {
  date:        string;        // ISO date 'YYYY-MM-DD'
  attending:   number;
  not_attending: number;
  maybe:       number;
  total:       number;
  cumulative_attending: number;
}

export interface RsvpByCategory {
  category_id:   string;
  category_name: string;
  color:         string | null;
  attending:     number;
  not_attending: number;
  maybe:         number;
  pending:       number;
  total_pax:     number;
}

export interface RsvpByGroup {
  group_id:    string;
  group_name:  string;
  color:       string | null;
  attending:   number;
  not_attending: number;
  pending:     number;
  total_pax:   number;
}

export interface MealChoiceBreakdown {
  meal_choice: string;
  count:       number;
  percentage:  number;
}

export interface RsvpResponseRate {
  total_tracked_guests:  number;  // guests with personal_token
  responded:             number;
  pending:               number;
  response_rate_pct:     number;
}
```

### 9.2 Prepared SQL Views

```sql
-- supabase/migrations/083_rsvp_analytics_views.sql

-- Daily RSVP trend for an invitation
CREATE OR REPLACE VIEW rsvp_daily_trend AS
SELECT
  invitation_id,
  DATE(submitted_at)                                  AS date,
  COUNT(*) FILTER (WHERE attendance = 'attending')    AS attending,
  COUNT(*) FILTER (WHERE attendance = 'not_attending') AS not_attending,
  COUNT(*) FILTER (WHERE attendance = 'maybe')        AS maybe,
  COUNT(*)                                            AS total
FROM rsvp_responses
WHERE is_spam = FALSE
GROUP BY invitation_id, DATE(submitted_at);

-- RSVP summary by guest category
CREATE OR REPLACE VIEW rsvp_by_category AS
SELECT
  r.invitation_id,
  gc.id                                               AS category_id,
  gc.name                                             AS category_name,
  gc.color,
  COUNT(r.id) FILTER (WHERE r.attendance = 'attending')    AS attending,
  COUNT(r.id) FILTER (WHERE r.attendance = 'not_attending') AS not_attending,
  COUNT(r.id) FILTER (WHERE r.attendance = 'maybe')        AS maybe,
  COALESCE(SUM(r.pax_count) FILTER (WHERE r.attendance = 'attending'), 0) AS total_pax
FROM rsvp_responses r
JOIN guests g ON g.id = r.guest_id
JOIN guest_categories gc ON gc.id = g.category_id
WHERE r.is_spam = FALSE
  AND r.guest_id IS NOT NULL
GROUP BY r.invitation_id, gc.id, gc.name, gc.color;

-- Response rate for tracked guests only
CREATE OR REPLACE VIEW rsvp_response_rate AS
SELECT
  g.invitation_id,
  COUNT(DISTINCT g.id)                                         AS total_tracked,
  COUNT(DISTINCT r.guest_id) FILTER (WHERE r.id IS NOT NULL)  AS responded,
  COUNT(DISTINCT g.id) - COUNT(DISTINCT r.guest_id)           AS pending
FROM guests g
LEFT JOIN rsvp_responses r
  ON r.guest_id = g.id AND r.is_spam = FALSE
WHERE g.deleted_at IS NULL
GROUP BY g.invitation_id;
```

### 9.3 `invitation_analytics` Nightly Roll-Up Preparation

The `invitation_analytics` table (PHASE2) already has `rsvp_attending`, `rsvp_not_attending`, `rsvp_maybe`, and `guestbook_count` columns. The nightly Edge Function that populates them is prepared here:

```typescript
// supabase/functions/aggregate-daily-analytics/index.ts
// (Skeleton only — implementation in analytics phase)

Deno.serve(async () => {
  const admin = createAdminClient();
  const yesterday = new Date();
  yesterday.setDate(yesterday.getDate() - 1);
  const dateStr = yesterday.toISOString().slice(0, 10);

  // For each invitation with activity yesterday:
  // 1. Aggregate rsvp_responses by attendance
  // 2. Count new guestbook_entries (approved)
  // 3. Count invitation_events by type
  // 4. Upsert into invitation_analytics (invitation_id, date)

  return new Response(JSON.stringify({ status: 'ok' }));
});
```

---

## 10. Notification Preparation

### 10.1 Notification Architecture

Notifications are queued via the `email_notifications` table (PHASE2) and processed asynchronously by a Supabase Edge Function. No synchronous email sending occurs in the RSVP submission path.

```
RSVP submitted
  │
  ▼
INSERT into email_notifications (status='pending')
  │
  ▼
Edge Function: process-email-notifications (runs every 60s)
  │
  ├── Fetch pending notifications (batch of 50)
  │
  ├── For each: render template + call Resend API
  │
  └── Update status: 'sent' | 'failed'
       Retry up to 3 times on failure
```

### 10.2 Notification Templates

```typescript
// lib/notifications/templates.ts

export type NotificationTemplateKey =
  | 'rsvp_received'           // Owner alert: new RSVP came in
  | 'rsvp_batch_summary'      // Owner: daily/weekly digest of RSVPs
  | 'guestbook_pending'       // Owner: new entry awaiting moderation
  | 'rsvp_confirmation'       // Guest: confirmation of their RSVP
  | 'rsvp_reminder'           // Guest: reminder to RSVP (Phase 3+)
  | 'rsvp_deadline_warning';  // Owner: deadline approaching (Phase 3+)

export interface NotificationContext {
  // Common
  invitation_title:   string;
  invitation_url:     string;
  dashboard_url:      string;
  groom_name:         string;
  bride_name:         string;
  event_date:         string;

  // rsvp_received specific
  respondent_name?:   string;
  attendance?:        AttendanceStatus;
  pax_count?:         number;
  message?:           string;

  // rsvp_batch_summary specific
  attending_count?:   number;
  not_attending_count?: number;
  maybe_count?:       number;
  total_pax?:         number;

  // guestbook_pending specific
  entry_name?:        string;
  entry_message?:     string;
  moderation_url?:    string;
}
```

### 10.3 Owner Notification Preferences

```sql
-- Phase 3+: per-tenant notification preferences
-- Stored in tenants.metadata JSONB in Phase 1-2

-- Phase 1-2 defaults (hardcoded in metadata):
{
  "notifications": {
    "rsvp_received":     true,   -- email on every RSVP
    "rsvp_daily_digest": false,  -- daily summary instead
    "guestbook_pending": true    -- email when entry needs moderation
  }
}
```

### 10.4 WhatsApp Notification Preparation

```typescript
// lib/notifications/whatsapp.ts
// Architecture only — implementation in Phase 3+

export interface WhatsAppNotificationPayload {
  to:           string;  // phone number with country code
  template_key: string;  // WhatsApp Business API approved template name
  variables:    Record<string, string>;
}

// Notification types prepared:
// 'rsvp_received_wa'   → Owner gets WA message when RSVP comes in
// 'rsvp_confirm_wa'    → Guest receives WA confirmation of their RSVP

// Flow (Phase 3+):
// 1. Queue in whatsapp_notifications table (similar to email_notifications)
// 2. Edge Function sends via WhatsApp Business Cloud API
// 3. Delivery status webhook updates record
```

### 10.5 Notification Queue Table

```sql
-- For Phase 2+: dedicated WhatsApp notification queue
-- Phase 1: only email_notifications table is used

CREATE TABLE whatsapp_notifications (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID        REFERENCES tenants(id),
  invitation_id   UUID        REFERENCES invitations(id),
  recipient_phone TEXT        NOT NULL,
  recipient_name  TEXT,
  template_key    TEXT        NOT NULL,
  variables       JSONB       NOT NULL DEFAULT '{}',
  status          TEXT        NOT NULL DEFAULT 'pending'
                              CHECK (status IN ('pending', 'sent', 'failed', 'delivered')),
  provider_ref    TEXT,       -- WhatsApp message ID
  error_message   TEXT,
  sent_at         TIMESTAMPTZ,
  delivered_at    TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_wa_notif_status ON whatsapp_notifications(status)
  WHERE status = 'pending';
CREATE INDEX idx_wa_notif_tenant ON whatsapp_notifications(tenant_id, created_at DESC);
```

---

## 11. Public Guest Experience

### 11.1 RSVP Submission Flow (Mobile-First)

```
Guest opens personalized link on phone:
  https://inv.weddingplatform.com/andi-ninah-2026?t=[token]
  │
  ▼
Page loads via ISR (< 1.5s on 3G)
Guest name pre-filled in RSVP form: "Dear Budi,"
  │
  ▼
Guest selects attendance (large touch targets, 44px min)
  │
  ├── "Joyfully Accept" → pax count shown, meal choice if enabled
  └── "Regretfully Decline" → form shortens (no pax needed)
  │
  ▼
Guest optionally fills message / wishes
  │
  ▼
Guest taps "Send RSVP" (44px height minimum, full width)
  │
  ▼
Loading spinner (< 800ms for typical submission)
  │
  ▼
Success animation + confirmation message
Page smoothly scrolls past RSVP section to continue reading
```

### 11.2 Guestbook Submission Flow

```
Guest scrolls to Guestbook section
  │
  ▼
Guestbook wall visible with previous entries
  (max 20 shown initially, "Load more" for pagination)
  │
  ▼
Guest taps message input
  │
  ▼
Keyboard opens → form scrolls into view (smooth behavior)
  │
  ▼
Guest types name (pre-filled if personalized link) + message
  │
  ▼
Submit → optimistic UI (entry appears instantly in list)
  (actual server response arrives < 1s, reverts on error)
```

### 11.3 Mobile Experience Requirements

```typescript
// Performance requirements for public RSVP/guestbook:

export const MOBILE_TARGETS = {
  // Form rendering
  RSVP_FORM_LCP:       1500,  // ms on 3G
  FORM_SUBMIT_RTT:      800,  // ms from tap to confirmation
  KEYBOARD_LAYOUT_CLS:  0.05, // CLS when keyboard opens

  // Touch targets
  BUTTON_MIN_HEIGHT:     44,  // px
  INPUT_MIN_HEIGHT:      44,  // px
  RADIO_TOUCH_AREA:      44,  // px (achieved via padding, not just the radio itself)

  // Interaction
  DEBOUNCE_MS:          300,  // ms for search inputs
  OPTIMISTIC_UPDATE_MS:   0,  // immediate (guestbook wall)
};
```

### 11.4 Validation Flow

Client-side validation provides immediate feedback; server-side validation is the authoritative guard.

```typescript
// Client-side (inline, no library):
// - Name: required, non-empty after trim
// - Attendance: required (radio selection)
// - Pax count: 1–10 (select dropdown, no invalid state possible)
// - Email: HTML5 type="email" validation
// - Message: maxlength=500 (browser-enforced)

// Server-side (Zod schema, Section 4.3):
// - All fields re-validated
// - Rate limit checked
// - Gate status checked
// - Spam score computed
// - Response persisted

// Error messages shown:
// - Above submit button (not in a toast, which may not be visible on mobile)
// - Clear, actionable text in the user's language
```

---

## 12. Permissions

### 12.1 Complete Permission Matrix

| Action | super_admin | reseller_admin | owner | editor | viewer | public |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| **RSVP** | | | | | | |
| Submit RSVP | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| View all RSVP responses | ✅ | ✅ (clients) | ✅ | ✅ | ✅ | ❌ |
| Export RSVP CSV | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| Open / close RSVP | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| Set RSVP deadline | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| Enable meal choice | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| Enable plus-one | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| Mark response as spam | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| Delete RSVP response | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| **GUESTBOOK** | | | | | | |
| Submit guestbook entry | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| View approved entries (public) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| View pending/rejected entries | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Approve entry | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| Reject entry | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| Hide entry | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| Delete entry | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| Bulk moderate | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| Enable/disable moderation | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |

### 12.2 API Route Permission Map

| Route | Method | Auth Required | Permission | Feature Gate |
|---|---|---|---|---|
| `/api/rsvp` | POST | ❌ Public | — | `rsvp` |
| `/api/guestbook` | POST | ❌ Public | — | `guestbook` |
| `/api/invitations/[id]/rsvp` | GET | ✅ | `rsvp:read` | — |
| `/api/invitations/[id]/rsvp/export` | GET | ✅ | `rsvp:read` | `export_rsvp_csv` |
| `/api/invitations/[id]/rsvp/summary` | GET | ✅ | `rsvp:read` | — |
| `/api/invitations/[id]/rsvp/[id]` | PATCH | ✅ | `rsvp:read` | — |
| `/api/invitations/[id]/rsvp/[id]` | DELETE | ✅ | `invitation:publish` | — |
| `/api/invitations/[id]/guestbook` | GET | ✅ | `rsvp:read` | `guestbook` |
| `/api/invitations/[id]/guestbook/[id]` | PATCH | ✅ | `rsvp:read` | — |
| `/api/invitations/[id]/guestbook/[id]` | DELETE | ✅ | `invitation:publish` | — |
| `/api/invitations/[id]/guestbook/bulk-moderate` | POST | ✅ | `rsvp:read` | `guestbook_moderation` |

### 12.3 RLS Policies

```sql
-- rsvp_responses
ALTER TABLE rsvp_responses ENABLE ROW LEVEL SECURITY;

-- Public can INSERT RSVP (gate enforced at app layer)
CREATE POLICY "rsvp_public_insert" ON rsvp_responses
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM invitations
      WHERE id = invitation_id
        AND status = 'published'
        AND is_rsvp_open = TRUE
        AND (rsvp_deadline IS NULL OR rsvp_deadline >= CURRENT_DATE)
    )
  );

-- Tenant members can read all their RSVP responses
CREATE POLICY "rsvp_read_own_tenant" ON rsvp_responses
  FOR SELECT
  USING (tenant_id = auth_tenant_id());

-- Tenant owner/editor can update (mark spam, etc.)
CREATE POLICY "rsvp_update_tenant" ON rsvp_responses
  FOR UPDATE
  USING (
    tenant_id = auth_tenant_id() AND
    auth_role() IN ('owner', 'editor')
  );

-- Reseller admin can read clients' RSVP
CREATE POLICY "rsvp_read_reseller" ON rsvp_responses
  FOR SELECT
  USING (
    tenant_id IN (
      SELECT tenant_id FROM reseller_tenants
      WHERE reseller_id = auth_reseller_id()
    )
  );

-- guestbook_entries
ALTER TABLE guestbook_entries ENABLE ROW LEVEL SECURITY;

-- Public can INSERT (gate enforced at app layer)
CREATE POLICY "guestbook_public_insert" ON guestbook_entries
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM invitations
      WHERE id = invitation_id AND status = 'published'
    )
  );

-- Public can read APPROVED, non-spam entries
CREATE POLICY "guestbook_public_read" ON guestbook_entries
  FOR SELECT
  USING (
    moderation_status = 'approved' AND
    is_spam = FALSE AND
    EXISTS (
      SELECT 1 FROM invitations
      WHERE id = invitation_id AND status = 'published'
    )
  );

-- Tenant members can read ALL (including pending/rejected)
CREATE POLICY "guestbook_tenant_all" ON guestbook_entries
  FOR ALL
  USING (tenant_id = auth_tenant_id());

-- Reseller admin read
CREATE POLICY "guestbook_reseller_read" ON guestbook_entries
  FOR SELECT
  USING (
    tenant_id IN (
      SELECT tenant_id FROM reseller_tenants
      WHERE reseller_id = auth_reseller_id()
    )
  );
```

---

## 13. Multi-Tenant Security

### 13.1 Tenant Isolation

Every `rsvp_responses` and `guestbook_entries` row carries a `tenant_id` column denormalized from the parent invitation. This enables:

- Single-column RLS policies without subqueries to `invitations`
- Efficient partial indexes scoped to tenant
- Reseller-scoped queries without joining through invitations

```typescript
// Defense-in-depth pattern for all RSVP API routes:

// Layer 1: RLS policy prevents cross-tenant reads at DB level
// Layer 2: Application always includes tenant_id in queries
// Layer 3: invitation_id FK ensures response belongs to the correct invitation

const { data } = await supabase
  .from('rsvp_responses')
  .select('*')
  .eq('invitation_id', params.id)
  .eq('tenant_id', auth.user.tenantId)   // explicit, even though RLS enforces it
  .order('submitted_at', { ascending: false });
```

### 13.2 Invitation Ownership Validation

Before accepting a public RSVP or guestbook submission, the server always validates:

```typescript
// lib/rsvp/gate.ts

export async function validateInvitationForPublicSubmission(
  supabase: SupabaseClient,
  slug: string
): Promise<{ valid: true; invitation: InvitationGateData } | { valid: false; reason: string }> {
  const { data: invitation } = await supabase
    .from('invitations')
    .select('id, tenant_id, status, is_rsvp_open, rsvp_deadline, password_hash')
    .eq('slug', slug)
    .single();

  if (!invitation) {
    return { valid: false, reason: 'Invitation not found.' };
  }

  if (invitation.status !== 'published') {
    return { valid: false, reason: 'This invitation is not currently available.' };
  }

  // Password-protected invitations: verify session cookie before accepting RSVP
  if (invitation.password_hash) {
    // Checked in middleware; if we reach here, password was verified
    // (middleware sets x-invitation-verified header)
  }

  return { valid: true, invitation };
}
```

### 13.3 Guest Ownership Validation

When a personal token is provided, the resolved `guest_id` must belong to the same `invitation_id`. This prevents token reuse across invitations.

```typescript
// lib/rsvp/token-resolver.ts

export async function resolveGuestFromToken(
  supabase: SupabaseClient,
  token: string,
  invitationId: string
): Promise<string | null> {
  // IMPORTANT: always filter by invitation_id, not just token
  // Prevents a guest from one invitation submitting as a guest of another
  const { data } = await supabase
    .from('guests')
    .select('id')
    .eq('personal_token', token)
    .eq('invitation_id', invitationId)  // critical constraint
    .is('deleted_at', null)
    .maybeSingle();

  return data?.id ?? null;
}
```

### 13.4 IP Address Privacy

IP addresses stored in `rsvp_responses` and `guestbook_entries` are used only for spam detection and rate limiting. They are:
- Stored as PostgreSQL `INET` type (not TEXT) to avoid format injection
- Never exposed in API responses to the public
- Masked in owner dashboard (last octet replaced with `.xxx`)
- Purged after 90 days by a nightly Edge Function (GDPR compliance preparation)

```typescript
// lib/rsvp/privacy.ts

export function maskIpAddress(ip: string): string {
  if (ip.includes(':')) {
    // IPv6: show only first 4 groups
    const parts = ip.split(':');
    return parts.slice(0, 4).join(':') + ':xxxx:xxxx:xxxx:xxxx';
  }
  // IPv4: mask last octet
  const parts = ip.split('.');
  return parts.slice(0, 3).join('.') + '.xxx';
}
```

---

## 14. Performance Optimization

### 14.1 Indexing Strategy

```sql
-- ── rsvp_responses ──────────────────────────────────────────────────

-- Hot path 1: tenant RSVP dashboard (all responses for an invitation)
CREATE INDEX idx_rsvp_inv_submitted
  ON rsvp_responses(invitation_id, submitted_at DESC)
  WHERE is_spam = FALSE;

-- Hot path 2: summary counts (attendance breakdown)
CREATE INDEX idx_rsvp_inv_attendance
  ON rsvp_responses(invitation_id, attendance)
  WHERE is_spam = FALSE;

-- Hot path 3: tracked guest latest response (LATERAL join in views)
CREATE INDEX idx_rsvp_guest_latest
  ON rsvp_responses(guest_id, submitted_at DESC)
  WHERE guest_id IS NOT NULL AND is_spam = FALSE;

-- Hot path 4: upsert constraint for tracked guests
CREATE UNIQUE INDEX idx_rsvp_guest_inv_unique
  ON rsvp_responses(guest_id, invitation_id)
  WHERE guest_id IS NOT NULL;

-- Spam analysis: find all submissions from an IP to an invitation
CREATE INDEX idx_rsvp_ip_inv_time
  ON rsvp_responses(invitation_id, ip_address, submitted_at DESC);

-- ── guestbook_entries ───────────────────────────────────────────────

-- Hot path 1: public guestbook wall (approved entries newest first)
CREATE INDEX idx_guestbook_wall
  ON guestbook_entries(invitation_id, submitted_at DESC)
  WHERE moderation_status = 'approved' AND is_spam = FALSE;

-- Hot path 2: owner moderation queue
CREATE INDEX idx_guestbook_pending
  ON guestbook_entries(invitation_id, submitted_at ASC)
  WHERE moderation_status = 'pending';

-- Hot path 3: spam queue
CREATE INDEX idx_guestbook_spam
  ON guestbook_entries(invitation_id, submitted_at DESC)
  WHERE is_spam = TRUE;

-- Verified guest lookup
CREATE INDEX idx_guestbook_verified_guest
  ON guestbook_entries(guest_id)
  WHERE guest_id IS NOT NULL AND moderation_status = 'approved';
```

### 14.2 Caching Strategy

```typescript
// lib/rsvp/cache.ts

const RSVP_SUMMARY_TTL   = 30;  // seconds — refreshed frequently for live dashboard
const GUESTBOOK_WALL_TTL = 60;  // seconds — public page doesn't need to be instantaneous

// RSVP summary cache (owner dashboard stat cards)
export async function getCachedRsvpSummary(
  invitationId: string
): Promise<RsvpSummary | null> {
  return redis.get<RsvpSummary>(`rsvp:summary:${invitationId}`);
}

export async function setCachedRsvpSummary(
  invitationId: string,
  summary: RsvpSummary
): Promise<void> {
  await redis.setex(`rsvp:summary:${invitationId}`, RSVP_SUMMARY_TTL, JSON.stringify(summary));
}

export async function invalidateRsvpSummary(invitationId: string): Promise<void> {
  await redis.del(`rsvp:summary:${invitationId}`);
}

// Guestbook wall cache (public page initial render)
export async function getCachedGuestbookWall(
  invitationId: string,
  page: number
): Promise<GuestbookEntry[] | null> {
  return redis.get<GuestbookEntry[]>(`guestbook:wall:${invitationId}:${page}`);
}
```

### 14.3 Pagination

```typescript
// RSVP response list: offset pagination (owner has full control)
// Default page size: 50, max: 200

// Guestbook wall: cursor pagination (append-only, newest-first)
// Initial load: 20 entries
// Load more: cursor = last entry's submitted_at

export async function getGuestbookWall(
  supabase: SupabaseClient,
  invitationId: string,
  cursor?: string,  // ISO datetime of oldest currently-shown entry
  limit = 20
): Promise<{ entries: GuestbookEntry[]; hasMore: boolean }> {
  let query = supabase
    .from('guestbook_entries')
    .select('id, name, message, submitted_at, guest_id, is_verified:guest_id')
    .eq('invitation_id', invitationId)
    .eq('moderation_status', 'approved')
    .eq('is_spam', false)
    .order('submitted_at', { ascending: false })
    .limit(limit + 1);  // fetch one extra to determine hasMore

  if (cursor) {
    query = query.lt('submitted_at', cursor);
  }

  const { data } = await query;
  const entries = (data ?? []).slice(0, limit);
  const hasMore = (data ?? []).length > limit;

  return { entries, hasMore };
}
```

### 14.4 High Volume Handling

```typescript
// For invitations expecting 1000+ RSVPs (large events):

// 1. Submission endpoint is stateless — can scale horizontally on Vercel
// 2. Rate limit per IP (not per invitation) prevents bottleneck at DB
// 3. Redis counter for spam detection (not DB query)
// 4. Realtime broadcast uses Supabase channel, not polling
// 5. Summary counts use Redis cache (30s TTL) — avoid COUNT(*) on each request
// 6. Export uses streaming generator (Section 13.1 cursor pattern)

// Database write path for RSVP submission:
// 1 INSERT into rsvp_responses       (primary write)
// 1 INSERT into invitation_events    (analytics, async in background)
// 1 INSERT into email_notifications  (queue, async)
// Total: 3 rows across 3 tables — fast even under load

// Supabase Realtime broadcast:
// New rsvp_responses INSERT triggers Realtime → owner dashboard updates live
// No polling needed → zero DB load for dashboard real-time updates
```

---

## 15. Scalability Design

### 15.1 Volume Projections

```
Assumptions (Year 2):
  Active invitations:     25,000
  Average RSVPs/invitation: 120
  Average guestbook/invitation: 40

Total rsvp_responses:     3,000,000
Total guestbook_entries:  1,000,000

At Year 3 (large-event tenants included):
  Total rsvp_responses:   ~15,000,000
  Total guestbook_entries: ~5,000,000

Spike scenario:
  Viral invitation: 10,000 RSVPs in 24h
  → ~7 RSVPs/minute sustained
  → Rate limit (10/min/IP) not a bottleneck for organic traffic
  → Redis spam counters handle burst without DB queries
```

### 15.2 `rsvp_responses` Partitioning (Phase 4+)

```sql
-- When rsvp_responses exceeds 10M rows, partition by created date
-- All existing indexes carry over; query patterns unchanged

CREATE TABLE rsvp_responses_partitioned (
  LIKE rsvp_responses INCLUDING ALL
) PARTITION BY RANGE (submitted_at);

CREATE TABLE rsvp_responses_2026
  PARTITION OF rsvp_responses_partitioned
  FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');

CREATE TABLE rsvp_responses_2027
  PARTITION OF rsvp_responses_partitioned
  FOR VALUES FROM ('2027-01-01') TO ('2028-01-01');

-- Automate with pg_partman (Supabase Pro extension)
```

### 15.3 `guestbook_entries` Archival

```typescript
// Guestbook entries for archived/deleted invitations are retained for 90 days
// A nightly Edge Function moves them to cold storage:

// supabase/functions/archive-old-guestbook/index.ts (skeleton)
// 1. Find guestbook_entries where invitation.deleted_at < 90 days ago
// 2. Export to Supabase Storage as JSONL (one file per invitation)
// 3. Hard delete from guestbook_entries
// This keeps the live table lean for active invitations
```

### 15.4 Realtime Scalability

Supabase Realtime uses a channel-per-invitation pattern. Each invitation page subscribes to its own channel. At 25,000 active invitations, this is within Supabase's connection limits.

```typescript
// Pattern: one channel per invitation, not one global channel
// supabase.channel(`rsvp:${invitationId}`) not supabase.channel('rsvp')

// Owner dashboard subscribes to:
// - rsvp_responses: INSERT (new response arrives)
// - guestbook_entries: INSERT (new guestbook message)

// Public invitation page subscribes to:
// - guestbook_entries: INSERT WHERE moderation_status=approved
//   (new approved message appears on wall)

// Connection lifecycle:
// - Owner: connected while /rsvp page is open (minutes to hours)
// - Public guest: connected while viewing invitation (seconds to minutes)
// - Both: disconnect on page close (no persistent connections)
```

### 15.5 Future Schema Extensions

| Future Feature | Extension Required |
|---|---|
| Custom RSVP questions | Already prepared: `rsvp_responses.custom_answers JSONB` |
| Seat reservation | `seat_reservations` table (Section 3.4) |
| Meal order tracking | `meal_choice` column already on `rsvp_responses` |
| Guest dietary notes | `guests.tags TEXT[]` already supports "vegetarian" tag |
| Multi-event RSVP | `event_id` FK on `rsvp_responses` (Phase 3+) |
| RSVP reminders | `rsvp_deadline` already on `invitations` |
| Guestbook reactions | `guestbook_reactions` table (emoji reactions per entry) |
| Anonymous guestbook off | `moderation_status` default changed to 'pending' via feature |

---

## 16. Future Integrations

### 16.1 QR Check-In Integration

RSVP data feeds directly into QR check-in when that system launches. The data contract is already in place:

```typescript
// When guest scans their QR code at the event:
// 1. qr_codes.token → qr_codes.guest_id → guests.name
// 2. Look up rsvp_responses WHERE guest_id = $id → attendance = 'attending'
// 3. If not attending or no RSVP → show warning to usher
// 4. INSERT qr_checkins row
// 5. Return: { guest, rsvp_status, already_checked_in }

// Data already available:
// - rsvp_responses.guest_id FK → guests.id
// - rsvp_responses.pax_count (seats allocated)
// - rsvp_responses.has_plus_one
// - guests.expected_pax (pre-event estimate)
```

### 16.2 Attendance Verification

```typescript
// Phase 3+: Attendance verification system
// Verifies RSVP against actual check-in

export interface AttendanceVerification {
  guest_id:      string;
  guest_name:    string;
  rsvp_status:   AttendanceStatus | 'no_rsvp';
  rsvp_pax:      number;
  checked_in:    boolean;
  checked_in_at: string | null;
  discrepancy:   boolean;
  // true if rsvp=not_attending but checked in, or vice versa
}
```

### 16.3 Event Dashboard Integration

```typescript
// Phase 3+: Live event dashboard for day-of-event use
// Aggregates real-time check-in data alongside RSVP data

export interface EventDashboard {
  invitation:    { title: string; event_date: string; venue: string };
  rsvp_summary:  RsvpSummary;
  checkin:       {
    total_checked_in:   number;
    checked_in_pct:     number;
    last_checkin_at:    string | null;
    live_feed:          CheckinEvent[];
  };
  meal_counts:   MealChoiceBreakdown[];
}
```

### 16.4 WhatsApp Blast — RSVP Follow-Up

```typescript
// Phase 2+: Send follow-up blast to guests who haven't responded

// Trigger: Owner clicks "Remind Pending Guests" in RSVP dashboard
// System: queries guests WHERE guest_id NOT IN (SELECT guest_id FROM rsvp_responses)
//         i.e., tracked guests with no RSVP yet

// Message template:
// "Hai {{name}}, kami ingin mengingatkan bahwa batas RSVP adalah {{deadline}}.
//  Mohon konfirmasi kehadiran Anda di: {{url}}"

// Rate limit: uses existing blast quota from PHASE8 Section 7.6
// Records: invite_sent_at updated on guests table
```

### 16.5 Email Campaign Integration

```typescript
// Phase 3+: Drip campaign for RSVP management

// Sequence:
// T-30 days: Save the date email blast to all guests
// T-14 days: RSVP reminder to non-responders
// T-7 days:  Final reminder + deadline notice
// T-1 day:   Thank you to confirmed attendees (with venue details)
// T+1 day:   Thank you for attending (guestbook link)

// Prepared hooks:
// email_notifications.template_key supports all above templates
// guests.invite_sent_at tracks last contact date
// rsvp_responses.submitted_at tracks response timing for analytics
```

---

## Appendix A — Migration Order (Phase 9 Additions)

```
Previously from PHASE1–8:
  001–079: Core tables, packages, features, themes, invitations, guests, RLS, seeds

New migrations (PHASE9 additions):
  080_rsvp_responses_v2.sql        -- Extend rsvp_responses: tenant_id, has_plus_one,
                                   --   plus_one_name, custom_answers, spam_score, is_spam,
                                   --   meal_choice (rename from existing), referrer
  081_rsvp_summary_fn.sql          -- get_rsvp_summary() RPC function
  082_rsvp_tracked_unique.sql      -- Unique index for upsert (guest_id, invitation_id)
  083_rsvp_analytics_views.sql     -- rsvp_daily_trend, rsvp_by_category,
                                   --   rsvp_response_rate views
  084_guestbook_entries_v2.sql     -- Extend guestbook_entries: moderation_status (enum),
                                   --   moderated_by, moderated_at, moderation_note,
                                   --   is_spam, spam_score, user_agent
  085_rsvp_indexes.sql             -- All new performance indexes for rsvp_responses
  086_guestbook_indexes.sql        -- All new performance indexes for guestbook_entries
  087_rls_rsvp_v2.sql              -- Updated RLS: tenant_id column, update policy
  088_rls_guestbook_v2.sql         -- Updated RLS: moderation_status filter for public read
  089_whatsapp_notifications.sql   -- whatsapp_notifications table (Phase 2+)
  090_privacy_purge_fn.sql         -- purge_old_ip_addresses() function (GDPR preparation)
```

## Appendix B — API Route Summary

```
── RSVP ───────────────────────────────────────────────────────────────
POST   /api/rsvp                               Public RSVP submission
GET    /api/invitations/[id]/rsvp              List RSVP responses (owner)
GET    /api/invitations/[id]/rsvp/summary      Attendance summary stats
GET    /api/invitations/[id]/rsvp/export       Export CSV (feature-gated)
PATCH  /api/invitations/[id]/rsvp/[rId]        Update response (spam flag, etc.)
DELETE /api/invitations/[id]/rsvp/[rId]        Delete response (owner only)
POST   /api/invitations/[id]/rsvp/settings     Toggle open/close, set deadline

── GUESTBOOK ──────────────────────────────────────────────────────────
POST   /api/guestbook                          Public guestbook submission
GET    /api/invitations/[id]/guestbook         List all entries (owner — all statuses)
GET    /api/invitations/[id]/guestbook/public  Approved entries (public page use)
PATCH  /api/invitations/[id]/guestbook/[eId]   Moderate single entry
DELETE /api/invitations/[id]/guestbook/[eId]   Delete entry
POST   /api/invitations/[id]/guestbook/bulk-moderate  Bulk moderation action
```

## Appendix C — Feature Flag Reference

| Feature Key | Free | Basic | Premium | Ultimate | Notes |
|---|:---:|:---:|:---:|:---:|---|
| `rsvp` | ✅ | ✅ | ✅ | ✅ | Core RSVP form |
| `rsvp_open_link` | ✅ | ✅ | ✅ | ✅ | RSVP without token |
| `rsvp_meal_choice` | ❌ | ✅ | ✅ | ✅ | Meal selection field |
| `rsvp_plus_one` | ❌ | ❌ | ✅ | ✅ | Bring a +1 option |
| `rsvp_wishes_wall` | ❌ | ✅ | ✅ | ✅ | Wishes via RSVP form |
| `export_rsvp_csv` | ❌ | ✅ | ✅ | ✅ | Download RSVP list |
| `guestbook` | ✅ | ✅ | ✅ | ✅ | Public guestbook wall |
| `guestbook_moderation` | ❌ | ✅ | ✅ | ✅ | Manual approval queue |

## Appendix D — Spam Score Signal Reference

| Signal | Score Added | Trigger |
|---|---|---|
| `ip_flood` | +40 | 5+ submissions from same IP in 5 minutes |
| `ip_flood_severe` | +30 | 10+ submissions (stacks with above) |
| `name_url` | +50 | URL pattern detected in name field |
| `msg_url` | +30 | Single URL in message |
| `msg_multi_url` | +40 | 3+ URLs in message (stacks) |
| `short_name` | +20 | Name under 2 characters |
| `spam_phrase` | +15 each | Known spam phrase per match |
| `all_caps_name` | +10 | All-uppercase name > 3 chars |
| `disposable_email` | +25 | Known throwaway email domain |
| **Auto-reject threshold** | **≥ 70** | `is_spam = true`, entry hidden |

---

*End of PHASE9_RSVP_GUESTBOOK.md*
