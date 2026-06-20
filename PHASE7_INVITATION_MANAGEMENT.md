# PHASE7_INVITATION_MANAGEMENT.md
# Wedding Invitation SaaS Platform — Invitation Management Architecture

> **Version:** 1.0.0
> **Date:** 2026-06-13
> **Status:** Approved for Development
> **Depends on:** PHASE1_ARCHITECTURE.md, PHASE2_DATABASE.md, PHASE3_AUTH.md, PHASE4_ADMIN_ARCHITECTURE.md, PHASE5_PACKAGE_FEATURE_SYSTEM.md, PHASE6_THEME_SYSTEM.md

---

## Table of Contents

1. [Invitation Architecture](#1-invitation-architecture)
2. [Invitation Data Model](#2-invitation-data-model)
3. [Invitation Creation Flow](#3-invitation-creation-flow)
4. [Invitation Editor Architecture](#4-invitation-editor-architecture)
5. [Invitation Content Management](#5-invitation-content-management)
6. [Invitation URL System](#6-invitation-url-system)
7. [Invitation Settings](#7-invitation-settings)
8. [Theme Integration](#8-theme-integration)
9. [Publishing System](#9-publishing-system)
10. [Duplication System](#10-duplication-system)
11. [Permission Rules](#11-permission-rules)
12. [Multi-Tenant Considerations](#12-multi-tenant-considerations)
13. [Performance Optimization](#13-performance-optimization)
14. [SEO Considerations](#14-seo-considerations)
15. [Scalability Considerations](#15-scalability-considerations)

---

## 1. Invitation Architecture

### 1.1 System Overview

An invitation is the core unit of value in the platform. It is a multi-section, theme-rendered public web page — not a static document — that serves as a live event hub for RSVPs, guestbook messages, gift information, and real-time guest management.

```
┌─────────────────────────────────────────────────────────────────────┐
│                    INVITATION SYSTEM LAYERS                          │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  1. MANAGEMENT LAYER (tenant-scoped, auth-required)          │   │
│  │     Dashboard CRUD · Editor · Settings · Guest Management    │   │
│  └──────────────────────────────┬──────────────────────────────┘   │
│                                 │                                   │
│  ┌──────────────────────────────▼──────────────────────────────┐   │
│  │  2. DATA LAYER                                               │   │
│  │     invitations (core) + sections + gallery + music + gifts  │   │
│  │     All rows scoped by tenant_id — enforced by RLS           │   │
│  └──────────────────────────────┬──────────────────────────────┘   │
│                                 │                                   │
│  ┌──────────────────────────────▼──────────────────────────────┐   │
│  │  3. FEATURE LAYER                                            │   │
│  │     Package entitlements · Feature flags · Quota enforcement │   │
│  └──────────────────────────────┬──────────────────────────────┘   │
│                                 │                                   │
│  ┌──────────────────────────────▼──────────────────────────────┐   │
│  │  4. PUBLIC RENDERING LAYER                                   │   │
│  │     ISR (60s) · Theme renderer · RSVP form · OG image        │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 Invitation Lifecycle

An invitation moves through a defined lifecycle. Each transition is an explicit user or system action — no automatic state changes except scheduled publishing (Section 9.4).

```
                    ┌─────────────────────────────┐
                    │         QUOTA CHECK          │
                    │  max_invitations not reached │
                    └──────────────┬──────────────┘
                                   │
                              CREATE (wizard)
                                   │
                                   ▼
                    ┌──────────────────────────────┐
                    │            DRAFT              │
                    │  - Not publicly accessible    │
                    │  - Editable by owner/editor   │
                    │  - SSR on preview (no cache)  │
                    └──────┬───────────────┬────────┘
                           │               │
                     PUBLISH            DELETE (soft)
                     (owner only)            │
                           │                ▼
                           ▼        ┌───────────────┐
               ┌───────────────────┐│    DELETED    │
               │     PUBLISHED     ││  (soft, 90d   │
               │  - Publicly live  ││   recovery)   │
               │  - ISR 60s cache  │└───────────────┘
               │  - RSVP active    │
               │  - Analytics on   │
               └──────┬──────┬─────┘
                      │      │
                  UNPUBLISH  ARCHIVE
                      │      │
                      │      ▼
                      │  ┌──────────────────────────┐
                      │  │         ARCHIVED          │
                      │  │  - Not publicly accessible│
                      │  │  - Read-only (no editing) │
                      │  │  - Data preserved         │
                      │  │  - Restoreable to draft   │
                      │  └──────────────────────────┘
                      │
                      ▼
                  (back to DRAFT)
```

### 1.3 Status Definitions

| Status | Public Access | Editable | RSVP Active | ISR Cached | Description |
|---|:---:|:---:|:---:|:---:|---|
| `draft` | ❌ | ✅ | ❌ | ❌ | Being built; SSR on preview |
| `published` | ✅ | ✅ | Configurable | ✅ 60s | Live to the world |
| `archived` | ❌ | ❌ | ❌ | ❌ | Preserved but inactive |
| `deleted` | ❌ | ❌ | ❌ | ❌ | Soft-deleted; recoverable 90 days |

### 1.4 Draft System

Drafts are fully functional invitations that are not yet publicly visible. The draft system supports:

- **Auto-save** — property panel changes debounce 2 seconds and flush via Server Action
- **Preview mode** — owner/editor can view the invitation via a signed preview URL
- **Draft validation** — publishing is blocked if required fields are empty (event date, couple names)
- **Draft quota** — drafts count against `max_invitations` quota to prevent abuse

```typescript
// lib/invitations/draft.ts

export interface DraftValidationResult {
  valid: boolean;
  errors: DraftValidationError[];
}

export interface DraftValidationError {
  field: string;
  message: string;
  severity: 'error' | 'warning';
}

export function validateDraftForPublish(invitation: Invitation): DraftValidationResult {
  const errors: DraftValidationError[] = [];

  const couple = invitation.couple_data as CoupleData;
  if (!couple?.groom_name?.trim()) {
    errors.push({ field: 'couple_data.groom_name', message: 'Groom name is required', severity: 'error' });
  }
  if (!couple?.bride_name?.trim()) {
    errors.push({ field: 'couple_data.bride_name', message: 'Bride name is required', severity: 'error' });
  }
  if (!invitation.event_date) {
    errors.push({ field: 'event_date', message: 'Event date is required', severity: 'error' });
  }
  if (!invitation.event_venue?.trim()) {
    errors.push({ field: 'event_venue', message: 'Venue name is required before publishing', severity: 'warning' });
  }
  if (!invitation.slug?.trim()) {
    errors.push({ field: 'slug', message: 'Invitation URL slug is required', severity: 'error' });
  }

  return {
    valid: errors.filter(e => e.severity === 'error').length === 0,
    errors,
  };
}
```

### 1.5 Publish System

Publishing makes the invitation publicly accessible at its slug URL. The publish action:

1. Runs validation (Section 1.4)
2. Sets `status = 'published'` and `published_at = NOW()`
3. Triggers ISR revalidation for the public page
4. Generates OG image if not already set
5. Writes audit log entry
6. Optionally sends email notification to owner

### 1.6 Archive System

Archiving preserves invitation data while removing public access. Useful for past events. Key behaviors:

- All data (guests, RSVPs, gallery, music, gifts) is retained
- The invitation can be restored to `draft` status by an owner
- Archived invitations do not consume `max_invitations` quota for Free/Starter tiers — only published + draft invitations count toward the limit
- ISR cache for the slug is purged on archive

**Trade-off decision:** Counting only active (draft + published) invitations against quota, not archived ones, is intentional. Archived invitations represent completed past events and punishing users for archiving would incentivize deletion, causing data loss.

---

## 2. Invitation Data Model

### 2.1 Core Invitation Entity

The `invitations` table is the root record for the entire invitation data graph. All related tables (`invitation_sections`, `invitation_gallery`, `invitation_music`, `invitation_gifts`, `guests`, `rsvp_responses`) cascade off this record.

```sql
-- Full schema (extending Phase 2 with Phase 7 additions)

CREATE TABLE invitations (
  -- Identity
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           UUID        NOT NULL REFERENCES tenants(id),
  created_by          UUID        NOT NULL REFERENCES users(id),

  -- Theme
  theme_id            UUID        NOT NULL REFERENCES invitation_themes(id),

  -- Routing
  slug                TEXT        NOT NULL UNIQUE,
  custom_domain_id    UUID        REFERENCES custom_domains(id),

  -- Display
  title               TEXT        NOT NULL,
  status              TEXT        NOT NULL DEFAULT 'draft'
                                  CHECK (status IN ('draft', 'published', 'archived')),

  -- Event Details
  event_date          DATE,
  event_time          TIME,
  event_venue         TEXT,
  event_address       TEXT,
  event_maps_url      TEXT,
  event_maps_embed    TEXT,

  -- Couple Content (JSONB for flexibility)
  couple_data         JSONB       NOT NULL DEFAULT '{}',
  -- Shape:
  -- {
  --   groom_name: string,
  --   groom_nickname: string,
  --   groom_photo_url: string | null,
  --   groom_parents: string,
  --   groom_instagram: string | null,
  --   bride_name: string,
  --   bride_nickname: string,
  --   bride_photo_url: string | null,
  --   bride_parents: string,
  --   bride_instagram: string | null,
  -- }

  -- Theme Customization (flat dot-notation keys per PHASE6)
  customization       JSONB       NOT NULL DEFAULT '{}',

  -- RSVP Settings
  is_rsvp_open        BOOLEAN     NOT NULL DEFAULT TRUE,
  rsvp_deadline       DATE,

  -- Access Control
  password_hash       TEXT,             -- bcrypt; null = no password gate

  -- SEO / Sharing
  meta_title          TEXT,
  meta_description    TEXT,
  og_image_url        TEXT,

  -- Scheduling (Phase 2 addition)
  scheduled_publish_at TIMESTAMPTZ,    -- null = manual publish only

  -- Stats (materialized by trigger)
  view_count          INTEGER     NOT NULL DEFAULT 0,

  -- Timestamps
  published_at        TIMESTAMPTZ,
  deleted_at          TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_invitations_updated_at
  BEFORE UPDATE ON invitations
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Indexes
CREATE INDEX idx_inv_tenant_id        ON invitations(tenant_id);
CREATE INDEX idx_inv_slug             ON invitations(slug);
CREATE INDEX idx_inv_status           ON invitations(status) WHERE deleted_at IS NULL;
CREATE INDEX idx_inv_tenant_status    ON invitations(tenant_id, status) WHERE deleted_at IS NULL;
CREATE INDEX idx_inv_published_at     ON invitations(published_at DESC) WHERE status = 'published';
CREATE INDEX idx_inv_scheduled        ON invitations(scheduled_publish_at)
  WHERE scheduled_publish_at IS NOT NULL AND status = 'draft';
CREATE INDEX idx_inv_custom_domain    ON invitations(custom_domain_id) WHERE custom_domain_id IS NOT NULL;
```

### 2.2 Couple Data Shape

```typescript
// types/invitation.ts

export interface CoupleData {
  // Groom
  groom_name:        string;
  groom_nickname?:   string;
  groom_photo_url?:  string | null;
  groom_parents?:    string;
  groom_instagram?:  string | null;

  // Bride
  bride_name:        string;
  bride_nickname?:   string;
  bride_photo_url?:  string | null;
  bride_parents?:    string;
  bride_instagram?:  string | null;
}

export interface InvitationSettings {
  is_rsvp_open:         boolean;
  rsvp_deadline:        string | null;  // ISO date
  password_protected:   boolean;
  scheduled_publish_at: string | null;  // ISO datetime
}
```

### 2.3 Full Entity Relationship Graph

```
tenants ─────────────────────────────────────────────────────────────┐
         │                                                            │
         │ 1                                                          │
         ▼ ∞                                                          │
    invitations                                                       │
         │                                                            │
         ├──── invitation_sections      (1:many, cascade delete)      │
         │       └── content JSONB per section_type                   │
         │                                                            │
         ├──── invitation_gallery       (1:many, cascade delete)      │
         │       └── file_url, thumbnail_url, caption, sort_order     │
         │                                                            │
         ├──── invitation_music         (1:many, cascade delete)      │
         │       └── title, artist, file_url, external_url, is_active │
         │                                                            │
         ├──── invitation_gifts         (1:many, cascade delete)      │
         │       └── gift_type, bank/qris/ewallet fields              │
         │                                                            │
         ├──── guests                   (1:many, soft delete)         │
         │       └── rsvp_responses     (1:many per guest)            │
         │                                                            │
         ├──── guestbook_entries        (1:many)                      │
         │                                                            │
         ├──── qr_codes                 (1:many, cascade delete)      │
         │       └── qr_checkins        (1:many per code)             │
         │                                                            │
         ├──── invitation_analytics     (1:many, by date)             │
         ├──── invitation_events        (1:many, append-only)         │
         │                                                            │
         ├──── invitation_feature_overrides (1:many, cascade delete)  │
         │                                                            │
         └──── invitation_themes ────── (many:1)                      │
                                                                      │
    users ────────────────────────────────────────────── (created_by) │
    custom_domains ──────────────────────────────── (custom_domain_id)│
```

### 2.4 Invitation Sections Table

Sections are the ordered content blocks that a theme renders. Each row maps to one section type. The `content` JSONB stores section-specific data on top of the global `invitation.customization`.

```sql
CREATE TABLE invitation_sections (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id  UUID        NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
  section_type   TEXT        NOT NULL
                             CHECK (section_type IN (
                               'hero', 'couple', 'event_details', 'countdown',
                               'gallery', 'love_story', 'music', 'rsvp',
                               'guestbook', 'gift', 'livestream', 'closing'
                             )),
  sort_order     INTEGER     NOT NULL DEFAULT 0,
  is_visible     BOOLEAN     NOT NULL DEFAULT TRUE,
  content        JSONB       NOT NULL DEFAULT '{}',
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (invitation_id, section_type)
);
```

**Content JSONB by section_type:**

| section_type | Content fields stored |
|---|---|
| `hero` | `opening_text`, `conjunction_text`, `background_image_url`, `overlay_opacity` |
| `couple` | `layout_style`, `show_parents` |
| `event_details` | `show_maps_button`, `maps_button_label`, `show_add_to_calendar` |
| `love_story` | `story_title`, `story_text`, `milestones: [{date, label, description}]` |
| `gallery` | `grid_style`, `title` |
| `countdown` | `style`, `label` |
| `music` | (links to `invitation_music` table; no inline content) |
| `rsvp` | `form_title`, `attending_label`, `not_attending_label` |
| `guestbook` | `title`, `placeholder_text`, `moderation_enabled` |
| `gift` | `title`, `intro_text` |
| `livestream` | `embed_url`, `platform`, `title`, `scheduled_at` |
| `closing` | `closing_text`, `show_hashtag`, `hashtag` |

### 2.5 Theme Assignment

```typescript
// types/invitation.ts

export interface InvitationWithTheme {
  id:           string;
  theme_id:     string;
  theme: {
    id:           string;
    slug:         string;
    name:         string;
    config_schema: ThemeConfigSchema;
    is_premium:   boolean;
    is_active:    boolean;
    version:      number;
  };
  customization: Record<string, unknown>; // flat dot-notation keys
}
```

### 2.6 Custom Domain Mapping

When a tenant has an active Custom Domain add-on or Premium+ subscription, they can map their invitation to a custom domain via the `custom_domains` table.

```sql
-- From Phase 2: custom_domains table (relevant to invitations)
-- An invitation is associated with a custom_domain_id FK

-- Lookup at edge middleware:
-- 1. Read Host header from request
-- 2. Query custom_domains WHERE domain = host AND status = 'active'
-- 3. If found: resolve invitation by slug on that domain
-- 4. If not found: fall through to platform subdomain resolution
```

```typescript
// lib/invitations/custom-domain-resolver.ts

export async function resolveInvitationByDomain(
  host: string,
  slug: string
): Promise<{ invitationId: string; tenantId: string } | null> {
  const supabase = createServerClient();

  // Check if this is a custom domain
  const { data: domain } = await supabase
    .from('custom_domains')
    .select('tenant_id, id')
    .eq('domain', host)
    .eq('status', 'active')
    .eq('type', 'invitation')
    .single();

  if (!domain) return null;

  const { data: invitation } = await supabase
    .from('invitations')
    .select('id, tenant_id')
    .eq('slug', slug)
    .eq('tenant_id', domain.tenant_id)
    .eq('status', 'published')
    .single();

  return invitation
    ? { invitationId: invitation.id, tenantId: invitation.tenant_id }
    : null;
}
```

---

## 3. Invitation Creation Flow

### 3.1 Creation Wizard Overview

New invitations are created via a 4-step wizard. Each step saves progress to the DB before advancing, so no progress is lost if the user closes the browser.

```
STEP 1: Choose Theme
  → Validates: quota check (max_invitations)
  → Creates: invitations row (status = 'draft'), invitation_sections rows

STEP 2: Couple Details
  → Updates: invitations.couple_data JSONB

STEP 3: Event Details
  → Updates: invitations.event_date, event_time, event_venue, event_address, event_maps_url

STEP 4: Invitation URL
  → Updates: invitations.slug (validated for uniqueness + format)
  → Redirects: /invitations/[id]/edit
```

### 3.2 Quota Check (Pre-Creation)

Before rendering the creation wizard, the quota is verified server-side. This prevents the user from going through the wizard only to be blocked at the end.

```typescript
// app/(app)/invitations/new/page.tsx — server component

import { checkQuota } from '@/lib/packages/quota';
import { requireSession } from '@/lib/auth/session';

export default async function NewInvitationPage() {
  const user = await requireSession();

  const quota = await checkQuota(user.tenantId, 'invitations');

  if (!quota.allowed) {
    return (
      <QuotaExceededState
        current={quota.current}
        limit={quota.limit}
        resource="invitations"
        upgradeHref="/subscription"
      />
    );
  }

  const themes = await getActiveThemes(user.tenantId);

  return <NewInvitationWizard themes={themes} tenantId={user.tenantId} />;
}
```

### 3.3 Step 1 — Theme Selection

```typescript
// app/(app)/invitations/new/actions.ts
'use server';

import { z } from 'zod';
import { createServerClient } from '@/lib/supabase/server';
import { requireSession } from '@/lib/auth/session';
import { checkQuota } from '@/lib/packages/quota';
import { resolveFeature } from '@/lib/packages/feature-resolver';
import { getDefaultSectionsForCategory } from '@/lib/invitations/sections';
import { generateUniqueSlug } from '@/lib/invitations/slug';
import { writeAuditLog } from '@/lib/audit/write';
import { redirect } from 'next/navigation';

const SelectThemeSchema = z.object({
  theme_id: z.string().uuid(),
});

export async function selectThemeAction(
  formData: FormData
): Promise<{ error?: string }> {
  const user = await requireSession();
  const parsed = SelectThemeSchema.safeParse(Object.fromEntries(formData));
  if (!parsed.success) return { error: 'Invalid theme selection' };

  // Re-check quota server-side (defense in depth)
  const quota = await checkQuota(user.tenantId, 'invitations');
  if (!quota.allowed) return { error: 'Invitation quota reached. Please upgrade your plan.' };

  const supabase = createServerClient();

  // Verify theme exists, is active, and tenant has access
  const { data: theme } = await supabase
    .from('invitation_themes')
    .select('id, slug, category, is_premium, is_active')
    .eq('id', parsed.data.theme_id)
    .eq('is_active', true)
    .single();

  if (!theme) return { error: 'Theme not found' };

  if (theme.is_premium) {
    const resolution = await resolveFeature(
      { tenantId: user.tenantId, packageId: user.packageId },
      'premium_themes'
    );
    if (!resolution.enabled) {
      return { error: 'Premium themes require a Basic plan or above.' };
    }
  }

  // Generate a safe default slug from timestamp (user customizes in step 4)
  const defaultSlug = await generateUniqueSlug(`invitation-${Date.now()}`);

  // Create invitation record
  const { data: invitation, error: invError } = await supabase
    .from('invitations')
    .insert({
      tenant_id:  user.tenantId,
      created_by: user.id,
      theme_id:   theme.id,
      slug:       defaultSlug,
      title:      'My Wedding Invitation',
      status:     'draft',
    })
    .select('id')
    .single();

  if (invError || !invitation) return { error: 'Failed to create invitation' };

  // Seed default sections for this theme's category
  const defaultSections = getDefaultSectionsForCategory(theme.category);
  await supabase.from('invitation_sections').insert(
    defaultSections.map(s => ({
      invitation_id: invitation.id,
      section_type:  s.type,
      sort_order:    s.sort_order,
      is_visible:    s.is_visible,
      content:       {},
    }))
  );

  await writeAuditLog(null, 'invitation.create', 'invitation', invitation.id, {
    tenantId: user.tenantId,
    userId:   user.id,
    newData:  { theme_id: theme.id, slug: defaultSlug },
  });

  // Proceed to step 2
  redirect(`/invitations/new/${invitation.id}/couple`);
}
```

### 3.4 Step 2 — Couple Details

```typescript
// app/(app)/invitations/new/[id]/couple/actions.ts
'use server';

const CoupleDataSchema = z.object({
  groom_name:       z.string().min(1).max(100).trim(),
  groom_nickname:   z.string().max(50).trim().optional(),
  groom_parents:    z.string().max(200).trim().optional(),
  groom_instagram:  z.string().max(100).trim().optional(),
  bride_name:       z.string().min(1).max(100).trim(),
  bride_nickname:   z.string().max(50).trim().optional(),
  bride_parents:    z.string().max(200).trim().optional(),
  bride_instagram:  z.string().max(100).trim().optional(),
});

export async function saveCoupleDataAction(
  invitationId: string,
  formData: FormData
): Promise<{ error?: string }> {
  const user = await requireSession();
  const parsed = CoupleDataSchema.safeParse(Object.fromEntries(formData));
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors as any };

  const supabase = createServerClient();

  const title = `${parsed.data.groom_name} & ${parsed.data.bride_name}`;

  const { error } = await supabase
    .from('invitations')
    .update({
      couple_data: parsed.data,
      title,
    })
    .eq('id', invitationId)
    .eq('tenant_id', user.tenantId)
    .eq('status', 'draft');

  if (error) return { error: 'Failed to save couple data' };

  redirect(`/invitations/new/${invitationId}/event`);
}
```

### 3.5 Step 3 — Event Details

```typescript
// app/(app)/invitations/new/[id]/event/actions.ts
'use server';

const EventDetailsSchema = z.object({
  event_date:      z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  event_time:      z.string().regex(/^\d{2}:\d{2}$/).optional(),
  event_venue:     z.string().max(200).trim().optional(),
  event_address:   z.string().max(500).trim().optional(),
  event_maps_url:  z.string().url().optional().or(z.literal('')),
});

export async function saveEventDetailsAction(
  invitationId: string,
  formData: FormData
): Promise<{ error?: string }> {
  const user = await requireSession();
  const parsed = EventDetailsSchema.safeParse(Object.fromEntries(formData));
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors as any };

  const supabase = createServerClient();

  const { error } = await supabase
    .from('invitations')
    .update({
      event_date:    parsed.data.event_date || null,
      event_time:    parsed.data.event_time || null,
      event_venue:   parsed.data.event_venue || null,
      event_address: parsed.data.event_address || null,
      event_maps_url: parsed.data.event_maps_url || null,
    })
    .eq('id', invitationId)
    .eq('tenant_id', user.tenantId)
    .eq('status', 'draft');

  if (error) return { error: 'Failed to save event details' };

  redirect(`/invitations/new/${invitationId}/slug`);
}
```

### 3.6 Step 4 — Invitation URL (Slug)

```typescript
// app/(app)/invitations/new/[id]/slug/actions.ts
'use server';

const SlugSchema = z.object({
  slug: z
    .string()
    .min(3, 'Minimum 3 characters')
    .max(60, 'Maximum 60 characters')
    .regex(/^[a-z0-9-]+$/, 'Only lowercase letters, numbers, and hyphens'),
});

export async function saveSlugAction(
  invitationId: string,
  formData: FormData
): Promise<{ error?: string }> {
  const user = await requireSession();
  const parsed = SlugSchema.safeParse(Object.fromEntries(formData));
  if (!parsed.success) return { error: parsed.error.flatten().fieldErrors as any };

  const supabase = createServerClient();

  // Check slug uniqueness (the DB UNIQUE constraint is the final guard)
  const { data: existing } = await supabase
    .from('invitations')
    .select('id')
    .eq('slug', parsed.data.slug)
    .neq('id', invitationId)
    .maybeSingle();

  if (existing) return { error: 'This URL is already taken. Please choose another.' };

  const { error } = await supabase
    .from('invitations')
    .update({ slug: parsed.data.slug })
    .eq('id', invitationId)
    .eq('tenant_id', user.tenantId)
    .eq('status', 'draft');

  if (error?.code === '23505') return { error: 'This URL was just taken. Please choose another.' };
  if (error) return { error: 'Failed to save URL' };

  redirect(`/invitations/${invitationId}/edit`);
}

// Real-time slug availability check (client-side, debounced)
export async function checkSlugAvailabilityAction(
  slug: string,
  currentInvitationId: string
): Promise<{ available: boolean }> {
  const parsed = SlugSchema.safeParse({ slug });
  if (!parsed.success) return { available: false };

  const supabase = createServerClient();
  const { data } = await supabase
    .from('invitations')
    .select('id')
    .eq('slug', slug)
    .neq('id', currentInvitationId)
    .maybeSingle();

  return { available: !data };
}
```

### 3.7 Default Sections Seeding

When an invitation is created, sections are seeded from the category defaults defined in PHASE6.

```typescript
// lib/invitations/sections.ts

import { THEME_CATEGORY_DEFAULTS } from '@/config/theme-categories';
import type { ThemeCategory } from '@/types/theme';

export interface SectionSeed {
  type:       string;
  sort_order: number;
  is_visible: boolean;
}

export function getDefaultSectionsForCategory(category: ThemeCategory): SectionSeed[] {
  return THEME_CATEGORY_DEFAULTS[category] ?? THEME_CATEGORY_DEFAULTS['wedding'];
}

// Reseed sections when a theme is changed (PHASE6 rule)
export async function reseedInvitationSections(
  supabase: SupabaseClient,
  invitationId: string,
  category: ThemeCategory
): Promise<void> {
  // Delete existing sections
  await supabase
    .from('invitation_sections')
    .delete()
    .eq('invitation_id', invitationId);

  // Insert fresh default sections
  const defaults = getDefaultSectionsForCategory(category);
  await supabase.from('invitation_sections').insert(
    defaults.map(s => ({
      invitation_id: invitationId,
      section_type:  s.type,
      sort_order:    s.sort_order,
      is_visible:    s.is_visible,
      content:       {},
    }))
  );
}
```

---

## 4. Invitation Editor Architecture

### 4.1 Editor Layout

The editor is a three-panel layout on desktop and a tab-based layout on mobile. It is a **property-based editor only** — no drag-and-drop, no canvas, no free positioning.

```
DESKTOP (≥1024px)
┌────────────────────────────────────────────────────────────────┐
│  EDITOR TOPBAR                                                 │
│  ← Invitations  │  Andi & Ninah  │  [Preview] [Publish] [⋮]  │
├────────────────┬───────────────────────────┬───────────────────┤
│ SECTION NAV    │ PROPERTY PANEL             │ LIVE PREVIEW      │
│ (w-56)         │ (flex-1)                   │ (w-[390px] scaled)│
│                │                            │                   │
│ ● Hero         │ Section: Hero              │ ┌─────────────┐   │
│ ○ Couple       │ ──────────────────         │ │             │   │
│ ○ Event        │ Background Photo           │ │  [preview]  │   │
│ ○ Love Story 🔒│ [upload]                   │ │             │   │
│ ○ Gallery      │                            │ │             │   │
│ ○ Countdown    │ Overlay Darkness           │ │             │   │
│ ○ Music 🔒     │ [━━━●──────] 30%           │ └─────────────┘   │
│ ○ RSVP         │                            │                   │
│ ○ Guestbook    │ Opening Line               │                   │
│ ○ Gift 🔒      │ [We joyfully invite...]    │                   │
│ ○ Closing      │                            │                   │
│ ──────────     │ ── Global: Colors ──────── │                   │
│ + Colors       │ Primary Color [●]          │                   │
│ + Fonts        │ Accent Color  [●]          │                   │
│ + Layout       │                            │                   │
└────────────────┴───────────────────────────┴───────────────────┘

MOBILE (<768px)
┌────────────────────────────────┐
│ EDITOR TOPBAR                  │
│ ← │ Andi & Ninah │ [Preview]  │
├────────────────────────────────┤
│ [Sections] [Edit] [Preview]   │← tab bar
├────────────────────────────────┤
│                                │
│  Active tab content renders    │
│  full-width                    │
│                                │
└────────────────────────────────┘
```

### 4.2 Editor Route Architecture

```typescript
// app/(app)/invitations/[id]/edit/page.tsx — server component

import { requireSession } from '@/lib/auth/session';
import { guard } from '@/lib/auth/guard';
import { createServerClient } from '@/lib/supabase/server';
import { checkThemeAccessForEdit } from '@/lib/theme/access-checker';
import { resolveAllFeaturesWithCache } from '@/lib/packages/feature-resolver';
import { mergeThemeConfig } from '@/lib/theme/config-merger';
import { getThemeModule } from '@/components/invitation/themes';
import { ensureCustomizationUpToDate } from '@/lib/theme/version-manager';
import { EditorLayout } from '@/components/invitation/editor/EditorLayout';
import { notFound, redirect } from 'next/navigation';

export default async function InvitationEditorPage({
  params,
}: {
  params: { id: string };
}) {
  const user = await requireSession();
  await guard({ role: user.role, permission: 'invitation:write' });

  const supabase = createServerClient();

  // Load invitation with all related data in parallel
  const [invResult, sectionsResult, galleryResult, musicResult, giftsResult] =
    await Promise.all([
      supabase
        .from('invitations')
        .select(`
          *,
          theme:invitation_themes(id, slug, name, config_schema, is_premium, is_active, version)
        `)
        .eq('id', params.id)
        .eq('tenant_id', user.tenantId)
        .is('deleted_at', null)
        .single(),
      supabase
        .from('invitation_sections')
        .select('*')
        .eq('invitation_id', params.id)
        .order('sort_order'),
      supabase
        .from('invitation_gallery')
        .select('*')
        .eq('invitation_id', params.id)
        .order('sort_order'),
      supabase
        .from('invitation_music')
        .select('*')
        .eq('invitation_id', params.id),
      supabase
        .from('invitation_gifts')
        .select('*')
        .eq('invitation_id', params.id)
        .order('sort_order'),
    ]);

  if (!invResult.data) notFound();

  const invitation = invResult.data;

  // Check theme access (handles premium theme downgrade scenario)
  const { canEdit, reason } = await checkThemeAccessForEdit(user.tenantId, params.id);
  if (!canEdit) {
    return <ThemeAccessDenied reason={reason} invitationId={params.id} />;
  }

  // Run schema version migration if needed (lazy, on editor load)
  const customization = await ensureCustomizationUpToDate(
    params.id,
    invitation.theme.slug,
    invitation.theme.version,
    invitation.customization as Record<string, unknown>
  );

  // Resolve all features in one DB round-trip
  const resolvedFeatures = await resolveAllFeaturesWithCache({
    tenantId:  user.tenantId,
    packageId: user.packageId,
  });

  // Merge theme config once — passed to preview + panel
  const themeModule   = getThemeModule(invitation.theme.slug);
  const mergedConfig  = themeModule
    ? mergeThemeConfig(invitation.theme.config_schema, themeModule.defaultConfig, customization)
    : null;

  return (
    <EditorLayout
      invitation={{ ...invitation, customization }}
      sections={sectionsResult.data ?? []}
      gallery={galleryResult.data ?? []}
      music={musicResult.data ?? []}
      gifts={giftsResult.data ?? []}
      mergedConfig={mergedConfig}
      resolvedFeatures={resolvedFeatures}
      userRole={user.role}
    />
  );
}
```

### 4.3 Section Navigation Panel

```typescript
// components/invitation/editor/SectionNavPanel.tsx

'use client';

import { useFeature } from '@/hooks/use-feature';
import { SECTION_FEATURE_GATES } from '@/config/section-types';
import type { InvitationSection, SectionType } from '@/types/invitation';

interface SectionNavPanelProps {
  sections:        InvitationSection[];
  activeSection:   SectionType | 'colors' | 'fonts' | 'layout';
  onSelect:        (section: SectionType | 'colors' | 'fonts' | 'layout') => void;
  onToggleVisible: (sectionId: string, isVisible: boolean) => void;
}

export function SectionNavPanel({
  sections,
  activeSection,
  onSelect,
  onToggleVisible,
}: SectionNavPanelProps) {
  return (
    <nav className="flex h-full flex-col overflow-y-auto border-r border-gray-200 bg-white py-4">
      {/* Section list */}
      <div className="flex-1 space-y-0.5 px-2">
        {sections
          .sort((a, b) => a.sort_order - b.sort_order)
          .map(section => (
            <SectionNavItem
              key={section.id}
              section={section}
              isActive={activeSection === section.section_type}
              onSelect={() => onSelect(section.section_type)}
              onToggleVisible={onToggleVisible}
            />
          ))}
      </div>

      {/* Global settings */}
      <div className="border-t border-gray-100 px-2 pt-3 pb-2">
        <p className="mb-1 px-2 text-[10px] font-semibold uppercase tracking-wider text-gray-400">
          Global
        </p>
        {(['colors', 'fonts', 'layout'] as const).map(group => (
          <button
            key={group}
            onClick={() => onSelect(group)}
            className={`w-full rounded-lg px-3 py-2 text-left text-sm transition
              ${activeSection === group
                ? 'bg-purple-50 font-medium text-purple-700'
                : 'text-gray-600 hover:bg-gray-50'}`}
          >
            {group.charAt(0).toUpperCase() + group.slice(1)}
          </button>
        ))}
      </div>
    </nav>
  );
}

function SectionNavItem({
  section,
  isActive,
  onSelect,
  onToggleVisible,
}: {
  section: InvitationSection;
  isActive: boolean;
  onSelect: () => void;
  onToggleVisible: (id: string, visible: boolean) => void;
}) {
  const requiredFeature = SECTION_FEATURE_GATES[section.section_type as SectionType];
  const featureEnabled = requiredFeature
    ? useFeature(requiredFeature as any).enabled
    : true;

  return (
    <div
      className={`group flex items-center gap-2 rounded-lg px-2 py-1.5 transition
        ${isActive ? 'bg-purple-50' : 'hover:bg-gray-50'}
        ${!featureEnabled ? 'opacity-60' : ''}`}
    >
      <button
        onClick={onSelect}
        className="flex flex-1 items-center gap-2 text-left"
      >
        <span className={`text-sm ${isActive ? 'font-medium text-purple-700' : 'text-gray-700'}`}>
          {SECTION_LABELS[section.section_type]}
        </span>
        {!featureEnabled && (
          <LockClosedIcon className="h-3 w-3 text-gray-400" />
        )}
      </button>

      {/* Visibility toggle — only for feature-gated sections */}
      {featureEnabled && (
        <button
          onClick={() => onToggleVisible(section.id, !section.is_visible)}
          className="opacity-0 group-hover:opacity-100 transition"
          title={section.is_visible ? 'Hide section' : 'Show section'}
        >
          {section.is_visible
            ? <EyeIcon className="h-3.5 w-3.5 text-gray-400" />
            : <EyeSlashIcon className="h-3.5 w-3.5 text-gray-400" />}
        </button>
      )}
    </div>
  );
}

const SECTION_LABELS: Record<string, string> = {
  hero:         'Hero',
  couple:       'Couple',
  event_details:'Event Details',
  love_story:   'Love Story',
  gallery:      'Gallery',
  countdown:    'Countdown',
  music:        'Music',
  rsvp:         'RSVP',
  guestbook:    'Guestbook',
  gift:         'Gift',
  livestream:   'Livestream',
  closing:      'Closing',
};
```

### 4.4 Auto-Save Architecture

The editor uses optimistic updates with a debounced server flush. Changes appear instantly in the preview; the network round-trip happens in the background.

```typescript
// hooks/use-invitation-editor.ts

'use client';

import { useState, useCallback, useRef, useTransition } from 'react';
import { updateCustomizationAction, updateSectionContentAction } from '@/app/(app)/invitations/[id]/edit/actions';

const DEBOUNCE_MS = 1500;

export function useInvitationEditor(invitationId: string) {
  const [customization, setCustomization] = useState<Record<string, unknown>>({});
  const [isPending, startTransition] = useTransition();
  const debounceTimer = useRef<ReturnType<typeof setTimeout>>();
  const pendingPatch = useRef<Record<string, unknown>>({});

  const updateProperty = useCallback((dotPath: string, value: unknown) => {
    // Optimistic update — instantly reflected in preview
    setCustomization(prev => ({ ...prev, [dotPath]: value }));

    // Batch into pending patch
    pendingPatch.current[dotPath] = value;

    // Debounce the server flush
    clearTimeout(debounceTimer.current);
    debounceTimer.current = setTimeout(() => {
      const patch = { ...pendingPatch.current };
      pendingPatch.current = {};

      startTransition(async () => {
        await updateCustomizationAction(invitationId, patch);
      });
    }, DEBOUNCE_MS);
  }, [invitationId]);

  const flushNow = useCallback(() => {
    clearTimeout(debounceTimer.current);
    const patch = { ...pendingPatch.current };
    pendingPatch.current = {};
    if (Object.keys(patch).length === 0) return;
    startTransition(async () => {
      await updateCustomizationAction(invitationId, patch);
    });
  }, [invitationId]);

  return { customization, updateProperty, flushNow, isPending };
}
```

### 4.5 Section Visibility Toggle Action

```typescript
// app/(app)/invitations/[id]/edit/actions.ts
'use server';

export async function toggleSectionVisibilityAction(
  sectionId: string,
  invitationId: string,
  isVisible: boolean
): Promise<{ success: boolean; error?: string }> {
  const user = await requireSession();
  await guard({ role: user.role, permission: 'invitation:write' });

  const supabase = createServerClient();

  const { error } = await supabase
    .from('invitation_sections')
    .update({ is_visible: isVisible })
    .eq('id', sectionId)
    .eq('invitation_id', invitationId)
    // Verify ownership through invitation's tenant_id
    .in('invitation_id',
      supabase
        .from('invitations')
        .select('id')
        .eq('tenant_id', user.tenantId)
    );

  if (error) return { success: false, error: error.message };
  return { success: true };
}
```

### 4.6 Editor Validation System

Before allowing publish, the editor runs a validation pass. Errors are surfaced in the topbar as a badge count.

```typescript
// lib/invitations/validation.ts

export interface EditorValidation {
  canPublish: boolean;
  errors:     ValidationItem[];
  warnings:   ValidationItem[];
}

export interface ValidationItem {
  section?: string;
  field:    string;
  message:  string;
}

export function validateForPublish(
  invitation: Invitation,
  sections: InvitationSection[]
): EditorValidation {
  const errors: ValidationItem[] = [];
  const warnings: ValidationItem[] = [];

  const couple = invitation.couple_data as CoupleData;

  // Required fields
  if (!couple?.groom_name?.trim())
    errors.push({ section: 'couple', field: 'groom_name', message: 'Groom name is required' });
  if (!couple?.bride_name?.trim())
    errors.push({ section: 'couple', field: 'bride_name', message: 'Bride name is required' });
  if (!invitation.event_date)
    errors.push({ section: 'event_details', field: 'event_date', message: 'Wedding date is required' });
  if (!invitation.slug?.trim())
    errors.push({ field: 'slug', message: 'Invitation URL is required' });

  // Warnings (soft)
  if (!invitation.event_venue?.trim())
    warnings.push({ section: 'event_details', field: 'event_venue', message: 'Venue name not set' });
  if (!couple?.groom_photo_url)
    warnings.push({ section: 'couple', field: 'groom_photo_url', message: 'Groom photo not uploaded' });
  if (!couple?.bride_photo_url)
    warnings.push({ section: 'couple', field: 'bride_photo_url', message: 'Bride photo not uploaded' });
  if (!invitation.og_image_url)
    warnings.push({ field: 'og_image_url', message: 'No OG image set — social share preview will be auto-generated' });

  return {
    canPublish: errors.length === 0,
    errors,
    warnings,
  };
}
```

---

## 5. Invitation Content Management

### 5.1 Content Architecture Overview

Invitation content is split across three storage locations:

| Content Type | Storage | Reason |
|---|---|---|
| Couple data, event details | `invitations.couple_data` JSONB | Frequently read together; denormalized for query efficiency |
| Theme overrides (colors, fonts, copy) | `invitations.customization` JSONB | Flat dot-notation; cheap PATCH updates |
| Section-specific overrides | `invitation_sections.content` JSONB | Scoped per section; avoids large monolithic JSONB |
| Gallery photos | `invitation_gallery` table | Orderable, quota-trackable, needs own metadata |
| Music tracks | `invitation_music` table | Multiple tracks, source type, active state |
| Gift accounts | `invitation_gifts` table | Multiple entries, gift type enum, sort order |

### 5.2 Couple Information

Managed via `invitations.couple_data` JSONB and the couple section editor panel.

```typescript
// components/invitation/editor/panels/CouplePanel.tsx

'use client';

interface CouplePanelProps {
  coupleData:   CoupleData;
  invitationId: string;
  onChange:     (data: Partial<CoupleData>) => void;
}

export function CouplePanel({ coupleData, invitationId, onChange }: CouplePanelProps) {
  return (
    <div className="space-y-6 p-4">
      {/* Groom */}
      <fieldset className="space-y-4">
        <legend className="text-sm font-semibold text-gray-700">Groom</legend>
        <TextInputField
          label="Full Name"
          value={coupleData.groom_name}
          onChange={v => onChange({ groom_name: v })}
          required
        />
        <TextInputField
          label="Nickname (optional)"
          value={coupleData.groom_nickname ?? ''}
          onChange={v => onChange({ groom_nickname: v })}
        />
        <TextInputField
          label="Parents"
          value={coupleData.groom_parents ?? ''}
          onChange={v => onChange({ groom_parents: v })}
          hint="e.g. Son of Bpk. Ahmad & Ibu Siti"
        />
        <TextInputField
          label="Instagram (optional)"
          value={coupleData.groom_instagram ?? ''}
          onChange={v => onChange({ groom_instagram: v })}
          placeholder="@username"
        />
        <ImageUploadField
          label="Photo"
          value={coupleData.groom_photo_url ?? null}
          bucket="invitation-images"
          pathPrefix={`${invitationId}/couple-groom`}
          onChange={v => onChange({ groom_photo_url: v })}
          hint="Recommended: square, min 400×400px"
        />
      </fieldset>

      {/* Bride */}
      <fieldset className="space-y-4">
        <legend className="text-sm font-semibold text-gray-700">Bride</legend>
        {/* Mirror of groom fields for bride */}
        <TextInputField label="Full Name" value={coupleData.bride_name} onChange={v => onChange({ bride_name: v })} required />
        <TextInputField label="Nickname" value={coupleData.bride_nickname ?? ''} onChange={v => onChange({ bride_nickname: v })} />
        <TextInputField label="Parents" value={coupleData.bride_parents ?? ''} onChange={v => onChange({ bride_parents: v })} />
        <TextInputField label="Instagram" value={coupleData.bride_instagram ?? ''} onChange={v => onChange({ bride_instagram: v })} />
        <ImageUploadField label="Photo" value={coupleData.bride_photo_url ?? null} bucket="invitation-images" pathPrefix={`${invitationId}/couple-bride`} onChange={v => onChange({ bride_photo_url: v })} />
      </fieldset>
    </div>
  );
}
```

### 5.3 Event Information

Event details are stored as first-class columns on `invitations` for indexing and querying efficiency (e.g. admin analytics by event date range).

```typescript
// components/invitation/editor/panels/EventDetailsPanel.tsx

// Fields rendered:
// - event_date (DatePicker)
// - event_time (TimePicker)
// - event_venue (TextInput)
// - event_address (Textarea)
// - event_maps_url (TextInput with URL validation)
// - event_maps_embed (Textarea — Google Maps iframe embed code, Premium+)
// - show_add_to_calendar (Toggle, from section content JSONB)

// Server action for event detail updates:
export async function updateEventDetailsAction(
  invitationId: string,
  data: EventDetailsUpdate
): Promise<void> {
  const user = await requireSession();
  const supabase = createServerClient();

  await supabase
    .from('invitations')
    .update({
      event_date:      data.event_date || null,
      event_time:      data.event_time || null,
      event_venue:     data.event_venue || null,
      event_address:   data.event_address || null,
      event_maps_url:  data.event_maps_url || null,
      event_maps_embed: data.event_maps_embed || null,
    })
    .eq('id', invitationId)
    .eq('tenant_id', user.tenantId);
}
```

### 5.4 Love Story (Feature-Gated)

The Love Story section is gated behind the `love_story` feature flag. Its content lives in `invitation_sections.content` for the `love_story` section type.

```typescript
// Content shape for love_story section
interface LoveStoryContent {
  story_title: string;
  story_text:  string;
  milestones: Array<{
    id:          string; // client-generated UUID for React key
    date:        string; // e.g. "14 February 2022"
    label:       string; // e.g. "First Meeting"
    description: string;
  }>;
}

// Action to update love story content
export async function updateSectionContentAction(
  invitationId: string,
  sectionType:  string,
  content:      Record<string, unknown>
): Promise<{ success: boolean }> {
  const user = await requireSession();
  const supabase = createServerClient();

  const { error } = await supabase
    .from('invitation_sections')
    .update({ content })
    .eq('invitation_id', invitationId)
    .eq('section_type', sectionType)
    .in('invitation_id',
      supabase.from('invitations').select('id').eq('tenant_id', user.tenantId)
    );

  return { success: !error };
}
```

### 5.5 Gallery Management

Gallery photos have their own table for quota tracking, ordering, and caption management. Upload is handled client-side to Supabase Storage; the resulting URL is then saved to the `invitation_gallery` table.

```typescript
// app/api/invitations/[id]/gallery/route.ts

export async function POST(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'invitation:write');
  if (auth instanceof NextResponse) return auth;

  const supabase = createServerClient();

  // Quota check for photos
  const quota = await checkQuota(auth.user.tenantId, 'photos');
  if (!quota.allowed) {
    return NextResponse.json(
      { error: `Photo quota reached (${quota.limit} photos per invitation). Upgrade to add more.` },
      { status: 422 }
    );
  }

  const { file_url, thumbnail_url, caption } = await request.json();

  // Get current max sort_order
  const { data: last } = await supabase
    .from('invitation_gallery')
    .select('sort_order')
    .eq('invitation_id', params.id)
    .order('sort_order', { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data: photo, error } = await supabase
    .from('invitation_gallery')
    .insert({
      invitation_id: params.id,
      tenant_id:     auth.user.tenantId,
      file_url,
      thumbnail_url,
      caption:       caption || null,
      sort_order:    (last?.sort_order ?? -1) + 1,
      is_visible:    true,
    })
    .select()
    .single();

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json(photo, { status: 201 });
}

// PATCH /api/invitations/[id]/gallery/[photoId] — update caption, visibility, sort
// DELETE /api/invitations/[id]/gallery/[photoId] — remove photo
// POST /api/invitations/[id]/gallery/reorder — batch sort_order update
```

### 5.6 Music Management

Music tracks support self-hosted uploads (MP3, M4A) and external links (YouTube, Spotify). Only one track can be active at a time.

```typescript
// app/api/invitations/[id]/music/route.ts

export async function POST(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'invitation:write');
  if (auth instanceof NextResponse) return auth;

  // Feature gate check
  const resolution = await resolveFeature(
    { tenantId: auth.user.tenantId, packageId: auth.user.packageId },
    'music_player'
  );
  if (!resolution.enabled) {
    return NextResponse.json(
      { error: 'Music player requires a Basic plan or above.' },
      { status: 403 }
    );
  }

  // Track count quota check
  const config = resolution.config as { max_tracks?: number };
  const maxTracks = config.max_tracks ?? 1;

  const supabase = createServerClient();
  const { count } = await supabase
    .from('invitation_music')
    .select('id', { count: 'exact', head: true })
    .eq('invitation_id', params.id);

  if (maxTracks !== -1 && (count ?? 0) >= maxTracks) {
    return NextResponse.json(
      { error: `Maximum ${maxTracks} music track(s) allowed on your plan.` },
      { status: 422 }
    );
  }

  const body = await request.json();

  // Deactivate all existing tracks before adding new one
  await supabase
    .from('invitation_music')
    .update({ is_active: false })
    .eq('invitation_id', params.id);

  const { data: track, error } = await supabase
    .from('invitation_music')
    .insert({
      invitation_id: params.id,
      tenant_id:     auth.user.tenantId,
      title:         body.title,
      artist:        body.artist || null,
      file_url:      body.source_type === 'upload' ? body.file_url : null,
      external_url:  body.source_type !== 'upload' ? body.external_url : null,
      source_type:   body.source_type,
      is_active:     true,
      duration_sec:  body.duration_sec || null,
    })
    .select()
    .single();

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json(track, { status: 201 });
}
```

### 5.7 Gift / Dana Amplop Management

Gift accounts support three types: bank transfer, QRIS QR code, and e-wallet. Multiple entries can be added, ordered, and toggled visible.

```typescript
// components/invitation/editor/panels/GiftPanel.tsx

// Feature-gated: requires 'gift_registry' feature
// Renders list of gift entries with drag-handle for sort order (native sort only,
// no drag-and-drop canvas — sort buttons ↑↓ for accessibility)

interface GiftEntry {
  id:             string;
  gift_type:      'bank_transfer' | 'qris' | 'e_wallet';
  label:          string;
  bank_name?:     string;
  account_number?:string;
  account_name?:  string;
  qris_image_url?:string;
  e_wallet_type?: string;
  e_wallet_number?:string;
  is_visible:     boolean;
  sort_order:     number;
}

// API: POST /api/invitations/[id]/gifts
// API: PATCH /api/invitations/[id]/gifts/[giftId]
// API: DELETE /api/invitations/[id]/gifts/[giftId]
// API: POST /api/invitations/[id]/gifts/reorder
```

### 5.8 Map Integration

Maps are handled via URL input (Google Maps share link) and optionally an embed code for Premium tenants. The embed code is stored on `invitations.event_maps_embed`.

```typescript
// Map embed feature gate
const mapEmbedEnabled = useFeature('map_embed').enabled;

// Display in EventDetailsPanel:
// - Google Maps URL (all plans): stored as invitations.event_maps_url
//   → rendered as a "Get Directions" button in the invitation
// - Map embed (map_embed feature): iframe embed code
//   → renders an interactive map directly in the Event Details section
```

### 5.9 Videos / Livestream (Feature-Gated)

Livestream links are stored in `invitation_sections.content` for the `livestream` section type. This requires the `livestream_embed` feature.

```typescript
// Content shape for livestream section
interface LivestreamContent {
  embed_url:    string;   // YouTube/Zoom URL
  platform:     'youtube' | 'zoom' | 'other';
  title:        string;   // e.g. "Watch Our Ceremony Live"
  scheduled_at: string | null; // ISO datetime of stream
}
```

---

## 6. Invitation URL System

### 6.1 URL Structure

```
Platform default:
  https://inv.weddingplatform.com/[slug]
  e.g.: https://inv.weddingplatform.com/andi-ninah-2026

With custom domain (Premium+):
  https://[custom-domain.com]/[slug]
  e.g.: https://andiandninah.com/wedding

Reseller white-label:
  https://[reseller-domain.com]/inv/[slug]
  (reseller's client invitation, served under reseller brand)

Personalized guest link:
  https://inv.weddingplatform.com/[slug]?t=[personal_token]
  (shows personalized greeting; token links to guests table)

Preview URL (draft, auth-required):
  https://app.weddingplatform.com/invitations/[id]/preview
  (serves draft via SSR with auth; no public caching)
```

### 6.2 Slug Validation Rules

```typescript
// lib/invitations/slug.ts

export const SLUG_REGEX = /^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$/;

export const SLUG_CONSTRAINTS = {
  minLength: 3,
  maxLength: 60,
  // Reserved slugs that cannot be used by tenants
  reserved: [
    'admin', 'api', 'app', 'auth', 'blog', 'dashboard', 'docs',
    'help', 'home', 'inv', 'login', 'logout', 'pricing', 'privacy',
    'register', 'reseller', 'settings', 'signup', 'status', 'support',
    'terms', 'www',
  ],
} as const;

export function validateSlug(slug: string): { valid: boolean; reason?: string } {
  if (slug.length < SLUG_CONSTRAINTS.minLength) {
    return { valid: false, reason: `Minimum ${SLUG_CONSTRAINTS.minLength} characters` };
  }
  if (slug.length > SLUG_CONSTRAINTS.maxLength) {
    return { valid: false, reason: `Maximum ${SLUG_CONSTRAINTS.maxLength} characters` };
  }
  if (!SLUG_REGEX.test(slug)) {
    return { valid: false, reason: 'Only lowercase letters, numbers, and hyphens. Cannot start or end with a hyphen.' };
  }
  if (SLUG_CONSTRAINTS.reserved.includes(slug)) {
    return { valid: false, reason: 'This URL is reserved. Please choose a different one.' };
  }
  return { valid: true };
}

export async function generateUniqueSlug(base: string): Promise<string> {
  // Sanitize base string
  const sanitized = base
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 50);

  const supabase = createServerClient();

  let candidate = sanitized;
  let attempt = 0;

  while (attempt < 10) {
    const { data } = await supabase
      .from('invitations')
      .select('id')
      .eq('slug', candidate)
      .maybeSingle();

    if (!data) return candidate;

    attempt++;
    candidate = `${sanitized}-${Math.random().toString(36).slice(2, 6)}`;
  }

  // Fallback: UUID-based slug
  return `inv-${crypto.randomUUID().slice(0, 8)}`;
}
```

### 6.3 Slug Change Policy

Slugs can be changed on draft invitations without restriction. On a **published** invitation:

- Changing the slug causes the old URL to return 404
- A redirect record is created from old slug → new slug (Phase 3+)
- ISR cache for the old slug is purged
- The invitation must be re-shared with the new URL

```typescript
// app/api/invitations/[id]/slug/route.ts

export async function PATCH(request: Request, { params }: { params: { id: string } }) {
  const auth = await requireAuth(request, 'invitation:write');
  if (auth instanceof NextResponse) return auth;

  const { slug } = await request.json();

  const validation = validateSlug(slug);
  if (!validation.valid) {
    return NextResponse.json({ error: validation.reason }, { status: 422 });
  }

  const supabase = createServerClient();

  // Get current invitation to capture old slug
  const { data: current } = await supabase
    .from('invitations')
    .select('slug, status')
    .eq('id', params.id)
    .eq('tenant_id', auth.user.tenantId)
    .single();

  if (!current) return NextResponse.json({ error: 'Not found' }, { status: 404 });

  const { error } = await supabase
    .from('invitations')
    .update({ slug })
    .eq('id', params.id)
    .eq('tenant_id', auth.user.tenantId);

  if (error?.code === '23505') {
    return NextResponse.json({ error: 'This URL is already taken.' }, { status: 409 });
  }
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  // Revalidate ISR for both old and new slugs
  if (current.status === 'published') {
    revalidatePath(`/inv/${current.slug}`);
    revalidatePath(`/inv/${slug}`);
    revalidatePath(`/api/og?slug=${current.slug}`);
    revalidatePath(`/api/og?slug=${slug}`);
  }

  return NextResponse.json({ slug });
}
```

### 6.4 Sharing URL Generation

```typescript
// lib/invitations/sharing.ts

export function getPublicUrl(slug: string, customDomain?: string): string {
  if (customDomain) {
    return `https://${customDomain}/${slug}`;
  }
  return `${process.env.NEXT_PUBLIC_INVITATION_BASE_URL}/${slug}`;
  // e.g. https://inv.weddingplatform.com/andi-ninah-2026
}

export function getPersonalizedUrl(
  slug: string,
  personalToken: string,
  customDomain?: string
): string {
  const base = getPublicUrl(slug, customDomain);
  return `${base}?t=${personalToken}`;
}

export function getWhatsAppShareText(
  groomName: string,
  brideName: string,
  eventDate: string,
  publicUrl: string,
  recipientName?: string
): string {
  const greeting = recipientName ? `Hai ${recipientName}! 👋\n\n` : '';
  return encodeURIComponent(
    `${greeting}Kami dengan penuh suka cita mengundang Anda untuk hadir di pernikahan kami:\n\n` +
    `💑 ${groomName} & ${brideName}\n` +
    `📅 ${eventDate}\n\n` +
    `Lihat undangan kami di:\n${publicUrl}`
  );
}

export function getWhatsAppShareUrl(text: string, phone?: string): string {
  const base = phone ? `https://wa.me/${phone}` : 'https://wa.me';
  return `${base}?text=${text}`;
}
```

---

## 7. Invitation Settings

### 7.1 Settings Overview

Invitation settings are accessible from a dedicated settings panel within the editor and from the invitation detail page. They are distinct from theme customization (visual properties) — settings control behavior and access.

```
/invitations/[id]/settings
├── Visibility & Access
│   ├── Password Protection (password_protection feature)
│   └── RSVP Settings
├── RSVP
│   ├── Open / Closed toggle
│   ├── RSVP Deadline date
│   ├── Meal Choice (rsvp_meal_choice feature)
│   └── Plus-One (rsvp_plus_one feature)
├── Guestbook
│   ├── Enable / Disable
│   └── Moderation (guestbook_moderation feature)
├── Music
│   └── Autoplay toggle
├── Gallery
│   └── Layout style (per-section config)
└── SEO & Sharing
    ├── Meta title
    ├── Meta description
    └── OG image upload
```

### 7.2 Settings API

```typescript
// app/api/invitations/[id]/settings/route.ts

const SettingsSchema = z.object({
  // Visibility
  is_rsvp_open:        z.boolean().optional(),
  rsvp_deadline:       z.string().nullable().optional(),
  // SEO
  meta_title:          z.string().max(70).nullable().optional(),
  meta_description:    z.string().max(160).nullable().optional(),
  og_image_url:        z.string().url().nullable().optional(),
  // Scheduling
  scheduled_publish_at: z.string().datetime().nullable().optional(),
});

export async function PATCH(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'invitation:write');
  if (auth instanceof NextResponse) return auth;

  const body = await request.json();
  const parsed = SettingsSchema.safeParse(body);
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.flatten() }, { status: 422 });
  }

  const supabase = createServerClient();

  const { error } = await supabase
    .from('invitations')
    .update(parsed.data)
    .eq('id', params.id)
    .eq('tenant_id', auth.user.tenantId);

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  // If a published invitation's settings changed, revalidate ISR
  const { data: inv } = await supabase
    .from('invitations')
    .select('slug, status')
    .eq('id', params.id)
    .single();

  if (inv?.status === 'published') {
    revalidatePath(`/inv/${inv.slug}`);
  }

  return NextResponse.json({ success: true });
}
```

### 7.3 Password Protection

When a password is set, the public invitation page redirects to a password gate before rendering the invitation.

```typescript
// app/api/invitations/[id]/password/route.ts

export async function POST(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'invitation:write');
  if (auth instanceof NextResponse) return auth;

  // Feature gate
  const resolution = await resolveFeature(
    { tenantId: auth.user.tenantId, packageId: auth.user.packageId },
    'password_protection'
  );
  if (!resolution.enabled) {
    return NextResponse.json(
      { error: 'Password protection requires a Basic plan or above.' },
      { status: 403 }
    );
  }

  const { password } = await request.json();
  if (!password) {
    // Remove password (set to null)
    await supabase.from('invitations').update({ password_hash: null })
      .eq('id', params.id).eq('tenant_id', auth.user.tenantId);
    return NextResponse.json({ success: true });
  }

  // Bcrypt hash (12 rounds)
  const hash = await bcrypt.hash(password, 12);
  const supabase = createServerClient();

  await supabase.from('invitations').update({ password_hash: hash })
    .eq('id', params.id).eq('tenant_id', auth.user.tenantId);

  return NextResponse.json({ success: true });
}
```

### 7.4 RSVP Settings

```typescript
// components/invitation/editor/settings/RsvpSettings.tsx

'use client';

interface RsvpSettingsProps {
  isRsvpOpen:    boolean;
  rsvpDeadline:  string | null;
  invitationId:  string;
}

export function RsvpSettings({ isRsvpOpen, rsvpDeadline, invitationId }: RsvpSettingsProps) {
  const mealChoiceEnabled = useFeature('rsvp_meal_choice').enabled;
  const plusOneEnabled    = useFeature('rsvp_plus_one').enabled;

  return (
    <div className="space-y-4 p-4">
      <ToggleField
        label="RSVP Open"
        value={isRsvpOpen}
        hint="When closed, guests can view but not submit RSVP responses"
        onChange={v => updateSettings(invitationId, { is_rsvp_open: v })}
      />

      <DateInputField
        label="RSVP Deadline"
        value={rsvpDeadline}
        hint="After this date, RSVP form is automatically closed"
        onChange={v => updateSettings(invitationId, { rsvp_deadline: v })}
      />

      {mealChoiceEnabled ? (
        <ToggleField
          label="Meal Choice"
          value={/* from section content */true}
          hint="Allow guests to select meal preference"
          onChange={v => updateSectionContent(invitationId, 'rsvp', { meal_choice_enabled: v })}
        />
      ) : (
        <LockedField label="Meal Choice" featureKey="rsvp_meal_choice" />
      )}

      {plusOneEnabled ? (
        <ToggleField
          label="Plus-One"
          value={/* from section content */false}
          hint="Allow guests to bring a plus-one"
          onChange={v => updateSectionContent(invitationId, 'rsvp', { plus_one_enabled: v })}
        />
      ) : (
        <LockedField label="Plus-One" featureKey="rsvp_plus_one" />
      )}
    </div>
  );
}
```

---

## 8. Theme Integration

### 8.1 Theme Assignment at Creation

When an invitation is created, the selected `theme_id` is stored on the `invitations` record. The theme determines:
- Which section types are supported
- Default section visibility
- The `config_schema` for the property panel
- The default color, font, and layout values

### 8.2 Theme Switching

Theme switching is allowed on `draft` invitations only. Published invitations must first be unpublished. When a theme is switched:

1. Confirm modal warns the user that customizations will be reset
2. `invitations.customization` is cleared (set to `{}`)
3. `invitation_sections` rows are deleted and reseeded from new theme defaults
4. `invitations.theme_id` is updated
5. Editor reloads with new theme's schema

```typescript
// app/api/invitations/[id]/theme/route.ts

export async function POST(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'invitation:write');
  if (auth instanceof NextResponse) return auth;

  const { theme_id } = await request.json();
  const supabase = createServerClient();

  const { data: invitation } = await supabase
    .from('invitations')
    .select('status, theme_id')
    .eq('id', params.id)
    .eq('tenant_id', auth.user.tenantId)
    .single();

  if (!invitation) return NextResponse.json({ error: 'Not found' }, { status: 404 });

  if (invitation.status === 'published') {
    return NextResponse.json(
      { error: 'Unpublish the invitation before changing its theme.' },
      { status: 422 }
    );
  }

  const { data: theme } = await supabase
    .from('invitation_themes')
    .select('id, slug, category, is_premium, is_active')
    .eq('id', theme_id)
    .eq('is_active', true)
    .single();

  if (!theme) return NextResponse.json({ error: 'Theme not found' }, { status: 404 });

  if (theme.is_premium) {
    const resolution = await resolveFeature(
      { tenantId: auth.user.tenantId, packageId: auth.user.packageId },
      'premium_themes'
    );
    if (!resolution.enabled) {
      return NextResponse.json({ error: 'Premium themes require a Basic plan.' }, { status: 403 });
    }
  }

  // Atomic theme change: clear customization + update theme + reseed sections
  await supabase.rpc('change_invitation_theme', {
    p_invitation_id:    params.id,
    p_theme_id:         theme_id,
    p_default_sections: getDefaultSectionsForCategory(theme.category),
  });

  await writeAuditLog(request, 'invitation.theme_change', 'invitation', params.id, {
    tenantId: auth.user.tenantId,
    userId:   auth.user.id,
    oldData:  { theme_id: invitation.theme_id },
    newData:  { theme_id },
  });

  return NextResponse.json({ success: true });
}
```

```sql
-- supabase/migrations/060_change_invitation_theme.sql

CREATE OR REPLACE FUNCTION change_invitation_theme(
  p_invitation_id    UUID,
  p_theme_id         UUID,
  p_default_sections JSONB
)
RETURNS VOID AS $$
BEGIN
  -- Clear customization and update theme atomically
  UPDATE invitations
  SET theme_id      = p_theme_id,
      customization = '{}',
      updated_at    = NOW()
  WHERE id = p_invitation_id;

  -- Delete all existing sections
  DELETE FROM invitation_sections
  WHERE invitation_id = p_invitation_id;

  -- Reseed from new theme defaults
  INSERT INTO invitation_sections (invitation_id, section_type, sort_order, is_visible, content)
  SELECT
    p_invitation_id,
    (section ->> 'type')::TEXT,
    (section ->> 'sort_order')::INTEGER,
    (section ->> 'is_visible')::BOOLEAN,
    '{}'::JSONB
  FROM jsonb_array_elements(p_default_sections) AS section;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### 8.3 Theme Configuration Flow

```
User opens editor
  │
  ▼
Server component loads:
  - invitation.theme_id → join invitation_themes (slug, config_schema, version)
  - invitation.customization (flat dot-notation JSONB)
  │
  ▼
ensureCustomizationUpToDate() runs lazy schema migration if needed
  │
  ▼
mergeThemeConfig(schema, themeDefaults, customization) → mergedConfig
  │
  ├── ThemeConfigProvider(mergedConfig) wraps editor
  │     └── LivePreview reads mergedConfig → renders at 390px scale
  │
  └── PropertyPanel reads schema fields → renders fields with current values
        → onChange: updateProperty(dotPath, value)
              → optimistic update to local state
              → debounced flush to updateCustomizationAction
```

### 8.4 Theme Compatibility Checks

When a tenant downgrades their plan, existing published invitations using premium themes remain live (grandfather behavior). However:

- The editor becomes read-only for premium-theme invitations on plans without `premium_themes`
- New invitations cannot use premium themes
- This is checked in `checkThemeAccessForEdit()` (PHASE6, Section 12.3)

---

## 9. Publishing System

### 9.1 Publish Action

```typescript
// app/api/invitations/[id]/publish/route.ts

export async function POST(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'invitation:publish');
  if (auth instanceof NextResponse) return auth;

  const supabase = createServerClient();

  const { data: invitation } = await supabase
    .from('invitations')
    .select('*, theme:invitation_themes(slug)')
    .eq('id', params.id)
    .eq('tenant_id', auth.user.tenantId)
    .is('deleted_at', null)
    .single();

  if (!invitation) return NextResponse.json({ error: 'Not found' }, { status: 404 });

  if (invitation.status === 'published') {
    return NextResponse.json({ error: 'Already published' }, { status: 409 });
  }

  // Validate required fields
  const validation = validateDraftForPublish(invitation);
  if (!validation.valid) {
    return NextResponse.json({ error: 'Validation failed', details: validation.errors }, { status: 422 });
  }

  const now = new Date().toISOString();

  const { error } = await supabase
    .from('invitations')
    .update({
      status:       'published',
      published_at: invitation.published_at ?? now, // preserve original first publish date
    })
    .eq('id', params.id)
    .eq('tenant_id', auth.user.tenantId);

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  // Revalidate ISR
  revalidatePath(`/inv/${invitation.slug}`);
  revalidatePath(`/api/og?slug=${invitation.slug}`);

  // Queue OG image generation if not set
  if (!invitation.og_image_url) {
    await supabase.functions.invoke('generate-og-image', {
      body: { invitation_id: params.id, slug: invitation.slug },
    });
  }

  await writeAuditLog(request, 'invitation.publish', 'invitation', params.id, {
    tenantId: auth.user.tenantId,
    userId:   auth.user.id,
  });

  return NextResponse.json({ success: true });
}
```

### 9.2 Unpublish Action

```typescript
// app/api/invitations/[id]/unpublish/route.ts

export async function POST(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'invitation:publish');
  if (auth instanceof NextResponse) return auth;

  const supabase = createServerClient();

  const { data: invitation } = await supabase
    .from('invitations')
    .select('slug, status')
    .eq('id', params.id)
    .eq('tenant_id', auth.user.tenantId)
    .single();

  if (!invitation) return NextResponse.json({ error: 'Not found' }, { status: 404 });
  if (invitation.status !== 'published') {
    return NextResponse.json({ error: 'Invitation is not published' }, { status: 409 });
  }

  await supabase
    .from('invitations')
    .update({ status: 'draft' })
    .eq('id', params.id)
    .eq('tenant_id', auth.user.tenantId);

  // Purge ISR cache — page now 404s (or returns to middleware-level 404)
  revalidatePath(`/inv/${invitation.slug}`);

  await writeAuditLog(request, 'invitation.unpublish', 'invitation', params.id, {
    tenantId: auth.user.tenantId,
    userId:   auth.user.id,
  });

  return NextResponse.json({ success: true });
}
```

### 9.3 Archive Action

```typescript
// app/api/invitations/[id]/archive/route.ts

export async function POST(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'invitation:publish');
  if (auth instanceof NextResponse) return auth;

  const supabase = createServerClient();

  const { data: invitation } = await supabase
    .from('invitations')
    .select('slug, status')
    .eq('id', params.id)
    .eq('tenant_id', auth.user.tenantId)
    .is('deleted_at', null)
    .single();

  if (!invitation) return NextResponse.json({ error: 'Not found' }, { status: 404 });
  if (invitation.status === 'archived') {
    return NextResponse.json({ error: 'Already archived' }, { status: 409 });
  }

  await supabase
    .from('invitations')
    .update({ status: 'archived' })
    .eq('id', params.id)
    .eq('tenant_id', auth.user.tenantId);

  // Purge ISR cache if was published
  if (invitation.status === 'published') {
    revalidatePath(`/inv/${invitation.slug}`);
  }

  await writeAuditLog(request, 'invitation.archive', 'invitation', params.id, {
    tenantId: auth.user.tenantId,
    userId:   auth.user.id,
  });

  return NextResponse.json({ success: true });
}
```

### 9.4 Scheduled Publishing

Invitations can be scheduled to publish at a future date/time using `invitations.scheduled_publish_at`. A Supabase Edge Function runs on a cron schedule to process pending scheduled publishes.

```typescript
// supabase/functions/process-scheduled-publishes/index.ts

Deno.serve(async () => {
  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  );

  const now = new Date().toISOString();

  // Find all draft invitations with a scheduled_publish_at in the past
  const { data: scheduled } = await admin
    .from('invitations')
    .select('id, slug, tenant_id, couple_data, og_image_url')
    .eq('status', 'draft')
    .not('scheduled_publish_at', 'is', null)
    .lte('scheduled_publish_at', now)
    .is('deleted_at', null);

  for (const inv of scheduled ?? []) {
    const validation = validateDraftForPublish(inv as any);

    if (!validation.valid) {
      // Cannot auto-publish — notify owner and clear the schedule
      await admin
        .from('invitations')
        .update({ scheduled_publish_at: null })
        .eq('id', inv.id);

      await admin.from('email_notifications').insert({
        tenant_id:        inv.tenant_id,
        invitation_id:    inv.id,
        recipient_email:  await getOwnerEmail(admin, inv.tenant_id),
        template_key:     'scheduled_publish_failed',
        status:           'pending',
        metadata:         { errors: validation.errors },
      });

      continue;
    }

    await admin
      .from('invitations')
      .update({
        status:              'published',
        published_at:        now,
        scheduled_publish_at: null,
      })
      .eq('id', inv.id);

    // Notify ISR revalidation via API
    await fetch(`${Deno.env.get('NEXT_PUBLIC_APP_URL')}/api/revalidate`, {
      method: 'POST',
      headers: { 'x-revalidate-secret': Deno.env.get('REVALIDATE_SECRET')! },
      body: JSON.stringify({ slug: inv.slug }),
    });

    await admin.from('audit_logs').insert({
      tenant_id:     inv.tenant_id,
      action:        'invitation.publish',
      resource_type: 'invitation',
      resource_id:   inv.id,
      actor_role:    'system',
    });
  }

  return new Response(JSON.stringify({ processed: scheduled?.length ?? 0 }), { status: 200 });
});
```

**Cron schedule:** Every 5 minutes via Supabase Edge Function schedule.

---

## 10. Duplication System

### 10.1 Duplication Scope

When an invitation is duplicated, the following data is cloned:

| Data | Cloned? | Notes |
|---|:---:|---|
| Core invitation fields (theme, title, event data, couple_data) | ✅ | New slug auto-generated |
| `customization` JSONB (theme overrides) | ✅ | Full copy |
| `invitation_sections` rows | ✅ | All sections with content JSONB |
| `invitation_gallery` rows | ✅ | File URLs reused (not re-uploaded) |
| `invitation_music` rows | ✅ | File URLs reused |
| `invitation_gifts` rows | ✅ | Full copy |
| `status` | ❌ | Always set to `draft` |
| `published_at`, `scheduled_publish_at` | ❌ | Cleared |
| `guests` | ❌ | Not cloned — specific to recipient list |
| `rsvp_responses` | ❌ | Not cloned |
| `guestbook_entries` | ❌ | Not cloned |
| `qr_codes` | ❌ | Not cloned |
| `invitation_analytics` | ❌ | Not cloned |
| `view_count` | ❌ | Reset to 0 |
| `password_hash` | ❌ | Cleared for safety |

### 10.2 Duplication Quota Check

Before duplicating, the `max_invitations` quota is checked. The user must have remaining quota capacity.

### 10.3 Duplication Action

```typescript
// app/api/invitations/[id]/duplicate/route.ts

export async function POST(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'invitation:write');
  if (auth instanceof NextResponse) return auth;

  const supabase = createServerClient();

  // Quota check
  const quota = await checkQuota(auth.user.tenantId, 'invitations');
  if (!quota.allowed) {
    return NextResponse.json(
      { error: 'Invitation quota reached. Upgrade your plan to duplicate.' },
      { status: 422 }
    );
  }

  // Load source invitation with all related data
  const [invResult, sectionsResult, galleryResult, musicResult, giftsResult] =
    await Promise.all([
      supabase
        .from('invitations')
        .select('*')
        .eq('id', params.id)
        .eq('tenant_id', auth.user.tenantId)
        .is('deleted_at', null)
        .single(),
      supabase
        .from('invitation_sections')
        .select('*')
        .eq('invitation_id', params.id),
      supabase
        .from('invitation_gallery')
        .select('*')
        .eq('invitation_id', params.id),
      supabase
        .from('invitation_music')
        .select('*')
        .eq('invitation_id', params.id),
      supabase
        .from('invitation_gifts')
        .select('*')
        .eq('invitation_id', params.id),
    ]);

  const source = invResult.data;
  if (!source) return NextResponse.json({ error: 'Not found' }, { status: 404 });

  // Generate unique slug for the clone
  const sourceSlug = source.slug;
  const newSlug = await generateUniqueSlug(`${sourceSlug}-copy`);

  // Create cloned invitation
  const { data: clone, error: cloneError } = await supabase
    .from('invitations')
    .insert({
      tenant_id:    source.tenant_id,
      created_by:   auth.user.id,
      theme_id:     source.theme_id,
      slug:         newSlug,
      title:        `${source.title} (Copy)`,
      status:       'draft',
      event_date:   source.event_date,
      event_time:   source.event_time,
      event_venue:  source.event_venue,
      event_address:source.event_address,
      event_maps_url: source.event_maps_url,
      event_maps_embed: source.event_maps_embed,
      couple_data:  source.couple_data,
      customization: source.customization,
      is_rsvp_open: source.is_rsvp_open,
      rsvp_deadline: source.rsvp_deadline,
      // Intentionally omitted: password_hash, published_at, scheduled_publish_at, view_count, og_image_url
    })
    .select('id, slug')
    .single();

  if (cloneError || !clone) {
    return NextResponse.json({ error: 'Duplication failed' }, { status: 500 });
  }

  // Clone sections
  if (sectionsResult.data?.length) {
    await supabase.from('invitation_sections').insert(
      sectionsResult.data.map(({ id: _id, invitation_id: _inv, created_at: _ca, updated_at: _ua, ...rest }) => ({
        ...rest,
        invitation_id: clone.id,
      }))
    );
  }

  // Clone gallery
  if (galleryResult.data?.length) {
    await supabase.from('invitation_gallery').insert(
      galleryResult.data.map(({ id: _id, invitation_id: _inv, created_at: _ca, ...rest }) => ({
        ...rest,
        invitation_id: clone.id,
        tenant_id:     auth.user.tenantId,
      }))
    );
  }

  // Clone music
  if (musicResult.data?.length) {
    await supabase.from('invitation_music').insert(
      musicResult.data.map(({ id: _id, invitation_id: _inv, created_at: _ca, updated_at: _ua, ...rest }) => ({
        ...rest,
        invitation_id: clone.id,
        tenant_id:     auth.user.tenantId,
      }))
    );
  }

  // Clone gifts
  if (giftsResult.data?.length) {
    await supabase.from('invitation_gifts').insert(
      giftsResult.data.map(({ id: _id, invitation_id: _inv, created_at: _ca, updated_at: _ua, ...rest }) => ({
        ...rest,
        invitation_id: clone.id,
        tenant_id:     auth.user.tenantId,
      }))
    );
  }

  await writeAuditLog(request, 'invitation.duplicate', 'invitation', clone.id, {
    tenantId: auth.user.tenantId,
    userId:   auth.user.id,
    oldData:  { source_invitation_id: params.id },
    newData:  { slug: newSlug },
  });

  return NextResponse.json({ id: clone.id, slug: clone.slug }, { status: 201 });
}
```

---

## 11. Permission Rules

### 11.1 Invitation Action Permission Matrix

| Action | super_admin | reseller_admin | owner | editor | viewer |
|---|:---:|:---:|:---:|:---:|:---:|
| **LIST** | | | | | |
| List all tenant invitations | ✅ | ✅ (clients only) | ✅ | ✅ | ✅ |
| **CREATE** | | | | | |
| Create invitation | ✅ | ✅ (for clients) | ✅ | ✅ | ❌ |
| **EDIT** | | | | | |
| Edit invitation content | ✅ | ✅ | ✅ | ✅ | ❌ |
| Edit invitation settings | ✅ | ✅ | ✅ | ❌ | ❌ |
| Change invitation theme | ✅ | ✅ | ✅ | ❌ | ❌ |
| Change invitation slug | ✅ | ✅ | ✅ | ❌ | ❌ |
| Set password protection | ✅ | ✅ | ✅ | ❌ | ❌ |
| **PUBLISH** | | | | | |
| Publish invitation | ✅ | ✅ | ✅ | ❌ | ❌ |
| Unpublish invitation | ✅ | ✅ | ✅ | ❌ | ❌ |
| Schedule publish | ✅ | ✅ | ✅ | ❌ | ❌ |
| **ARCHIVE / DELETE** | | | | | |
| Archive invitation | ✅ | ✅ | ✅ | ❌ | ❌ |
| Restore archived invitation | ✅ | ✅ | ✅ | ❌ | ❌ |
| Soft delete invitation | ✅ | ✅ | ✅ | ❌ | ❌ |
| Hard delete invitation | ✅ | ❌ | ❌ | ❌ | ❌ |
| **DUPLICATE** | | | | | |
| Duplicate invitation | ✅ | ✅ | ✅ | ❌ | ❌ |
| **PREVIEW** | | | | | |
| Preview draft (auth-gated) | ✅ | ✅ | ✅ | ✅ | ✅ |
| View published (public) | ✅ | ✅ | ✅ | ✅ | ✅ |
| **CONTENT** | | | | | |
| Edit gallery photos | ✅ | ✅ | ✅ | ✅ | ❌ |
| Edit music | ✅ | ✅ | ✅ | ✅ | ❌ |
| Edit gifts | ✅ | ✅ | ✅ | ✅ | ❌ |
| **FEATURE OVERRIDES** | | | | | |
| Override invitation feature flags | ✅ | ✅ (clients only) | ❌ | ❌ | ❌ |

### 11.2 API Route Permission Map

| Route | Method | Required Permission | Feature Gate | Quota |
|---|---|---|---|---|
| `/api/invitations` | GET | `invitation:read` | — | — |
| `/api/invitations` | POST | `invitation:write` | — | `max_invitations` |
| `/api/invitations/[id]` | GET | `invitation:read` | — | — |
| `/api/invitations/[id]` | PATCH | `invitation:write` | — | — |
| `/api/invitations/[id]/publish` | POST | `invitation:publish` | — | — |
| `/api/invitations/[id]/unpublish` | POST | `invitation:publish` | — | — |
| `/api/invitations/[id]/archive` | POST | `invitation:publish` | — | — |
| `/api/invitations/[id]/duplicate` | POST | `invitation:write` | — | `max_invitations` |
| `/api/invitations/[id]/theme` | POST | `invitation:write` | `premium_themes` (if premium) | — |
| `/api/invitations/[id]/slug` | PATCH | `invitation:write` | — | — |
| `/api/invitations/[id]/settings` | PATCH | `invitation:write` | — | — |
| `/api/invitations/[id]/password` | POST | `invitation:publish` | `password_protection` | — |
| `/api/invitations/[id]/gallery` | GET | `invitation:read` | `gallery` | — |
| `/api/invitations/[id]/gallery` | POST | `invitation:write` | `gallery` | `max_photos` |
| `/api/invitations/[id]/gallery/[id]` | PATCH | `invitation:write` | `gallery` | — |
| `/api/invitations/[id]/gallery/[id]` | DELETE | `invitation:write` | `gallery` | — |
| `/api/invitations/[id]/music` | POST | `invitation:write` | `music_player` | `max_music_tracks` |
| `/api/invitations/[id]/gifts` | POST | `invitation:write` | `gift_registry` | — |
| `/api/invitations/[id]/customization` | PATCH | `invitation:write` | (per field) | — |
| `/api/invitations/[id]/sections/[type]` | PATCH | `invitation:write` | (per section) | — |

### 11.3 RLS Policies (Invitations Domain)

```sql
-- All policies referencing PHASE2 helpers: auth_tenant_id(), auth_role(), auth_reseller_id()

ALTER TABLE invitations ENABLE ROW LEVEL SECURITY;

-- Tenant members read their own invitations (non-deleted)
CREATE POLICY "inv_read_own_tenant" ON invitations
  FOR SELECT
  USING (tenant_id = auth_tenant_id() AND deleted_at IS NULL);

-- Reseller admins read their clients' invitations
CREATE POLICY "inv_read_reseller_clients" ON invitations
  FOR SELECT
  USING (
    deleted_at IS NULL AND
    tenant_id IN (
      SELECT tenant_id FROM reseller_tenants
      WHERE reseller_id = auth_reseller_id()
    )
  );

-- Public read: published invitations only (no auth required)
CREATE POLICY "inv_public_read" ON invitations
  FOR SELECT
  USING (status = 'published' AND deleted_at IS NULL);

-- Owners and editors can insert
CREATE POLICY "inv_insert_tenant" ON invitations
  FOR INSERT
  WITH CHECK (
    tenant_id = auth_tenant_id() AND
    auth_role() IN ('owner', 'editor')
  );

-- Owners and editors can update
-- (publish/unpublish restricted to 'owner' at application layer)
CREATE POLICY "inv_update_tenant" ON invitations
  FOR UPDATE
  USING (
    tenant_id = auth_tenant_id() AND
    auth_role() IN ('owner', 'editor') AND
    deleted_at IS NULL
  );

-- Soft delete: owner only (UPDATE deleted_at = NOW())
-- Hard guarded at app layer; RLS allows the UPDATE.

-- Cascade tables inherit tenant isolation through invitation ownership:
ALTER TABLE invitation_sections ENABLE ROW LEVEL SECURITY;
CREATE POLICY "sections_tenant" ON invitation_sections
  FOR ALL
  USING (
    invitation_id IN (
      SELECT id FROM invitations WHERE tenant_id = auth_tenant_id() AND deleted_at IS NULL
    )
  );

-- Same pattern for invitation_gallery, invitation_music, invitation_gifts
```

---

## 12. Multi-Tenant Considerations

### 12.1 Tenant Isolation Architecture

Every invitation is isolated by `tenant_id` at the database row level through RLS. The application layer never passes a `tenant_id` as a query filter — it comes from the JWT claim and is enforced by the database.

```
Request arrives
  │
  ▼
Edge Middleware: extract tenant_id from JWT
  │
  ▼
Server component / API route: createServerClient()
  │  Uses anon key + user JWT
  │  RLS policies enforce tenant_id = auth_tenant_id()
  ▼
PostgreSQL: only rows matching tenant_id are returned
  │  Regardless of application-layer query
  ▼
Response: tenant-scoped data only
```

**Defense-in-depth:** Even if application code mistakenly omits a `.eq('tenant_id', ...)` filter, RLS prevents data leakage. The database is the last line of defense.

### 12.2 Slug Uniqueness and Tenant Isolation

Slugs are globally unique (UNIQUE constraint on `invitations.slug`) — not scoped per tenant. This prevents:
- URL collisions across tenants
- Confusion when a public URL serves one tenant's content on another tenant's subdomain

**Trade-off:** A popular couple name slug (e.g. `andi-ninah`) can only be taken once platform-wide. The slug availability check makes this clear to the user before they invest in content.

### 12.3 Resource Ownership Transfer

If a user is removed from a tenant (team invite revoked), their `created_by` FK on invitations is preserved — invitations are owned by the tenant, not the individual user. The invitation remains accessible to the tenant owner and other team members.

```sql
-- created_by is informational — the tenant_id is the ownership boundary
-- No CASCADE DELETE on users.id → invitations.created_by
-- (FK is nullable-safe; user deactivation doesn't orphan invitations)
```

### 12.4 Cross-Tenant Data Access Prevention

```typescript
// Defensive pattern used in all invitation API routes

// WRONG — relies only on params.id; vulnerable if RLS is misconfigured
const { data } = await supabase.from('invitations').select('*').eq('id', params.id);

// CORRECT — always include tenant_id scoping at application layer too
const { data } = await supabase
  .from('invitations')
  .select('*')
  .eq('id', params.id)
  .eq('tenant_id', auth.user.tenantId)  // explicit, even though RLS enforces it
  .single();
```

### 12.5 Public Invitation Access (No Auth)

Public invitation pages are served without authentication. The RLS `inv_public_read` policy allows SELECT on `status = 'published'` rows for unauthenticated (anon) requests. The public Supabase anon key is safe to use here because RLS prevents reading draft/archived/deleted invitations.

### 12.6 Quota Enforcement Across Tenants

Each tenant's quota is checked independently:

```typescript
// lib/packages/quota.ts

async function getCurrentUsage(
  supabase: SupabaseClient,
  tenantId: string,
  resource: QuotaResource
): Promise<number> {
  switch (resource) {
    case 'invitations': {
      // Count only draft + published; archived doesn't count
      const { count } = await supabase
        .from('invitations')
        .select('id', { count: 'exact', head: true })
        .eq('tenant_id', tenantId)
        .in('status', ['draft', 'published'])
        .is('deleted_at', null);
      return count ?? 0;
    }
    case 'photos': {
      // Count gallery photos across ALL invitations for this tenant
      const { count } = await supabase
        .from('invitation_gallery')
        .select('id', { count: 'exact', head: true })
        .eq('tenant_id', tenantId);
      return count ?? 0;
    }
    // ... other resources
  }
}
```

---

## 13. Performance Optimization

### 13.1 Public Page Caching Strategy

Public invitation pages use **ISR (Incremental Static Regeneration)** with a 60-second revalidation window. This is the primary performance lever.

```typescript
// app/inv/[slug]/page.tsx

// ISR: serves cached HTML for up to 60 seconds
export const revalidate = 60;

// Draft preview: never cached — always SSR
// (served from /invitations/[id]/preview, auth-gated)
```

**Cache invalidation triggers:**
- `publishInvitation()` → `revalidatePath('/inv/[slug]')`
- `unpublishInvitation()` → `revalidatePath('/inv/[slug]')`
- `archiveInvitation()` → `revalidatePath('/inv/[slug]')`
- `updateCustomization()` → deferred: ISR revalidates on next 60s window
- `changeSlug()` → `revalidatePath` for both old and new slugs

**Trade-off:** The 60-second window means a customization change takes up to 60 seconds to appear on the public page. This is acceptable because the invitation owner uses the live preview in the editor, not the public URL, while editing.

### 13.2 Data Loading Strategy

```typescript
// app/inv/[slug]/page.tsx — parallel data loading

const [invitation, sub] = await Promise.all([
  supabase
    .from('invitations')
    .select(`
      id, slug, title, status,
      couple_data, customization,
      event_date, event_time, event_venue, event_address,
      event_maps_url, event_maps_embed,
      is_rsvp_open, rsvp_deadline, password_hash,
      meta_title, meta_description, og_image_url,
      theme:invitation_themes(id, slug, name, config_schema, version),
      sections:invitation_sections(id, section_type, sort_order, is_visible, content),
      gallery:invitation_gallery(id, file_url, thumbnail_url, caption, sort_order) ...filter(is_visible=true),
      music:invitation_music(id, title, artist, file_url, external_url, source_type, is_active) ...filter(is_active=true),
      gifts:invitation_gifts(id, gift_type, label, bank_name, account_number, account_name, qris_image_url, e_wallet_type, e_wallet_number, sort_order) ...filter(is_visible=true)
    `)
    .eq('slug', params.slug)
    .eq('status', 'published')
    .single(),
  supabase
    .from('tenant_subscriptions')
    .select('package_id')
    // ... resolve tenant from invitation's tenant_id
]);

// Resolve features in parallel with data load
const resolvedFeatures = await resolveAllFeaturesWithCache({
  tenantId:  invitation.tenant_id,
  packageId: sub.package_id,
});
```

### 13.3 Editor Performance

The editor uses optimistic updates to avoid perceived latency. The live preview re-renders synchronously on state change (no network round-trip for preview updates).

```typescript
// Auto-save debounce: 1500ms (tuned for comfortable typing cadence)
// Optimistic update: immediate (zero perceived latency in preview)
// Server flush: background (transparent to user)
// Conflict resolution: last-write-wins (acceptable for single-user edit sessions)
```

### 13.4 Image Loading

```typescript
// Public page image loading strategy:

// Hero image: priority (LCP candidate)
<Image src={heroImageUrl} priority fill quality={82} sizes="100vw" />

// Couple photos: eager but not priority
<Image src={couplePhotoUrl} loading="eager" width={400} height={400} quality={80} />

// Gallery: lazy + blur placeholder
<Image
  src={photo.thumbnail_url}
  loading="lazy"
  placeholder="blur"
  blurDataURL={generateBlurDataUrl(photo.thumbnail_url)}
  sizes="(max-width: 768px) 50vw, 33vw"
/>

// All images served through next/image:
// - Automatic WebP conversion
// - Responsive srcset
// - Built-in lazy loading
```

### 13.5 View Count Batching

The `view_count` on invitations is not incremented synchronously on every page load (would cause row-level lock contention under concurrent traffic).

```typescript
// Redis-buffered view counting via Upstash

// On each public page load (Edge Function):
// 1. Increment Redis counter: INCR inv:views:{invitation_id}
// 2. Every 60s: batch flush to DB

// lib/analytics/view-counter.ts
export async function recordPageView(invitationId: string): Promise<void> {
  await redis.incr(`inv:views:${invitationId}`);
}

// Supabase Edge Function (runs every 60s):
// SELECT keys matching inv:views:*
// For each: UPDATE invitations SET view_count = view_count + $count WHERE id = $id
// Then DEL the Redis keys
```

---

## 14. SEO Considerations

### 14.1 Metadata Strategy

```typescript
// app/inv/[slug]/page.tsx

export async function generateMetadata({
  params,
}: {
  params: { slug: string };
}): Promise<Metadata> {
  const supabase = createServerClient();

  const { data: inv } = await supabase
    .from('invitations')
    .select('meta_title, meta_description, og_image_url, couple_data, event_date, slug')
    .eq('slug', params.slug)
    .eq('status', 'published')
    .single();

  if (!inv) {
    return { title: 'Invitation Not Found' };
  }

  const { groom_name, bride_name } = inv.couple_data as CoupleData;
  const coupleNames = `${groom_name} & ${bride_name}`;
  const eventDate   = inv.event_date
    ? new Date(inv.event_date).toLocaleDateString('id-ID', {
        day: 'numeric', month: 'long', year: 'numeric',
      })
    : null;

  const title       = inv.meta_title ?? `${coupleNames} — Wedding Invitation`;
  const description = inv.meta_description ??
    `You're invited to the wedding of ${coupleNames}${eventDate ? ` on ${eventDate}` : ''}.`;
  const ogImage     = inv.og_image_url ?? `/api/og?slug=${inv.slug}`;

  return {
    title,
    description,
    openGraph: {
      type:        'website',
      title,
      description,
      images: [{ url: ogImage, width: 1200, height: 630, alt: coupleNames }],
    },
    twitter: {
      card:        'summary_large_image',
      title,
      description,
      images:      [ogImage],
    },
    // Invitations are private pages — not for indexing by default
    robots: { index: false, follow: false },
  };
}
```

### 14.2 OG Image Generation

```typescript
// app/api/og/route.tsx — Edge runtime, < 50ms

import { ImageResponse } from '@vercel/og';

export const runtime = 'edge';

// Cache-Control: max-age=3600 (CDN caches for 1 hour)
// Automatically invalidated by revalidatePath() on publish/settings change

export async function GET(request: NextRequest) {
  const slug = request.nextUrl.searchParams.get('slug');
  // ... fetch invitation data
  // ... render React tree to PNG via @vercel/og
  // ... return ImageResponse with cache headers
}
```

OG images are served from `/api/og?slug=[slug]` and are:
- Generated on-demand at edge (< 50ms)
- CDN-cached for 1 hour
- Uses the invitation's hero image as background (if set)
- Falls back to theme colors + couple names
- Regenerated on next request after ISR revalidation

### 14.3 Structured Data (JSON-LD)

```typescript
// components/invitation/renderer/InvitationJsonLd.tsx

export function InvitationJsonLd({ invitation }: Props) {
  const { groom_name, bride_name } = invitation.couple_data as CoupleData;

  const jsonLd = {
    '@context': 'https://schema.org',
    '@type':    'Event',
    name:       `${groom_name} & ${bride_name} Wedding`,
    startDate:  invitation.event_date,
    startTime:  invitation.event_time,
    location: invitation.event_venue ? {
      '@type': 'Place',
      name:    invitation.event_venue,
      address: invitation.event_address,
    } : undefined,
    description: `Wedding celebration of ${groom_name} and ${bride_name}.`,
    image:      invitation.og_image_url,
    eventAttendanceMode: 'https://schema.org/OfflineEventAttendanceMode',
    eventStatus: 'https://schema.org/EventScheduled',
  };

  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
    />
  );
}
```

### 14.4 Robots / Indexing Policy

Invitation pages are **not indexed** by default (`robots: { index: false }`). They are personal invitations sent to specific guests, not discoverable content. Exceptions:

- Premium+ tenants with custom domains can opt in to indexing (Phase 3+)
- The platform marketing site and pricing page are fully indexed
- The public invitation page serves OG tags for social sharing even when noindex is set

### 14.5 Sitemap Strategy

```typescript
// Sitemap scope:
// /sitemap.xml → Platform marketing pages (landing, pricing, blog, etc.)
// Invitation pages are EXCLUDED from sitemap (noindex + private content)

// app/sitemap.ts
export default function sitemap(): MetadataRoute.Sitemap {
  return [
    { url: 'https://weddingplatform.com', lastModified: new Date(), changeFrequency: 'weekly', priority: 1 },
    { url: 'https://weddingplatform.com/pricing', lastModified: new Date(), changeFrequency: 'weekly', priority: 0.9 },
    // ... marketing pages only
    // NOTE: /inv/* pages deliberately excluded
  ];
}
```

### 14.6 WhatsApp Share Optimization

WhatsApp renders OG cards for links in chat. Optimizations:

- OG image: 1200×630, JPEG, < 300KB for fast WhatsApp rendering
- `og:title`: kept under 65 characters (WhatsApp truncates longer titles)
- `og:description`: kept under 100 characters
- Invitation URL is short and readable: `inv.weddingplatform.com/andi-ninah-2026`
- Pre-filled WhatsApp share text generated by `getWhatsAppShareText()` (Section 6.4)

---

## 15. Scalability Considerations

### 15.1 Database Scalability

**Partitioning candidates:** At scale, `invitation_events` (raw analytics) and `audit_logs` should be partitioned by `created_at` using range partitioning. See PHASE2 Section 9.1 for the partitioning strategy.

**Index coverage:** All hot-path queries are covered by existing indexes (PHASE2 Section 5):
- Slug lookup: `idx_inv_slug`
- Tenant list: `idx_inv_tenant_status`
- Published feed: `idx_inv_published_at`
- Scheduled publish cron: `idx_inv_scheduled`

**Connection pooling:** All Next.js API routes use PgBouncer in transaction mode. Direct connections reserved for migrations and Edge Functions using LISTEN/NOTIFY.

### 15.2 ISR Scalability

ISR pages are cached at the Vercel Edge CDN. Each unique slug generates one cache entry. With thousands of invitations:

- Cache storage is cheap (HTML snapshots, ~50–200KB each)
- Cache hit rate is high (invitation pages are read far more than written)
- Revalidation is on-demand (triggered by publish/settings actions), not time-expiry polling

At very high scale (100K+ active invitations), the 60-second window can be increased to 300 seconds to reduce origin load, since RSVP submissions and guestbook entries don't require ISR revalidation (they're handled by client-side Supabase Realtime subscriptions).

### 15.3 Slug Uniqueness at Scale

The globally unique slug constraint performs well up to tens of millions of rows due to the `idx_inv_slug` B-tree index. Slug collision probability is low because couples naturally choose personalized slugs (`groom-bride-year`).

For extreme scale, the slug namespace can be extended with a prefix (e.g., regional codes), but this is not needed in Phase 1–3.

### 15.4 Storage Scalability

Gallery photos and music files are stored in Supabase Storage (S3-compatible). Storage is horizontally unlimited. Cost is managed through:
- Per-tenant quota enforcement (`max_photos`, `max_storage_mb`)
- Image compression at upload (Sharp processing in Edge Function)
- Archival policy: files from soft-deleted invitations are cleaned up after 90 days by a nightly Edge Function

### 15.5 Feature System Integration at Scale

The feature resolution engine (PHASE5) resolves all features in one DB round-trip and caches in Redis for 60 seconds. At 10K active editors simultaneously, this is:
- 10K Redis reads/minute (trivially handled by Upstash)
- ~167 DB queries/minute for cache misses (well within Supabase connection limits)

### 15.6 Future Feature Expansion

The invitation data model is designed to absorb new features without schema migration:

| Future Feature | Storage approach |
|---|---|
| Multi-event per invitation | `invitation_sections` already supports multiple `event_details` type rows (remove the UNIQUE constraint) |
| Livestream recording link | Add to `invitation_sections.content` for `livestream` type |
| Invitation A/B testing | `theme_experiments` table (PHASE6 Section 20.2) |
| Physical printing metadata | `invitation_print_orders` table (Phase 5+) |
| Accommodation info | New `accommodation` section_type in the section_type CHECK constraint |
| Dress code section | New `dress_code` section_type |
| FAQ section | New `faq` section_type |

Adding a new section type requires:
1. Adding to `invitation_sections.section_type` CHECK constraint (migration)
2. Adding to `SECTION_TYPES` array in `config/section-types.ts`
3. Implementing the section component in each theme
4. Adding to the property panel

No changes to the `invitations` core table are needed.

### 15.7 Tenant Isolation at Scale

RLS scales linearly with the number of rows — each query adds only a constant-time predicate check against the JWT claim. No multi-tenant performance degradation occurs at tens of thousands of tenants because:
- Each query already has a `tenant_id` index scan (not a full-table scan)
- The JWT claim is already decoded in memory by PostgreSQL (no additional round-trip)
- Partial indexes on `(tenant_id, status)` keep common queries sub-millisecond

---

## Appendix A — Migration Order (Phase 7 Additions)

```
Previously from PHASE1–6:
  001–056: Core tables, packages, features, themes, RLS, seeds

New migrations (PHASE7 additions):
  057_invitations_v2.sql           -- Add scheduled_publish_at, custom_domain_id FK
  058_change_invitation_theme.sql  -- change_invitation_theme() stored procedure
  059_jsonb_merge_patch.sql        -- jsonb_merge_patch() helper (if not from PHASE6)
  060_invitation_slug_redirects.sql-- slug_redirects table (Phase 3+ for slug renames)
  061_scheduled_publish_index.sql  -- idx_inv_scheduled partial index
  062_rls_invitation_sections.sql  -- RLS policies for invitation_sections
  063_rls_gallery_music_gifts.sql  -- RLS policies for gallery/music/gifts
  064_view_count_trigger.sql       -- view_count increment trigger (Redis fallback)
  065_seed_reserved_slugs.sql      -- reserved slug list for validation reference
```

## Appendix B — API Route Summary

```
POST   /api/invitations                           Create invitation
GET    /api/invitations                           List invitations (tenant-scoped)
GET    /api/invitations/[id]                      Get single invitation
PATCH  /api/invitations/[id]                      Update core fields
DELETE /api/invitations/[id]                      Soft delete

POST   /api/invitations/[id]/publish              Publish
POST   /api/invitations/[id]/unpublish            Unpublish → draft
POST   /api/invitations/[id]/archive              Archive
POST   /api/invitations/[id]/restore              Restore archived → draft
POST   /api/invitations/[id]/duplicate            Clone invitation
POST   /api/invitations/[id]/theme                Change theme
PATCH  /api/invitations/[id]/slug                 Update slug
PATCH  /api/invitations/[id]/settings             Update settings
POST   /api/invitations/[id]/password             Set/clear password
PATCH  /api/invitations/[id]/customization        Update theme customization patch

GET    /api/invitations/[id]/sections             List sections
PATCH  /api/invitations/[id]/sections/[type]      Update section content + visibility

GET    /api/invitations/[id]/gallery              List gallery photos
POST   /api/invitations/[id]/gallery              Add photo
PATCH  /api/invitations/[id]/gallery/[photoId]    Update photo (caption, visibility)
DELETE /api/invitations/[id]/gallery/[photoId]    Remove photo
POST   /api/invitations/[id]/gallery/reorder      Batch sort_order update

GET    /api/invitations/[id]/music                List tracks
POST   /api/invitations/[id]/music                Add track
PATCH  /api/invitations/[id]/music/[trackId]      Update track
DELETE /api/invitations/[id]/music/[trackId]      Remove track

GET    /api/invitations/[id]/gifts                List gift accounts
POST   /api/invitations/[id]/gifts                Add gift account
PATCH  /api/invitations/[id]/gifts/[giftId]       Update gift account
DELETE /api/invitations/[id]/gifts/[giftId]       Remove gift account
POST   /api/invitations/[id]/gifts/reorder        Batch sort_order update

GET    /api/invitations/[id]/slug/check?slug=...  Check slug availability

POST   /api/revalidate                            Internal ISR purge endpoint
GET    /api/og                                    OG image generation (Edge)
```

## Appendix C — Invitation Status Transition Reference

```
VALID TRANSITIONS:
  draft → published     (publish action, owner only)
  draft → archived      (archive action, owner only)
  draft → deleted       (soft delete, owner only)
  published → draft     (unpublish action, owner only)
  published → archived  (archive action, owner only)
  published → deleted   (soft delete, owner only)
  archived → draft      (restore action, owner only)

INVALID TRANSITIONS:
  archived → published  (must restore to draft first, then publish)
  deleted → *           (no recovery via UI; admin-only DB operation within 90 days)

SYSTEM TRANSITIONS (scheduled publish cron):
  draft → published     (when scheduled_publish_at <= NOW() and validation passes)
  draft → draft         (scheduled_publish_at cleared if validation fails; notification sent)
```

## Appendix D — Invitation Content Field Reference

| Field | Storage | Type | Feature Gate | Notes |
|---|---|---|---|---|
| Groom name | `invitations.couple_data` | string | — | Required for publish |
| Bride name | `invitations.couple_data` | string | — | Required for publish |
| Groom photo | `invitations.couple_data` | URL | — | Warning if missing |
| Bride photo | `invitations.couple_data` | URL | — | Warning if missing |
| Groom parents | `invitations.couple_data` | string | — | Optional |
| Bride parents | `invitations.couple_data` | URL | — | Optional |
| Groom Instagram | `invitations.couple_data` | string | — | Optional |
| Bride Instagram | `invitations.couple_data` | string | — | Optional |
| Event date | `invitations.event_date` | DATE | — | Required for publish |
| Event time | `invitations.event_time` | TIME | — | Optional |
| Venue name | `invitations.event_venue` | string | — | Warning if missing |
| Venue address | `invitations.event_address` | string | — | Optional |
| Maps URL | `invitations.event_maps_url` | URL | — | Optional |
| Maps embed | `invitations.event_maps_embed` | HTML | `map_embed` | Premium+ |
| Love story title | `invitation_sections.content` | string | `love_story` | — |
| Love story text | `invitation_sections.content` | text | `love_story` | — |
| Milestones | `invitation_sections.content` | array | `love_story` | — |
| Gallery photos | `invitation_gallery` table | URLs | `gallery` | Quota: `max_photos` |
| Music track | `invitation_music` table | URL/link | `music_player` | Quota: `max_music_tracks` |
| Gift accounts | `invitation_gifts` table | structured | `gift_registry` | Multiple entries |
| QRIS code | `invitation_gifts` table | image URL | `gift_registry` + `qris_payment` | — |
| Livestream URL | `invitation_sections.content` | URL | `livestream_embed` | — |
| Closing text | `invitation_sections.content` | text | — | — |
| Wedding hashtag | `invitation_sections.content` | string | — | Optional |
| Theme colors | `invitations.customization` | hex strings | `custom_color` | — |
| Theme fonts | `invitations.customization` | font names | `custom_font` | — |
| Hero background | `invitations.customization` | image URL | — | — |
| Password | `invitations.password_hash` | bcrypt | `password_protection` | Basic+ |
| Meta title | `invitations.meta_title` | string | — | Max 70 chars |
| Meta description | `invitations.meta_description` | string | — | Max 160 chars |
| OG image | `invitations.og_image_url` | URL | — | Auto-generated if absent |

---

*End of PHASE7_INVITATION_MANAGEMENT.md*
