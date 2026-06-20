# PHASE8_GUEST_MANAGEMENT.md
# Wedding Invitation SaaS Platform — Guest Management Architecture

> **Version:** 1.0.0
> **Date:** 2026-06-13
> **Status:** Approved for Development
> **Depends on:** PHASE1_ARCHITECTURE.md, PHASE2_DATABASE.md, PHASE3_AUTH.md, PHASE4_ADMIN_ARCHITECTURE.md, PHASE5_PACKAGE_FEATURE_SYSTEM.md, PHASE6_THEME_SYSTEM.md, PHASE7_INVITATION_MANAGEMENT.md

---

## Table of Contents

1. [Guest Management Architecture](#1-guest-management-architecture)
2. [Guest Data Model](#2-guest-data-model)
3. [Guest Creation Flow](#3-guest-creation-flow)
4. [Guest Group System](#4-guest-group-system)
5. [Guest Category System](#5-guest-category-system)
6. [Bulk Import System](#6-bulk-import-system)
7. [Personalized Invitation System](#7-personalized-invitation-system)
8. [Guest Search & Filtering](#8-guest-search--filtering)
9. [Guest Quota Management](#9-guest-quota-management)
10. [Attendance Tracking Preparation](#10-attendance-tracking-preparation)
11. [Permission Rules](#11-permission-rules)
12. [Multi-Tenant Considerations](#12-multi-tenant-considerations)
13. [Performance Optimization](#13-performance-optimization)
14. [Scalability Considerations](#14-scalability-considerations)
15. [Future Integrations](#15-future-integrations)

---

## 1. Guest Management Architecture

### 1.1 System Overview

The guest management system is the operational layer connecting the invitation owner to the people who will attend the event. It manages the full lifecycle of a guest — from creation through tracking — and integrates tightly with the package feature system (quotas, import, export) and the public invitation layer (personalized URLs, RSVP correlation).

```
┌─────────────────────────────────────────────────────────────────────┐
│                  GUEST MANAGEMENT SYSTEM LAYERS                      │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  1. MANAGEMENT LAYER (auth-required, tenant-scoped)          │   │
│  │     Guest CRUD · Groups · Categories · Bulk Import           │   │
│  └──────────────────────────────┬──────────────────────────────┘   │
│                                 │                                   │
│  ┌──────────────────────────────▼──────────────────────────────┐   │
│  │  2. DATA LAYER                                               │   │
│  │     guests table · guest_groups · guest_categories           │   │
│  │     All rows scoped by tenant_id — enforced by RLS           │   │
│  └──────────────────────────────┬──────────────────────────────┘   │
│                                 │                                   │
│  ┌──────────────────────────────▼──────────────────────────────┐   │
│  │  3. FEATURE & QUOTA LAYER                                    │   │
│  │     Package-driven max_guests · import/export feature flags  │   │
│  │     WhatsApp blast quota · personalized link feature gate    │   │
│  └──────────────────────────────┬──────────────────────────────┘   │
│                                 │                                   │
│  ┌──────────────────────────────▼──────────────────────────────┐   │
│  │  4. INTEGRATION LAYER (prepared, not yet implemented)        │   │
│  │     RSVP correlation · QR check-in · WhatsApp / Email blast  │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 Guest Lifecycle

```
                    ┌─────────────────────────────┐
                    │       QUOTA CHECK            │
                    │   max_guests not reached     │
                    └──────────────┬──────────────┘
                                   │
                          CREATE (manual | import)
                                   │
                                   ▼
                    ┌──────────────────────────────┐
                    │           ACTIVE              │
                    │  - Linked to invitation       │
                    │  - Has personal_token         │
                    │  - Can receive invite link    │
                    │  - Can be in group/category   │
                    └──────┬───────────────┬────────┘
                           │               │
                     UPDATE             SOFT DELETE
                           │               │
                           ▼               ▼
                    ┌──────────────┐  ┌────────────────┐
                    │   UPDATED    │  │    DELETED      │
                    │  (same row)  │  │  deleted_at set │
                    └──────────────┘  │  recoverable   │
                                      └────────────────┘

  Throughout lifecycle, guest is correlated to:
    rsvp_responses   (when guest RSVPs)
    qr_codes         (when personalized QR generated)
    qr_checkins      (when guest checks in at event)
    invitation_events (when guest opens their invite link)
    guestbook_entries (when guest posts a message)
```

### 1.3 Guest Ownership

A guest belongs to exactly one invitation (via `invitation_id`) and one tenant (via `tenant_id`). The `tenant_id` is denormalized onto the `guests` table for performance — it avoids a JOIN to `invitations` on every tenant-scoped query and allows efficient partial indexes.

**Ownership rules:**
- A guest cannot exist without a parent invitation
- Deleting an invitation cascade-deletes all its guests
- A guest cannot be moved between invitations (re-create is the correct pattern)
- `tenant_id` is always inherited from the parent invitation at insert time

### 1.4 Guest Assignment to Invitation

Every guest is assigned to a single invitation at creation time. The assignment is enforced by:
1. The `invitation_id NOT NULL` FK constraint
2. The `tenant_id` must match the invitation's `tenant_id` (validated at app layer)
3. RLS policies that scope all reads/writes to the current tenant

### 1.5 Guest Status Flow

Guest status is not a dedicated column — it is derived from related tables at query time to avoid update contention:

```typescript
// Derived guest status (computed at query time, not stored)
export type GuestDerivedStatus =
  | 'pending'          // No RSVP response yet
  | 'attending'        // rsvp_responses.attendance = 'attending'
  | 'not_attending'    // rsvp_responses.attendance = 'not_attending'
  | 'maybe'           // rsvp_responses.attendance = 'maybe'
  | 'checked_in';     // Has a qr_checkins record

// For display in the guest list, status is resolved via a LEFT JOIN:
// guests LEFT JOIN rsvp_responses ON guest_id = guests.id
//        LEFT JOIN qr_checkins ON guest_id = guests.id
```

**Design decision:** Storing attendance status on the `guests` row would require synchronous updates every time an RSVP is submitted. Using derived status via JOIN keeps the `guests` table as a pure roster and `rsvp_responses` as the immutable truth of attendance.

---

## 2. Guest Data Model

### 2.1 Extended `guests` Table

The base `guests` table from PHASE2 is extended with `group_id` and `category_id` foreign keys to support the group and category systems.

```sql
-- Extension of PHASE2 guests table
-- Adds: group_id FK, category_id FK, pax_count, notes_private

CREATE TABLE guests (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id   UUID        NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  tenant_id       UUID        NOT NULL REFERENCES tenants(id),

  -- Identity
  name            TEXT        NOT NULL,
  phone           TEXT,
  email           TEXT,
  address         TEXT,

  -- Classification (see Sections 4 & 5)
  group_id        UUID        REFERENCES guest_groups(id) ON DELETE SET NULL,
  category_id     UUID        REFERENCES guest_categories(id) ON DELETE SET NULL,
  group_label     TEXT,
  -- Legacy free-text label kept for backward compat.
  -- group_id is the normalized reference going forward.

  -- Invitation delivery
  personal_token  TEXT        NOT NULL UNIQUE DEFAULT gen_random_uuid()::TEXT,
  -- Used in URL: /inv/[slug]?t=[personal_token]
  -- Generated once, never rotated (changing it breaks shared links)

  -- Attendance hint (set by organizer, not RSVP outcome)
  expected_pax    INTEGER     NOT NULL DEFAULT 1 CHECK (expected_pax >= 1),
  -- Expected number of people for this guest entry (e.g. "The Ahmad Family" = 4)

  -- Organizer notes
  notes           TEXT,        -- visible to organizer only, never shown publicly
  tags            TEXT[]      NOT NULL DEFAULT '{}',
  -- Free-form tags for flexible filtering e.g. {"vip", "vegetarian", "parking"}

  -- Import tracking
  imported_from   TEXT        CHECK (imported_from IN ('csv', 'excel', 'manual', 'api')),
  import_batch_id UUID,
  -- References guest_import_batches.id for rollback support

  -- Invite delivery tracking
  is_invited      BOOLEAN     NOT NULL DEFAULT TRUE,
  -- FALSE = in list but invite not yet sent

  invite_sent_at  TIMESTAMPTZ,
  -- Timestamp of last WhatsApp/email invite sent

  -- Soft delete
  deleted_at      TIMESTAMPTZ,

  -- Timestamps
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_guests_updated_at
  BEFORE UPDATE ON guests
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Core indexes
CREATE INDEX idx_guests_invitation    ON guests(invitation_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_guests_tenant        ON guests(tenant_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_guests_token         ON guests(personal_token);
CREATE INDEX idx_guests_phone         ON guests(phone) WHERE phone IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX idx_guests_email         ON guests(email) WHERE email IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX idx_guests_group         ON guests(group_id) WHERE group_id IS NOT NULL;
CREATE INDEX idx_guests_category      ON guests(category_id) WHERE category_id IS NOT NULL;

-- pg_trgm GIN index for fast fuzzy name search (extension enabled in migration 001)
CREATE INDEX idx_guests_name_trgm     ON guests USING GIN (name gin_trgm_ops)
  WHERE deleted_at IS NULL;

-- Composite: invitation + group for group-level counts
CREATE INDEX idx_guests_inv_group     ON guests(invitation_id, group_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_guests_inv_category  ON guests(invitation_id, category_id) WHERE deleted_at IS NULL;

-- Import batch lookups
CREATE INDEX idx_guests_import_batch  ON guests(import_batch_id) WHERE import_batch_id IS NOT NULL;
```

### 2.2 Guest Groups Table

```sql
-- Groups represent social circles e.g. "Keluarga Mempelai Pria", "Teman Kampus"
-- Groups are scoped to an invitation (not shared across invitations)

CREATE TABLE guest_groups (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id   UUID        NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  tenant_id       UUID        NOT NULL REFERENCES tenants(id),
  name            TEXT        NOT NULL,
  -- e.g. "Family", "College Friends", "Colleagues"
  color           TEXT,
  -- Hex color for UI label e.g. "#8B5CF6"
  sort_order      INTEGER     NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (invitation_id, name)
);

CREATE TRIGGER trg_guest_groups_updated_at
  BEFORE UPDATE ON guest_groups
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_guest_groups_invitation ON guest_groups(invitation_id);
CREATE INDEX idx_guest_groups_tenant     ON guest_groups(tenant_id);
```

### 2.3 Guest Categories Table

```sql
-- Categories represent sides/affiliation e.g. "Mempelai Pria", "Mempelai Wanita"
-- Categories are scoped to an invitation

CREATE TABLE guest_categories (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id   UUID        NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  tenant_id       UUID        NOT NULL REFERENCES tenants(id),
  name            TEXT        NOT NULL,
  -- e.g. "Bride Side", "Groom Side", "Mutual"
  description     TEXT,
  color           TEXT,
  sort_order      INTEGER     NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (invitation_id, name)
);

CREATE TRIGGER trg_guest_categories_updated_at
  BEFORE UPDATE ON guest_categories
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_guest_categories_invitation ON guest_categories(invitation_id);
CREATE INDEX idx_guest_categories_tenant     ON guest_categories(tenant_id);
```

### 2.4 Guest Import Batches Table

```sql
-- Tracks every bulk import session for rollback and audit purposes

CREATE TABLE guest_import_batches (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id   UUID        NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  tenant_id       UUID        NOT NULL REFERENCES tenants(id),
  imported_by     UUID        NOT NULL REFERENCES users(id),
  source_type     TEXT        NOT NULL CHECK (source_type IN ('csv', 'excel')),
  original_filename TEXT,
  total_rows      INTEGER     NOT NULL DEFAULT 0,
  imported_count  INTEGER     NOT NULL DEFAULT 0,
  skipped_count   INTEGER     NOT NULL DEFAULT 0,
  error_count     INTEGER     NOT NULL DEFAULT 0,
  status          TEXT        NOT NULL DEFAULT 'pending'
                              CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'rolled_back')),
  error_log       JSONB       NOT NULL DEFAULT '[]',
  -- Array of { row, field, message } objects
  rolled_back_at  TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at    TIMESTAMPTZ
);

CREATE INDEX idx_import_batches_invitation ON guest_import_batches(invitation_id);
CREATE INDEX idx_import_batches_tenant     ON guest_import_batches(tenant_id, created_at DESC);
CREATE INDEX idx_import_batches_status     ON guest_import_batches(status)
  WHERE status IN ('pending', 'processing');
```

### 2.5 Full Entity Relationship Graph

```
tenants
  │
  ├──── invitations
  │         │
  │         ├──── guest_groups          (1:many, cascade delete, UNIQUE name per inv)
  │         │
  │         ├──── guest_categories      (1:many, cascade delete, UNIQUE name per inv)
  │         │
  │         ├──── guest_import_batches  (1:many, cascade delete, audit trail)
  │         │
  │         └──── guests                (1:many, soft delete)
  │                   │
  │                   ├── group_id ──────────────► guest_groups.id (nullable)
  │                   │
  │                   ├── category_id ────────────► guest_categories.id (nullable)
  │                   │
  │                   ├── import_batch_id ─────────► guest_import_batches.id (nullable)
  │                   │
  │                   ├──── rsvp_responses          (1:many, guest_id nullable)
  │                   │
  │                   ├──── guestbook_entries        (1:many, guest_id nullable)
  │                   │
  │                   ├──── qr_codes                (1:1 per guest type)
  │                   │
  │                   └──── invitation_events        (1:many, guest_id nullable)
  │
  └──── users ─────────────────────────────── (imported_by, checked_in_by)
```

### 2.6 TypeScript Type Definitions

```typescript
// types/guest.ts

export interface Guest {
  id:              string;
  invitation_id:   string;
  tenant_id:       string;
  name:            string;
  phone:           string | null;
  email:           string | null;
  address:         string | null;
  group_id:        string | null;
  category_id:     string | null;
  group_label:     string | null;   // legacy free-text
  personal_token:  string;
  expected_pax:    number;
  notes:           string | null;
  tags:            string[];
  imported_from:   'csv' | 'excel' | 'manual' | 'api' | null;
  import_batch_id: string | null;
  is_invited:      boolean;
  invite_sent_at:  string | null;
  deleted_at:      string | null;
  created_at:      string;
  updated_at:      string;
}

export interface GuestWithStatus extends Guest {
  // Derived via JOIN — not stored
  rsvp_attendance:  'attending' | 'not_attending' | 'maybe' | null;
  rsvp_pax_count:   number | null;
  rsvp_submitted_at: string | null;
  is_checked_in:    boolean;
  checked_in_at:    string | null;
  // Joined relations
  group:            GuestGroup | null;
  category:         GuestCategory | null;
}

export interface GuestGroup {
  id:           string;
  invitation_id: string;
  tenant_id:    string;
  name:         string;
  color:        string | null;
  sort_order:   number;
  // Computed
  guest_count?: number;
}

export interface GuestCategory {
  id:           string;
  invitation_id: string;
  tenant_id:    string;
  name:         string;
  description:  string | null;
  color:        string | null;
  sort_order:   number;
  // Computed
  guest_count?: number;
}

export interface GuestImportBatch {
  id:               string;
  invitation_id:    string;
  tenant_id:        string;
  imported_by:      string;
  source_type:      'csv' | 'excel';
  original_filename: string | null;
  total_rows:       number;
  imported_count:   number;
  skipped_count:    number;
  error_count:      number;
  status:           'pending' | 'processing' | 'completed' | 'failed' | 'rolled_back';
  error_log:        ImportError[];
  rolled_back_at:   string | null;
  created_at:       string;
  completed_at:     string | null;
}

export interface ImportError {
  row:     number;
  field:   string;
  message: string;
  value?:  unknown;
}
```

---

## 3. Guest Creation Flow

### 3.1 Manual Guest Creation

Single guest creation via a modal form. Validates quota before inserting.

```typescript
// app/api/invitations/[id]/guests/route.ts

import { z } from 'zod';
import { requireAuth } from '@/lib/auth/api-guard';
import { checkQuota } from '@/lib/packages/quota';
import { writeAuditLog } from '@/lib/audit/write';

const CreateGuestSchema = z.object({
  name:         z.string().min(1).max(150).trim(),
  phone:        z.string().max(20).trim().nullable().optional(),
  email:        z.string().email().max(254).toLowerCase().trim().nullable().optional(),
  address:      z.string().max(500).trim().nullable().optional(),
  group_id:     z.string().uuid().nullable().optional(),
  category_id:  z.string().uuid().nullable().optional(),
  expected_pax: z.coerce.number().int().min(1).max(20).default(1),
  notes:        z.string().max(1000).trim().nullable().optional(),
  tags:         z.array(z.string().max(50)).max(10).default([]),
});

export async function POST(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'guest:write');
  if (auth instanceof NextResponse) return auth;

  const body = await request.json();
  const parsed = CreateGuestSchema.safeParse(body);
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.flatten() }, { status: 422 });
  }

  // Quota check — max_guests is per invitation, not per tenant
  const quota = await checkGuestQuota(auth.user.tenantId, params.id);
  if (!quota.allowed) {
    return NextResponse.json(
      {
        error: `Guest limit reached (${quota.limit} guests per invitation). Upgrade your plan to add more.`,
        quota,
      },
      { status: 422 }
    );
  }

  const supabase = createServerClient();

  // Verify group_id and category_id belong to this invitation
  if (parsed.data.group_id) {
    const { data: group } = await supabase
      .from('guest_groups')
      .select('id')
      .eq('id', parsed.data.group_id)
      .eq('invitation_id', params.id)
      .single();
    if (!group) {
      return NextResponse.json({ error: 'Invalid group_id for this invitation' }, { status: 422 });
    }
  }

  if (parsed.data.category_id) {
    const { data: category } = await supabase
      .from('guest_categories')
      .select('id')
      .eq('id', parsed.data.category_id)
      .eq('invitation_id', params.id)
      .single();
    if (!category) {
      return NextResponse.json({ error: 'Invalid category_id for this invitation' }, { status: 422 });
    }
  }

  const { data: guest, error } = await supabase
    .from('guests')
    .insert({
      invitation_id:   params.id,
      tenant_id:       auth.user.tenantId,
      name:            parsed.data.name,
      phone:           parsed.data.phone ?? null,
      email:           parsed.data.email ?? null,
      address:         parsed.data.address ?? null,
      group_id:        parsed.data.group_id ?? null,
      category_id:     parsed.data.category_id ?? null,
      expected_pax:    parsed.data.expected_pax,
      notes:           parsed.data.notes ?? null,
      tags:            parsed.data.tags,
      imported_from:   'manual',
      is_invited:      true,
    })
    .select()
    .single();

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }

  return NextResponse.json(guest, { status: 201 });
}
```

### 3.2 Bulk Guest Creation (Programmatic)

Used internally by the import system. Inserts in batches of 100 rows per statement to stay within Supabase payload limits.

```typescript
// lib/guests/bulk-create.ts

export async function bulkCreateGuests(
  supabase: SupabaseClient,
  invitationId: string,
  tenantId: string,
  importBatchId: string,
  guests: GuestInsertRow[],
  batchSize = 100
): Promise<{ inserted: number; errors: ImportError[] }> {
  let inserted = 0;
  const errors: ImportError[] = [];

  for (let i = 0; i < guests.length; i += batchSize) {
    const chunk = guests.slice(i, i + batchSize);

    const rows = chunk.map(g => ({
      invitation_id:   invitationId,
      tenant_id:       tenantId,
      name:            g.name,
      phone:           g.phone ?? null,
      email:           g.email ?? null,
      address:         g.address ?? null,
      group_id:        g.group_id ?? null,
      category_id:     g.category_id ?? null,
      expected_pax:    g.expected_pax ?? 1,
      notes:           g.notes ?? null,
      tags:            g.tags ?? [],
      imported_from:   g.source_type,
      import_batch_id: importBatchId,
      is_invited:      true,
    }));

    const { error, count } = await supabase
      .from('guests')
      .insert(rows, { count: 'exact' });

    if (error) {
      // Log chunk-level error; continue with next chunk
      errors.push({
        row: i,
        field: '_batch',
        message: `Batch insert failed: ${error.message}`,
      });
    } else {
      inserted += count ?? 0;
    }
  }

  return { inserted, errors };
}
```

### 3.3 Duplicate Detection

Duplicate detection runs at the application layer before insertion, checking for matching phone or email within the same invitation. It is a soft warning — not a hard block — because different people can share a phone (family).

```typescript
// lib/guests/duplicate-detector.ts

export interface DuplicateCheckResult {
  isDuplicate: boolean;
  matchedOn:   'phone' | 'email' | 'name' | null;
  existingGuest: { id: string; name: string } | null;
}

export async function checkForDuplicate(
  supabase: SupabaseClient,
  invitationId: string,
  candidate: { name: string; phone?: string | null; email?: string | null }
): Promise<DuplicateCheckResult> {
  // Priority: phone > email > name (exact)
  if (candidate.phone) {
    const { data } = await supabase
      .from('guests')
      .select('id, name')
      .eq('invitation_id', invitationId)
      .eq('phone', candidate.phone)
      .is('deleted_at', null)
      .maybeSingle();

    if (data) return { isDuplicate: true, matchedOn: 'phone', existingGuest: data };
  }

  if (candidate.email) {
    const { data } = await supabase
      .from('guests')
      .select('id, name')
      .eq('invitation_id', invitationId)
      .eq('email', candidate.email)
      .is('deleted_at', null)
      .maybeSingle();

    if (data) return { isDuplicate: true, matchedOn: 'email', existingGuest: data };
  }

  // Exact name match as last resort
  const { data } = await supabase
    .from('guests')
    .select('id, name')
    .eq('invitation_id', invitationId)
    .ilike('name', candidate.name.trim())
    .is('deleted_at', null)
    .maybeSingle();

  if (data) return { isDuplicate: true, matchedOn: 'name', existingGuest: data };

  return { isDuplicate: false, matchedOn: null, existingGuest: null };
}
```

**Duplicate behavior during bulk import:**
- `SKIP` mode — duplicates are skipped and counted in `skipped_count`
- `UPDATE` mode — existing guest record is updated with new data (name, pax, group)
- `ALLOW` mode — inserts regardless (for families sharing a phone)

The user selects the mode in the import preview step before committing.

### 3.4 Guest Validation Schema

```typescript
// lib/guests/validation.ts

import { z } from 'zod';

export const GuestValidationSchema = z.object({
  name:         z.string()
    .min(1, 'Name is required')
    .max(150, 'Name must be under 150 characters')
    .trim(),
  phone:        z.string()
    .regex(/^[+\d\s\-()]{7,20}$/, 'Invalid phone format')
    .nullable()
    .optional(),
  email:        z.string()
    .email('Invalid email address')
    .max(254)
    .toLowerCase()
    .nullable()
    .optional(),
  expected_pax: z.coerce.number()
    .int()
    .min(1, 'Must be at least 1')
    .max(20, 'Maximum 20 people per guest entry')
    .default(1),
  group_id:     z.string().uuid().nullable().optional(),
  category_id:  z.string().uuid().nullable().optional(),
  notes:        z.string().max(1000).nullable().optional(),
  tags:         z.array(z.string().max(50).trim()).max(10).default([]),
});

export type GuestInput = z.infer<typeof GuestValidationSchema>;

// Batch validation — returns per-row errors without throwing
export function validateGuestRows(rows: unknown[]): {
  valid: GuestInput[];
  errors: Array<{ row: number; issues: z.ZodIssue[] }>;
} {
  const valid: GuestInput[] = [];
  const errors: Array<{ row: number; issues: z.ZodIssue[] }> = [];

  rows.forEach((row, index) => {
    const result = GuestValidationSchema.safeParse(row);
    if (result.success) {
      valid.push(result.data);
    } else {
      errors.push({ row: index + 1, issues: result.error.issues });
    }
  });

  return { valid, errors };
}
```

---

## 4. Guest Group System

### 4.1 Design Philosophy

Groups represent the **social circle** of the guest — who they are to the couple (college friends, family, coworkers). Groups are invitation-scoped: the same group name can exist on multiple invitations without collision.

**Group vs Category distinction:**
- **Group** = relationship type → "Teman Kampus", "Keluarga Besar", "Rekan Kerja"
- **Category** = which side of the wedding → "Mempelai Pria", "Mempelai Wanita", "Bersama"

A guest has one group AND one category (both nullable).

### 4.2 Default Groups

When a new invitation is created, a default set of groups is seeded for the invitation. Users can rename, delete, or add groups.

```typescript
// config/guest-defaults.ts

export const DEFAULT_GUEST_GROUPS = [
  { name: 'Family',     color: '#8B5CF6', sort_order: 0 },
  { name: 'Friends',    color: '#3B82F6', sort_order: 1 },
  { name: 'Colleagues', color: '#10B981', sort_order: 2 },
  { name: 'VIP',        color: '#F59E0B', sort_order: 3 },
] as const;

export const DEFAULT_GUEST_CATEGORIES = [
  { name: 'Groom Side', color: '#6366F1', sort_order: 0 },
  { name: 'Bride Side', color: '#EC4899', sort_order: 1 },
  { name: 'Mutual',     color: '#6B7280', sort_order: 2 },
] as const;
```

These are seeded via the invitation creation flow after the invitation row is inserted.

### 4.3 Group Management API

```typescript
// app/api/invitations/[id]/groups/route.ts

// GET  — List all groups for an invitation (with guest counts)
// POST — Create a new group

export async function GET(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'guest:read');
  if (auth instanceof NextResponse) return auth;

  const supabase = createServerClient();

  // Fetch groups with guest counts via a subquery
  const { data: groups, error } = await supabase
    .from('guest_groups')
    .select(`
      id, name, color, sort_order,
      guest_count:guests(count)
    `)
    .eq('invitation_id', params.id)
    .eq('tenant_id', auth.user.tenantId)
    .order('sort_order');

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  return NextResponse.json(groups);
}

export async function POST(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'guest:write');
  if (auth instanceof NextResponse) return auth;

  const { name, color } = await request.json();

  if (!name?.trim()) {
    return NextResponse.json({ error: 'Group name is required' }, { status: 422 });
  }

  const supabase = createServerClient();

  // Get next sort_order
  const { data: last } = await supabase
    .from('guest_groups')
    .select('sort_order')
    .eq('invitation_id', params.id)
    .order('sort_order', { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data: group, error } = await supabase
    .from('guest_groups')
    .insert({
      invitation_id: params.id,
      tenant_id:     auth.user.tenantId,
      name:          name.trim(),
      color:         color ?? null,
      sort_order:    (last?.sort_order ?? -1) + 1,
    })
    .select()
    .single();

  if (error?.code === '23505') {
    return NextResponse.json(
      { error: `A group named "${name.trim()}" already exists for this invitation.` },
      { status: 409 }
    );
  }
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  return NextResponse.json(group, { status: 201 });
}

// PATCH /api/invitations/[id]/groups/[groupId] — rename, recolor
// DELETE /api/invitations/[id]/groups/[groupId] — delete; guests.group_id set NULL
// POST /api/invitations/[id]/groups/reorder     — batch sort_order update
```

### 4.4 Built-In Group Labels

For backward compatibility with the legacy `group_label` free-text field (from PHASE2), the API accepts both `group_id` (normalized) and `group_label` (free-text). When `group_id` is provided it takes precedence. The legacy `group_label` remains on the schema for tenants that imported data before the group system existed.

```typescript
// lib/guests/group-resolver.ts

export async function resolveGroupDisplay(guest: Guest): Promise<string> {
  if (guest.group_id && guest.group) {
    return guest.group.name;
  }
  if (guest.group_label) {
    return guest.group_label;
  }
  return '—';
}
```

---

## 5. Guest Category System

### 5.1 Design Philosophy

Categories represent the **wedding side affiliation** of the guest. Unlike groups, which are open-ended, categories are typically limited in number (2–5 per invitation). They are used to split the guest list by family side for seating, coordination, and analytics.

### 5.2 Category Management API

```typescript
// app/api/invitations/[id]/categories/route.ts

// GET  — List all categories with guest counts
// POST — Create a new category

const CategorySchema = z.object({
  name:        z.string().min(1).max(100).trim(),
  description: z.string().max(300).trim().nullable().optional(),
  color:       z.string().regex(/^#[0-9A-Fa-f]{6}$/).nullable().optional(),
});

export async function POST(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'guest:write');
  if (auth instanceof NextResponse) return auth;

  const parsed = CategorySchema.safeParse(await request.json());
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.flatten() }, { status: 422 });
  }

  const supabase = createServerClient();

  const { data: last } = await supabase
    .from('guest_categories')
    .select('sort_order')
    .eq('invitation_id', params.id)
    .order('sort_order', { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data: category, error } = await supabase
    .from('guest_categories')
    .insert({
      invitation_id: params.id,
      tenant_id:     auth.user.tenantId,
      name:          parsed.data.name,
      description:   parsed.data.description ?? null,
      color:         parsed.data.color ?? null,
      sort_order:    (last?.sort_order ?? -1) + 1,
    })
    .select()
    .single();

  if (error?.code === '23505') {
    return NextResponse.json(
      { error: `A category named "${parsed.data.name}" already exists.` },
      { status: 409 }
    );
  }
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  return NextResponse.json(category, { status: 201 });
}
```

### 5.3 Category Analytics Query

```sql
-- Summary of guests by category for a given invitation
-- Used in the guest management dashboard header stats

SELECT
  gc.id,
  gc.name,
  gc.color,
  COUNT(g.id)                                        AS total_guests,
  COUNT(r.id) FILTER (WHERE r.attendance = 'attending')   AS attending,
  COUNT(r.id) FILTER (WHERE r.attendance = 'not_attending') AS not_attending,
  COUNT(r.id) FILTER (WHERE r.id IS NULL)            AS pending,
  SUM(g.expected_pax)                                AS expected_pax
FROM guest_categories gc
LEFT JOIN guests g
  ON g.category_id = gc.id
  AND g.deleted_at IS NULL
LEFT JOIN LATERAL (
  SELECT attendance
  FROM rsvp_responses
  WHERE guest_id = g.id
  ORDER BY submitted_at DESC
  LIMIT 1
) r ON TRUE
WHERE gc.invitation_id = $1
  AND gc.tenant_id = $2
GROUP BY gc.id, gc.name, gc.color
ORDER BY gc.sort_order;
```

---

## 6. Bulk Import System

### 6.1 Import Architecture Overview

```
User selects file (CSV or Excel)
  │
  ▼
Client: parse file in browser (Papa Parse / SheetJS)
  → Preview first 5 rows
  │
  ▼
Column Mapper UI
  → User maps columns: Name, Phone, Email, Group, Category, Pax
  │
  ▼
POST /api/invitations/[id]/guests/import/preview
  → Server validates all rows (Zod)
  → Runs duplicate detection
  → Returns: valid_count, duplicate_count, error_count, preview_rows
  │
  ▼
User reviews preview, selects duplicate strategy (SKIP / UPDATE / ALLOW)
  │
  ▼
POST /api/invitations/[id]/guests/import/commit
  → Quota check (current + valid_count <= max_guests)
  → Creates guest_import_batches row
  → Bulk inserts in chunks of 100
  → Updates batch status: completed / failed
  │
  ▼
Response: { batch_id, imported, skipped, errors }
  │
  ▼
Optional: POST /api/invitations/[id]/guests/import/[batchId]/rollback
  → Soft-deletes all guests with import_batch_id = batchId
```

### 6.2 Feature Gate

Bulk import requires the `guest_import_csv` feature flag.

```typescript
// app/api/invitations/[id]/guests/import/preview/route.ts

export async function POST(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'guest:write');
  if (auth instanceof NextResponse) return auth;

  // Feature gate
  const resolution = await resolveFeature(
    { tenantId: auth.user.tenantId, packageId: auth.user.packageId },
    'guest_import_csv'
  );
  if (!resolution.enabled) {
    return NextResponse.json(
      { error: 'CSV import requires a Premium plan or above.' },
      { status: 403 }
    );
  }

  // ... proceed with preview logic
}
```

### 6.3 File Parsing (Client-Side)

Client-side parsing keeps large files off the server during the preview step. The raw parsed rows are sent to the server only for validation.

```typescript
// lib/guests/import-parser.ts

import Papa from 'papaparse';
import * as XLSX from 'xlsx';

export interface RawImportRow {
  [key: string]: string;
}

export function parseCSV(file: File): Promise<RawImportRow[]> {
  return new Promise((resolve, reject) => {
    Papa.parse(file, {
      header: true,
      skipEmptyLines: true,
      trimHeaders: true,
      transform: (value) => value.trim(),
      complete: (result) => resolve(result.data as RawImportRow[]),
      error: (err) => reject(err),
    });
  });
}

export function parseExcel(file: File): Promise<RawImportRow[]> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = (e) => {
      try {
        const data = new Uint8Array(e.target!.result as ArrayBuffer);
        const workbook = XLSX.read(data, { type: 'array' });
        const sheet = workbook.Sheets[workbook.SheetNames[0]];
        const rows = XLSX.utils.sheet_to_json<RawImportRow>(sheet, {
          defval: '',
          raw: false,
        });
        resolve(rows);
      } catch (err) {
        reject(err);
      }
    };
    reader.readAsArrayBuffer(file);
  });
}
```

### 6.4 Column Mapper Component

```typescript
// components/guests/import/ColumnMapper.tsx

'use client';

// Maps raw file columns to the guest schema fields
// User drags or selects which file column = which guest field

interface ColumnMapperProps {
  fileColumns: string[];           // headers from the uploaded file
  previewRows: RawImportRow[];    // first 5 rows for preview
  onMappingChange: (mapping: ColumnMapping) => void;
}

export interface ColumnMapping {
  name:         string | null;  // required
  phone:        string | null;
  email:        string | null;
  group:        string | null;  // will be looked up by name in guest_groups
  category:     string | null;  // will be looked up by name in guest_categories
  expected_pax: string | null;
  notes:        string | null;
}

// Auto-detect mapping by fuzzy matching column headers
export function autoDetectMapping(columns: string[]): Partial<ColumnMapping> {
  const normalize = (s: string) => s.toLowerCase().replace(/[^a-z]/g, '');
  const mapping: Partial<ColumnMapping> = {};

  for (const col of columns) {
    const n = normalize(col);
    if (['name', 'nama', 'fullname', 'namalengkap'].includes(n)) mapping.name = col;
    else if (['phone', 'hp', 'telepon', 'nohp', 'mobile', 'handphone'].includes(n)) mapping.phone = col;
    else if (['email', 'emailaddress', 'surel'].includes(n)) mapping.email = col;
    else if (['group', 'grup', 'kelompok', 'circle'].includes(n)) mapping.group = col;
    else if (['category', 'kategori', 'side', 'pihak'].includes(n)) mapping.category = col;
    else if (['pax', 'jumlah', 'orang', 'count', 'qty'].includes(n)) mapping.expected_pax = col;
    else if (['notes', 'catatan', 'note', 'remarks'].includes(n)) mapping.notes = col;
  }

  return mapping;
}
```

### 6.5 Import Preview Server Action

```typescript
// app/api/invitations/[id]/guests/import/preview/route.ts

const PreviewRequestSchema = z.object({
  rows:    z.array(z.record(z.string())).max(5000),
  mapping: z.object({
    name:         z.string(),
    phone:        z.string().nullable(),
    email:        z.string().nullable(),
    group:        z.string().nullable(),
    category:     z.string().nullable(),
    expected_pax: z.string().nullable(),
    notes:        z.string().nullable(),
  }),
});

export async function POST(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'guest:write');
  if (auth instanceof NextResponse) return auth;

  const body = await request.json();
  const parsed = PreviewRequestSchema.safeParse(body);
  if (!parsed.success) {
    return NextResponse.json({ error: 'Invalid request' }, { status: 422 });
  }

  const { rows, mapping } = parsed.data;
  const supabase = createServerClient();

  // Load existing groups and categories for name resolution
  const [groupsResult, categoriesResult] = await Promise.all([
    supabase.from('guest_groups').select('id, name').eq('invitation_id', params.id),
    supabase.from('guest_categories').select('id, name').eq('invitation_id', params.id),
  ]);

  const groupMap = new Map(
    (groupsResult.data ?? []).map(g => [g.name.toLowerCase(), g.id])
  );
  const categoryMap = new Map(
    (categoriesResult.data ?? []).map(c => [c.name.toLowerCase(), c.id])
  );

  // Map raw rows to guest inputs
  const mapped = rows.map((row, index) => ({
    _row:         index + 1,
    name:         mapping.name ? row[mapping.name]?.trim() : '',
    phone:        mapping.phone ? row[mapping.phone]?.trim() || null : null,
    email:        mapping.email ? row[mapping.email]?.trim() || null : null,
    expected_pax: mapping.expected_pax
      ? parseInt(row[mapping.expected_pax] ?? '1', 10) || 1
      : 1,
    group_id:     mapping.group && row[mapping.group]
      ? groupMap.get(row[mapping.group].toLowerCase().trim()) ?? null
      : null,
    category_id:  mapping.category && row[mapping.category]
      ? categoryMap.get(row[mapping.category].toLowerCase().trim()) ?? null
      : null,
    notes:        mapping.notes ? row[mapping.notes]?.trim() || null : null,
    // Preserve raw group/category text for display even if not mapped
    _raw_group:   mapping.group ? row[mapping.group]?.trim() : null,
    _raw_category: mapping.category ? row[mapping.category]?.trim() : null,
  }));

  // Validate rows
  const { valid, errors } = validateGuestRows(mapped);

  // Run duplicate detection on valid rows (batch phone/email lookup)
  const phones = valid.map(g => g.phone).filter(Boolean) as string[];
  const emails = valid.map(g => g.email).filter(Boolean) as string[];

  const [existingByPhone, existingByEmail] = await Promise.all([
    phones.length
      ? supabase.from('guests').select('phone, id, name').eq('invitation_id', params.id).in('phone', phones).is('deleted_at', null)
      : Promise.resolve({ data: [] }),
    emails.length
      ? supabase.from('guests').select('email, id, name').eq('invitation_id', params.id).in('email', emails).is('deleted_at', null)
      : Promise.resolve({ data: [] }),
  ]);

  const duplicatePhones = new Set((existingByPhone.data ?? []).map(g => g.phone));
  const duplicateEmails = new Set((existingByEmail.data ?? []).map(g => g.email));

  const duplicates = valid.filter(
    g => (g.phone && duplicatePhones.has(g.phone)) ||
         (g.email && duplicateEmails.has(g.email))
  );

  return NextResponse.json({
    total_rows:      rows.length,
    valid_count:     valid.length,
    duplicate_count: duplicates.length,
    error_count:     errors.length,
    preview_rows:    mapped.slice(0, 5),
    errors:          errors.slice(0, 50), // cap error list for response size
    unmapped_groups: [...new Set(
      mapped.map(r => r._raw_group).filter(Boolean)
    )].filter(name => !groupMap.has(name!.toLowerCase())),
    unmapped_categories: [...new Set(
      mapped.map(r => r._raw_category).filter(Boolean)
    )].filter(name => !categoryMap.has(name!.toLowerCase())),
  });
}
```

### 6.6 Import Commit Action

```typescript
// app/api/invitations/[id]/guests/import/commit/route.ts

const CommitRequestSchema = z.object({
  rows:               z.array(z.record(z.string())).max(5000),
  mapping:            PreviewRequestSchema.shape.mapping,
  duplicate_strategy: z.enum(['skip', 'update', 'allow']).default('skip'),
  source_type:        z.enum(['csv', 'excel']),
  filename:           z.string().max(255).optional(),
});

export async function POST(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'guest:write');
  if (auth instanceof NextResponse) return auth;

  const parsed = CommitRequestSchema.safeParse(await request.json());
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.flatten() }, { status: 422 });
  }

  const { rows, mapping, duplicate_strategy, source_type, filename } = parsed.data;
  const supabase = createServerClient();

  // Final quota check
  const quota = await checkGuestQuota(auth.user.tenantId, params.id);
  if (!quota.allowed) {
    return NextResponse.json(
      { error: `Guest limit already reached. Upgrade to import more.` },
      { status: 422 }
    );
  }

  const remainingSlots = quota.limit === -1 ? Infinity : quota.remaining;
  if (rows.length > remainingSlots) {
    return NextResponse.json(
      { error: `Import would exceed quota. You can import up to ${remainingSlots} more guests.` },
      { status: 422 }
    );
  }

  // Create import batch record
  const { data: batch, error: batchError } = await supabase
    .from('guest_import_batches')
    .insert({
      invitation_id:    params.id,
      tenant_id:        auth.user.tenantId,
      imported_by:      auth.user.id,
      source_type,
      original_filename: filename ?? null,
      total_rows:       rows.length,
      status:           'processing',
    })
    .select('id')
    .single();

  if (batchError || !batch) {
    return NextResponse.json({ error: 'Failed to start import' }, { status: 500 });
  }

  // Map + validate
  const { valid, errors } = validateGuestRows(
    mapRawRowsToGuests(rows, mapping, groupMap, categoryMap, source_type)
  );

  // Run bulk insert with duplicate handling
  const { inserted, errors: insertErrors } = await bulkCreateGuests(
    supabase,
    params.id,
    auth.user.tenantId,
    batch.id,
    valid,
  );

  const allErrors = [...errors.map(e => ({ row: e.row, field: '_validation', message: e.issues.map(i => i.message).join(', ') })), ...insertErrors];

  // Update batch record
  await supabase
    .from('guest_import_batches')
    .update({
      imported_count: inserted,
      skipped_count:  rows.length - valid.length,
      error_count:    allErrors.length,
      error_log:      allErrors,
      status:         allErrors.length === rows.length ? 'failed' : 'completed',
      completed_at:   new Date().toISOString(),
    })
    .eq('id', batch.id);

  return NextResponse.json({
    batch_id: batch.id,
    imported: inserted,
    skipped:  rows.length - valid.length,
    errors:   allErrors.length,
  });
}
```

### 6.7 Rollback Strategy

```typescript
// app/api/invitations/[id]/guests/import/[batchId]/rollback/route.ts

export async function POST(
  request: Request,
  { params }: { params: { id: string; batchId: string } }
) {
  const auth = await requireAuth(request, 'guest:write');
  if (auth instanceof NextResponse) return auth;

  const supabase = createServerClient();

  // Verify batch belongs to this invitation and tenant
  const { data: batch } = await supabase
    .from('guest_import_batches')
    .select('id, status, imported_count')
    .eq('id', params.batchId)
    .eq('invitation_id', params.id)
    .eq('tenant_id', auth.user.tenantId)
    .single();

  if (!batch) {
    return NextResponse.json({ error: 'Import batch not found' }, { status: 404 });
  }

  if (batch.status === 'rolled_back') {
    return NextResponse.json({ error: 'Already rolled back' }, { status: 409 });
  }

  // Soft-delete all guests from this batch
  const { count, error } = await supabase
    .from('guests')
    .update({ deleted_at: new Date().toISOString() })
    .eq('import_batch_id', params.batchId)
    .eq('tenant_id', auth.user.tenantId)
    .is('deleted_at', null);

  if (error) {
    return NextResponse.json({ error: 'Rollback failed' }, { status: 500 });
  }

  // Update batch status
  await supabase
    .from('guest_import_batches')
    .update({ status: 'rolled_back', rolled_back_at: new Date().toISOString() })
    .eq('id', params.batchId);

  await writeAuditLog(request, 'guest_import.rollback', 'guest_import_batch', params.batchId, {
    tenantId: auth.user.tenantId,
    userId:   auth.user.id,
    newData:  { rolled_back_guests: count },
  });

  return NextResponse.json({ rolled_back: count });
}
```

### 6.8 Export System

```typescript
// app/api/invitations/[id]/guests/export/route.ts

export async function GET(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'guest:read');
  if (auth instanceof NextResponse) return auth;

  // Feature gate
  const resolution = await resolveFeature(
    { tenantId: auth.user.tenantId, packageId: auth.user.packageId },
    'guest_export_csv'
  );
  if (!resolution.enabled) {
    return NextResponse.json(
      { error: 'Guest export requires a Premium plan or above.' },
      { status: 403 }
    );
  }

  const supabase = createServerClient();

  // Fetch guests with RSVP status via join
  const { data: guests, error } = await supabase
    .from('guests')
    .select(`
      name, phone, email, address, expected_pax, notes, tags,
      is_invited, invite_sent_at, created_at,
      group:guest_groups(name),
      category:guest_categories(name),
      rsvp:rsvp_responses(attendance, pax_count, submitted_at)
    `)
    .eq('invitation_id', params.id)
    .eq('tenant_id', auth.user.tenantId)
    .is('deleted_at', null)
    .order('name');

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  // Build CSV
  const headers = [
    'Name', 'Phone', 'Email', 'Address', 'Group', 'Category',
    'Expected Pax', 'RSVP Status', 'RSVP Pax', 'RSVP Submitted',
    'Invited', 'Invite Sent', 'Notes', 'Tags', 'Added On',
  ];

  const csvRows = (guests ?? []).map(g => [
    g.name,
    g.phone ?? '',
    g.email ?? '',
    g.address ?? '',
    (g.group as any)?.name ?? '',
    (g.category as any)?.name ?? '',
    g.expected_pax,
    (g.rsvp as any)?.[0]?.attendance ?? 'pending',
    (g.rsvp as any)?.[0]?.pax_count ?? '',
    (g.rsvp as any)?.[0]?.submitted_at ?? '',
    g.is_invited ? 'Yes' : 'No',
    g.invite_sent_at ?? '',
    g.notes ?? '',
    (g.tags ?? []).join(', '),
    g.created_at,
  ]);

  const csvContent = [headers, ...csvRows]
    .map(row => row.map(cell => `"${String(cell).replace(/"/g, '""')}"`).join(','))
    .join('\n');

  return new Response(csvContent, {
    headers: {
      'Content-Type': 'text/csv; charset=utf-8',
      'Content-Disposition': `attachment; filename="guests-${params.id}.csv"`,
    },
  });
}
```

---

## 7. Personalized Invitation System

### 7.1 Personal Token Architecture

Every guest record has a `personal_token` — a UUID-v4 string generated at creation time and never changed. The token is appended to the public invitation URL as a query parameter:

```
https://inv.weddingplatform.com/andi-ninah-2026?t=3a7f8c2d-...
```

**Security properties:**
- Non-guessable (UUID-v4 = 122 bits of entropy)
- Never rotated (changing it breaks sent links)
- Not a secret — it identifies the guest, not authenticates them
- Only meaningful when combined with a valid `invitation_id` context

### 7.2 Feature Gate

Personalized links require the `guest_personalized_link` feature. On plans without this feature, all guests share the same public URL (no `?t=` parameter).

```typescript
// lib/guests/personalized-link.ts

import { resolveFeature } from '@/lib/packages/feature-resolver';

export async function canUsePersonalizedLinks(
  tenantId: string,
  packageId: string
): Promise<boolean> {
  const resolution = await resolveFeature(
    { tenantId, packageId },
    'guest_personalized_link'
  );
  return resolution.enabled;
}

export function buildPersonalizedUrl(
  invitationSlug: string,
  personalToken: string,
  customDomain?: string
): string {
  const base = customDomain
    ? `https://${customDomain}/${invitationSlug}`
    : `${process.env.NEXT_PUBLIC_INVITATION_BASE_URL}/${invitationSlug}`;
  return `${base}?t=${personalToken}`;
}
```

### 7.3 Public Page — Token Resolution

When a guest opens their personalized link, the public invitation page reads the `?t=` parameter, looks up the guest record, and passes the guest context to the renderer.

```typescript
// app/inv/[slug]/page.tsx (relevant portion)

export default async function InvitationPage({
  params,
  searchParams,
}: {
  params: { slug: string };
  searchParams: { t?: string };
}) {
  const supabase = createServerClient();

  // ... fetch invitation ...

  // Resolve guest from personal token
  let guest: GuestContext | null = null;
  if (searchParams.t) {
    const { data: guestRow } = await supabase
      .from('guests')
      .select('id, name, group_id, category_id, expected_pax')
      .eq('personal_token', searchParams.t)
      .eq('invitation_id', invitation.id)
      .is('deleted_at', null)
      .maybeSingle();

    if (guestRow) {
      guest = guestRow;

      // Record the page view event with guest context
      await supabase.from('invitation_events').insert({
        invitation_id: invitation.id,
        tenant_id:     invitation.tenant_id,
        event_type:    'page_view',
        guest_id:      guestRow.id,
        session_id:    searchParams.t,
        metadata:      { referrer: 'personalized_link' },
      });
    }
  }

  return (
    <InvitationRenderer
      invitationData={{ ...invitation, resolvedFeatures }}
      customization={invitation.customization}
      guestToken={searchParams.t}
      guest={guest}
    />
  );
}
```

### 7.4 Personalized Greeting in Theme

The theme renderer uses the guest context to personalize the hero section greeting:

```typescript
// components/invitation/themes/classic/sections/HeroSection.tsx

interface HeroSectionProps extends SectionProps {
  guest?: GuestContext | null;
}

export function HeroSection({ sectionContent, invitationData, guest }: HeroSectionProps) {
  const personalGreeting = guest
    ? `Dear ${guest.name},`
    : null;

  return (
    <section /* ... */>
      {personalGreeting && (
        <p className="mb-6 text-sm tracking-widest" style={{ color: 'var(--color-text-secondary)' }}>
          {personalGreeting}
        </p>
      )}
      {/* ... rest of hero ... */}
    </section>
  );
}
```

### 7.5 WhatsApp Blast — Personalized Message Generation

```typescript
// lib/guests/whatsapp-blast.ts

export interface WhatsAppBlastOptions {
  invitationSlug: string;
  groomName:      string;
  brideName:      string;
  eventDate:      string;
  customMessage?: string;
  customDomain?:  string;
}

export function buildPersonalizedWhatsAppUrl(
  guest: Guest,
  options: WhatsAppBlastOptions
): string {
  const inviteUrl = buildPersonalizedUrl(
    options.invitationSlug,
    guest.personal_token,
    options.customDomain
  );

  const message = options.customMessage
    ? options.customMessage
        .replace('{{name}}', guest.name)
        .replace('{{url}}', inviteUrl)
    : buildDefaultMessage(guest.name, options.groomName, options.brideName, options.eventDate, inviteUrl);

  const phone = guest.phone?.replace(/[^0-9]/g, '');
  const baseUrl = phone ? `https://wa.me/${phone}` : 'https://wa.me';

  return `${baseUrl}?text=${encodeURIComponent(message)}`;
}

function buildDefaultMessage(
  guestName: string,
  groomName: string,
  brideName: string,
  eventDate: string,
  inviteUrl: string
): string {
  return (
    `Assalamu'alaikum / Salam Sejahtera,\n\n` +
    `Yth. ${guestName},\n\n` +
    `Dengan penuh suka cita, kami mengundang Anda untuk hadir pada pernikahan kami:\n\n` +
    `💑 ${groomName} & ${brideName}\n` +
    `📅 ${eventDate}\n\n` +
    `Lihat undangan lengkap kami di:\n${inviteUrl}\n\n` +
    `Kehadiran Anda sangat berarti bagi kami 🙏`
  );
}
```

### 7.6 Blast Rate Limiting and Quota

```typescript
// lib/guests/blast-quota.ts

export async function checkBlastQuota(
  tenantId: string,
  packageId: string,
  recipientCount: number
): Promise<{ allowed: boolean; maxPerDay: number; usedToday: number }> {
  const resolution = await resolveFeature(
    { tenantId, packageId },
    'guest_whatsapp_blast'
  );

  if (!resolution.enabled) {
    return { allowed: false, maxPerDay: 0, usedToday: 0 };
  }

  const config = resolution.config as { max_recipients_per_day?: number };
  const maxPerDay = config.max_recipients_per_day ?? 200;

  if (maxPerDay === -1) {
    return { allowed: true, maxPerDay: -1, usedToday: 0 };
  }

  // Count invites sent today via Redis (Upstash)
  const key = `blast:${tenantId}:${new Date().toISOString().slice(0, 10)}`;
  const usedToday = await redis.get<number>(key) ?? 0;

  return {
    allowed:    usedToday + recipientCount <= maxPerDay,
    maxPerDay,
    usedToday,
  };
}

export async function recordBlastSent(tenantId: string, count: number): Promise<void> {
  const key = `blast:${tenantId}:${new Date().toISOString().slice(0, 10)}`;
  await redis.incrby(key, count);
  await redis.expire(key, 86400); // reset TTL to 24h from now
}
```

---

## 8. Guest Search & Filtering

### 8.1 Search Architecture

Guest search must support three simultaneous axes:
1. **Full-text name search** — fuzzy, typo-tolerant (pg_trgm)
2. **Exact field filters** — group, category, RSVP status, invited status
3. **Composite sorting** — name, created date, RSVP status

All search is server-side. There is no client-side data store. URL state via `nuqs` ensures shareable filter links.

### 8.2 Search Query Builder

```typescript
// lib/guests/search.ts

export interface GuestSearchParams {
  invitationId:  string;
  tenantId:      string;
  query?:        string;   // fuzzy name/phone search
  groupId?:      string;
  categoryId?:   string;
  rsvpStatus?:   'attending' | 'not_attending' | 'maybe' | 'pending';
  isInvited?:    boolean;
  tags?:         string[];
  sortBy?:       'name' | 'created_at' | 'rsvp_submitted_at';
  sortDir?:      'asc' | 'desc';
  page?:         number;
  pageSize?:     number;
}

export async function searchGuests(
  supabase: SupabaseClient,
  params: GuestSearchParams
): Promise<{ guests: GuestWithStatus[]; total: number }> {
  const {
    invitationId, tenantId, query, groupId, categoryId,
    rsvpStatus, isInvited, tags,
    sortBy = 'name', sortDir = 'asc',
    page = 1, pageSize = 50,
  } = params;

  const offset = (page - 1) * pageSize;

  let queryBuilder = supabase
    .from('guests')
    .select(
      `
        id, name, phone, email, expected_pax, is_invited, invite_sent_at,
        tags, created_at, personal_token,
        group:guest_groups(id, name, color),
        category:guest_categories(id, name, color),
        rsvp:rsvp_responses(attendance, pax_count, submitted_at)
      `,
      { count: 'exact' }
    )
    .eq('invitation_id', invitationId)
    .eq('tenant_id', tenantId)
    .is('deleted_at', null);

  // Name / phone fuzzy search using pg_trgm similarity
  if (query?.trim()) {
    queryBuilder = queryBuilder
      .or(`name.ilike.%${query}%,phone.ilike.%${query}%,email.ilike.%${query}%`);
  }

  // Exact filters
  if (groupId)    queryBuilder = queryBuilder.eq('group_id', groupId);
  if (categoryId) queryBuilder = queryBuilder.eq('category_id', categoryId);
  if (typeof isInvited === 'boolean') queryBuilder = queryBuilder.eq('is_invited', isInvited);
  if (tags?.length) queryBuilder = queryBuilder.contains('tags', tags);

  // RSVP status filter requires a subquery — handled via RPC for complex cases
  // For simple cases, post-filter in application layer after fetching

  // Sorting
  queryBuilder = queryBuilder.order(
    sortBy === 'name' ? 'name' : 'created_at',
    { ascending: sortDir === 'asc' }
  );

  // Pagination
  queryBuilder = queryBuilder.range(offset, offset + pageSize - 1);

  const { data, count, error } = await queryBuilder;

  if (error) throw new Error(error.message);

  // Post-process RSVP status filter (derived field)
  let guests = (data ?? []) as GuestWithStatus[];
  if (rsvpStatus) {
    guests = guests.filter(g => {
      const latestRsvp = (g.rsvp as any)?.[0];
      if (rsvpStatus === 'pending') return !latestRsvp;
      return latestRsvp?.attendance === rsvpStatus;
    });
  }

  return { guests, total: count ?? 0 };
}
```

### 8.3 Indexing Strategy

```sql
-- Full-text / fuzzy name search (pg_trgm GIN index)
-- Already declared in Section 2.1:
-- CREATE INDEX idx_guests_name_trgm ON guests USING GIN (name gin_trgm_ops)

-- Compound index for the most common query pattern:
-- invitation_id + not deleted, ordered by name
CREATE INDEX idx_guests_inv_name
  ON guests(invitation_id, name)
  WHERE deleted_at IS NULL;

-- Phone lookup (exact match for duplicate detection)
CREATE INDEX idx_guests_phone_inv
  ON guests(invitation_id, phone)
  WHERE phone IS NOT NULL AND deleted_at IS NULL;

-- Email lookup (exact match)
CREATE INDEX idx_guests_email_inv
  ON guests(invitation_id, email)
  WHERE email IS NOT NULL AND deleted_at IS NULL;

-- Tag array containment (GIN for @> operator)
CREATE INDEX idx_guests_tags
  ON guests USING GIN (tags)
  WHERE deleted_at IS NULL;

-- is_invited filter (partial — only uninvited guests)
CREATE INDEX idx_guests_not_invited
  ON guests(invitation_id)
  WHERE is_invited = FALSE AND deleted_at IS NULL;
```

### 8.4 Filter UI Component

```typescript
// components/guests/GuestFilterBar.tsx

'use client';

interface GuestFilterBarProps {
  groups:     GuestGroup[];
  categories: GuestCategory[];
  onFilter:   (params: Partial<GuestSearchParams>) => void;
}

export function GuestFilterBar({ groups, categories, onFilter }: GuestFilterBarProps) {
  return (
    <div className="flex flex-wrap items-center gap-2">
      <SearchInput
        placeholder="Search by name, phone, email..."
        onChange={q => onFilter({ query: q })}
        debounceMs={300}
        className="w-full sm:w-64"
      />

      <FilterSelect
        label="Group"
        options={[
          { value: '', label: 'All Groups' },
          ...groups.map(g => ({ value: g.id, label: g.name })),
        ]}
        onChange={v => onFilter({ groupId: v || undefined })}
      />

      <FilterSelect
        label="Category"
        options={[
          { value: '', label: 'All Categories' },
          ...categories.map(c => ({ value: c.id, label: c.name })),
        ]}
        onChange={v => onFilter({ categoryId: v || undefined })}
      />

      <FilterSelect
        label="RSVP"
        options={[
          { value: '',              label: 'All RSVP' },
          { value: 'pending',       label: 'No Response' },
          { value: 'attending',     label: 'Attending' },
          { value: 'not_attending', label: 'Not Attending' },
          { value: 'maybe',         label: 'Maybe' },
        ]}
        onChange={v => onFilter({ rsvpStatus: v as any || undefined })}
      />

      <FilterSelect
        label="Status"
        options={[
          { value: '',      label: 'All' },
          { value: 'true',  label: 'Invited' },
          { value: 'false', label: 'Not Sent' },
        ]}
        onChange={v => onFilter({
          isInvited: v === '' ? undefined : v === 'true',
        })}
      />
    </div>
  );
}
```

---

## 9. Guest Quota Management

### 9.1 Quota Model

Guest quotas are **per-invitation**, not per-tenant. The `packages.max_guests` column defines how many guests can be added to a single invitation. `-1` means unlimited.

```typescript
// Quota interpretation
// max_guests = 50   → Free plan: max 50 guests per invitation
// max_guests = 200  → Basic plan: max 200 guests per invitation
// max_guests = 2000 → Premium plan: max 2000 guests per invitation
// max_guests = -1   → Ultimate/Reseller: unlimited
```

### 9.2 Quota Check Implementation

```typescript
// lib/packages/quota.ts (guest-specific extension)

export async function checkGuestQuota(
  tenantId: string,
  invitationId: string
): Promise<QuotaCheck> {
  const supabase = createServerClient();

  // Get active subscription with package quotas
  const { data: sub } = await supabase
    .from('tenant_subscriptions')
    .select('package:packages(max_guests)')
    .eq('tenant_id', tenantId)
    .in('status', ['active', 'trialing'])
    .order('created_at', { ascending: false })
    .limit(1)
    .single();

  const pkg = sub?.package as any;
  const limit: number = pkg?.max_guests ?? 50;

  // Count active (non-deleted) guests for this specific invitation
  const { count: current } = await supabase
    .from('guests')
    .select('id', { count: 'exact', head: true })
    .eq('invitation_id', invitationId)
    .is('deleted_at', null);

  const currentCount = current ?? 0;

  // Check add-on quota boost (extra_gallery_photos pattern, but for guests)
  // Note: no guest add-on exists in current catalog; structure is prepared

  if (limit === -1) {
    return { allowed: true, limit: -1, current: currentCount, remaining: -1 };
  }

  return {
    allowed:   currentCount < limit,
    limit,
    current:   currentCount,
    remaining: Math.max(0, limit - currentCount),
  };
}
```

### 9.3 Quota Display Component

```typescript
// components/guests/GuestQuotaMeter.tsx

'use client';

interface GuestQuotaMeterProps {
  current: number;
  limit:   number;    // -1 = unlimited
}

export function GuestQuotaMeter({ current, limit }: GuestQuotaMeterProps) {
  if (limit === -1) {
    return (
      <p className="text-sm text-gray-500">
        <span className="font-semibold text-gray-700">{current.toLocaleString()}</span> guests
        {' '}
        <span className="text-green-600">· Unlimited</span>
      </p>
    );
  }

  const pct = Math.min((current / limit) * 100, 100);
  const isWarning = pct >= 80;
  const isFull    = current >= limit;

  return (
    <div className="space-y-1">
      <div className="flex items-center justify-between text-sm">
        <span className={`font-semibold ${isFull ? 'text-red-600' : 'text-gray-700'}`}>
          {current.toLocaleString()} / {limit.toLocaleString()} guests
        </span>
        {isFull && (
          <Link href="/subscription" className="text-xs font-medium text-purple-600 hover:underline">
            Upgrade to add more
          </Link>
        )}
      </div>
      <div className="h-1.5 w-full rounded-full bg-gray-100">
        <div
          className={`h-1.5 rounded-full transition-all ${
            isFull ? 'bg-red-500' : isWarning ? 'bg-amber-500' : 'bg-purple-500'
          }`}
          style={{ width: `${pct}%` }}
        />
      </div>
    </div>
  );
}
```

### 9.4 Package Quota Reference

| Package | `max_guests` | Effective Limit |
|---|---|---|
| Free | 50 | 50 guests per invitation |
| Basic | 200 | 200 guests per invitation |
| Premium | 2000 | 2,000 guests per invitation |
| Ultimate | -1 | Unlimited |
| Reseller Base | -1 | Unlimited (reseller sets sub-limits) |

> Reseller packages can sub-limit `max_guests` below the base package ceiling. This is enforced in `PHASE5_PACKAGE_FEATURE_SYSTEM.md` Section 7.2.

---

## 10. Attendance Tracking Preparation

This section defines data structures and interfaces for the RSVP, QR Check-In, and analytics systems. No RSVP or check-in logic is implemented here — only the preparatory schema and correlation patterns.

### 10.1 RSVP Correlation Structure

The `rsvp_responses` table (defined in PHASE2) accepts a nullable `guest_id`. When a guest submits RSVP via their personalized link, the `guest_id` is populated. When someone submits via the open RSVP form (no token), `guest_id` is NULL.

```sql
-- rsvp_responses (from PHASE2, shown here for context)
-- guest_id IS NOT NULL → tracked submission (personalized link)
-- guest_id IS NULL     → open submission (general public)

-- Prepared query pattern for guest RSVP status:
CREATE OR REPLACE VIEW guest_rsvp_status AS
SELECT
  g.id              AS guest_id,
  g.invitation_id,
  g.tenant_id,
  g.name,
  g.expected_pax,
  r.attendance,
  r.pax_count       AS rsvp_pax,
  r.meal_choice,
  r.message,
  r.submitted_at    AS rsvp_submitted_at,
  CASE
    WHEN r.id IS NULL THEN 'pending'
    ELSE r.attendance
  END               AS derived_status
FROM guests g
LEFT JOIN LATERAL (
  SELECT id, attendance, pax_count, meal_choice, message, submitted_at
  FROM rsvp_responses
  WHERE guest_id = g.id
  ORDER BY submitted_at DESC
  LIMIT 1
) r ON TRUE
WHERE g.deleted_at IS NULL;

-- Index to support the LATERAL join efficiently
CREATE INDEX idx_rsvp_guest_recent
  ON rsvp_responses(guest_id, submitted_at DESC)
  WHERE guest_id IS NOT NULL;
```

### 10.2 QR Check-In Correlation Structure

Each guest can have one QR code of type `'guest'`. The QR code is generated on-demand (not at guest creation time) to avoid storage costs for guests that never check in.

```sql
-- From PHASE2: qr_codes and qr_checkins

-- Prepared: guest check-in status view
CREATE OR REPLACE VIEW guest_checkin_status AS
SELECT
  g.id           AS guest_id,
  g.invitation_id,
  g.name,
  qr.id          AS qr_code_id,
  qr.token       AS qr_token,
  ci.checked_in_at,
  ci.checked_in_by,
  u.full_name    AS checked_in_by_name,
  CASE
    WHEN ci.id IS NOT NULL THEN TRUE
    ELSE FALSE
  END            AS is_checked_in
FROM guests g
LEFT JOIN qr_codes qr
  ON qr.guest_id = g.id AND qr.type = 'guest'
LEFT JOIN LATERAL (
  SELECT id, checked_in_at, checked_in_by
  FROM qr_checkins
  WHERE qr_code_id = qr.id
  ORDER BY checked_in_at DESC
  LIMIT 1
) ci ON TRUE
LEFT JOIN users u ON u.id = ci.checked_in_by
WHERE g.deleted_at IS NULL;
```

### 10.3 Guest Engagement Event Tracking

Guest-linked events are stored in `invitation_events` with `guest_id` populated when the guest token is resolved.

```typescript
// Prepared event types relevant to guest tracking:
// 'page_view'       → guest opened their personalized link
// 'rsvp_open'       → guest opened the RSVP form
// 'rsvp_submit'     → guest submitted RSVP (correlated with rsvp_responses)
// 'qr_scan'         → guest QR code was scanned
// 'share_click'     → guest clicked a share button

// Guest engagement summary (prepared query pattern):
const engagementQuery = `
  SELECT
    g.id,
    g.name,
    COUNT(e.*) FILTER (WHERE e.event_type = 'page_view')   AS views,
    COUNT(e.*) FILTER (WHERE e.event_type = 'rsvp_open')   AS rsvp_opens,
    MAX(e.created_at)                                       AS last_seen_at
  FROM guests g
  LEFT JOIN invitation_events e ON e.guest_id = g.id
  WHERE g.invitation_id = $1
    AND g.tenant_id = $2
    AND g.deleted_at IS NULL
  GROUP BY g.id, g.name
  ORDER BY last_seen_at DESC NULLS LAST
`;
```

### 10.4 Attendance Analytics Preparation

```typescript
// Prepared data shape for attendance dashboard (populated when RSVP phase launches)

export interface AttendanceSummary {
  total_guests:     number;
  rsvp_attending:   number;
  rsvp_declining:   number;
  rsvp_maybe:       number;
  rsvp_pending:     number;
  total_pax:        number;   // sum of expected_pax for attending guests
  checked_in:       number;   // populated from qr_checkins
  check_in_rate:    number;   // checked_in / rsvp_attending * 100
}

// By group breakdown (used for seating arrangement exports)
export interface AttendanceByGroup {
  group_id:   string;
  group_name: string;
  attending:  number;
  declining:  number;
  pending:    number;
  total_pax:  number;
}

// By category breakdown (bride side / groom side split)
export interface AttendanceByCategory {
  category_id:   string;
  category_name: string;
  attending:     number;
  declining:     number;
  pending:       number;
}
```

---

## 11. Permission Rules

### 11.1 Guest Action Permission Matrix

| Action | super_admin | reseller_admin | owner | editor | viewer |
|---|:---:|:---:|:---:|:---:|:---:|
| **VIEW** | | | | | |
| View guest list | ✅ | ✅ (clients only) | ✅ | ✅ | ❌ |
| View guest details | ✅ | ✅ | ✅ | ✅ | ❌ |
| View RSVP responses | ✅ | ✅ | ✅ | ✅ | ✅ |
| **CREATE** | | | | | |
| Add single guest | ✅ | ✅ | ✅ | ✅ | ❌ |
| Import guests (CSV/Excel) | ✅ | ✅ | ✅ | ❌ | ❌ |
| **EDIT** | | | | | |
| Edit guest details | ✅ | ✅ | ✅ | ✅ | ❌ |
| Change guest group | ✅ | ✅ | ✅ | ✅ | ❌ |
| Change guest category | ✅ | ✅ | ✅ | ✅ | ❌ |
| Mark as invited | ✅ | ✅ | ✅ | ✅ | ❌ |
| **DELETE** | | | | | |
| Delete single guest (soft) | ✅ | ✅ | ✅ | ✅ | ❌ |
| Bulk delete guests | ✅ | ✅ | ✅ | ❌ | ❌ |
| Rollback import batch | ✅ | ✅ | ✅ | ❌ | ❌ |
| **EXPORT** | | | | | |
| Export guest CSV | ✅ | ✅ | ✅ | ❌ | ❌ |
| **SHARE** | | | | | |
| Generate personalized links | ✅ | ✅ | ✅ | ✅ | ❌ |
| Send WhatsApp blast | ✅ | ✅ | ✅ | ✅ | ❌ |
| **GROUPS & CATEGORIES** | | | | | |
| Manage groups | ✅ | ✅ | ✅ | ✅ | ❌ |
| Manage categories | ✅ | ✅ | ✅ | ✅ | ❌ |
| **QR CODES** | | | | | |
| Generate guest QR | ✅ | ✅ | ✅ | ✅ | ❌ |
| Perform check-in | ✅ | ✅ | ✅ | ✅ | ❌ |
| View check-in log | ✅ | ✅ | ✅ | ✅ | ✅ |

### 11.2 Feature-Gated Actions

| Action | Feature Flag | Fallback Behavior |
|---|---|---|
| Import from CSV/Excel | `guest_import_csv` | Button hidden; upgrade prompt shown |
| Export guest list CSV | `guest_export_csv` | Button hidden |
| Personalized invite URLs | `guest_personalized_link` | All guests get plain public URL |
| WhatsApp blast | `guest_whatsapp_blast` | Button hidden |
| QR code per guest | `qr_invitation` | Guest QR tab hidden |
| QR check-in scanning | `qr_checkin` | Check-in page hidden |

### 11.3 API Route Permission Map

| Route | Method | Permission | Feature Gate | Quota |
|---|---|---|---|---|
| `/api/invitations/[id]/guests` | GET | `guest:read` | — | — |
| `/api/invitations/[id]/guests` | POST | `guest:write` | — | `max_guests` |
| `/api/invitations/[id]/guests/[guestId]` | GET | `guest:read` | — | — |
| `/api/invitations/[id]/guests/[guestId]` | PATCH | `guest:write` | — | — |
| `/api/invitations/[id]/guests/[guestId]` | DELETE | `guest:write` | — | — |
| `/api/invitations/[id]/guests/bulk-delete` | POST | `guest:write` | — | — |
| `/api/invitations/[id]/guests/export` | GET | `guest:read` | `guest_export_csv` | — |
| `/api/invitations/[id]/guests/import/preview` | POST | `guest:write` | `guest_import_csv` | — |
| `/api/invitations/[id]/guests/import/commit` | POST | `guest:write` | `guest_import_csv` | `max_guests` |
| `/api/invitations/[id]/guests/import/[batchId]/rollback` | POST | `guest:write` | — | — |
| `/api/invitations/[id]/groups` | GET | `guest:read` | — | — |
| `/api/invitations/[id]/groups` | POST | `guest:write` | — | — |
| `/api/invitations/[id]/groups/[groupId]` | PATCH | `guest:write` | — | — |
| `/api/invitations/[id]/groups/[groupId]` | DELETE | `guest:write` | — | — |
| `/api/invitations/[id]/groups/reorder` | POST | `guest:write` | — | — |
| `/api/invitations/[id]/categories` | GET | `guest:read` | — | — |
| `/api/invitations/[id]/categories` | POST | `guest:write` | — | — |
| `/api/invitations/[id]/categories/[catId]` | PATCH | `guest:write` | — | — |
| `/api/invitations/[id]/categories/[catId]` | DELETE | `guest:write` | — | — |

### 11.4 RLS Policies (Guests Domain)

```sql
-- guests table
ALTER TABLE guests ENABLE ROW LEVEL SECURITY;

-- Tenant members manage their own guests (non-deleted)
CREATE POLICY "guests_crud_own_tenant" ON guests
  FOR ALL
  USING (
    tenant_id = auth_tenant_id() AND
    deleted_at IS NULL
  )
  WITH CHECK (tenant_id = auth_tenant_id());

-- Reseller admins read their clients' guests
CREATE POLICY "guests_read_reseller" ON guests
  FOR SELECT
  USING (
    tenant_id IN (
      SELECT tenant_id FROM reseller_tenants
      WHERE reseller_id = auth_reseller_id()
    )
  );

-- guest_groups table
ALTER TABLE guest_groups ENABLE ROW LEVEL SECURITY;

CREATE POLICY "groups_tenant" ON guest_groups
  FOR ALL
  USING (tenant_id = auth_tenant_id())
  WITH CHECK (tenant_id = auth_tenant_id());

CREATE POLICY "groups_reseller_read" ON guest_groups
  FOR SELECT
  USING (
    tenant_id IN (
      SELECT tenant_id FROM reseller_tenants
      WHERE reseller_id = auth_reseller_id()
    )
  );

-- guest_categories table
ALTER TABLE guest_categories ENABLE ROW LEVEL SECURITY;

CREATE POLICY "categories_tenant" ON guest_categories
  FOR ALL
  USING (tenant_id = auth_tenant_id())
  WITH CHECK (tenant_id = auth_tenant_id());

-- guest_import_batches table
ALTER TABLE guest_import_batches ENABLE ROW LEVEL SECURITY;

CREATE POLICY "import_batches_tenant" ON guest_import_batches
  FOR ALL
  USING (tenant_id = auth_tenant_id())
  WITH CHECK (tenant_id = auth_tenant_id());
```

---

## 12. Multi-Tenant Considerations

### 12.1 Tenant Isolation Architecture

Every guest row carries both `invitation_id` and `tenant_id`. The `tenant_id` is redundant (inferrable from `invitation_id` → `invitations.tenant_id`) but is denormalized for:
- Direct partial index support without JOIN
- Faster RLS policy evaluation (no subquery to `invitations`)
- Efficient reseller-scope queries (reseller sees all client guests via `tenant_id`)

```sql
-- Verified at insert via application layer:
-- guests.tenant_id must equal invitations.tenant_id for the given invitation_id

CREATE OR REPLACE FUNCTION validate_guest_tenant()
RETURNS TRIGGER AS $$
DECLARE
  v_inv_tenant_id UUID;
BEGIN
  SELECT tenant_id INTO v_inv_tenant_id
  FROM invitations
  WHERE id = NEW.invitation_id;

  IF v_inv_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Invitation not found: %', NEW.invitation_id;
  END IF;

  IF NEW.tenant_id != v_inv_tenant_id THEN
    RAISE EXCEPTION 'tenant_id mismatch: guest.tenant_id must match invitation.tenant_id';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validate_guest_tenant
  BEFORE INSERT ON guests
  FOR EACH ROW EXECUTE FUNCTION validate_guest_tenant();
```

### 12.2 Personal Token Uniqueness

`personal_token` is globally UNIQUE across all tenants (not scoped per invitation). This matters for the public page token resolution: when the URL `?t=[token]` is received, the server queries `WHERE personal_token = $t` — it does not need to know which tenant or invitation first, the token resolves to exactly one guest.

**Security implication:** Tokens must never be predictable. UUID-v4 generation via PostgreSQL `gen_random_uuid()` ensures sufficient entropy.

### 12.3 Group and Category Isolation

Groups and categories are invitation-scoped (not tenant-scoped across invitations). This means:
- The couple for Invitation A and Invitation B (same tenant) each have independent group lists
- Renaming a group on one invitation does not affect others
- No "shared group library" across invitations (deferred to Phase 4+)

### 12.4 Import Batch Isolation

Import batches are tenant-scoped. A tenant cannot view, rollback, or reference another tenant's import batch. The RLS policy on `guest_import_batches` enforces this at the DB level.

### 12.5 Data Security

```typescript
// lib/guests/security.ts

// Personal tokens must NEVER appear in server logs or audit records
// Log the guest_id (UUID) instead

export function sanitizeGuestForLog(guest: Guest): Omit<Guest, 'personal_token'> {
  const { personal_token: _omit, ...safe } = guest;
  return safe;
}

// Phone numbers in logs are masked
export function maskPhone(phone: string): string {
  if (phone.length < 6) return '***';
  return phone.slice(0, 3) + '***' + phone.slice(-2);
}

// Email addresses in logs are masked
export function maskEmail(email: string): string {
  const [local, domain] = email.split('@');
  return local.slice(0, 2) + '***@' + domain;
}
```

---

## 13. Performance Optimization

### 13.1 Pagination Strategy

All guest list APIs use **offset-based pagination** for the primary list view (standard page/pageSize UX) and **cursor-based pagination** for export and large batch operations.

```typescript
// Offset pagination for UI (supports page jumping)
const PAGE_SIZE_OPTIONS = [25, 50, 100] as const;
const DEFAULT_PAGE_SIZE = 50;

// Cursor pagination for export (avoids memory issues with large lists)
export async function* streamGuests(
  supabase: SupabaseClient,
  invitationId: string,
  tenantId: string,
  batchSize = 500
): AsyncGenerator<Guest[]> {
  let lastId: string | null = null;

  while (true) {
    let query = supabase
      .from('guests')
      .select('*')
      .eq('invitation_id', invitationId)
      .eq('tenant_id', tenantId)
      .is('deleted_at', null)
      .order('id')
      .limit(batchSize);

    if (lastId) {
      query = query.gt('id', lastId);
    }

    const { data, error } = await query;
    if (error || !data?.length) break;

    yield data;
    lastId = data[data.length - 1].id;

    if (data.length < batchSize) break;
  }
}
```

### 13.2 Search Optimization

```typescript
// lib/guests/search-optimizer.ts

// For large guest lists (>1000), use DB-level search via pg_trgm
// For smaller lists (<200), allow client-side filter as progressive enhancement

// pg_trgm similarity threshold (0.3 = fairly lenient, catches typos)
const SIMILARITY_THRESHOLD = 0.3;

export async function triggramSearch(
  supabase: SupabaseClient,
  invitationId: string,
  query: string,
  limit = 50
): Promise<Guest[]> {
  // Uses the GIN index idx_guests_name_trgm
  const { data } = await supabase.rpc('search_guests_by_name', {
    p_invitation_id: invitationId,
    p_query:         query,
    p_threshold:     SIMILARITY_THRESHOLD,
    p_limit:         limit,
  });
  return data ?? [];
}
```

```sql
-- supabase/migrations/071_guest_search_function.sql

CREATE OR REPLACE FUNCTION search_guests_by_name(
  p_invitation_id UUID,
  p_query         TEXT,
  p_threshold     FLOAT DEFAULT 0.3,
  p_limit         INTEGER DEFAULT 50
)
RETURNS SETOF guests AS $$
BEGIN
  RETURN QUERY
  SELECT *
  FROM guests
  WHERE invitation_id = p_invitation_id
    AND deleted_at IS NULL
    AND (
      similarity(name, p_query) > p_threshold
      OR name ILIKE '%' || p_query || '%'
      OR phone ILIKE '%' || p_query || '%'
      OR email ILIKE '%' || p_query || '%'
    )
  ORDER BY similarity(name, p_query) DESC
  LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;
```

### 13.3 Bulk Operations Optimization

```typescript
// lib/guests/bulk-ops.ts

// Bulk soft-delete using a single UPDATE with IN clause (not N individual DELETEs)
export async function bulkSoftDelete(
  supabase: SupabaseClient,
  guestIds: string[],
  tenantId: string
): Promise<number> {
  if (guestIds.length === 0) return 0;

  // PostgreSQL has a practical limit of ~65535 parameters per query
  // Chunk to 1000 IDs per statement to be safe
  let total = 0;
  for (let i = 0; i < guestIds.length; i += 1000) {
    const chunk = guestIds.slice(i, i + 1000);
    const { count } = await supabase
      .from('guests')
      .update({ deleted_at: new Date().toISOString() })
      .in('id', chunk)
      .eq('tenant_id', tenantId)
      .is('deleted_at', null);
    total += count ?? 0;
  }
  return total;
}

// Bulk group assignment
export async function bulkAssignGroup(
  supabase: SupabaseClient,
  guestIds: string[],
  groupId: string | null,
  tenantId: string
): Promise<void> {
  for (let i = 0; i < guestIds.length; i += 1000) {
    const chunk = guestIds.slice(i, i + 1000);
    await supabase
      .from('guests')
      .update({ group_id: groupId })
      .in('id', chunk)
      .eq('tenant_id', tenantId);
  }
}
```

### 13.4 Import Performance

```typescript
// Import performance targets:
// - 100 rows:   < 2 seconds end-to-end
// - 1,000 rows: < 10 seconds
// - 5,000 rows: < 45 seconds

// Optimizations applied:
// 1. Client-side parsing (zero server load during parse)
// 2. Batch inserts of 100 rows per statement (reduces round-trips)
// 3. Duplicate detection via IN query (single DB call per field type)
// 4. Async batch status update (non-blocking response)
// 5. pg_trgm index not used during import (avoids index maintenance overhead)

// For very large imports (>2000 rows), consider offloading to a Supabase Edge Function:
export async function triggerAsyncImport(
  invitationId: string,
  batchId: string,
  rows: GuestInsertRow[]
): Promise<void> {
  await supabase.functions.invoke('process-guest-import', {
    body: { invitation_id: invitationId, batch_id: batchId, rows },
  });
}
```

### 13.5 Guest Count Caching

For guest list header stats (total, attending, pending), avoid a full COUNT on every page load by caching the summary in Redis with a short TTL.

```typescript
// lib/guests/count-cache.ts

const CACHE_TTL = 30; // 30 seconds

export async function getCachedGuestSummary(
  invitationId: string
): Promise<GuestSummary | null> {
  const cached = await redis.get<GuestSummary>(`guest_summary:${invitationId}`);
  return cached;
}

export async function setCachedGuestSummary(
  invitationId: string,
  summary: GuestSummary
): Promise<void> {
  await redis.setex(`guest_summary:${invitationId}`, CACHE_TTL, JSON.stringify(summary));
}

export async function invalidateGuestSummary(invitationId: string): Promise<void> {
  await redis.del(`guest_summary:${invitationId}`);
}
// Called on: guest create, delete, bulk import, rollback
```

---

## 14. Scalability Considerations

### 14.1 Data Volume Projections

```
Assumptions (conservative Year 2 estimate):
  Active tenants:      10,000
  Invitations:         25,000  (2.5 per active tenant average)
  Guests per invite:   150     (average across plans)

Total guests rows:     3,750,000

At Year 3:
  Total guests rows:   ~15,000,000

Per-invitation max (Ultimate): no limit
Pathological case: 1 invitation with 50,000 guests (large corporate event)
```

### 14.2 Index Scaling

The `idx_guests_name_trgm` GIN index will grow proportionally with guest count. GIN indexes are slower to update than B-tree but handle similarity search. At 10M+ rows:

- Consider switching GIN → GIST for lower write amplification
- Or use a separate search service (Meilisearch / Typesense) for guest name autocomplete

The partial indexes (`WHERE deleted_at IS NULL`) keep index sizes manageable — deleted guests are excluded from all operational indexes.

### 14.3 Partitioning Strategy

At 15M+ guest rows, consider range-partitioning `guests` by `tenant_id` hash (16 partitions). Since all operational queries include `tenant_id`, partition pruning will eliminate 15/16 of the table per query.

```sql
-- Phase 4+ migration (not needed in Phase 1-3)

-- Convert guests to partitioned table
CREATE TABLE guests_partitioned (LIKE guests INCLUDING ALL)
  PARTITION BY HASH (tenant_id);

CREATE TABLE guests_p0 PARTITION OF guests_partitioned
  FOR VALUES WITH (MODULUS 16, REMAINDER 0);
-- ... repeat for p1 through p15
```

### 14.4 Import at Scale

For tenants on Ultimate plan importing 5,000+ guests:
- Move commit to an async Supabase Edge Function
- Return `{ batch_id, status: 'processing' }` immediately
- Client polls `GET /api/invitations/[id]/guests/import/[batchId]` for status
- Edge Function updates batch record on completion
- Realtime subscription on `guest_import_batches.status` notifies the UI

```typescript
// Async import status polling
// app/(app)/invitations/[id]/guests/import/page.tsx

const { data: batch } = useRealtimeQuery(
  supabase
    .from('guest_import_batches')
    .select('status, imported_count, error_count')
    .eq('id', batchId),
  { event: 'UPDATE' }
);
```

### 14.5 Personal Token at Scale

`personal_token` is indexed with a UNIQUE constraint. At 15M rows, a UUID lookup is O(log N) on the B-tree index — effectively O(1) for practical purposes. No scaling concern here.

### 14.6 Future Schema Extensions

| Future Feature | Extension Required |
|---|---|
| Guest dietary preferences | `dietary_restrictions TEXT[]` column on `guests` |
| Guest seating assignment | New `guest_seats` table with table/seat reference |
| Guest accommodation tracking | `accommodation_id` FK to future `accommodations` table |
| Multi-language guest names | `name_localized JSONB` column `{ "id": "...", "en": "..." }` |
| Guest relationship map | `invited_by UUID REFERENCES guests(id)` for +1 tracking |
| Guest tags standardized | Migrate `tags TEXT[]` to normalized `guest_tag_assignments` table |
| Guest communication history | `guest_communications` table for email/SMS/WhatsApp logs |

---

## 15. Future Integrations

### 15.1 RSVP System Integration (Phase 2)

The guest management layer is fully prepared for RSVP. When the RSVP system launches:

```typescript
// Data contract already in place:
// guests.personal_token → used in RSVP form URL (?t=[token])
// rsvp_responses.guest_id → FK to guests.id (nullable for open RSVP)
// invitations.is_rsvp_open → controls RSVP form availability
// invitations.rsvp_deadline → auto-closes RSVP after date

// The guest list will show:
// - "No Response" guests → re-send reminder option
// - "Attending" guests → pax count, meal choice
// - "Declining" guests → excluded from logistics count

// Ready hooks:
// - guest_rsvp_status view (Section 10.1)
// - GuestWithStatus.rsvp_attendance field
// - GuestDerivedStatus type union
```

### 15.2 Guestbook Integration (Phase 2)

```typescript
// Guestbook entries already link to guests.id (nullable):
// guestbook_entries.guest_id → guests.id

// When guest opens personalized link and posts to guestbook:
// → guestbook_entries.guest_id is populated from personal_token resolution
// → Guestbook wall can show guest name (verified) vs anonymous name (unverified)

// UI differentiation:
// [✓ Verified Guest]  Andi Prasetyo: "Cannot wait for the big day!"
// [  Public]          Anonymous: "Best wishes!"
```

### 15.3 QR Check-In Integration (Phase 2)

```typescript
// QR code generation for a guest:
// POST /api/invitations/[id]/guests/[guestId]/qr

// Generates:
// - qr_codes row with type='guest', guest_id=guestId
// - QR image stored in storage/qrcodes/{tenant_id}/{inv_id}/guests/{guest_id}.png
// - QR encodes: { token: qr_codes.token }

// Check-in flow:
// 1. Usher scans QR at venue
// 2. App resolves qr_codes.token → qr_codes.guest_id → guests.name
// 3. Creates qr_checkins row
// 4. Returns { guest: { name, expected_pax, group }, already_checked_in: false }

// Batch QR generation for all guests:
// POST /api/invitations/[id]/guests/generate-qr-codes
// → background Edge Function, returns batch_id for polling
```

### 15.4 WhatsApp Invitation Integration (Phase 2)

```typescript
// WhatsApp blast flow is partly ready in Section 7.5.
// When Phase 2 launches:

// 1. User selects guests to blast (filter by: not invited, pending RSVP, all)
// 2. Chooses/customizes message template with {{name}} and {{url}} placeholders
// 3. System generates personalized wa.me deep links per guest
// 4. Opens WhatsApp on mobile (one at a time) or batch-generates links for manual send
// 5. Records invite_sent_at on each sent guest

// Future: WhatsApp Business API integration (Phase 3+)
// - Direct API send without opening WhatsApp
// - Delivery receipts stored in guest_communications
// - Rate limit enforcement via blast quota (Section 7.6)
```

### 15.5 Email Invitation Integration (Phase 3+)

```typescript
// Email blast architecture (prepared, not implemented):

interface GuestEmailBlastRequest {
  invitation_id:  string;
  guest_ids:      string[];   // empty = all guests with email
  template_key:   string;     // 'invitation_personal' | 'invitation_reminder'
  subject:        string;
  custom_message?: string;
}

// Flow:
// 1. Server validates guest_ids have email addresses
// 2. Creates email_notifications row per guest
// 3. Passes to Resend batch API
// 4. Resend webhook updates email_notifications.status
// 5. invite_sent_at updated on guests.invite_sent_at

// Template variables available per email:
// {{guest_name}}, {{groom_name}}, {{bride_name}}, {{event_date}},
// {{event_venue}}, {{invite_url}}, {{rsvp_url}}
```

### 15.6 Analytics Integration

```typescript
// Guest-level analytics (prepared data structures in Section 10.3):

// When full analytics launch, the following metrics will be available per guest:
// - Did they open their personalized link? (invitation_events.guest_id)
// - How many times? (COUNT page_view events)
// - Did they share it? (share_click events)
// - When did they RSVP? (rsvp_responses.submitted_at)
// - Were they checked in? (qr_checkins)

// Prepared Supabase Realtime subscription for live guest activity:
// supabase
//   .channel(`invitation:${invitationId}:guests`)
//   .on('postgres_changes', {
//     event: 'INSERT',
//     schema: 'public',
//     table: 'invitation_events',
//     filter: `invitation_id=eq.${invitationId}`,
//   }, handleGuestEvent)
//   .subscribe();
```

---

## Appendix A — Migration Order (Phase 8 Additions)

```
Previously from PHASE1–7:
  001–065: Core tables, packages, features, themes, invitations, RLS, seeds

New migrations (PHASE8 additions):
  066_guest_groups.sql              -- guest_groups table + indexes + RLS
  067_guest_categories.sql          -- guest_categories table + indexes + RLS
  068_guest_import_batches.sql      -- guest_import_batches table + indexes + RLS
  069_guests_v2.sql                 -- ALTER guests: add group_id FK, category_id FK,
                                   --   expected_pax, tags, import_batch_id, invite_sent_at
  070_guests_trgm_index.sql         -- GIN trigram index on guests.name
  071_guest_search_function.sql     -- search_guests_by_name() RPC function
  072_guest_tenant_validator.sql    -- validate_guest_tenant() trigger
  073_guest_rsvp_status_view.sql    -- guest_rsvp_status materialized view
  074_guest_checkin_status_view.sql -- guest_checkin_status view
  075_rls_guest_groups.sql          -- RLS policies for guest_groups
  076_rls_guest_categories.sql      -- RLS policies for guest_categories
  077_rls_import_batches.sql        -- RLS policies for guest_import_batches
  078_seed_default_groups.sql       -- No seed data (groups are per-invitation)
  079_invitation_seed_groups_fn.sql -- seed_invitation_groups() function called
                                   --   by invitation creation flow
```

## Appendix B — API Route Summary

```
── GUESTS ─────────────────────────────────────────────────────────────
GET    /api/invitations/[id]/guests                List guests (paginated, filtered)
POST   /api/invitations/[id]/guests                Create single guest
GET    /api/invitations/[id]/guests/summary        Attendance summary stats
GET    /api/invitations/[id]/guests/export         Export CSV (feature-gated)
POST   /api/invitations/[id]/guests/bulk-delete    Soft-delete multiple guests

GET    /api/invitations/[id]/guests/[guestId]      Get guest detail
PATCH  /api/invitations/[id]/guests/[guestId]      Update guest
DELETE /api/invitations/[id]/guests/[guestId]      Soft-delete guest

── IMPORT ─────────────────────────────────────────────────────────────
POST   /api/invitations/[id]/guests/import/preview       Validate + preview rows
POST   /api/invitations/[id]/guests/import/commit        Execute import
GET    /api/invitations/[id]/guests/import/[batchId]     Get batch status
POST   /api/invitations/[id]/guests/import/[batchId]/rollback  Undo import

── GROUPS ─────────────────────────────────────────────────────────────
GET    /api/invitations/[id]/groups                List groups with counts
POST   /api/invitations/[id]/groups                Create group
PATCH  /api/invitations/[id]/groups/[groupId]      Rename / recolor group
DELETE /api/invitations/[id]/groups/[groupId]      Delete group (guests.group_id → NULL)
POST   /api/invitations/[id]/groups/reorder        Update sort_order

── CATEGORIES ─────────────────────────────────────────────────────────
GET    /api/invitations/[id]/categories            List categories with counts
POST   /api/invitations/[id]/categories            Create category
PATCH  /api/invitations/[id]/categories/[catId]    Update category
DELETE /api/invitations/[id]/categories/[catId]    Delete (guests.category_id → NULL)
POST   /api/invitations/[id]/categories/reorder    Update sort_order

── BULK OPERATIONS ────────────────────────────────────────────────────
POST   /api/invitations/[id]/guests/bulk-assign-group     Assign group to N guests
POST   /api/invitations/[id]/guests/bulk-assign-category  Assign category to N guests
POST   /api/invitations/[id]/guests/bulk-mark-invited     Set is_invited = true for N guests
```

## Appendix C — Feature Flag Reference for Guest Management

| Feature Key | Free | Basic | Premium | Ultimate | Notes |
|---|:---:|:---:|:---:|:---:|---|
| `guest_personalized_link` | ❌ | ✅ | ✅ | ✅ | Personalized ?t= URLs |
| `guest_import_csv` | ❌ | ❌ | ✅ | ✅ | CSV + Excel import |
| `guest_export_csv` | ❌ | ❌ | ✅ | ✅ | Download guest list |
| `guest_whatsapp_blast` | ❌ | ❌ | ✅ (200/day) | ✅ (∞) | WhatsApp deep links |
| `qr_invitation` | ❌ | ✅ | ✅ | ✅ | General invitation QR |
| `qr_checkin` | ❌ | ❌ | ✅ (2 devices) | ✅ (∞) | Per-guest QR + check-in |

## Appendix D — Guest Quota Reference

| Package | `max_guests` | Per Invitation | Notes |
|---|---|---|---|
| Free | 50 | 50 guests | Hard limit enforced at insert |
| Basic | 200 | 200 guests | — |
| Premium | 2,000 | 2,000 guests | — |
| Ultimate | -1 | Unlimited | No quota enforced |
| Reseller Base | -1 | Unlimited (reseller sub-limits apply) | — |

> Quota is **per invitation**, not total across all invitations. A Premium tenant with 3 invitations can have up to 2,000 guests per invitation (6,000 total).

---

*End of PHASE8_GUEST_MANAGEMENT.md*
