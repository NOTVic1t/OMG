# PHASE6_THEME_SYSTEM.md
# Wedding Invitation SaaS Platform — Theme System Architecture

> **Version:** 1.0.0
> **Date:** 2026-06-13
> **Status:** Approved for Development
> **Depends on:** PHASE1_ARCHITECTURE.md, PHASE2_DATABASE.md, PHASE3_AUTH.md, PHASE4_ADMIN_ARCHITECTURE.md, PHASE5_PACKAGE_FEATURE_SYSTEM.md

---

## Table of Contents

1. [Theme Architecture Overview](#1-theme-architecture-overview)
2. [Theme Categories](#2-theme-categories)
3. [Theme Component System](#3-theme-component-system)
4. [Theme Configuration System](#4-theme-configuration-system)
5. [Theme Builder Strategy](#5-theme-builder-strategy)
6. [Theme Customization Rules](#6-theme-customization-rules)
7. [Font System](#7-font-system)
8. [Color System](#8-color-system)
9. [Layout System](#9-layout-system)
10. [Theme Asset Management](#10-theme-asset-management)
11. [Theme Package Restrictions](#11-theme-package-restrictions)
12. [Premium Theme Handling](#12-premium-theme-handling)
13. [Theme Versioning](#13-theme-versioning)
14. [Theme Marketplace Preparation](#14-theme-marketplace-preparation)
15. [White Label Support](#15-white-label-support)
16. [Theme Rendering Engine](#16-theme-rendering-engine)
17. [Mobile Optimization](#17-mobile-optimization)
18. [Performance Optimization](#18-performance-optimization)
19. [SEO Considerations](#19-seo-considerations)
20. [Future Scalability](#20-future-scalability)

---

## 1. Theme Architecture Overview

### 1.1 Design Philosophy

The theme system is built on three foundational constraints that drive every architectural decision:

**Property-based editor only.** No drag-and-drop canvas. Sections are fixed in their structural role; only their visual properties are user-configurable. This keeps the rendering engine deterministic, the mobile experience clean, and the codebase maintainable.

**Data-driven theming.** A theme is a JSON schema definition plus a React component tree. The schema describes what is customizable; the component tree renders it. Swapping a theme means pointing the renderer at a different component tree with the same data shape — no re-entry of invitation content.

**Multi-tenant isolation.** Every theme customization is stored in `invitations.customization` JSONB, scoped to the tenant's invitation. Theme definitions themselves are global, platform-managed resources. Tenants never modify theme source code.

### 1.2 System Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        THEME SYSTEM LAYERS                           │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  1. THEME DEFINITION LAYER (admin-managed)                   │   │
│  │     invitation_themes table + config_schema JSONB            │   │
│  │     Defines what fields exist and their constraints          │   │
│  └──────────────────────────────┬──────────────────────────────┘   │
│                                 │                                   │
│  ┌──────────────────────────────▼──────────────────────────────┐   │
│  │  2. CUSTOMIZATION LAYER (tenant-managed)                     │   │
│  │     invitations.customization JSONB                          │   │
│  │     User's property-panel overrides keyed by schema fields   │   │
│  └──────────────────────────────┬──────────────────────────────┘   │
│                                 │                                   │
│  ┌──────────────────────────────▼──────────────────────────────┐   │
│  │  3. RENDERING LAYER (platform-managed)                       │   │
│  │     React component trees per theme                          │   │
│  │     Reads merged config = theme defaults + user overrides    │   │
│  └──────────────────────────────┬──────────────────────────────┘   │
│                                 │                                   │
│  ┌──────────────────────────────▼──────────────────────────────┐   │
│  │  4. OUTPUT LAYER                                             │   │
│  │     Public invitation page (ISR, 60s revalidation)          │   │
│  │     Editor live preview (real-time, server component)        │   │
│  │     OG image (Vercel OG, on-demand)                         │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.3 Theme Anatomy

Each theme consists of exactly four artifacts:

| Artifact | Location | Purpose |
|---|---|---|
| Theme definition row | `invitation_themes` table | Metadata, schema, access control |
| Config schema | `invitation_themes.config_schema` JSONB | Declares all customizable fields |
| Component tree | `components/invitation/themes/[slug]/` | React rendering implementation |
| Static assets | `supabase/storage/themes/[slug]/` | Preview images, thumbnails |

### 1.4 Trade-Off Log

| Decision | Options | Choice | Reason |
|---|---|---|---|
| Editor model | Drag-and-drop canvas vs property panel | Property panel | Performance, mobile compatibility, deterministic layout |
| Theme delivery | CSS-in-JS vs Tailwind variants vs CSS variables | CSS variables + Tailwind | Runtime themability without style recalculation overhead |
| Theme storage | Code-only vs DB-backed | DB-backed metadata + code components | Runtime toggle of is_active, premium flag; components still deployed as code |
| Section ordering | User-configurable vs fixed | Fixed order per theme, visibility toggle only | Prevents layout corruption; themes are opinionated designs |
| Font loading | Self-hosted vs Google Fonts | Both (self-hosted for performance, Google Fonts as fallback) | Self-hosted fonts pass Core Web Vitals; Google Fonts for the long tail |
| Preview rendering | iframe vs React component | React component with scale transform | iframe has CSP issues and cross-origin latency; React component is faster and type-safe |

---

## 2. Theme Categories

### 2.1 Category Definitions

Themes are grouped into categories that determine their intended use case, default section configuration, and content schema defaults.

```typescript
// config/theme-categories.ts

export const THEME_CATEGORIES = {
  WEDDING:    'wedding',      // Full wedding ceremony + reception
  ENGAGEMENT: 'engagement',  // Engagement party / pre-wedding
  GENERAL:    'general',     // Multipurpose event (akad only, reception only)
} as const;

export type ThemeCategory = typeof THEME_CATEGORIES[keyof typeof THEME_CATEGORIES];
```

### 2.2 Category Defaults

Each category ships with a recommended default section set and section visibility:

#### `wedding` (Full Wedding)
```typescript
const WEDDING_DEFAULT_SECTIONS: SectionDefault[] = [
  { type: 'hero',           sort_order: 0,  is_visible: true },
  { type: 'couple',         sort_order: 1,  is_visible: true },
  { type: 'event_details',  sort_order: 2,  is_visible: true },
  { type: 'love_story',     sort_order: 3,  is_visible: false }, // feature-gated
  { type: 'gallery',        sort_order: 4,  is_visible: true },
  { type: 'countdown',      sort_order: 5,  is_visible: true },
  { type: 'music',          sort_order: 6,  is_visible: false }, // feature-gated
  { type: 'rsvp',           sort_order: 7,  is_visible: true },
  { type: 'guestbook',      sort_order: 8,  is_visible: true },
  { type: 'gift',           sort_order: 9,  is_visible: false }, // feature-gated
  { type: 'closing',        sort_order: 10, is_visible: true },
];
```

#### `engagement`
```typescript
const ENGAGEMENT_DEFAULT_SECTIONS: SectionDefault[] = [
  { type: 'hero',           sort_order: 0,  is_visible: true },
  { type: 'couple',         sort_order: 1,  is_visible: true },
  { type: 'event_details',  sort_order: 2,  is_visible: true },
  { type: 'countdown',      sort_order: 3,  is_visible: true },
  { type: 'rsvp',           sort_order: 4,  is_visible: true },
  { type: 'guestbook',      sort_order: 5,  is_visible: true },
  { type: 'closing',        sort_order: 6,  is_visible: true },
];
```

#### `general`
```typescript
const GENERAL_DEFAULT_SECTIONS: SectionDefault[] = [
  { type: 'hero',           sort_order: 0,  is_visible: true },
  { type: 'event_details',  sort_order: 1,  is_visible: true },
  { type: 'countdown',      sort_order: 2,  is_visible: true },
  { type: 'rsvp',           sort_order: 3,  is_visible: true },
  { type: 'closing',        sort_order: 4,  is_visible: true },
];
```

### 2.3 Section Type Registry

All section types that any theme may use. A theme's `config_schema` declares which of these it implements and what is customizable per section.

```typescript
// config/section-types.ts

export const SECTION_TYPES = [
  'hero',
  'couple',
  'event_details',
  'love_story',
  'gallery',
  'countdown',
  'music',
  'rsvp',
  'guestbook',
  'gift',
  'livestream',
  'closing',
] as const;

export type SectionType = typeof SECTION_TYPES[number];

// Feature gate map: which feature key gates which section type
export const SECTION_FEATURE_GATES: Partial<Record<SectionType, string>> = {
  love_story: 'love_story',
  gallery:    'gallery',
  music:      'music_player',
  gift:       'gift_registry',
  guestbook:  'guestbook',
  livestream: 'livestream_embed',
};
```

### 2.4 Phase 1 Theme Catalog

Four themes ship with Phase 1. Each covers the `wedding` category.

| Slug | Name | Style | Is Premium | Sections |
|---|---|---|---|---|
| `classic` | Classic Elegance | Serif, ivory, gold | No | All 11 |
| `floral` | Garden Floral | Script, blush, sage | No | All 11 |
| `modern` | Modern Minimal | Sans-serif, black, white | No | All 11 |
| `rustic` | Rustic Romance | Slab, warm brown, cream | Yes | All 11 |

Phase 2 expands with 4 more themes (2 free, 2 premium). Phase 3+ targets a marketplace of 20+ themes.

---

## 3. Theme Component System

### 3.1 Folder Structure

```
components/invitation/
├── themes/
│   ├── classic/
│   │   ├── index.ts                  # Theme entry point + export
│   │   ├── ThemeClassic.tsx          # Root theme shell (fonts, CSS vars, layout)
│   │   ├── sections/
│   │   │   ├── HeroSection.tsx
│   │   │   ├── CoupleSection.tsx
│   │   │   ├── EventDetailsSection.tsx
│   │   │   ├── LoveStorySection.tsx
│   │   │   ├── GallerySection.tsx
│   │   │   ├── CountdownSection.tsx
│   │   │   ├── MusicSection.tsx
│   │   │   ├── RsvpSection.tsx
│   │   │   ├── GuestbookSection.tsx
│   │   │   ├── GiftSection.tsx
│   │   │   ├── LivestreamSection.tsx
│   │   │   └── ClosingSection.tsx
│   │   └── components/
│   │       ├── Ornament.tsx          # Theme-specific decorative elements
│   │       ├── Divider.tsx
│   │       └── FloralBorder.tsx
│   │
│   ├── floral/
│   │   └── [same structure]
│   ├── modern/
│   │   └── [same structure]
│   ├── rustic/
│   │   └── [same structure]
│   │
│   └── index.ts                      # Theme registry
│
├── renderer/
│   ├── InvitationRenderer.tsx        # Selects theme by slug, passes config
│   ├── SectionRenderer.tsx           # Renders individual sections with feature gates
│   └── ThemeConfigContext.tsx        # Context: merged theme config for a section
│
├── editor/
│   ├── EditorLayout.tsx              # Desktop 3-col / mobile tab layout
│   ├── SectionNavPanel.tsx           # Section list + visibility toggles
│   ├── PropertyPanel.tsx             # Property form switcher
│   ├── LivePreview.tsx               # Scaled theme preview
│   └── panels/
│       ├── HeroPanel.tsx
│       ├── CouplePanel.tsx
│       ├── EventDetailsPanel.tsx
│       ├── LoveStoryPanel.tsx
│       ├── GalleryPanel.tsx
│       ├── CountdownPanel.tsx
│       ├── MusicPanel.tsx
│       ├── RsvpPanel.tsx
│       ├── GuestbookPanel.tsx
│       ├── GiftPanel.tsx
│       └── ClosingPanel.tsx
│
└── shared/
    ├── UpgradePrompt.tsx             # Feature-locked section placeholder
    ├── RsvpForm.tsx                  # Shared RSVP form (works across all themes)
    ├── GuestbookWall.tsx             # Shared guestbook (works across all themes)
    └── MusicPlayer.tsx               # Shared audio player (works across all themes)
```

### 3.2 Theme Registry

The registry maps theme slugs to component trees. It is the only place the application couples DB records to code.

```typescript
// components/invitation/themes/index.ts

import { ClassicTheme } from './classic';
import { FloralTheme } from './floral';
import { ModernTheme } from './modern';
import { RusticTheme } from './rustic';
import type { ThemeModule } from '@/types/theme';

export const THEME_REGISTRY: Record<string, ThemeModule> = {
  classic: ClassicTheme,
  floral:  FloralTheme,
  modern:  ModernTheme,
  rustic:  RusticTheme,
};

export function getThemeModule(slug: string): ThemeModule | null {
  return THEME_REGISTRY[slug] ?? null;
}
```

### 3.3 ThemeModule Interface

Every theme must satisfy this interface. This is the contract between the DB and the rendering layer.

```typescript
// types/theme.ts

export interface ThemeModule {
  slug: string;
  Shell: React.ComponentType<ThemeShellProps>;
  sections: Record<SectionType, React.ComponentType<SectionProps>>;
  defaultConfig: ThemeConfig;
}

export interface ThemeShellProps {
  config: ThemeConfig;
  children: React.ReactNode;
  // CSS variables injected here; children are section components
}

export interface SectionProps {
  config: ThemeConfig;
  sectionContent: SectionContent;
  invitationData: InvitationData;
  isPreview?: boolean;
  // isPreview=true disables interactive elements (music autoplay, RSVP form)
}

export interface ThemeConfig {
  colors: ThemeColors;
  fonts: ThemeFonts;
  layout: ThemeLayout;
  sections: Record<SectionType, SectionConfig>;
}

export interface SectionContent {
  type: SectionType;
  is_visible: boolean;
  sort_order: number;
  content: Record<string, unknown>; // section-specific JSONB
}
```

### 3.4 Theme Shell Pattern

The Theme Shell is the outermost wrapper. It injects CSS variables derived from the merged config, loads fonts, and renders the section list in order.

```typescript
// components/invitation/themes/classic/ThemeClassic.tsx

import { useMemo } from 'react';
import type { ThemeShellProps } from '@/types/theme';
import { buildCssVars } from '@/lib/theme/css-vars';
import { FontLoader } from '@/components/invitation/shared/FontLoader';

export function ThemeClassicShell({ config, children }: ThemeShellProps) {
  const cssVars = useMemo(() => buildCssVars(config), [config]);

  return (
    <>
      <FontLoader fonts={[config.fonts.heading, config.fonts.body]} />
      <div
        className="min-h-screen w-full"
        style={cssVars as React.CSSProperties}
      >
        {children}
      </div>
    </>
  );
}
```

```typescript
// lib/theme/css-vars.ts

export function buildCssVars(config: ThemeConfig): Record<string, string> {
  return {
    '--color-primary':       config.colors.primary,
    '--color-secondary':     config.colors.secondary,
    '--color-background':    config.colors.background,
    '--color-surface':       config.colors.surface,
    '--color-text-primary':  config.colors.textPrimary,
    '--color-text-secondary':config.colors.textSecondary,
    '--color-accent':        config.colors.accent,
    '--font-heading':        `"${config.fonts.heading}", ${config.fonts.headingFallback}`,
    '--font-body':           `"${config.fonts.body}", ${config.fonts.bodyFallback}`,
    '--font-script':         config.fonts.script
                               ? `"${config.fonts.script}", cursive`
                               : 'cursive',
    '--spacing-section':     config.layout.sectionSpacing,
    '--border-radius-card':  config.layout.cardBorderRadius,
  };
}
```

### 3.5 Section Component Pattern

Every section component follows the same pattern: read merged config via context, render content, handle feature gates internally.

```typescript
// components/invitation/themes/classic/sections/HeroSection.tsx

import { useThemeConfig } from '@/components/invitation/renderer/ThemeConfigContext';
import type { SectionProps } from '@/types/theme';

export function HeroSection({ sectionContent, invitationData, isPreview }: SectionProps) {
  const config = useThemeConfig();
  const { groom_name, bride_name } = invitationData.couple_data;
  const sectionCfg = config.sections.hero;

  return (
    <section
      className="relative flex min-h-screen flex-col items-center justify-center overflow-hidden px-6 py-20"
      style={{ backgroundColor: 'var(--color-background)' }}
    >
      {/* Background image */}
      {sectionCfg.background_image_url && (
        <div
          className="absolute inset-0 bg-cover bg-center"
          style={{
            backgroundImage: `url(${sectionCfg.background_image_url})`,
            opacity: sectionCfg.overlay_opacity ?? 0.3,
          }}
        />
      )}

      {/* Content */}
      <div className="relative z-10 text-center">
        <p
          className="mb-4 text-sm uppercase tracking-[0.3em]"
          style={{
            fontFamily: 'var(--font-body)',
            color: 'var(--color-text-secondary)',
          }}
        >
          {sectionCfg.opening_text ?? 'We joyfully invite you to celebrate'}
        </p>

        <h1
          className="mb-2 text-5xl md:text-7xl leading-tight"
          style={{
            fontFamily: 'var(--font-heading)',
            color: 'var(--color-primary)',
          }}
        >
          {groom_name}
        </h1>

        <p
          className="my-4 text-2xl"
          style={{ fontFamily: 'var(--font-script)', color: 'var(--color-accent)' }}
        >
          {sectionCfg.conjunction_text ?? '&'}
        </p>

        <h1
          className="mb-8 text-5xl md:text-7xl leading-tight"
          style={{
            fontFamily: 'var(--font-heading)',
            color: 'var(--color-primary)',
          }}
        >
          {bride_name}
        </h1>

        {invitationData.event_date && (
          <p
            className="text-base tracking-widest"
            style={{ color: 'var(--color-text-secondary)', fontFamily: 'var(--font-body)' }}
          >
            {formatEventDate(invitationData.event_date)}
          </p>
        )}
      </div>
    </section>
  );
}
```

---

## 4. Theme Configuration System

### 4.1 Config Schema Architecture

The `config_schema` column on `invitation_themes` is a JSON Schema document that defines every field the property panel exposes for that theme. It is the source of truth for what users can customize.

```typescript
// types/theme-schema.ts

export type FieldType =
  | 'color'
  | 'font_select'
  | 'text'
  | 'textarea'
  | 'select'
  | 'toggle'
  | 'number'
  | 'image_upload'
  | 'range'        // 0–1 opacity, 0–100 percentage
  | 'spacing';     // xs | sm | md | lg | xl

export interface SchemaField {
  type: FieldType;
  label: string;
  default: unknown;
  options?: string[];          // for 'select' type
  min?: number;                // for 'number' and 'range'
  max?: number;
  step?: number;
  hint?: string;               // helper text shown in property panel
  feature_gate?: string;       // feature key required to use this field
  package_gate?: string[];     // package slugs that unlock this field
}

export interface ThemeConfigSchema {
  version: number;
  colors: Record<string, SchemaField>;
  fonts: Record<string, SchemaField>;
  layout: Record<string, SchemaField>;
  sections: Record<SectionType, Record<string, SchemaField>>;
}
```

### 4.2 Classic Theme Config Schema Example

```json
{
  "version": 1,
  "colors": {
    "primary": {
      "type": "color",
      "label": "Primary Color",
      "default": "#2C1810",
      "hint": "Used for headings and key text"
    },
    "secondary": {
      "type": "color",
      "label": "Secondary Color",
      "default": "#8B6914"
    },
    "background": {
      "type": "color",
      "label": "Page Background",
      "default": "#FDF8F0"
    },
    "surface": {
      "type": "color",
      "label": "Card Background",
      "default": "#FFFFFF"
    },
    "textPrimary": {
      "type": "color",
      "label": "Body Text",
      "default": "#3D2B1F"
    },
    "textSecondary": {
      "type": "color",
      "label": "Secondary Text",
      "default": "#7C6B5E"
    },
    "accent": {
      "type": "color",
      "label": "Accent / Script Color",
      "default": "#C4974A",
      "feature_gate": "custom_color"
    }
  },
  "fonts": {
    "heading": {
      "type": "font_select",
      "label": "Heading Font",
      "default": "Cormorant Garamond",
      "options": ["Cormorant Garamond", "Playfair Display", "EB Garamond", "Libre Baskerville"],
      "feature_gate": "custom_font"
    },
    "body": {
      "type": "font_select",
      "label": "Body Font",
      "default": "Lato",
      "options": ["Lato", "Raleway", "Nunito", "Open Sans"],
      "feature_gate": "custom_font"
    },
    "script": {
      "type": "font_select",
      "label": "Script / Accent Font",
      "default": "Great Vibes",
      "options": ["Great Vibes", "Dancing Script", "Pacifico", "Sacramento"],
      "feature_gate": "custom_font"
    }
  },
  "layout": {
    "sectionSpacing": {
      "type": "spacing",
      "label": "Section Spacing",
      "default": "lg",
      "options": ["sm", "md", "lg", "xl"]
    },
    "cardBorderRadius": {
      "type": "select",
      "label": "Card Corner Style",
      "default": "0.5rem",
      "options": ["0rem", "0.25rem", "0.5rem", "1rem", "1.5rem"]
    }
  },
  "sections": {
    "hero": {
      "background_image_url": {
        "type": "image_upload",
        "label": "Background Photo",
        "default": null,
        "hint": "Recommended: 1920×1080px or larger"
      },
      "overlay_opacity": {
        "type": "range",
        "label": "Photo Overlay Darkness",
        "default": 0.3,
        "min": 0,
        "max": 0.85,
        "step": 0.05
      },
      "opening_text": {
        "type": "text",
        "label": "Opening Line",
        "default": "We joyfully invite you to celebrate"
      },
      "conjunction_text": {
        "type": "text",
        "label": "Conjunction",
        "default": "&"
      }
    },
    "couple": {
      "layout_style": {
        "type": "select",
        "label": "Photo Layout",
        "default": "side-by-side",
        "options": ["side-by-side", "stacked", "overlapping", "circle"]
      },
      "show_parents": {
        "type": "toggle",
        "label": "Show Parents' Names",
        "default": true
      }
    },
    "event_details": {
      "show_maps_button": {
        "type": "toggle",
        "label": "Show Maps Button",
        "default": true
      },
      "maps_button_label": {
        "type": "text",
        "label": "Maps Button Text",
        "default": "Open in Google Maps"
      },
      "show_add_to_calendar": {
        "type": "toggle",
        "label": "Add to Calendar Button",
        "default": true
      }
    },
    "gallery": {
      "grid_style": {
        "type": "select",
        "label": "Gallery Layout",
        "default": "masonry",
        "options": ["masonry", "grid-2", "grid-3", "carousel"]
      }
    },
    "countdown": {
      "style": {
        "type": "select",
        "label": "Countdown Style",
        "default": "rings",
        "options": ["rings", "flip", "minimal", "elegant"]
      },
      "label": {
        "type": "text",
        "label": "Countdown Label",
        "default": "Days Until We Say I Do"
      }
    },
    "rsvp": {
      "form_title": {
        "type": "text",
        "label": "RSVP Section Title",
        "default": "Kindly Reply"
      },
      "attending_label": {
        "type": "text",
        "label": "'Attending' Option Label",
        "default": "Joyfully Accept"
      },
      "not_attending_label": {
        "type": "text",
        "label": "'Decline' Option Label",
        "default": "Regretfully Decline"
      }
    },
    "closing": {
      "closing_text": {
        "type": "textarea",
        "label": "Closing Message",
        "default": "We look forward to celebrating this special day with you."
      },
      "show_hashtag": {
        "type": "toggle",
        "label": "Show Wedding Hashtag",
        "default": false
      },
      "hashtag": {
        "type": "text",
        "label": "Wedding Hashtag",
        "default": "#OurWeddingDay"
      }
    }
  }
}
```

### 4.3 Config Merge Strategy

At render time, the config is resolved by merging theme defaults with user overrides. This happens in the server component before rendering.

```typescript
// lib/theme/config-merger.ts

import type { ThemeConfig, ThemeConfigSchema } from '@/types/theme';

export function mergeThemeConfig(
  schema: ThemeConfigSchema,
  themeDefaults: ThemeConfig,
  userCustomization: Record<string, unknown>
): ThemeConfig {
  // Deep merge: userCustomization values override themeDefaults at every leaf
  // Nested keys use dot notation in userCustomization: "sections.hero.overlay_opacity"

  const result = structuredClone(themeDefaults);

  for (const [path, value] of Object.entries(userCustomization)) {
    setNestedValue(result, path.split('.'), value);
  }

  return result;
}

function setNestedValue(
  obj: Record<string, unknown>,
  keys: string[],
  value: unknown
): void {
  const [head, ...tail] = keys;
  if (tail.length === 0) {
    obj[head] = value;
  } else {
    if (typeof obj[head] !== 'object' || obj[head] === null) {
      obj[head] = {};
    }
    setNestedValue(obj[head] as Record<string, unknown>, tail, value);
  }
}
```

### 4.4 Customization Storage Format

User customizations are stored flat in `invitations.customization` JSONB using dot-notation keys. This avoids deeply nested JSON mutation and makes partial updates cheap.

```json
// Example invitations.customization for a Classic theme invitation
{
  "colors.primary": "#1A0A5E",
  "colors.accent": "#D4AF37",
  "colors.background": "#FAFAF5",
  "fonts.heading": "Playfair Display",
  "fonts.script": "Dancing Script",
  "sections.hero.overlay_opacity": 0.45,
  "sections.hero.opening_text": "Together with their families",
  "sections.couple.show_parents": false,
  "sections.countdown.style": "flip",
  "sections.rsvp.form_title": "Will You Join Us?",
  "sections.closing.show_hashtag": true,
  "sections.closing.hashtag": "#AndiNinahWedding2026"
}
```

**Advantages of flat dot-notation storage:**
- PATCH operations update only changed keys: `UPDATE invitations SET customization = customization || $1`
- No full JSONB replacement needed for single property changes
- Easier to diff for audit logging
- `jsonb_set` can be used for atomic partial updates

---

## 5. Theme Builder Strategy

### 5.1 Property Panel Architecture

The property panel is the only interface users have for theme customization. It is entirely driven by the active theme's `config_schema`. This means adding a new customizable field to a theme requires only a schema update — no new panel component needed for standard field types.

```
┌─────────────────────────────────────────────────────────────────┐
│  EDITOR LAYOUT (desktop: 3-col split; mobile: tabbed)           │
│                                                                 │
│  ┌────────────┐  ┌────────────────────────┐  ┌──────────────┐  │
│  │ SECTION    │  │ PROPERTY PANEL          │  │ LIVE PREVIEW │  │
│  │ NAV        │  │                        │  │              │  │
│  │            │  │ Section: Hero          │  │ [scaled      │  │
│  │ ● Hero     │  │ ─────────────────────  │  │  theme       │  │
│  │ ○ Couple   │  │ Background Photo       │  │  render]     │  │
│  │ ○ Event    │  │ [upload or URL]        │  │              │  │
│  │ ○ Gallery  │  │                        │  │              │  │
│  │ ○ Countdown│  │ Photo Overlay Darkness │  │              │  │
│  │ ○ Music 🔒 │  │ [━━━━●───────] 45%     │  │              │  │
│  │ ○ RSVP     │  │                        │  │              │  │
│  │ ○ Guestbook│  │ Opening Line           │  │              │  │
│  │ ○ Gift 🔒  │  │ [Together with their…] │  │              │  │
│  │ ○ Closing  │  │                        │  │              │  │
│  │            │  │ ── Global Settings ─── │  │              │  │
│  │ ─────────  │  │ Primary Color [●]      │  │              │  │
│  │ + Colors   │  │ Heading Font [select]  │  │              │  │
│  │ + Fonts    │  │                        │  │              │  │
│  │ + Layout   │  │ [Save Changes]         │  │              │  │
│  └────────────┘  └────────────────────────┘  └──────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 Property Panel Component

```typescript
// components/invitation/editor/PropertyPanel.tsx

'use client';

import { useCallback, useTransition } from 'react';
import type { ThemeConfigSchema, SchemaField, SectionType } from '@/types/theme';
import { useFeature } from '@/hooks/use-feature';
import { ColorField } from './fields/ColorField';
import { FontSelectField } from './fields/FontSelectField';
import { TextInputField } from './fields/TextInputField';
import { ToggleField } from './fields/ToggleField';
import { RangeField } from './fields/RangeField';
import { SelectField } from './fields/SelectField';
import { ImageUploadField } from './fields/ImageUploadField';
import { LockedField } from './fields/LockedField';
import { updateCustomizationAction } from '@/app/(app)/invitations/[id]/edit/actions';

interface PropertyPanelProps {
  invitationId: string;
  schema: ThemeConfigSchema;
  activeSection: SectionType | 'colors' | 'fonts' | 'layout';
  currentCustomization: Record<string, unknown>;
}

export function PropertyPanel({
  invitationId,
  schema,
  activeSection,
  currentCustomization,
}: PropertyPanelProps) {
  const [isPending, startTransition] = useTransition();

  const handleChange = useCallback(
    (dotPath: string, value: unknown) => {
      startTransition(async () => {
        await updateCustomizationAction(invitationId, { [dotPath]: value });
      });
    },
    [invitationId]
  );

  const fields = resolveFieldsForSection(schema, activeSection);

  return (
    <div className="flex flex-col gap-6 p-4">
      {fields.map(({ path, field }) => (
        <FieldRenderer
          key={path}
          path={path}
          field={field}
          currentValue={currentCustomization[path]}
          onChange={handleChange}
          isPending={isPending}
        />
      ))}
    </div>
  );
}

function FieldRenderer({
  path, field, currentValue, onChange, isPending,
}: {
  path: string;
  field: SchemaField;
  currentValue: unknown;
  onChange: (path: string, value: unknown) => void;
  isPending: boolean;
}) {
  // Feature gate check
  const featureResolution = field.feature_gate
    ? useFeature(field.feature_gate as any)
    : { enabled: true };

  if (!featureResolution.enabled) {
    return (
      <LockedField
        label={field.label}
        featureKey={field.feature_gate!}
        hint={field.hint}
      />
    );
  }

  const value = currentValue ?? field.default;
  const handleChange = (v: unknown) => onChange(path, v);

  switch (field.type) {
    case 'color':        return <ColorField label={field.label} value={value as string} onChange={handleChange} hint={field.hint} disabled={isPending} />;
    case 'font_select':  return <FontSelectField label={field.label} value={value as string} options={field.options!} onChange={handleChange} />;
    case 'text':         return <TextInputField label={field.label} value={value as string} onChange={handleChange} />;
    case 'textarea':     return <TextareaField label={field.label} value={value as string} onChange={handleChange} />;
    case 'toggle':       return <ToggleField label={field.label} value={value as boolean} onChange={handleChange} hint={field.hint} />;
    case 'range':        return <RangeField label={field.label} value={value as number} min={field.min!} max={field.max!} step={field.step} onChange={handleChange} />;
    case 'select':       return <SelectField label={field.label} value={value as string} options={field.options!} onChange={handleChange} />;
    case 'image_upload': return <ImageUploadField label={field.label} value={value as string | null} invitationId={''} onChange={handleChange} hint={field.hint} />;
    default:             return null;
  }
}
```

### 5.3 Auto-Save Server Action

Changes debounce in the client, then flush via a Server Action.

```typescript
// app/(app)/invitations/[id]/edit/actions.ts
'use server';

import { z } from 'zod';
import { createServerClient } from '@/lib/supabase/server';
import { requireSession } from '@/lib/auth/session';
import { revalidatePath } from 'next/cache';

const CustomizationPatchSchema = z.record(z.unknown());

export async function updateCustomizationAction(
  invitationId: string,
  patch: Record<string, unknown>
): Promise<{ success: boolean; error?: string }> {
  const user = await requireSession();
  const parsed = CustomizationPatchSchema.safeParse(patch);
  if (!parsed.success) return { success: false, error: 'Invalid data' };

  const supabase = createServerClient();

  // Merge patch into existing customization using PostgreSQL jsonb concat operator
  const { error } = await supabase
    .from('invitations')
    .update({
      // jsonb || jsonb merges at top level — flat dot-notation keys work perfectly
      customization: supabase.rpc('jsonb_merge_patch', {
        target_id: invitationId,
        patch: parsed.data,
      }),
      updated_at: new Date().toISOString(),
    })
    .eq('id', invitationId)
    .eq('tenant_id', user.tenantId);

  if (error) return { success: false, error: error.message };

  // Revalidate the public invitation ISR page
  revalidatePath(`/inv/[slug]`, 'page');

  return { success: true };
}
```

```sql
-- supabase/migrations/050_jsonb_helpers.sql

-- Helper function for atomic JSONB key-level merge (not deep replace)
CREATE OR REPLACE FUNCTION jsonb_merge_patch(target_id UUID, patch JSONB)
RETURNS JSONB AS $$
DECLARE
  current JSONB;
BEGIN
  SELECT customization INTO current FROM invitations WHERE id = target_id;
  RETURN COALESCE(current, '{}') || patch;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### 5.4 Live Preview Architecture

The live preview renders the actual theme component tree scaled down to fit the preview pane. It is a React component — not an iframe — ensuring no cross-origin latency or CSP friction.

```typescript
// components/invitation/editor/LivePreview.tsx

'use client';

import { useRef } from 'react';
import { InvitationRenderer } from '@/components/invitation/renderer/InvitationRenderer';
import type { ResolvedInvitationData } from '@/types/invitation';

interface LivePreviewProps {
  invitationData: ResolvedInvitationData;
  customization: Record<string, unknown>;
}

export function LivePreview({ invitationData, customization }: LivePreviewProps) {
  const containerRef = useRef<HTMLDivElement>(null);

  // Scale the 390px-wide invitation preview to fit the container
  // 390px = dominant mobile viewport (WhatsApp-opened link)
  const PREVIEW_WIDTH = 390;

  return (
    <div
      ref={containerRef}
      className="relative w-full overflow-hidden rounded-xl border border-gray-200 bg-gray-50"
      style={{ height: '70vh' }}
    >
      <div
        className="origin-top-left overflow-y-auto"
        style={{
          width: PREVIEW_WIDTH,
          transform: `scale(${containerRef.current
            ? containerRef.current.clientWidth / PREVIEW_WIDTH
            : 1})`,
          height: `${100 / (containerRef.current
            ? containerRef.current.clientWidth / PREVIEW_WIDTH
            : 1)}%`,
        }}
      >
        <InvitationRenderer
          invitationData={invitationData}
          customization={customization}
          isPreview
        />
      </div>
    </div>
  );
}
```

---

## 6. Theme Customization Rules

### 6.1 What Users Can Customize

Customization is strictly bounded by the theme's `config_schema`. Users can only configure fields declared in the schema — nothing more.

| Scope | Field Types | Notes |
|---|---|---|
| Global colors | `color` | Up to 7 color tokens |
| Global fonts | `font_select` | Heading, body, script — feature-gated |
| Global layout | `spacing`, `select` | Section gap, border radius |
| Per-section content | `text`, `textarea` | Labels, copy overrides |
| Per-section appearance | `color`, `range`, `toggle`, `select` | Style choices scoped to section |
| Per-section media | `image_upload` | Background photos, overlay opacity |

### 6.2 What Users Cannot Customize

- HTML structure of sections
- Section order (fixed per theme by `sort_order`)
- Section type (cannot add or remove section types not in the theme)
- CSS class names or raw CSS
- JavaScript behavior (animations, scroll triggers — these are theme-defined)

### 6.3 Customization Validation Rules

All customization values are validated server-side against the schema before persistence.

```typescript
// lib/theme/customization-validator.ts

import { z } from 'zod';
import type { ThemeConfigSchema, SchemaField } from '@/types/theme';

export function buildValidationSchema(configSchema: ThemeConfigSchema): z.ZodSchema {
  const shape: Record<string, z.ZodTypeAny> = {};

  for (const [section, fields] of Object.entries(configSchema.sections ?? {})) {
    for (const [key, field] of Object.entries(fields as Record<string, SchemaField>)) {
      const dotKey = `sections.${section}.${key}`;
      shape[dotKey] = buildFieldValidator(field).optional();
    }
  }

  for (const [key, field] of Object.entries(configSchema.colors ?? {})) {
    shape[`colors.${key}`] = buildFieldValidator(field).optional();
  }

  for (const [key, field] of Object.entries(configSchema.fonts ?? {})) {
    shape[`fonts.${key}`] = buildFieldValidator(field).optional();
  }

  for (const [key, field] of Object.entries(configSchema.layout ?? {})) {
    shape[`layout.${key}`] = buildFieldValidator(field).optional();
  }

  return z.object(shape).strip(); // strip unknown keys
}

function buildFieldValidator(field: SchemaField): z.ZodTypeAny {
  switch (field.type) {
    case 'color':
      return z.string().regex(/^#[0-9A-Fa-f]{6}$/);
    case 'font_select':
      return field.options ? z.enum(field.options as [string, ...string[]]) : z.string();
    case 'text':
      return z.string().max(200);
    case 'textarea':
      return z.string().max(1000);
    case 'toggle':
      return z.boolean();
    case 'range':
      return z.number()
        .min(field.min ?? 0)
        .max(field.max ?? 1);
    case 'select':
      return field.options ? z.enum(field.options as [string, ...string[]]) : z.string();
    case 'image_upload':
      return z.string().url().nullable();
    case 'number':
      return z.number().min(field.min ?? 0).max(field.max ?? 9999);
    default:
      return z.unknown();
  }
}
```

### 6.4 Theme Change Rule

Users can change the theme of a draft invitation at any time. When a theme is changed:

1. `invitations.theme_id` is updated.
2. `invitations.customization` is **cleared** — the old theme's customization keys are meaningless to the new theme schema.
3. `invitation_sections` rows are re-seeded from the new theme's default sections.
4. User is warned via a confirmation modal before proceeding.

Changing a theme on a **published** invitation requires unpublishing first, then re-publishing after confirming the new theme looks correct.

```typescript
// app/api/invitations/[id]/change-theme/route.ts

export async function POST(request: Request) {
  const auth = await requireAuth(request, 'invitation:write');
  if (auth instanceof NextResponse) return auth;

  const { theme_id } = await request.json();
  const supabase = createServerClient();

  const { data: invitation } = await supabase
    .from('invitations')
    .select('id, status')
    .eq('id', params.id)
    .eq('tenant_id', auth.user.tenantId)
    .single();

  if (invitation?.status === 'published') {
    return NextResponse.json(
      { error: 'Unpublish the invitation before changing its theme.' },
      { status: 422 }
    );
  }

  // Fetch new theme defaults for sections
  const { data: theme } = await supabase
    .from('invitation_themes')
    .select('id, slug, config_schema')
    .eq('id', theme_id)
    .eq('is_active', true)
    .single();

  if (!theme) return NextResponse.json({ error: 'Theme not found' }, { status: 404 });

  // Transaction: clear customization, update theme, reseed sections
  await supabase.rpc('change_invitation_theme', {
    p_invitation_id: params.id,
    p_theme_id: theme_id,
    p_default_sections: getDefaultSectionsForTheme(theme.slug),
  });

  return NextResponse.json({ success: true });
}
```

---

## 7. Font System

### 7.1 Font Strategy

**Phase 1:** Curated list of Google Fonts, self-hosted via Next.js `next/font`. Self-hosting eliminates third-party DNS lookup, renders fonts with zero layout shift using `font-display: swap`, and passes Core Web Vitals.

**Phase 2+:** Custom font upload for Premium/Ultimate tenants (WOFF2 format, stored in Supabase Storage, `fonts/` bucket).

### 7.2 Font Registry

```typescript
// config/fonts.ts

export interface FontDefinition {
  name: string;
  slug: string;
  role: 'heading' | 'body' | 'script' | 'any';
  weights: number[];
  subsets: string[];
  nextFontKey: string; // key used in next/font/google
  category: 'serif' | 'sans-serif' | 'display' | 'handwriting' | 'monospace';
  previewText: string;
}

export const FONT_REGISTRY: FontDefinition[] = [
  // Heading / Display
  { name: 'Cormorant Garamond', slug: 'cormorant-garamond', role: 'heading', weights: [300,400,500,600,700], subsets: ['latin'], nextFontKey: 'Cormorant_Garamond', category: 'serif', previewText: 'Elegance in Every Detail' },
  { name: 'Playfair Display',   slug: 'playfair-display',   role: 'heading', weights: [400,500,600,700,800,900], subsets: ['latin'], nextFontKey: 'Playfair_Display', category: 'serif', previewText: 'A Day to Remember' },
  { name: 'EB Garamond',        slug: 'eb-garamond',        role: 'heading', weights: [400,500,600,700,800], subsets: ['latin'], nextFontKey: 'EB_Garamond', category: 'serif', previewText: 'Timeless Romance' },
  { name: 'Libre Baskerville',  slug: 'libre-baskerville',  role: 'heading', weights: [400,700], subsets: ['latin'], nextFontKey: 'Libre_Baskerville', category: 'serif', previewText: 'Classic & Beautiful' },
  { name: 'Josefin Sans',       slug: 'josefin-sans',       role: 'heading', weights: [100,200,300,400,600,700], subsets: ['latin'], nextFontKey: 'Josefin_Sans', category: 'sans-serif', previewText: 'Modern Simplicity' },
  { name: 'Montserrat',         slug: 'montserrat',         role: 'heading', weights: [300,400,500,600,700,800], subsets: ['latin'], nextFontKey: 'Montserrat', category: 'sans-serif', previewText: 'Clean & Contemporary' },

  // Body
  { name: 'Lato',               slug: 'lato',               role: 'body', weights: [300,400,700], subsets: ['latin'], nextFontKey: 'Lato', category: 'sans-serif', previewText: 'Readable and Refined' },
  { name: 'Raleway',            slug: 'raleway',            role: 'body', weights: [300,400,500,600,700], subsets: ['latin'], nextFontKey: 'Raleway', category: 'sans-serif', previewText: 'Elegant Body Text' },
  { name: 'Nunito',             slug: 'nunito',             role: 'body', weights: [300,400,500,600,700], subsets: ['latin'], nextFontKey: 'Nunito', category: 'sans-serif', previewText: 'Friendly and Warm' },
  { name: 'Open Sans',          slug: 'open-sans',          role: 'body', weights: [300,400,600,700], subsets: ['latin'], nextFontKey: 'Open_Sans', category: 'sans-serif', previewText: 'Clear and Legible' },

  // Script / Accent
  { name: 'Great Vibes',        slug: 'great-vibes',        role: 'script', weights: [400], subsets: ['latin'], nextFontKey: 'Great_Vibes', category: 'handwriting', previewText: 'With Love' },
  { name: 'Dancing Script',     slug: 'dancing-script',     role: 'script', weights: [400,500,600,700], subsets: ['latin'], nextFontKey: 'Dancing_Script', category: 'handwriting', previewText: 'Together Forever' },
  { name: 'Sacramento',         slug: 'sacramento',         role: 'script', weights: [400], subsets: ['latin'], nextFontKey: 'Sacramento', category: 'handwriting', previewText: 'Always & Forever' },
  { name: 'Pacifico',           slug: 'pacifico',           role: 'script', weights: [400], subsets: ['latin'], nextFontKey: 'Pacifico', category: 'handwriting', previewText: 'Happily Ever After' },
];

export const FONTS_BY_ROLE = {
  heading: FONT_REGISTRY.filter(f => f.role === 'heading' || f.role === 'any'),
  body:    FONT_REGISTRY.filter(f => f.role === 'body'    || f.role === 'any'),
  script:  FONT_REGISTRY.filter(f => f.role === 'script'  || f.role === 'any'),
};
```

### 7.3 Font Loader Component

Fonts are loaded lazily — only the fonts actually selected for an invitation are fetched. This is implemented via Next.js `next/font/google` with dynamic import at the Shell level.

```typescript
// components/invitation/shared/FontLoader.tsx

'use client';

import { useEffect } from 'react';

interface FontLoaderProps {
  fonts: string[];  // font names currently in use
}

// Maps font name → CSS import URL for Google Fonts (CDN fallback)
// In production, these are self-hosted via next/font. This component handles
// the dynamic case where a user selects a font that wasn't pre-loaded.
export function FontLoader({ fonts }: FontLoaderProps) {
  useEffect(() => {
    for (const fontName of fonts) {
      if (!fontName) continue;
      const id = `gfont-${fontName.replace(/\s/g, '-').toLowerCase()}`;
      if (document.getElementById(id)) continue;

      const link = document.createElement('link');
      link.id = id;
      link.rel = 'stylesheet';
      link.href = `https://fonts.googleapis.com/css2?family=${fontName.replace(/\s/g, '+')}:wght@300;400;500;600;700&display=swap`;
      document.head.appendChild(link);
    }
  }, [fonts]);

  return null;
}
```

**Production note:** For the initial Phase 1 theme set, all fonts are pre-loaded via Next.js `next/font/google` in the theme Shell components. The `FontLoader` component is a progressive enhancement fallback for fonts added dynamically via the property panel.

### 7.4 Font Subsetting Strategy

To minimize font file sizes, only the Latin subset is loaded for Phase 1. Indonesian content uses Latin characters. Phase 3+ adds `latin-ext` for European reseller markets.

---

## 8. Color System

### 8.1 Color Token Architecture

Every theme exposes exactly 7 color tokens via CSS variables. Components use only these tokens — never raw hex values inside component code.

```typescript
// types/theme.ts

export interface ThemeColors {
  primary:       string;  // --color-primary: headings, key elements
  secondary:     string;  // --color-secondary: subheadings, borders
  background:    string;  // --color-background: page bg
  surface:       string;  // --color-surface: cards, panels
  textPrimary:   string;  // --color-text-primary: body copy
  textSecondary: string;  // --color-text-secondary: captions, labels
  accent:        string;  // --color-accent: CTAs, decorative elements
}
```

### 8.2 Color Validation

All hex color inputs are validated for contrast ratio against their expected pairing to catch accessibility issues. Warnings (not blocks) are shown in the property panel.

```typescript
// lib/theme/color-contrast.ts

// WCAG 2.1 relative luminance calculation
function getLuminance(hex: string): number {
  const rgb = hexToRgb(hex);
  const [r, g, b] = [rgb.r, rgb.g, rgb.b].map(v => {
    v /= 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

export function getContrastRatio(hex1: string, hex2: string): number {
  const l1 = getLuminance(hex1);
  const l2 = getLuminance(hex2);
  const lighter = Math.max(l1, l2);
  const darker  = Math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

// Returns null if contrast is acceptable, warning message if not
export function checkColorContrast(
  textColor: string,
  bgColor: string,
  level: 'AA' | 'AAA' = 'AA'
): string | null {
  const ratio = getContrastRatio(textColor, bgColor);
  const threshold = level === 'AAA' ? 7 : 4.5;
  if (ratio < threshold) {
    return `Low contrast (${ratio.toFixed(1)}:1). WCAG ${level} requires ${threshold}:1.`;
  }
  return null;
}
```

### 8.3 Default Color Palettes per Theme

```typescript
// components/invitation/themes/classic/index.ts

export const ClassicDefaultColors: ThemeColors = {
  primary:       '#2C1810',  // Deep espresso
  secondary:     '#8B6914',  // Antique gold
  background:    '#FDF8F0',  // Warm ivory
  surface:       '#FFFFFF',
  textPrimary:   '#3D2B1F',
  textSecondary: '#7C6B5E',
  accent:        '#C4974A',  // Warm gold
};

export const FloralDefaultColors: ThemeColors = {
  primary:       '#4A2040',  // Deep plum
  secondary:     '#8B4F6B',  // Dusty rose
  background:    '#FDF0F5',  // Blush white
  surface:       '#FFFFFF',
  textPrimary:   '#3D1E32',
  textSecondary: '#8B6B7A',
  accent:        '#B87A8C',  // Muted rose
};

export const ModernDefaultColors: ThemeColors = {
  primary:       '#0A0A0A',  // Near black
  secondary:     '#404040',  // Dark gray
  background:    '#FFFFFF',
  surface:       '#F8F8F8',
  textPrimary:   '#1A1A1A',
  textSecondary: '#666666',
  accent:        '#0A0A0A',  // Same as primary — monochrome
};

export const RusticDefaultColors: ThemeColors = {
  primary:       '#3E2010',  // Burnt sienna
  secondary:     '#7A5C2E',  // Warm brown
  background:    '#F5EFE6',  // Warm cream
  surface:       '#FBF7F2',
  textPrimary:   '#2E180C',
  textSecondary: '#7A5C3A',
  accent:        '#8B6914',  // Harvest gold
};
```

---

## 9. Layout System

### 9.1 Section Layout Model

Sections are rendered in a vertical stack, full-width, in the order defined by `sort_order`. This is not configurable by users.

```
Page
├── Section: Hero           (sort_order: 0, min-height: 100vh)
├── Section: Couple         (sort_order: 1, padding: var(--spacing-section))
├── Section: Event Details  (sort_order: 2, padding: var(--spacing-section))
├── Section: Love Story     (sort_order: 3, visible if feature enabled)
├── Section: Gallery        (sort_order: 4)
├── Section: Countdown      (sort_order: 5)
├── Section: Music          (sort_order: 6, visible if feature enabled, sticky player)
├── Section: RSVP           (sort_order: 7)
├── Section: Guestbook      (sort_order: 8)
├── Section: Gift           (sort_order: 9, visible if feature enabled)
└── Section: Closing        (sort_order: 10)
```

### 9.2 Section Spacing Tokens

```typescript
// config/spacing.ts

export const SECTION_SPACING = {
  sm: '2rem',    // 32px — compact
  md: '3.5rem',  // 56px — default for most themes
  lg: '5rem',    // 80px — airy, editorial
  xl: '7rem',    // 112px — very spacious
} as const;

export type SpacingToken = keyof typeof SECTION_SPACING;
```

### 9.3 Max-Width Container Strategy

All section content uses a constrained max-width to keep text legible at large viewports while the section background bleeds full-width.

```typescript
// lib/theme/layout-constants.ts

export const LAYOUT = {
  // Section content max-width — applied to inner container, not section itself
  CONTENT_MAX_WIDTH: '680px',    // Optimized for mobile-first reading
  CONTENT_WIDE_MAX_WIDTH: '960px', // For gallery grids, event cards

  // Horizontal padding on mobile
  MOBILE_PADDING: '1.25rem',     // 20px

  // Typography scale multipliers
  HERO_HEADING_CLAMP: 'clamp(2.5rem, 8vw, 5rem)',
  SECTION_HEADING_CLAMP: 'clamp(1.75rem, 5vw, 3rem)',
} as const;
```

### 9.4 Layout Variants per Section

Some sections offer layout variant options exposed through the schema:

**Couple Section:**
- `side-by-side` — groom left, bride right (default)
- `stacked` — bride above groom
- `overlapping` — photos overlap with offset
- `circle` — circular cropped photos

**Gallery Section:**
- `masonry` — CSS masonry layout (default)
- `grid-2` — 2-column uniform grid
- `grid-3` — 3-column uniform grid
- `carousel` — horizontal swipeable carousel

**Countdown Section:**
- `rings` — circular progress rings (default)
- `flip` — flip-clock animation
- `minimal` — plain number + label, no decoration
- `elegant` — large serif numbers, gold underline

---

## 10. Theme Asset Management

### 10.1 Asset Types per Theme

| Asset | Bucket | Path Pattern | Access | Max Size |
|---|---|---|---|---|
| Theme preview image | `themes` | `{slug}/preview.jpg` | Public | 1 MB |
| Theme thumbnail | `themes` | `{slug}/thumbnail.jpg` | Public | 300 KB |
| Section demo screenshots | `themes` | `{slug}/sections/{section}.jpg` | Public | 500 KB |
| Invitation hero background (user) | `invitation-images` | `{tenant_id}/{inv_id}/hero-bg.jpg` | Public (via signed URL path) | 5 MB |
| Couple photos (user) | `invitation-images` | `{tenant_id}/{inv_id}/couple-{role}.jpg` | Public | 3 MB each |
| Gallery photos (user) | `gallery` | `{tenant_id}/{inv_id}/{uuid}.jpg` | Public (CDN) | 8 MB each |
| Gallery thumbnails | `gallery` | `{tenant_id}/{inv_id}/thumbs/{uuid}.jpg` | Public (CDN) | 200 KB each |

### 10.2 Image Processing Pipeline

All user-uploaded images for invitations are processed server-side via Supabase Edge Functions before storage.

```typescript
// supabase/functions/process-invitation-image/index.ts

// Triggered after upload to invitation-images bucket
// Performs: resize, compress, generate thumbnail, strip EXIF

Deno.serve(async (req) => {
  const { bucket, key, contentType } = await req.json();

  // Fetch uploaded file from Supabase Storage
  const imageBuffer = await fetchFromStorage(bucket, key);

  // Process via Sharp (WASM build for Deno)
  const processed = await sharp(imageBuffer)
    .rotate()              // Auto-rotate based on EXIF
    .resize(1920, 1080, { fit: 'inside', withoutEnlargement: true })
    .jpeg({ quality: 82, progressive: true })
    .toBuffer();

  // Generate thumbnail for gallery
  const thumbnail = await sharp(imageBuffer)
    .rotate()
    .resize(400, 400, { fit: 'cover' })
    .jpeg({ quality: 75 })
    .toBuffer();

  // Replace original with processed version
  await uploadToStorage(bucket, key, processed);

  // Store thumbnail if this is a gallery image
  if (bucket === 'gallery') {
    const thumbKey = key.replace('/', '/thumbs/');
    await uploadToStorage(bucket, thumbKey, thumbnail);
  }

  return new Response(JSON.stringify({ success: true }), { status: 200 });
});
```

### 10.3 Image Upload Component

```typescript
// components/invitation/editor/fields/ImageUploadField.tsx

'use client';

import { useState, useCallback } from 'react';
import { createBrowserClient } from '@/lib/supabase/client';
import { checkQuota } from '@/lib/packages/quota';

interface ImageUploadFieldProps {
  label: string;
  value: string | null;
  invitationId: string;
  bucket: 'invitation-images' | 'gallery';
  pathPrefix: string;
  onChange: (url: string | null) => void;
  maxSizeMB?: number;
  hint?: string;
}

export function ImageUploadField({ label, value, invitationId, bucket, pathPrefix, onChange, maxSizeMB = 5, hint }: ImageUploadFieldProps) {
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const supabase = createBrowserClient();

  const handleUpload = useCallback(async (file: File) => {
    setError(null);

    // Client-side size validation
    if (file.size > maxSizeMB * 1024 * 1024) {
      setError(`File must be under ${maxSizeMB}MB`);
      return;
    }

    // Accept only images
    if (!file.type.startsWith('image/')) {
      setError('Only image files are allowed');
      return;
    }

    setUploading(true);
    try {
      const ext = file.name.split('.').pop();
      const path = `${pathPrefix}/${crypto.randomUUID()}.${ext}`;

      const { error: uploadError } = await supabase.storage
        .from(bucket)
        .upload(path, file, { upsert: true });

      if (uploadError) throw uploadError;

      const { data } = supabase.storage.from(bucket).getPublicUrl(path);
      onChange(data.publicUrl);
    } catch (err) {
      setError('Upload failed. Please try again.');
    } finally {
      setUploading(false);
    }
  }, [bucket, pathPrefix, maxSizeMB, onChange, supabase]);

  return (
    <div className="space-y-2">
      <label className="block text-sm font-medium text-gray-700">{label}</label>
      {hint && <p className="text-xs text-gray-500">{hint}</p>}
      {value && (
        <div className="relative">
          <img src={value} alt="Uploaded" className="w-full h-32 object-cover rounded-lg" />
          <button
            onClick={() => onChange(null)}
            className="absolute top-2 right-2 rounded-full bg-black/60 p-1 text-white hover:bg-black/80"
          >
            ✕
          </button>
        </div>
      )}
      <label className={`flex cursor-pointer items-center justify-center rounded-lg border-2 border-dashed p-4 transition ${uploading ? 'opacity-50' : 'hover:border-gray-400'}`}>
        <input
          type="file"
          accept="image/jpeg,image/png,image/webp"
          className="sr-only"
          disabled={uploading}
          onChange={e => e.target.files?.[0] && handleUpload(e.target.files[0])}
        />
        <span className="text-sm text-gray-500">
          {uploading ? 'Uploading…' : 'Click to upload'}
        </span>
      </label>
      {error && <p className="text-xs text-red-600">{error}</p>}
    </div>
  );
}
```

### 10.4 OG Image Generation

Each published invitation generates an OG image via Vercel OG (`@vercel/og`). This image is shown when the invitation link is shared on WhatsApp, Instagram, or other social platforms.

```typescript
// app/api/og/route.tsx

import { ImageResponse } from '@vercel/og';
import { NextRequest } from 'next/server';
import { createServerClient } from '@/lib/supabase/server';

export const runtime = 'edge';

export async function GET(request: NextRequest) {
  const slug = request.nextUrl.searchParams.get('slug');
  if (!slug) return new Response('Missing slug', { status: 400 });

  const supabase = createServerClient();
  const { data: inv } = await supabase
    .from('invitations')
    .select('title, couple_data, event_date, og_image_url, customization, theme:invitation_themes(slug)')
    .eq('slug', slug)
    .eq('status', 'published')
    .single();

  if (!inv) return new Response('Not found', { status: 404 });

  const { groom_name, bride_name } = inv.couple_data as any;
  const primaryColor = (inv.customization as any)?.['colors.primary'] ?? '#2C1810';
  const bgColor = (inv.customization as any)?.['colors.background'] ?? '#FDF8F0';

  return new ImageResponse(
    (
      <div
        style={{
          width: '100%',
          height: '100%',
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          backgroundColor: bgColor,
          fontFamily: 'serif',
          padding: '60px',
        }}
      >
        {inv.og_image_url && (
          <img
            src={inv.og_image_url}
            style={{
              position: 'absolute',
              inset: 0,
              width: '100%',
              height: '100%',
              objectFit: 'cover',
              opacity: 0.25,
            }}
          />
        )}
        <p style={{ color: primaryColor, fontSize: 24, letterSpacing: '0.2em', textTransform: 'uppercase', margin: 0 }}>
          Wedding Invitation
        </p>
        <h1 style={{ color: primaryColor, fontSize: 72, margin: '16px 0', textAlign: 'center', lineHeight: 1.2 }}>
          {groom_name} & {bride_name}
        </h1>
        {inv.event_date && (
          <p style={{ color: primaryColor, fontSize: 28, opacity: 0.7, margin: 0 }}>
            {new Date(inv.event_date).toLocaleDateString('id-ID', { day: 'numeric', month: 'long', year: 'numeric' })}
          </p>
        )}
      </div>
    ),
    {
      width: 1200,
      height: 630,
    }
  );
}
```

---

## 11. Theme Package Restrictions

### 11.1 Access Control Matrix

| Theme | Is Premium | Required Feature | Required Package |
|---|:---:|---|---|
| Classic | No | — | Free+ |
| Floral | No | — | Free+ |
| Modern | No | — | Free+ |
| Rustic | Yes | `premium_themes` | Basic+ |
| (Phase 2 themes) | Varies | `premium_themes` | Basic+ |

Free plan tenants see a curated subset of 3 free themes. The gallery shows all themes but premium ones display a lock overlay with an upgrade CTA.

### 11.2 Theme Access Enforcement

Theme access is enforced at two points:

**1. Theme Gallery (create invitation flow):**

```typescript
// components/invitation/ThemeGallery.tsx

'use client';

import { useFeature } from '@/hooks/use-feature';

interface ThemeGalleryProps {
  themes: ThemeListItem[];
  selectedThemeId: string | null;
  onSelect: (themeId: string) => void;
}

export function ThemeGallery({ themes, selectedThemeId, onSelect }: ThemeGalleryProps) {
  const premiumThemesEnabled = useFeature('premium_themes').enabled;

  return (
    <div className="grid grid-cols-2 gap-4 md:grid-cols-3">
      {themes.filter(t => t.is_active).map(theme => {
        const isLocked = theme.is_premium && !premiumThemesEnabled;

        return (
          <ThemeCard
            key={theme.id}
            theme={theme}
            isSelected={selectedThemeId === theme.id}
            isLocked={isLocked}
            onSelect={isLocked ? undefined : () => onSelect(theme.id)}
          />
        );
      })}
    </div>
  );
}
```

**2. API route (server-side enforcement):**

```typescript
// app/api/invitations/[id]/change-theme/route.ts

// Validate tenant has access to the selected theme
if (theme.is_premium) {
  const resolution = await resolveFeature(
    { tenantId: auth.user.tenantId, packageId: auth.user.packageId },
    'premium_themes'
  );
  if (!resolution.enabled) {
    return NextResponse.json(
      { error: 'Premium themes require a Basic plan or above.' },
      { status: 403 }
    );
  }
}
```

### 11.3 Customization Feature Gates

Certain customization fields within a theme are feature-gated. The property panel renders a locked state for these fields based on the resolved feature set.

```typescript
// components/invitation/editor/fields/LockedField.tsx

'use client';

import Link from 'next/link';
import { LockClosedIcon } from '@heroicons/react/24/outline';

interface LockedFieldProps {
  label: string;
  featureKey: string;
  hint?: string;
}

export function LockedField({ label, featureKey, hint }: LockedFieldProps) {
  const planMap: Record<string, string> = {
    custom_font:  'Basic',
    custom_color: 'Basic',
    custom_domain:'Premium',
  };

  const requiredPlan = planMap[featureKey] ?? 'a higher plan';

  return (
    <div className="rounded-lg border border-dashed border-gray-300 bg-gray-50 p-3">
      <div className="flex items-center gap-2">
        <LockClosedIcon className="h-4 w-4 text-gray-400" />
        <span className="text-sm font-medium text-gray-500">{label}</span>
      </div>
      {hint && <p className="mt-1 text-xs text-gray-400">{hint}</p>}
      <p className="mt-2 text-xs text-gray-500">
        Requires {requiredPlan} plan.{' '}
        <Link href="/subscription" className="text-purple-600 underline">
          Upgrade now
        </Link>
      </p>
    </div>
  );
}
```

---

## 12. Premium Theme Handling

### 12.1 Premium Theme Database Fields

```sql
-- invitation_themes table (relevant columns)
CREATE TABLE invitation_themes (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name           TEXT NOT NULL,
  slug           TEXT NOT NULL UNIQUE,
  preview_url    TEXT,
  thumbnail_url  TEXT,
  category       TEXT NOT NULL DEFAULT 'wedding',
  is_premium     BOOLEAN NOT NULL DEFAULT FALSE,
  is_active      BOOLEAN NOT NULL DEFAULT TRUE,
  config_schema  JSONB NOT NULL DEFAULT '{}',
  sort_order     INTEGER NOT NULL DEFAULT 0,
  -- Versioning fields (Section 13)
  version        INTEGER NOT NULL DEFAULT 1,
  changelog      JSONB NOT NULL DEFAULT '[]',
  -- Marketplace fields (Section 14)
  author         TEXT,
  author_url     TEXT,
  tags           TEXT[] NOT NULL DEFAULT '{}',
  -- Stats (denormalized for performance)
  usage_count    INTEGER NOT NULL DEFAULT 0,
  -- Price for marketplace (Phase 3+, null = subscription-gated)
  marketplace_price NUMERIC(12,2),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### 12.2 Premium Theme Preview

Locked premium themes show a full preview in the theme gallery with an upgrade prompt overlay. The preview image is always publicly accessible (no auth needed) to allow the marketing page to display all themes.

```typescript
// components/invitation/ThemeCard.tsx

interface ThemeCardProps {
  theme: ThemeListItem;
  isSelected: boolean;
  isLocked: boolean;
  onSelect?: () => void;
}

export function ThemeCard({ theme, isSelected, isLocked, onSelect }: ThemeCardProps) {
  return (
    <div
      className={`relative cursor-pointer overflow-hidden rounded-xl border-2 transition-all
        ${isSelected ? 'border-purple-500 shadow-lg' : 'border-transparent hover:border-gray-300'}
        ${isLocked ? 'cursor-default' : ''}`}
      onClick={!isLocked ? onSelect : undefined}
    >
      <img
        src={theme.thumbnail_url ?? '/theme-placeholder.jpg'}
        alt={theme.name}
        className={`aspect-[9/16] w-full object-cover ${isLocked ? 'opacity-60' : ''}`}
      />

      {isLocked && (
        <div className="absolute inset-0 flex flex-col items-center justify-center bg-black/30">
          <LockClosedIcon className="h-8 w-8 text-white" />
          <span className="mt-2 text-sm font-semibold text-white">Premium Theme</span>
          <Link
            href="/subscription"
            className="mt-3 rounded-full bg-white px-4 py-1.5 text-xs font-semibold text-gray-900 hover:bg-gray-100"
            onClick={e => e.stopPropagation()}
          >
            Upgrade to Basic
          </Link>
        </div>
      )}

      {theme.is_premium && !isLocked && (
        <div className="absolute top-2 right-2 rounded-full bg-amber-500 px-2 py-0.5 text-xs font-semibold text-white">
          Premium
        </div>
      )}

      <div className="p-2">
        <p className="text-sm font-medium text-gray-800">{theme.name}</p>
        <p className="text-xs text-gray-500 capitalize">{theme.category}</p>
      </div>
    </div>
  );
}
```

### 12.3 Theme Entitlement at Subscription Change

When a tenant downgrades to a package that no longer includes `premium_themes`, their existing published invitations using premium themes continue to render (no forced unpublish). However, they cannot:
- Create new invitations with premium themes
- Access the property panel for those invitations (shown a read-only view with upgrade prompt)

This "grandfather" behavior is intentional to avoid breaking live wedding invitation pages.

```typescript
// lib/theme/access-checker.ts

export async function checkThemeAccessForEdit(
  tenantId: string,
  invitationId: string
): Promise<{ canEdit: boolean; reason?: string }> {
  const supabase = createServerClient();

  const { data: inv } = await supabase
    .from('invitations')
    .select('theme:invitation_themes(is_premium)')
    .eq('id', invitationId)
    .eq('tenant_id', tenantId)
    .single();

  if (!inv?.theme?.is_premium) return { canEdit: true };

  const resolution = await resolveFeature(
    await getTenantContext(tenantId),
    'premium_themes'
  );

  if (!resolution.enabled) {
    return {
      canEdit: false,
      reason: 'This invitation uses a premium theme. Upgrade to Basic or above to continue editing.',
    };
  }

  return { canEdit: true };
}
```

---

## 13. Theme Versioning

### 13.1 Version Strategy

Themes follow semantic versioning at the **major** level only. Minor property additions are backward-compatible; major versions represent breaking schema changes.

```typescript
// types/theme.ts

export interface ThemeVersion {
  version: number;          // Integer, increments on schema breaking change
  changelog: ChangelogEntry[];
}

export interface ChangelogEntry {
  version: number;
  date: string;             // ISO date
  changes: string[];        // Human-readable change list
  migration?: string;       // Optional migration script key
}
```

### 13.2 Version Migration

When a theme's `config_schema` version increments and existing invitations have stale customization keys, a migration function transforms the old customization to match the new schema.

```typescript
// lib/theme/migrations/classic-v1-to-v2.ts

// Example: Classic theme v1 used "sections.hero.bg_image" 
// v2 renamed it to "sections.hero.background_image_url"

export function migrateClassicV1toV2(
  customization: Record<string, unknown>
): Record<string, unknown> {
  const result = { ...customization };

  // Rename key
  if ('sections.hero.bg_image' in result) {
    result['sections.hero.background_image_url'] = result['sections.hero.bg_image'];
    delete result['sections.hero.bg_image'];
  }

  return result;
}
```

Migration runs lazily on the first editor load after a theme version bump:

```typescript
// lib/theme/version-manager.ts

export async function ensureCustomizationUpToDate(
  invitationId: string,
  themeSlug: string,
  currentSchemaVersion: number,
  storedCustomization: Record<string, unknown>
): Promise<Record<string, unknown>> {
  const storedVersion = (storedCustomization['__schema_version'] as number) ?? 1;

  if (storedVersion >= currentSchemaVersion) {
    return storedCustomization;
  }

  // Run migrations chain
  let migrated = { ...storedCustomization };
  for (let v = storedVersion; v < currentSchemaVersion; v++) {
    const migrationFn = await getMigrationFn(themeSlug, v, v + 1);
    if (migrationFn) {
      migrated = migrationFn(migrated);
    }
  }

  migrated['__schema_version'] = currentSchemaVersion;

  // Persist migrated customization
  const supabase = createServerClient();
  await supabase
    .from('invitations')
    .update({ customization: migrated })
    .eq('id', invitationId);

  return migrated;
}
```

### 13.3 Version Tracking in DB

```sql
-- Track which customization schema version an invitation was built against
-- Stored as a top-level key in invitations.customization

-- invitations.customization shape after migration:
-- { "__schema_version": 2, "colors.primary": "#...", ... }

-- Admin query: find invitations needing migration for a theme
SELECT i.id, i.slug, i.tenant_id,
       (i.customization->>'__schema_version')::INT AS stored_version,
       it.version AS current_version
FROM invitations i
JOIN invitation_themes it ON it.id = i.theme_id
WHERE it.slug = 'classic'
  AND COALESCE((i.customization->>'__schema_version')::INT, 1) < it.version
  AND i.deleted_at IS NULL;
```

---

## 14. Theme Marketplace Preparation

### 14.1 Marketplace Architecture (Phase 3+)

The marketplace allows third-party designers to submit themes. Platform admin reviews and approves them. This section documents the data model to avoid schema migrations when the marketplace is built.

```sql
-- invitation_themes additions for marketplace (Phase 3+, already in schema via metadata JSONB)

-- Phase 1: these live in invitation_themes.metadata JSONB
-- Phase 3: migrate to dedicated columns

-- Marketplace-specific fields (stored in metadata in Phase 1)
{
  "marketplace": {
    "enabled": false,        -- Phase 3: true when marketplace is live
    "author_name": null,
    "author_url": null,
    "license": "platform",   -- "platform" | "third_party" | "cc0"
    "price": null,           -- null = subscription-included; number = one-time purchase
    "tags": [],
    "demo_url": null,
    "submission_status": "approved"  -- "draft" | "pending" | "approved" | "rejected"
  }
}
```

### 14.2 Third-Party Theme Submission Flow (Phase 3+)

```
Designer submits theme via /admin/themes/submit form:
  - Theme name, category, preview images
  - config_schema JSON
  - Component bundle URL (hosted on designer's CDN)
  - License type + pricing

Admin reviews:
  - Visual QA on all sections
  - Schema validation
  - Security review of component bundle (no external fetch, no eval)
  - Performance audit (LCP < 1.5s on simulated mobile)

Admin approves:
  - invitation_themes row inserted with is_active = true
  - Component bundle imported into platform's CDN
  - Theme appears in gallery (premium if priced)
```

### 14.3 Theme Revenue Sharing (Phase 3+)

```typescript
// Future: theme_purchases table
// For themes with marketplace_price > 0

interface ThemePurchase {
  id: string;
  tenant_id: string;
  theme_id: string;
  amount: number;
  platform_share: number;    // e.g. 30%
  author_share: number;      // e.g. 70%
  currency: string;
  purchased_at: string;
}
```

---

## 15. White Label Support

### 15.1 White Label Theme Implications

Resellers in white-label mode need their branding embedded in invitation pages without exposing the platform name. The theme system handles this through the `WhiteLabelContext` (defined in PHASE5).

```typescript
// lib/theme/white-label-injector.ts

export function applyWhiteLabelToConfig(
  config: ThemeConfig,
  whiteLabelCtx: WhiteLabelContext | null
): ThemeConfig {
  if (!whiteLabelCtx) return config;

  const result = structuredClone(config);

  // Override platform badge visibility
  if (whiteLabelCtx.branding.hide_platform_badge) {
    // Injected as a resolved feature, not config override
    // The closing section reads this flag to hide the footer badge
  }

  return result;
}
```

### 15.2 Platform Badge in Closing Section

All invitations include a "Powered by [Platform]" badge in the closing section by default. This badge is removed when:
- The tenant's package includes `remove_platform_badge` feature, OR
- The reseller's white-label config sets `hide_platform_badge: true`

```typescript
// components/invitation/themes/classic/sections/ClosingSection.tsx

const removeBadge = useFeature('remove_platform_badge').enabled;
const { branding: whiteLabelBranding } = useWhiteLabelContext() ?? {};

const showBadge = !removeBadge && !whiteLabelBranding?.hide_platform_badge;

// In render:
{showBadge && (
  <div className="mt-12 text-center">
    <a
      href="https://weddingplatform.com"
      target="_blank"
      rel="noopener noreferrer"
      className="text-xs text-gray-400 hover:text-gray-600"
    >
      Made with WeddingPlatform
    </a>
  </div>
)}
```

### 15.3 White Label Custom Styling

Resellers can inject a primary color override that propagates into invitation pages rendered for their tenants:

```typescript
// middleware.ts (extend existing middleware)

// After resolving reseller context:
if (resellerId && resellerBranding?.primary_color) {
  response.headers.set('x-reseller-primary-color', resellerBranding.primary_color);
}

// In InvitationRenderer:
// If x-reseller-primary-color header is present AND invitation is on a reseller domain,
// inject as a CSS variable override (ONLY on public pages, not editor)
```

---

## 16. Theme Rendering Engine

### 16.1 InvitationRenderer

The central rendering component. Used on the public invitation page and in the editor preview.

```typescript
// components/invitation/renderer/InvitationRenderer.tsx

import { getThemeModule } from '@/components/invitation/themes';
import { mergeThemeConfig } from '@/lib/theme/config-merger';
import { ThemeConfigProvider } from './ThemeConfigContext';
import { SectionRenderer } from './SectionRenderer';
import type { ResolvedInvitationData } from '@/types/invitation';

interface InvitationRendererProps {
  invitationData: ResolvedInvitationData;
  customization: Record<string, unknown>;
  isPreview?: boolean;
  guestToken?: string;   // personalized guest link token
}

export function InvitationRenderer({
  invitationData,
  customization,
  isPreview = false,
  guestToken,
}: InvitationRendererProps) {
  const themeModule = getThemeModule(invitationData.theme.slug);

  if (!themeModule) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <p className="text-gray-500">Theme not available.</p>
      </div>
    );
  }

  // Merge: theme defaults + user customization
  const mergedConfig = mergeThemeConfig(
    invitationData.theme.config_schema,
    themeModule.defaultConfig,
    customization
  );

  const { Shell } = themeModule;

  return (
    <ThemeConfigProvider config={mergedConfig}>
      <Shell config={mergedConfig}>
        {invitationData.sections
          .filter(s => s.is_visible)
          .sort((a, b) => a.sort_order - b.sort_order)
          .map(section => (
            <SectionRenderer
              key={section.id}
              themeModule={themeModule}
              section={section}
              invitationData={invitationData}
              isPreview={isPreview}
              guestToken={guestToken}
            />
          ))}
      </Shell>
    </ThemeConfigProvider>
  );
}
```

### 16.2 SectionRenderer

Handles feature gating, section visibility, and section-level customization loading.

```typescript
// components/invitation/renderer/SectionRenderer.tsx

import { SECTION_FEATURE_GATES } from '@/config/section-types';
import { UpgradePrompt } from '../shared/UpgradePrompt';
import type { ThemeModule, SectionContent } from '@/types/theme';
import type { ResolvedInvitationData } from '@/types/invitation';

interface SectionRendererProps {
  themeModule: ThemeModule;
  section: SectionContent;
  invitationData: ResolvedInvitationData;
  isPreview: boolean;
  guestToken?: string;
}

export function SectionRenderer({
  themeModule,
  section,
  invitationData,
  isPreview,
  guestToken,
}: SectionRendererProps) {
  const SectionComponent = themeModule.sections[section.section_type];

  if (!SectionComponent) return null;

  // Feature gate check
  const requiredFeature = SECTION_FEATURE_GATES[section.section_type];
  if (requiredFeature) {
    // On the PUBLIC page, we check the invitation's resolved features
    // (tenant features are embedded in invitationData at SSR time)
    const featureEnabled = invitationData.resolvedFeatures?.[requiredFeature]?.enabled ?? false;
    if (!featureEnabled) {
      // On public page: simply don't render (user shouldn't see feature-gated sections)
      // In editor preview: show locked placeholder
      if (!isPreview) return null;
      return (
        <UpgradePrompt
          feature={section.section_type}
          featureKey={requiredFeature}
        />
      );
    }
  }

  return (
    <SectionComponent
      config={useThemeConfig()}
      sectionContent={section}
      invitationData={{ ...invitationData, guestToken }}
      isPreview={isPreview}
    />
  );
}
```

### 16.3 Public Invitation Page (ISR)

```typescript
// app/inv/[slug]/page.tsx

import { createServerClient } from '@/lib/supabase/server';
import { InvitationRenderer } from '@/components/invitation/renderer/InvitationRenderer';
import { resolveAllFeaturesWithCache } from '@/lib/packages/feature-resolver';
import { notFound } from 'next/navigation';

// ISR: revalidate every 60 seconds for published invitations
export const revalidate = 60;

export async function generateMetadata({ params }: { params: { slug: string } }) {
  const supabase = createServerClient();
  const { data: inv } = await supabase
    .from('invitations')
    .select('meta_title, meta_description, og_image_url, couple_data')
    .eq('slug', params.slug)
    .eq('status', 'published')
    .single();

  if (!inv) return {};

  const { groom_name, bride_name } = inv.couple_data as any;

  return {
    title: inv.meta_title ?? `${groom_name} & ${bride_name} — Wedding Invitation`,
    description: inv.meta_description ?? `Join us to celebrate the wedding of ${groom_name} and ${bride_name}.`,
    openGraph: {
      images: [
        inv.og_image_url ??
        `/api/og?slug=${params.slug}`,
      ],
    },
  };
}

export default async function InvitationPage({
  params,
  searchParams,
}: {
  params: { slug: string };
  searchParams: { t?: string }; // personalized guest token
}) {
  const supabase = createServerClient();

  const { data: invitation } = await supabase
    .from('invitations')
    .select(`
      *,
      theme:invitation_themes(id, slug, config_schema, is_premium, is_active),
      sections:invitation_sections(*)
    `)
    .eq('slug', params.slug)
    .eq('status', 'published')
    .single();

  if (!invitation) notFound();

  // Password protection check (Phase 2+)
  if (invitation.password_hash) {
    // Redirect to password gate page
    // redirect(`/inv/${params.slug}/enter`);
  }

  // Resolve tenant features for section gating
  const { data: sub } = await supabase
    .from('tenant_subscriptions')
    .select('package_id')
    .eq('tenant_id', invitation.tenant_id)
    .in('status', ['active', 'trialing'])
    .single();

  const resolvedFeatures = await resolveAllFeaturesWithCache({
    tenantId: invitation.tenant_id,
    packageId: sub?.package_id ?? '',
  });

  // Resolve guest from token (for personalized greeting)
  let guest = null;
  if (searchParams.t) {
    const { data: g } = await supabase
      .from('guests')
      .select('name, group_label')
      .eq('personal_token', searchParams.t)
      .eq('invitation_id', invitation.id)
      .single();
    guest = g;
  }

  return (
    <InvitationRenderer
      invitationData={{
        ...invitation,
        resolvedFeatures,
        guest,
      }}
      customization={invitation.customization as Record<string, unknown>}
      guestToken={searchParams.t}
    />
  );
}
```

### 16.4 ThemeConfigContext

```typescript
// components/invitation/renderer/ThemeConfigContext.tsx

'use client';

import { createContext, useContext } from 'react';
import type { ThemeConfig } from '@/types/theme';

const ThemeConfigContext = createContext<ThemeConfig | null>(null);

export function ThemeConfigProvider({
  config,
  children,
}: {
  config: ThemeConfig;
  children: React.ReactNode;
}) {
  return (
    <ThemeConfigContext.Provider value={config}>
      {children}
    </ThemeConfigContext.Provider>
  );
}

export function useThemeConfig(): ThemeConfig {
  const ctx = useContext(ThemeConfigContext);
  if (!ctx) throw new Error('useThemeConfig must be used within ThemeConfigProvider');
  return ctx;
}
```

---

## 17. Mobile Optimization

### 17.1 Mobile-First Design Principles

All section components are built mobile-first. The 390px viewport (dominant WhatsApp-shared link width) is the primary design target.

```typescript
// Mobile-first Tailwind class ordering pattern:
// Base = mobile styles
// md: = tablet overrides
// lg: = desktop overrides

// Example from HeroSection:
<h1 className="
  text-5xl         /* mobile: 50px */
  md:text-6xl      /* tablet: 60px */
  lg:text-7xl      /* desktop: 70px */
  leading-tight
  text-center
">
```

### 17.2 Touch Interaction Targets

All interactive elements meet WCAG 2.5.5 minimum target size (44×44px):

```typescript
// components/invitation/shared/RsvpForm.tsx

// Radio buttons for attendance use large touch targets
<label className="flex cursor-pointer items-center gap-3 rounded-xl border-2 p-4 transition
  hover:border-[var(--color-primary)] has-[:checked]:border-[var(--color-primary)]">
  <input type="radio" className="sr-only" name="attendance" value="attending" />
  <div className="h-5 w-5 flex-shrink-0 rounded-full border-2 border-current" />
  <span className="text-base">{config.sections.rsvp.attending_label}</span>
</label>
```

### 17.3 Scroll Performance

Sections use `will-change: transform` only during active scroll animations (not permanently), applied via JS intersection observer.

```typescript
// hooks/use-section-enter.ts

import { useEffect, useRef } from 'react';

// Fires a CSS class when section enters viewport, triggering entrance animation
export function useSectionEnter(threshold = 0.15) {
  const ref = useRef<HTMLElement>(null);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;

    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          el.classList.add('section-entered');
          observer.disconnect();
        }
      },
      { threshold }
    );

    observer.observe(el);
    return () => observer.disconnect();
  }, [threshold]);

  return ref;
}
```

```css
/* global.css */
.section-entered {
  animation: fadeInUp 0.6s ease forwards;
}

@keyframes fadeInUp {
  from { opacity: 0; transform: translateY(24px); }
  to   { opacity: 1; transform: translateY(0); }
}

@media (prefers-reduced-motion: reduce) {
  .section-entered {
    animation: none;
    opacity: 1;
  }
}
```

### 17.4 Music Player (Mobile UX)

The music player is a fixed bottom bar on mobile — never an inline section element. It respects autoplay policies: music only starts after first user interaction.

```typescript
// components/invitation/shared/MusicPlayer.tsx

'use client';

import { useState, useEffect, useRef } from 'react';

export function MusicPlayer({ musicUrl, title }: { musicUrl: string; title?: string }) {
  const audioRef = useRef<HTMLAudioElement>(null);
  const [isPlaying, setIsPlaying] = useState(false);
  const [hasInteracted, setHasInteracted] = useState(false);

  // Try autoplay after first document interaction
  useEffect(() => {
    const handleInteraction = () => {
      setHasInteracted(true);
      document.removeEventListener('touchstart', handleInteraction);
      document.removeEventListener('click', handleInteraction);
    };
    document.addEventListener('touchstart', handleInteraction, { passive: true });
    document.addEventListener('click', handleInteraction);
    return () => {
      document.removeEventListener('touchstart', handleInteraction);
      document.removeEventListener('click', handleInteraction);
    };
  }, []);

  useEffect(() => {
    if (hasInteracted && audioRef.current) {
      audioRef.current.play().then(() => setIsPlaying(true)).catch(() => {});
    }
  }, [hasInteracted]);

  const toggle = () => {
    if (!audioRef.current) return;
    if (isPlaying) {
      audioRef.current.pause();
      setIsPlaying(false);
    } else {
      audioRef.current.play();
      setIsPlaying(true);
    }
  };

  return (
    <>
      <audio ref={audioRef} src={musicUrl} loop preload="metadata" />
      <div className="fixed bottom-4 right-4 z-50">
        <button
          onClick={toggle}
          className="flex h-12 w-12 items-center justify-center rounded-full shadow-lg"
          style={{ backgroundColor: 'var(--color-primary)' }}
          aria-label={isPlaying ? 'Pause music' : 'Play music'}
        >
          {isPlaying ? (
            <PauseIcon className="h-5 w-5 text-white" />
          ) : (
            <PlayIcon className="h-5 w-5 text-white" />
          )}
        </button>
      </div>
    </>
  );
}
```

### 17.5 Gallery Mobile Optimization

```typescript
// Gallery section: carousel on mobile, masonry on desktop
// Uses CSS media queries + Intersection Observer for lazy loading

// Mobile: touch-swipeable horizontal scroll with snap
// Tablet+: 2-column masonry
// Desktop: 3-column masonry
```

---

## 18. Performance Optimization

### 18.1 Core Web Vitals Targets

| Metric | Target | Strategy |
|---|---|---|
| LCP | < 1.5s | ISR + CDN, hero image preload, next/image |
| INP | < 200ms | Minimal client JS on public page, no heavy libraries |
| CLS | < 0.05 | Fixed image dimensions, font-display:swap, explicit heights |
| TTFB | < 400ms | ISR cached at edge, Supabase Singapore region |

### 18.2 Image Optimization

```typescript
// All invitation images use next/image for automatic:
// - WebP conversion
// - Responsive srcset generation
// - Lazy loading (except hero, which is eagerly loaded)
// - Placeholder blur

import Image from 'next/image';

// Hero background - eagerly loaded
<Image
  src={heroImageUrl}
  alt=""
  fill
  priority                    // Preloads immediately
  quality={82}
  sizes="100vw"
  className="object-cover"
/>

// Gallery photos - lazy loaded
<Image
  src={photo.thumbnail_url}
  alt={photo.caption ?? ''}
  width={400}
  height={300}
  loading="lazy"
  quality={75}
  sizes="(max-width: 768px) 50vw, 33vw"
  className="w-full object-cover"
  placeholder="blur"
  blurDataURL={photo.blur_data_url}  // Generated at upload time
/>
```

### 18.3 Font Loading Strategy

```typescript
// app/inv/[slug]/layout.tsx or page.tsx
// Preconnect to Google Fonts for fallback, preload self-hosted fonts

export default function InvitationLayout({ children }) {
  return (
    <>
      <link rel="preconnect" href="https://fonts.googleapis.com" />
      <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="" />
      {children}
    </>
  );
}
```

### 18.4 Bundle Size Strategy

The public invitation page must load zero unnecessary JavaScript:

- **No date-picker libraries** — event_date is formatted server-side
- **No charting libraries** — no charts on public page
- **No form validation libraries** — RSVP form uses HTML5 validation + minimal Zod on server
- **No state management libraries** — React `useState` only; no Redux/Zustand
- **No CSS-in-JS** — CSS variables handle all theming; no styled-components runtime

```typescript
// next.config.ts — bundle analysis
const nextConfig = {
  experimental: {
    optimizePackageImports: [
      '@heroicons/react',
    ],
  },
};
```

### 18.5 ISR Revalidation Strategy

```typescript
// Public invitation page: ISR 60s
// Force revalidate on publish/unpublish via Server Action

export async function publishInvitationAction(invitationId: string) {
  // ... update DB status ...

  // Purge ISR cache for this invitation's slug
  revalidatePath(`/inv/${invitation.slug}`);
  revalidatePath(`/api/og?slug=${invitation.slug}`);
}
```

### 18.6 Countdown Timer — Server vs Client

The countdown timer section renders a static server-side snapshot of days/hours/minutes at request time, then hydrates with a client-side interval. This ensures no CLS from the timer appearing and jumping.

```typescript
// components/invitation/themes/classic/sections/CountdownSection.tsx

// Server-side: calculate initial values
const now = new Date();
const target = new Date(invitationData.event_date);
const initialDiff = target.getTime() - now.getTime();

// Client-side: interval to update
const [diff, setDiff] = useState(initialDiff);
useEffect(() => {
  const interval = setInterval(() => {
    setDiff(new Date(invitationData.event_date).getTime() - Date.now());
  }, 1000);
  return () => clearInterval(interval);
}, []);
```

---

## 19. SEO Considerations

### 19.1 Metadata Strategy

```typescript
// app/inv/[slug]/page.tsx — generateMetadata

export async function generateMetadata({ params }) {
  // ... fetch invitation ...

  return {
    title: inv.meta_title
      ?? `${groom_name} & ${bride_name} — Wedding Invitation`,
    description: inv.meta_description
      ?? `You're invited to the wedding of ${groom_name} and ${bride_name} on ${formatDate(inv.event_date)}.`,
    openGraph: {
      type: 'website',
      title: ...,
      description: ...,
      images: [{ url: ogImageUrl, width: 1200, height: 630 }],
    },
    twitter: {
      card: 'summary_large_image',
      title: ...,
      description: ...,
      images: [ogImageUrl],
    },
    // Invitation pages are intentionally not indexed — they're private by nature
    robots: { index: false, follow: false },
  };
}
```

### 19.2 Robots / Indexing Policy

Public invitation pages are **not indexed** by default. They are personal invitations, not marketing content. The `robots: noindex` directive prevents search engines from crawling them.

```typescript
// app/inv/[slug]/page.tsx
export const metadata = {
  robots: { index: false, follow: false },
};
```

Exception: Tenants with custom domains on Premium+ may opt in to indexing for their invitation landing page (Phase 3+).

### 19.3 WhatsApp Share Optimization

WhatsApp uses OG meta tags for link previews. The OG image (`1200×630`) and `og:title` are the two most important elements. The OG image generation endpoint (`/api/og?slug=...`) is:
- Edge runtime (< 50ms response)
- Cached at CDN level (Cache-Control: max-age=3600)
- Uses the invitation's hero image as background if available

### 19.4 Structured Data (JSON-LD)

A `Event` JSON-LD block is injected into published invitation pages to improve social preview richness.

```typescript
// components/invitation/renderer/InvitationJsonLd.tsx

export function InvitationJsonLd({ invitation }: { invitation: ResolvedInvitationData }) {
  const { groom_name, bride_name } = invitation.couple_data as any;

  const jsonLd = {
    '@context': 'https://schema.org',
    '@type': 'Event',
    name: `${groom_name} & ${bride_name} Wedding`,
    startDate: invitation.event_date,
    location: {
      '@type': 'Place',
      name: invitation.event_venue,
      address: invitation.event_address,
    },
    description: `Wedding celebration of ${groom_name} and ${bride_name}.`,
    image: invitation.og_image_url,
  };

  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
    />
  );
}
```

---

## 20. Future Scalability

### 20.1 Theme Hot-Reload (Phase 3+)

Currently, adding a new theme requires a code deployment. Phase 3+ introduces a remote component loading strategy where theme components are bundled as separate JS chunks, loaded at runtime from a CDN, without redeploying the main application.

**Trade-off:** Remote component loading introduces security surface area (code injection risk). This requires strict Content Security Policy enforcement and a code review process before any third-party theme bundle is published to the CDN.

### 20.2 Theme A/B Testing (Phase 4+)

For tenants wanting to test theme performance:

```sql
-- Future: theme_experiments table
CREATE TABLE theme_experiments (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invitation_id   UUID NOT NULL REFERENCES invitations(id),
  variant_a_theme UUID NOT NULL REFERENCES invitation_themes(id),
  variant_b_theme UUID NOT NULL REFERENCES invitation_themes(id),
  traffic_split   INTEGER NOT NULL DEFAULT 50, -- % to variant B
  started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ended_at        TIMESTAMPTZ,
  winner          TEXT CHECK (winner IN ('a', 'b'))
);
```

### 20.3 Section Component Expansion

The section type registry is designed for extension. New section types (e.g., `accommodation`, `dress_code`, `faq`, `transport`) can be added by:
1. Adding the type to `SECTION_TYPES` array
2. Creating the section component in each theme
3. Adding the schema definition to `config_schema`
4. Adding a feature gate if needed

No DB schema migration required for new section types — they're stored as `content JSONB` in `invitation_sections`.

### 20.4 Multi-Language Theme Support (Phase 4+)

The theme config schema supports locale-specific defaults:

```json
{
  "sections": {
    "rsvp": {
      "form_title": {
        "type": "text",
        "label": "RSVP Title",
        "default": "Kindly Reply",
        "locale_defaults": {
          "id": "Konfirmasi Kehadiran",
          "en": "Kindly Reply"
        }
      }
    }
  }
}
```

The `locale_defaults` object is used to pre-fill the default value when a tenant's locale is set in `tenants.metadata.locale`.

### 20.5 Theme Performance Monitoring

Phase 4+ adds automatic LCP monitoring per theme. Each time a public invitation page is loaded, a `page_view` event is recorded in `invitation_events` with timing data. A nightly aggregation identifies themes with P75 LCP > 1.5s for admin review.

```typescript
// components/invitation/shared/PerformanceObserver.tsx
// Client component — fires on public pages only

'use client';

import { useEffect } from 'react';

export function PerformanceReporter({ invitationId, themeSlug }: { invitationId: string; themeSlug: string }) {
  useEffect(() => {
    if (typeof window === 'undefined') return;

    new PerformanceObserver((list) => {
      const lcp = list.getEntries().at(-1);
      if (!lcp) return;

      fetch('/api/events', {
        method: 'POST',
        body: JSON.stringify({
          invitation_id: invitationId,
          event_type: 'page_view',
          metadata: {
            lcp_ms: Math.round(lcp.startTime),
            theme_slug: themeSlug,
            viewport: window.innerWidth,
          },
        }),
      });
    }).observe({ type: 'largest-contentful-paint', buffered: true });
  }, []);

  return null;
}
```

### 20.6 Database Indexes for Theme Queries

```sql
-- supabase/migrations/051_theme_indexes.sql

-- Hot path: fetch active themes by category for theme gallery
CREATE INDEX idx_themes_category_active
  ON invitation_themes(category, sort_order, is_premium)
  WHERE is_active = TRUE;

-- Hot path: fetch theme by slug (used in every invitation render)
CREATE INDEX idx_themes_slug
  ON invitation_themes(slug)
  WHERE is_active = TRUE;

-- Analytics: themes by usage count (for marketplace sorting)
CREATE INDEX idx_themes_usage
  ON invitation_themes(usage_count DESC)
  WHERE is_active = TRUE;

-- Find invitations needing migration after theme version bump
CREATE INDEX idx_inv_theme_version
  ON invitations(theme_id, (customization->>'__schema_version'))
  WHERE deleted_at IS NULL;
```

---

## Appendix A — Migration Order (Theme System)

```
Previously from PHASE1–5:
  001–045: Core tables, packages, features, RLS

New migrations (PHASE6 additions):
  046_invitation_themes_v2.sql     -- Add version, changelog, author, tags, usage_count
  047_invitation_sections_v2.sql   -- Add UNIQUE (invitation_id, section_type) constraint
  048_invitation_gallery_v2.sql    -- Add blur_data_url column for next/image placeholder
  049_theme_purchases.sql          -- Phase 3+ marketplace purchase tracking
  050_jsonb_helpers.sql            -- jsonb_merge_patch() helper function
  051_theme_indexes.sql            -- All performance indexes for theme queries
  052_seed_themes_v2.sql           -- Updated theme seed with version + changelog
  053_seed_classic_schema.sql      -- Classic theme full config_schema
  054_seed_floral_schema.sql       -- Floral theme full config_schema
  055_seed_modern_schema.sql       -- Modern theme full config_schema
  056_seed_rustic_schema.sql       -- Rustic (premium) theme full config_schema
```

## Appendix B — Theme Component Checklist

Every new theme must implement:

- [ ] `ThemeShell` — CSS variable injection, font loading, root layout
- [ ] `HeroSection` — Full-viewport opening with couple names
- [ ] `CoupleSection` — Photos + names + parents
- [ ] `EventDetailsSection` — Date, time, venue, maps button
- [ ] `LoveStorySection` — Timeline or narrative format (feature-gated)
- [ ] `GallerySection` — Grid/masonry/carousel (feature-gated, quota-aware)
- [ ] `CountdownSection` — Days until event
- [ ] `MusicSection` — Audio player integration (feature-gated)
- [ ] `RsvpSection` — Shared RsvpForm component integration
- [ ] `GuestbookSection` — Shared GuestbookWall component integration (feature-gated)
- [ ] `GiftSection` — Bank, QRIS, e-wallet display (feature-gated)
- [ ] `ClosingSection` — Closing text + hashtag + platform badge
- [ ] `config_schema` — Complete JSON schema for all customizable fields
- [ ] `defaultConfig` — TypeScript object with all defaults
- [ ] Preview image (800×600, JPEG, < 1MB)
- [ ] Thumbnail image (400×300, JPEG, < 300KB)
- [ ] Mobile LCP < 1.5s verified on simulated Moto G4 throttled 3G
- [ ] `prefers-reduced-motion` respected on all animations
- [ ] Platform badge rendered in ClosingSection (hidden by feature flag)
- [ ] TypeScript: zero `any` types in component props

## Appendix C — Property Panel Field Type Reference

| Field Type | Component | Use Case | Validation |
|---|---|---|---|
| `color` | `<ColorField>` | Any hex color token | Regex `#[0-9A-Fa-f]{6}`, contrast warning |
| `font_select` | `<FontSelectField>` | Font family selection | Must be in FONT_REGISTRY |
| `text` | `<TextInputField>` | Short labels, copy | Max 200 chars |
| `textarea` | `<TextareaField>` | Longer messages | Max 1000 chars |
| `toggle` | `<ToggleField>` | Boolean on/off options | Boolean |
| `range` | `<RangeField>` | Opacity, percentage values | min/max/step bounds |
| `select` | `<SelectField>` | Enum choices (layout styles) | Must be in options[] |
| `image_upload` | `<ImageUploadField>` | Photos, backgrounds | JPEG/PNG/WebP, size limit |
| `number` | `<NumberInputField>` | Numeric configuration | min/max bounds |
| `spacing` | `<SpacingField>` | Section gap selection | Must be in SECTION_SPACING keys |

---

*End of PHASE6_THEME_SYSTEM.md*
