# M0_FOUNDATION.md
# Wedding Invitation SaaS Platform — Milestone M0: Program & Infrastructure Bootstrap

> **Version:** 1.0.0
> **Implementation authority:** BUILD_ORDER.md — Phase A (`= M0` in IMPLEMENTATION_ROADMAP.md)
> **Upstream source documents:** PHASE1_ARCHITECTURE.md (§3, §8.2, §10.1, §10.2), PHASE12_DEPLOYMENT.md (§3.3, §4, §5.1, §7.4, §8, Appendix A)
> **Scope boundary:** This document specifies **only** Phase A of BUILD_ORDER.md. No table, RLS policy, API route, business-logic function, or UI component is created in this milestone — those begin at Phase B onward. No architectural decision is introduced, altered, or reinterpreted here; every configuration value below traces to a cited section of the source documents. **No application code is included in this document** — only folder/file scaffolding, configuration file contents, dependency manifests, and shell commands.

---

## 1. Milestone Scope

**Goal (BUILD_ORDER Phase A):** Stand up the infrastructure substrate so that Phase B onward has a real place to deploy to.

**Dependencies:** None — this is the first milestone.

**In scope:**
- Terraform module/environment scaffold (no resources applied beyond empty/zero-drift baseline).
- Empty Supabase production + staging projects (no schema).
- Empty Next.js 14 App Router project scaffold (no routes, no components, no business logic).
- Secrets vault bootstrap.
- `lib/supabase/client.ts`, `server.ts`, `middleware.ts` as **empty stub files** (signatures only, per Phase B).
- `components/ui/` directory scaffold (shadcn/ui base, no components implemented).
- First CI Stage 1 pass and first staging deploy of the empty app.

**Explicitly out of scope (deferred to later phases per BUILD_ORDER):**
- Any database table (Phase B).
- Any API route implementation (Phase B onward).
- Google OAuth provider configuration (Phase B, BUILD_ORDER §4 Auth build order step 1).
- Security headers / CSP (Phase N, PHASE12 §7.5).
- Redis, Resend, Sentry, PostHog, payment gateway, or analytics credentials (Phases B, L, M, N respectively per BUILD_ORDER §7 Secrets).

---

## 2. Exact Folder Structure

```
wedding-saas/
├── infra/
│   ├── terraform/
│   │   ├── modules/
│   │   │   ├── cloudflare/
│   │   │   ├── vercel/
│   │   │   ├── upstash/
│   │   │   └── monitoring/
│   │   ├── environments/
│   │   │   ├── production/
│   │   │   ├── staging/
│   │   │   └── preview/
│   │   ├── backend.tf
│   │   └── variables.tf
│   └── supabase/
│       ├── migrations/        (empty — ready for Phase B)
│       ├── seed.sql
│       └── config.toml
├── lib/
│   └── supabase/
│       ├── client.ts           (stub)
│       ├── server.ts           (stub)
│       └── middleware.ts       (stub)
├── components/
│   └── ui/                     (shadcn/ui base scaffold — empty)
├── .env.example
├── next.config.ts
├── tailwind.config.ts
├── tsconfig.json
└── package.json
```

This tree reproduces, without modification, the exact file list given under BUILD_ORDER Phase A → "Files to create." No path has been renamed, nested, or relocated.

---

## 3. Exact File Structure

| Path | Type | Status at end of M0 | Populated further in |
|---|---|---|---|
| `infra/terraform/modules/cloudflare/` | Terraform module dir | Empty placeholder (`.gitkeep`) | Phase N |
| `infra/terraform/modules/vercel/` | Terraform module dir | Empty placeholder (`.gitkeep`) | Phase N |
| `infra/terraform/modules/upstash/` | Terraform module dir | Empty placeholder (`.gitkeep`) | Phase N |
| `infra/terraform/modules/monitoring/` | Terraform module dir | Empty placeholder (`.gitkeep`) | Phase N |
| `infra/terraform/environments/production/` | Terraform env dir | Empty placeholder (`.gitkeep`) | Phase N |
| `infra/terraform/environments/staging/` | Terraform env dir | Empty placeholder (`.gitkeep`) | Phase N |
| `infra/terraform/environments/preview/` | Terraform env dir | Empty placeholder (`.gitkeep`) | Phase N |
| `infra/terraform/backend.tf` | Terraform config | Full content (§6 below) | — |
| `infra/terraform/variables.tf` | Terraform config | Full content (§6 below) | Phase N |
| `infra/supabase/migrations/` | SQL migration dir | Empty — zero files | Phase B (`091`+ in Phase L, `106`+ in Phase M) |
| `infra/supabase/seed.sql` | SQL seed file | Empty placeholder | Phase B |
| `infra/supabase/config.toml` | Supabase CLI config | Full content (§7 below) | — |
| `.env.example` | Env template | Full content (§5 below), no real values | Phase B/L/M/N append more keys |
| `next.config.ts` | Next.js config | Full content (§8 below) | Phase N (security headers) |
| `tailwind.config.ts` | Tailwind config | Full content (§8 below) | — |
| `tsconfig.json` | TypeScript config | Full content (§8 below) | — |
| `package.json` | npm manifest | Full content (§4 below) | Every later phase adds deps |
| `lib/supabase/client.ts` | TS stub | Empty signature stub, no logic | Phase B |
| `lib/supabase/server.ts` | TS stub | Empty signature stub, no logic (will hold `createAdminClient()`, PHASE1 §8.2) | Phase B |
| `lib/supabase/middleware.ts` | TS stub | Empty signature stub, no logic | Phase B |
| `components/ui/` | Directory | shadcn/ui scaffold only, zero components | Phase B onward |

**Database changes in this milestone:** None. Two empty Supabase projects are provisioned (no tables, no RLS) — see §7.

**API endpoints in this milestone:** None.

**Components in this milestone:** None implemented — only the `components/ui/` directory scaffold exists.

**Services in this milestone:** None implemented — `createAdminClient()` exists only as a named stub in `lib/supabase/server.ts`, not yet called from any route (PHASE1 §8.2).

---

## 4. Exact Package Dependencies

`package.json` (root, per BUILD_ORDER Phase A):

```json
{
  "name": "wedding-saas",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "start": "next start",
    "lint": "next lint",
    "type-check": "tsc --noEmit",
    "format": "prettier --write .",
    "format:check": "prettier --check ."
  },
  "dependencies": {
    "next": "14.2.5",
    "react": "18.3.1",
    "react-dom": "18.3.1",
    "@supabase/supabase-js": "2.43.4",
    "@supabase/ssr": "0.3.0"
  },
  "devDependencies": {
    "typescript": "5.4.5",
    "@types/node": "20.12.7",
    "@types/react": "18.2.79",
    "@types/react-dom": "18.2.25",
    "tailwindcss": "3.4.3",
    "postcss": "8.4.38",
    "autoprefixer": "10.4.19",
    "eslint": "8.57.0",
    "eslint-config-next": "14.2.5",
    "prettier": "3.2.5"
  }
}
```

**Rule (PHASE12 §7.4):** the generated `package-lock.json` is committed and verified in CI via `npm ci` — never `npm install` in CI. Dependency versions are pinned, not floating, and bumped deliberately.

**Not installed at this milestone** (introduced by later phases per BUILD_ORDER §7 Secrets/§4 Backend Build Order, listed here only to mark the boundary, not to install now):
- `zod` — first used in Phase H/L route validation.
- `@upstash/redis`, `@upstash/ratelimit` — first used in Phase F (cache) / Phase M (rate limiting).
- Payment gateway SDKs/fetch wrappers — Phase L.
- `ts-morph` — Phase N (`scripts/audit-service-role-usage.ts`).

---

## 5. Exact Environment Variables

### 5.1 `.env.example` (committed to git, no real values — PHASE12 §4.4)

```bash
# Supabase
NEXT_PUBLIC_SUPABASE_URL=
NEXT_PUBLIC_SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=

# App
NEXT_PUBLIC_APP_URL=
NEXT_PUBLIC_APP_DOMAIN=
```

These five variables are the minimum required for `lib/supabase/client.ts`, `server.ts`, and `middleware.ts` to be wired in Phase B against the Supabase projects provisioned in this milestone. All other application variables (`RESEND_API_KEY`, `UPSTASH_REDIS_REST_URL`, `UPSTASH_REDIS_REST_TOKEN`, `SENTRY_DSN`, `NEXT_PUBLIC_POSTHOG_KEY`, payment gateway keys, analytics keys, infra/ops keys) are **out of scope for M0** and are introduced in Phases B, L, M, and N respectively, exactly as sequenced in BUILD_ORDER §7 "Secrets."

### 5.2 Vault-only infrastructure credentials (never in `.env.example`, never committed)

Required to execute this milestone's own Terraform applies (PHASE12 Appendix A, §3.3, §8):

```bash
TF_CLOUD_API_TOKEN=
CLOUDFLARE_API_TOKEN=
VERCEL_API_TOKEN=
UPSTASH_API_KEY=
DOPPLER_TOKEN=                       # or 1PASSWORD_SERVICE_ACCOUNT_TOKEN
```

These five live exclusively in the secrets vault (Doppler or 1Password) and are read by Terraform/CI at apply time — never hand-typed into a dashboard, never pasted into Slack, never committed (PHASE12 §4.4, §8.2).

---

## 6. Exact Infrastructure Configuration (Terraform)

`infra/terraform/backend.tf`:

```hcl
terraform {
  cloud {
    organization = "weddingplatform"
    workspaces {
      tags = ["wedding-saas"]
    }
  }

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    vercel = {
      source  = "vercel/vercel"
      version = "~> 1.0"
    }
    upstash = {
      source  = "upstash/upstash"
      version = "~> 1.0"
    }
  }

  required_version = ">= 1.7.0"
}
```

`infra/terraform/variables.tf`:

```hcl
variable "environment" {
  description = "Deployment environment: production | staging | preview"
  type        = string
}

variable "project_name" {
  description = "Platform project name"
  type        = string
  default     = "wedding-saas"
}

variable "region" {
  description = "Primary infrastructure region"
  type        = string
  default     = "ap-southeast-1"
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token (sourced from vault, never hardcoded)"
  type        = string
  sensitive   = true
}

variable "vercel_api_token" {
  description = "Vercel API token (sourced from vault, never hardcoded)"
  type        = string
  sensitive   = true
}

variable "upstash_api_key" {
  description = "Upstash API key (sourced from vault, never hardcoded)"
  type        = string
  sensitive   = true
}

variable "root_domain" {
  description = "Platform root domain"
  type        = string
  default     = "weddingplatform.com"
}
```

Provider/version pinning here satisfies PHASE12 §7.4 ("Supabase/Vercel/Cloudflare/Upstash provider versions pinned in Terraform; bumped deliberately, not floating").

At the end of this milestone, `infra/terraform/modules/{cloudflare,vercel,upstash,monitoring}/` and `infra/terraform/environments/{production,staging,preview}/` contain **no resource definitions yet** — only directory placeholders (`.gitkeep`). Module/resource content is added starting Phase N (BUILD_ORDER Phase N "Infrastructure tasks: Finalize Terraform modules"). `terraform plan` at this milestone must report **zero drift** because there is nothing yet to drift from.

---

## 7. Exact Supabase Configuration

### 7.1 Cloud Project Provisioning (PHASE1 §10.1)

| Parameter | Production | Staging |
|---|---|---|
| Project count | 1 | 1 (separate project) |
| Region | `ap-southeast-1` (Singapore) | `ap-southeast-1` (Singapore) |
| Plan tier | Pro (required for daily automated backups, PHASE1 §10.1) | Pro |
| Connection pooling | PgBouncer, transaction mode (PHASE1 §10.1) | PgBouncer, transaction mode |
| Schema at end of M0 | None — zero tables | None — zero tables |

### 7.2 `infra/supabase/config.toml`

```toml
project_id = "wedding-saas"

[api]
enabled = true
port = 54321
schemas = ["public", "storage", "graphql_public"]
extra_search_path = ["public", "extensions"]
max_rows = 1000

[db]
port = 54322
shadow_port = 54320
major_version = 15

[studio]
enabled = true
port = 54323

[inbucket]
enabled = true
port = 54324

[storage]
enabled = true
file_size_limit = "50MiB"

[auth]
enabled = true
site_url = "http://localhost:3000"
additional_redirect_urls = [
  "https://staging.weddingplatform.com",
  "https://app.weddingplatform.com"
]
jwt_expiry = 3600
enable_signup = true

[auth.email]
enable_signup = true
double_confirm_changes = true
enable_confirmations = false

[edge_functions]
enabled = true
```

**Explicitly excluded at this milestone:** the `[auth.external.google]` provider block. Google OAuth configuration belongs to Phase B (BUILD_ORDER §4 Backend Build Order → Auth, step 1: "Configure Supabase Auth (email/password + Google OAuth) (Phase B)") and is not added here.

### 7.3 `infra/supabase/migrations/` and `infra/supabase/seed.sql`

Both exist as empty artifacts at the end of M0. The first migration file is written in Phase B (BUILD_ORDER §3 Migration Order, "Phase B (PHASE1 baseline)").

---

## 8. Exact Next.js Configuration

### 8.1 `next.config.ts`

```ts
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  images: {
    remotePatterns: [
      {
        protocol: "https",
        hostname: "*.supabase.co",
      },
    ],
  },
};

export default nextConfig;
```

**Explicitly excluded at this milestone:** the security headers block (`X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`, `Content-Security-Policy`, `Strict-Transport-Security`). That block is added in Phase N per BUILD_ORDER Phase N file list (`next.config.ts — security headers block added`) and PHASE12 §7.5. Adding it now would be out of sequence.

### 8.2 `tailwind.config.ts`

```ts
import type { Config } from "tailwindcss";

const config: Config = {
  content: [
    "./app/**/*.{js,ts,jsx,tsx,mdx}",
    "./components/**/*.{js,ts,jsx,tsx,mdx}",
    "./lib/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {},
  },
  plugins: [],
};

export default config;
```

### 8.3 `tsconfig.json`

```json
{
  "compilerOptions": {
    "target": "ES2017",
    "lib": ["dom", "dom.iterable", "esnext"],
    "allowJs": true,
    "skipLibCheck": true,
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "module": "esnext",
    "moduleResolution": "bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "jsx": "preserve",
    "incremental": true,
    "plugins": [{ "name": "next" }],
    "paths": {
      "@/*": ["./*"]
    }
  },
  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
  "exclude": ["node_modules"]
}
```

The `"@/*": ["./*"]` path alias is required because later phases' files import via this exact alias (e.g. `@/lib/supabase/server`, `@/lib/billing/...`, `@/lib/analytics/...` as used throughout PHASE10/PHASE11). Establishing it now prevents a breaking path change later.

---

## 9. Exact Setup Commands

Run in this exact order.

```bash
# ── 1. Secrets vault bootstrap ────────────────────────────────────────
doppler login
doppler setup --project wedding-saas --config dev

# ── 2. Supabase cloud project provisioning ────────────────────────────
supabase login
supabase projects create wedding-saas-production --org-id <ORG_ID> --region ap-southeast-1 --plan pro
supabase projects create wedding-saas-staging    --org-id <ORG_ID> --region ap-southeast-1 --plan pro

# ── 3. Repository root scaffold ────────────────────────────────────────
mkdir wedding-saas && cd wedding-saas
git init

# ── 4. Next.js 14 App Router scaffold ───────────────────────────────────
npx create-next-app@14 . --typescript --tailwind --eslint --app --no-src-dir --import-alias "@/*"

# ── 5. Install Supabase client libraries ────────────────────────────────
npm install @supabase/supabase-js@2.43.4 @supabase/ssr@0.3.0

# ── 6. Install dev tooling ────────────────────────────────────────────────
npm install -D prettier@3.2.5

# ── 7. Create lib/supabase stub files ──────────────────────────────────────
mkdir -p lib/supabase
touch lib/supabase/client.ts lib/supabase/server.ts lib/supabase/middleware.ts

# ── 8. Scaffold shadcn/ui base design system (components/ui/) ──────────────
npx shadcn-ui@latest init

# ── 9. Create environment template ──────────────────────────────────────────
touch .env.example
# populate per §5.1 above — no real values committed

# ── 10. Initialize local Supabase CLI config ─────────────────────────────────
mkdir -p infra/supabase
cd infra/supabase
supabase init
supabase link --project-ref <STAGING_PROJECT_REF>
cd ../..

# ── 11. Scaffold Terraform ──────────────────────────────────────────────────
mkdir -p infra/terraform/modules/cloudflare
mkdir -p infra/terraform/modules/vercel
mkdir -p infra/terraform/modules/upstash
mkdir -p infra/terraform/modules/monitoring
mkdir -p infra/terraform/environments/production
mkdir -p infra/terraform/environments/staging
mkdir -p infra/terraform/environments/preview
cd infra/terraform
terraform init
terraform workspace new staging
terraform workspace new production
terraform plan -var="environment=staging" -var="cloudflare_api_token=$CLOUDFLARE_API_TOKEN" -var="vercel_api_token=$VERCEL_API_TOKEN" -var="upstash_api_key=$UPSTASH_API_KEY"
cd ../..

# ── 12. Link Vercel project and push baseline env vars ─────────────────────
vercel login
vercel link
vercel env add NEXT_PUBLIC_SUPABASE_URL staging
vercel env add NEXT_PUBLIC_SUPABASE_ANON_KEY staging
vercel env add SUPABASE_SERVICE_ROLE_KEY staging
vercel env add NEXT_PUBLIC_APP_URL staging
vercel env add NEXT_PUBLIC_APP_DOMAIN staging

# ── 13. Commit and push ─────────────────────────────────────────────────────
git add .
git commit -m "M0: program and infrastructure bootstrap"
git remote add origin <REPO_URL>
git push -u origin main

# ── 14. First CI run + first deploy ─────────────────────────────────────────
npm run type-check
npm run lint
npm run format:check
npm audit --audit-level=high
npm run build
vercel --prod=false
```

---

## 10. Acceptance Criteria

This milestone is complete only when **every** item below is true.

### Folder / file structure
- [ ] `infra/terraform/modules/{cloudflare,vercel,upstash,monitoring}/` exist (placeholder only).
- [ ] `infra/terraform/environments/{production,staging,preview}/` exist (placeholder only).
- [ ] `infra/terraform/backend.tf` and `infra/terraform/variables.tf` exist with the exact content in §6.
- [ ] `infra/supabase/migrations/` exists and contains zero files.
- [ ] `infra/supabase/seed.sql` exists and is empty.
- [ ] `infra/supabase/config.toml` exists with the exact content in §7.2 (no `[auth.external.google]` block).
- [ ] `.env.example` exists with the exact five keys in §5.1, no real values.
- [ ] `next.config.ts`, `tailwind.config.ts`, `tsconfig.json`, `package.json` exist with the exact content in §4/§8.
- [ ] `lib/supabase/client.ts`, `server.ts`, `middleware.ts` exist as empty stubs with zero implementation logic.
- [ ] `components/ui/` exists as a shadcn/ui scaffold with zero implemented components.

### Database
- [ ] Supabase production project provisioned, `ap-southeast-1`, Pro tier, zero tables.
- [ ] Supabase staging project provisioned, `ap-southeast-1`, Pro tier, zero tables.
- [ ] PgBouncer transaction-mode pooling enabled on both projects.

### Infrastructure
- [ ] `terraform plan` exits clean (zero drift) for both `staging` and `production` workspaces.
- [ ] Secrets vault (Doppler/1Password) operational; the five vault-only credentials in §5.2 are stored there and nowhere else.
- [ ] No real secret value exists in git history (verified via a history scan, not just current-state inspection).

### Application shell
- [ ] `npm run type-check` (`tsc --noEmit`) passes with zero errors.
- [ ] `npm run lint` passes with zero warnings.
- [ ] `npm run format:check` passes.
- [ ] `npm audit --audit-level=high` reports zero high/critical vulnerabilities.
- [ ] `npm run build` succeeds.
- [ ] The empty application deploys successfully to `staging.weddingplatform.com` via Vercel.

### Negative checks (must remain true at end of M0)
- [ ] Zero database tables exist beyond the empty project shell.
- [ ] Zero API routes are implemented.
- [ ] Zero UI components are implemented.
- [ ] `createAdminClient()` is not referenced or called anywhere in the codebase — it does not exist yet as a function, only as a planned stub location.
- [ ] No security-header configuration is present in `next.config.ts`.
- [ ] No Google OAuth configuration is present in `config.toml`.

**Once every box above is checked, Phase B (Core Multi-Tenant Foundation) may begin.**

---

*End of M0_FOUNDATION.md*
