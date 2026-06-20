# PHASE12_DEPLOYMENT.md
# Wedding Invitation SaaS Platform — Production Deployment & Operations Architecture

> **Version:** 1.0.0
> **Date:** 2026-06-18
> **Status:** Approved for Development
> **Depends on:** PHASE1_ARCHITECTURE.md, PHASE2_DATABASE.md, PHASE3_AUTH.md, PHASE4_ADMIN_ARCHITECTURE.md, PHASE5_PACKAGE_FEATURE_SYSTEM.md, PHASE6_THEME_SYSTEM.md, PHASE7_INVITATION_MANAGEMENT.md, PHASE8_GUEST_MANAGEMENT.md, PHASE9_RSVP_GUESTBOOK.md, PHASE10_PAYMENT_SYSTEM.md, PHASE11_ANALYTICS.md

> **This document formalizes the operational layer underneath every prior phase.** It does not introduce new product features. It answers: how the application defined in PHASE1–11 actually runs in production, how it deploys safely, how it is secured at the infrastructure level (as distinct from the application-level RLS/RBAC already specified), how it is observed, how it survives failure, and how it scales. Where a prior phase already made an infrastructure decision (e.g. PHASE1 §10 deployment architecture, PHASE7 ISR strategy, PHASE10/11 Edge Function cron jobs), this phase reuses and formalizes it rather than re-deciding it.

---

## Table of Contents

1. [Deployment Architecture Overview](#1-deployment-architecture-overview)
2. [Design Principles & Trade-offs](#2-design-principles--trade-offs)
3. [Cloud-Agnostic Infrastructure Architecture](#3-cloud-agnostic-infrastructure-architecture)
4. [Environment Strategy](#4-environment-strategy)
5. [CI/CD Pipeline](#5-cicd-pipeline)
6. [Database Migration & Release Strategy](#6-database-migration--release-strategy)
7. [Security Architecture](#7-security-architecture)
8. [Secrets Management](#8-secrets-management)
9. [Multi-Tenant Deployment Model](#9-multi-tenant-deployment-model)
10. [Monitoring & Observability](#10-monitoring--observability)
11. [Logging Architecture](#11-logging-architecture)
12. [Alerting & On-Call](#12-alerting--on-call)
13. [Backup & Disaster Recovery](#13-backup--disaster-recovery)
14. [High Availability Architecture](#14-high-availability-architecture)
15. [Scaling Strategy](#15-scaling-strategy)
16. [Incident Response & Runbooks](#16-incident-response--runbooks)
17. [Cost Architecture](#17-cost-architecture)
18. [Compliance & Data Residency](#18-compliance--data-residency)
19. [Pre-Production Launch Checklist](#19-pre-production-launch-checklist)
20. [Appendices](#20-appendices)

---

## 1. Deployment Architecture Overview

### 1.1 Scope of This Phase

PHASE1 §10 already established the baseline: Vercel + Supabase + Cloudflare + Upstash + Resend. PHASE12 takes that baseline to production-grade by specifying:

- How code moves from commit to production safely (CI/CD, §5)
- How the database schema moves forward without downtime (§6)
- How the platform is secured at the network/infra layer, on top of the RLS/RBAC already built (§7)
- How failures are detected before users report them (§10–12)
- How data survives provider outages, corruption, or operator error (§13)
- How the system absorbs 10×, 50×, 100× current load without architectural rewrite (§15)

This phase is **cloud-agnostic by design**: every primitive used (object storage, managed Postgres, edge functions, CDN, queue, secrets store) has a named primary (Vercel/Supabase, matching PHASE1) and an explicit portability path to AWS/GCP/Azure/self-hosted equivalents, so the architecture is not a hidden single-vendor lock-in even though the default stack is opinionated.

### 1.2 System Deployment Topology

```
┌────────────────────────────────────────────────────────────────────────┐
│                          DEPLOYMENT TOPOLOGY                           │
│                                                                        │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │  EDGE / CDN TIER                                                │    │
│  │  Cloudflare (DNS, WAF, DDoS) → Vercel Edge Network (CDN, ISR)  │    │
│  └──────────────────────────────┬───────────────────────────────┘    │
│                                  │                                      │
│  ┌──────────────────────────────▼───────────────────────────────┐    │
│  │  COMPUTE TIER                                                   │    │
│  │  Vercel Serverless Functions (API routes) — auto-scaled,       │    │
│  │  stateless, region-pinned to ap-southeast-1 (Singapore)        │    │
│  └──────────────────────────────┬───────────────────────────────┘    │
│                                  │                                      │
│  ┌──────────────────────────────▼───────────────────────────────┐    │
│  │  BACKGROUND / ASYNC TIER                                        │    │
│  │  Supabase Edge Functions (Deno) — cron jobs, webhooks,          │    │
│  │  rollups (PHASE10 §8, PHASE11 §5), exports (PHASE11 §13)       │    │
│  └──────────────────────────────┬───────────────────────────────┘    │
│                                  │                                      │
│  ┌──────────────────────────────▼───────────────────────────────┐    │
│  │  DATA TIER                                                       │    │
│  │  Supabase Postgres (primary + read replica) · Storage (S3-     │    │
│  │  compatible) · Realtime · Auth                                  │    │
│  └──────────────────────────────┬───────────────────────────────┘    │
│                                  │                                      │
│  ┌──────────────────────────────▼───────────────────────────────┐    │
│  │  CACHING / EPHEMERAL TIER                                        │    │
│  │  Upstash Redis (feature cache, rate limiting, view-count buffer)│    │
│  └──────────────────────────────────────────────────────────────┘    │
│                                                                        │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │  EXTERNAL SERVICE TIER                                          │    │
│  │  Resend (email) · Midtrans/Xendit (payments) · Sentry (errors) │    │
│  │  Better Stack/Grafana (metrics) · PagerDuty (on-call)           │    │
│  └──────────────────────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────────────────────┘
```

### 1.3 Request Lifecycle (Production)

```
Browser/WhatsApp → DNS (Cloudflare) → TLS termination (Cloudflare/Vercel edge)
  → WAF rule evaluation (bot/DDoS filter)
  → Vercel Edge Middleware (tenant resolution, JWT validation — PHASE1 §2.4, §2.2)
  → Routed to: Static ISR cache (public invitation pages, PHASE1 §10.5)
              OR Serverless Function (API routes, dashboard SSR)
  → Serverless Function calls Supabase (Postgres via PgBouncer, or Storage, or Auth)
  → Response cached at edge (where ISR-eligible) or streamed directly
```

### 1.4 Relationship to Prior Phases — What This Phase Does Not Redo

| Already Decided In | Decision | PHASE12 Action |
|---|---|---|
| PHASE1 §2, §10 | Vercel + Supabase + Cloudflare + Upstash + Resend stack; subdomain tenant resolution; RLS isolation | Adopted as-is; hardened with explicit SLOs, failover, and IaC (§3, §14) |
| PHASE1 §10.5 | ISR (60s) for public invitation pages | Reused; extended with multi-region cache invalidation strategy (§15.4) |
| PHASE7 (perf posture) | Core Web Vitals targets, no-blocking-analytics invariant | Reused as the SLO basis for synthetic monitoring (§10.4) |
| PHASE9 §15 / PHASE10 §18 / PHASE11 §18 | Per-domain scalability projections (RSVP, billing, analytics volume) | Composed into one platform-wide capacity model (§15.1) |
| PHASE10 §16, PHASE11 §16 | Service-role containment pattern (admin clients only in Edge Functions / `/api/admin/*`) | Elevated to a platform-wide security invariant, audited at the infra level (§7.6) |
| PHASE5 §12 | Redis feature-cache, materialized view scaling path | Reused as one input into the general caching/scaling strategy (§15.3) |

No table, RLS policy, or feature key from PHASE1–11 is altered by this phase.

---

## 2. Design Principles & Trade-offs

| Decision | Options Considered | Choice | Reason |
|---|---|---|---|
| Cloud strategy | Single-vendor lock-in vs full multi-cloud abstraction vs "cloud-agnostic primitives, opinionated default" | Opinionated default (Vercel/Supabase) with named portability path per primitive | Full abstraction (e.g. Terraform modules for 3 clouds from day one) adds engineering cost with no near-term buyer; a documented swap path captures most of the optionality at a fraction of the cost |
| Infrastructure-as-Code | Manual console config vs full IaC | Full IaC (Terraform for Cloudflare/Vercel/Upstash projects; Supabase CLI migrations for DB) | Manual config is the single largest source of unreproducible production incidents; IaC makes environments diffable and DR-rebuildable |
| Deployment strategy | Big-bang deploy vs blue-green vs canary | Vercel's native atomic deploy + instant rollback (effectively blue-green at the edge) for app code; expand/contract migrations for DB (§6) | Vercel's immutable deployment model already gives blue-green semantics for free; reinventing it adds no value |
| Multi-region compute | Single-region vs active-active multi-region | Single primary region (ap-southeast-1) for writes, with edge-cached reads globally | Tenant base is Indonesia-concentrated (per PHASE10 currency/payment-method choices); active-active write topology adds conflict-resolution complexity not justified by current latency requirements — documented as the Year-3 scaling path (§15.5), not built now |
| Database HA | Single instance vs primary+replica vs multi-primary | Primary + same-region read replica + cross-region physical backup | Matches Supabase's supported HA tier; multi-primary (e.g. CockroachDB-style) is unnecessary complexity for a single-region-write workload |
| Disaster recovery target | Best-effort vs formal RPO/RTO | Formal RPO ≤ 5 min, RTO ≤ 60 min for full regional loss (§13.1) | A billing-bearing SaaS platform (PHASE10) cannot operate on "we'll figure it out" — formal targets force the backup architecture to actually meet them |
| Secrets storage | `.env` files in CI vs dedicated secrets manager | Dedicated secrets manager (Vercel encrypted env vars + Doppler/1Password for cross-system sync) | `.env`-in-CI is the most common source of credential leaks in serverless deployments; centralizing avoids drift between Vercel/Supabase/Upstash secret copies |
| Observability stack | Build vs buy | Buy (Sentry + Vercel Analytics + Better Stack/Grafana Cloud + Supabase built-in metrics) | At this team size, building observability tooling is pure opportunity cost; all chosen tools have generous free/low tiers and zero-infra-to-manage footprints |
| Logging retention | Indefinite vs tiered | Tiered: 30 days hot (queryable), 1 year cold (compliance/audit), aligned with PHASE11 §19 retention philosophy | Mirrors the "no hardcoded forever-retention" principle already established for analytics data |

---

## 3. Cloud-Agnostic Infrastructure Architecture

### 3.1 Primitive-to-Provider Mapping

Every infrastructure primitive is named generically first, then mapped to the chosen default provider and an explicit alternative. This is the cloud-agnostic contract: application code talks to the **primitive's interface** (e.g. "S3-compatible object storage," "Postgres-compatible relational DB"), never to a provider-specific SDK quirk where avoidable.

| Primitive | Default Provider | Alternative (Portability Path) |
|---|---|---|
| Compute (serverless functions) | Vercel Functions | AWS Lambda + API Gateway, Cloudflare Workers, Google Cloud Run |
| Static/CDN edge | Vercel Edge Network | Cloudflare Pages, AWS CloudFront + S3 |
| Relational database | Supabase Postgres | AWS RDS Postgres, Google Cloud SQL, self-hosted Postgres + PgBouncer |
| Object storage | Supabase Storage (S3-compatible) | AWS S3, Google Cloud Storage, Cloudflare R2 |
| Auth | Supabase Auth | Auth0, AWS Cognito, self-hosted (e.g. Ory, Keycloak) |
| Realtime / pub-sub | Supabase Realtime | AWS AppSync, Pusher, self-hosted (Postgres LISTEN/NOTIFY + WebSocket gateway) |
| Background jobs / cron | Supabase Edge Functions (Deno) | AWS Lambda + EventBridge, Google Cloud Functions + Cloud Scheduler |
| Cache / rate-limit store | Upstash Redis | AWS ElastiCache, Google Memorystore, self-hosted Redis |
| DNS / WAF / DDoS | Cloudflare | AWS Route53 + Shield + WAF, Google Cloud Armor |
| Transactional email | Resend | AWS SES, SendGrid, Postmark |
| Payments | Midtrans / Xendit (PHASE10 §4) | Stripe (already prepared as secondary in PHASE10 §18.4) |
| Error monitoring | Sentry | Self-hosted Sentry, Rollbar, Datadog Error Tracking |
| Metrics / dashboards | Vercel Analytics + Grafana Cloud / Better Stack | Self-hosted Grafana + Prometheus, Datadog |
| Secrets manager | Vercel encrypted env vars + Doppler | AWS Secrets Manager, HashiCorp Vault, Google Secret Manager |
| Infrastructure-as-Code | Terraform (Cloudflare, Upstash, Vercel providers) + Supabase CLI | Pulumi, AWS CDK |

### 3.2 Why This Counts as Cloud-Agnostic Without Being Multi-Cloud-Today

The platform runs on one set of providers today — that is a cost and velocity decision appropriate for current scale, not a contradiction of "cloud-agnostic." Cloud-agnostic here means: **no application code, database schema, or business logic assumes a specific cloud vendor's proprietary API.** Concretely:

- All database access goes through standard Postgres wire protocol + the Supabase JS client, which is a thin wrapper — a migration to RDS Postgres changes only the connection string and the `createServerClient()`/`createAdminClient()` implementations in `lib/supabase/*` (PHASE1 §3 folder structure), not any query, RLS policy, or business logic.
- Object storage usage (invoice PDFs, analytics exports, gallery photos) uses S3-compatible APIs exclusively — Supabase Storage, AWS S3, and Cloudflare R2 are interchangeable behind the same `storage.from(bucket).upload()`-style interface.
- Edge Functions are plain Deno/TypeScript with no Supabase-proprietary runtime API beyond the admin client invocation — portable to any Deno-compatible or Node-compatible serverless runtime with a thin adapter.
- Feature flags, pricing, and quotas are 100% database-driven (PHASE5 §1.1) — there is no vendor-specific feature-flagging SaaS dependency to migrate away from.

### 3.3 Infrastructure-as-Code Layout

```
infra/
├── terraform/
│   ├── modules/
│   │   ├── cloudflare/          # DNS records, WAF rules, page rules
│   │   ├── vercel/               # Project config, env var references, domains
│   │   ├── upstash/               # Redis database provisioning
│   │   └── monitoring/             # Grafana Cloud / Better Stack dashboards as code
│   ├── environments/
│   │   ├── production/
│   │   ├── staging/
│   │   └── preview/                # ephemeral, PR-scoped (see §4.3)
│   ├── backend.tf                   # Remote state (Terraform Cloud or S3+DynamoDB lock)
│   └── variables.tf
├── supabase/
│   ├── migrations/                  # SQL migrations (PHASE2–11 appendices, chronological)
│   ├── seed.sql
│   └── config.toml
└── scripts/
    ├── dr-restore.sh                 # Disaster recovery restore automation (§13.4)
    ├── pre-deploy-check.sh           # Migration safety lint (§6.4)
    └── smoke-test.sh                  # Post-deploy synthetic checks (§5.5)
```

All infrastructure changes — DNS, WAF rules, Redis instance sizing, Vercel project settings — go through a Terraform PR with the same review gate as application code. Console/dashboard manual changes are treated as configuration drift and are flagged by a nightly `terraform plan` diff job (§5.6).

---

## 4. Environment Strategy

### 4.1 Environment Tiers

```
production   → app.weddingplatform.com, *.weddingplatform.com           (real tenants, real money)
staging      → staging.weddingplatform.com                              (pre-prod validation, synthetic data)
preview      → preview-<pr-number>.vercel.app                            (per-PR, ephemeral, auto-destroyed)
local        → developer machine, Supabase local CLI (Docker)            (no shared state)
```

### 4.2 Environment Parity

| Aspect | Production | Staging | Preview | Local |
|---|---|---|---|---|
| Database | Supabase prod project | Supabase staging project (separate, same region) | Branched DB (Supabase branching) or shared staging DB with tenant-scoped seed | Supabase CLI local Postgres (Docker) |
| Payment gateway | Live Midtrans/Xendit keys | Sandbox keys (PHASE10 Appendix C) | Sandbox keys | Sandbox keys, mocked where possible |
| Email | Live Resend, real domain | Resend test mode / sandboxed domain | Suppressed or routed to a test inbox | Suppressed (logged to console) |
| Redis | Upstash production instance | Upstash staging instance | Shared staging Redis with PR-prefixed keys, or in-memory mock | In-memory mock |
| Feature flags | Real package/feature seed | Mirrors production seed via nightly sync | Mirrors staging | Mirrors staging seed script |
| Traffic | Real users | Internal QA + automated E2E | Reviewer + automated E2E only | Developer only |

Staging is **not** a scaled-down production — it runs the identical Next.js build and identical Supabase schema version, differing only in data volume and external-service credentials. This is what makes a staging smoke-test result trustworthy.

### 4.3 Preview Environments (Per-PR)

Every pull request gets:
- A Vercel preview deployment (automatic, free at this scale).
- A Supabase **branched database** (schema-identical fork of staging, seeded with a fixed synthetic dataset) where the PR touches migrations; PRs that don't touch `supabase/migrations/` reuse the shared staging DB to avoid unnecessary branch churn.
- Sandboxed payment/email credentials shared across all previews (no per-PR secret provisioning needed).

Preview environments are destroyed automatically on PR merge or close, and a nightly job force-destroys any preview database branch older than 14 days as a safety net against runaway resource usage.

### 4.4 Environment Variable Governance

Environment variables are defined once in `infra/terraform/modules/vercel` per environment and synced to Vercel via Terraform — never hand-edited in the Vercel dashboard for production. PHASE1 §10.2 and PHASE10 Appendix C and PHASE11 Appendix E enumerate the actual variable names; this phase governs **how they get there safely**:

```
Local .env.example (checked into git, no real values)
  → Doppler/1Password vault (source of truth for actual secret values, per environment)
  → Terraform reads from vault at apply time → writes to Vercel/Supabase/Upstash env config
  → Never: a real secret value committed to git, pasted into Slack, or hand-typed into a dashboard
```

---

## 5. CI/CD Pipeline

### 5.1 Pipeline Stages

```
Developer pushes branch / opens PR
  │
  ▼
┌─────────────────────────────────────────────────────────────────┐
│ STAGE 1 — STATIC VALIDATION (fails fast, <2 min)                  │
│  - TypeScript: tsc --noEmit                                        │
│  - Lint: eslint, with zero-warning policy on changed files         │
│  - Format check: prettier --check                                  │
│  - Dependency audit: npm audit --audit-level=high                  │
└──────────────────────────────┬──────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ STAGE 2 — UNIT & INTEGRATION TESTS (<8 min)                        │
│  - Unit tests (Vitest): pricing calc, feature resolver, proration  │
│    (PHASE5 §11.3, PHASE10 §3.1) — pure functions, no I/O           │
│  - Integration tests against local Supabase (Docker): RLS policy   │
│    assertions, webhook signature validation (PHASE10 §8.2)         │
└──────────────────────────────┬──────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ STAGE 3 — MIGRATION SAFETY CHECK (only if supabase/migrations/     │
│           changed) (<3 min)                                        │
│  - supabase db lint (schema lint)                                  │
│  - Migration dry-run against an ephemeral branched DB              │
│  - Backward-compatibility lint (§6.4): blocks unsafe DDL patterns   │
└──────────────────────────────┬──────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ STAGE 4 — BUILD & PREVIEW DEPLOY (<5 min)                          │
│  - next build                                                      │
│  - Vercel preview deployment created                               │
│  - Supabase preview branch created (if migrations changed)         │
└──────────────────────────────┬──────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ STAGE 5 — E2E SMOKE TESTS ON PREVIEW (<10 min)                     │
│  - Playwright: signup → create invitation → publish → RSVP →       │
│    payment sandbox checkout → webhook simulation → analytics event │
│  - Accessibility scan (axe-core) on public invitation page          │
│  - Lighthouse CI: Core Web Vitals budget enforcement (PHASE1 §10.4) │
└──────────────────────────────┬──────────────────────────────────┘
                                ▼
                     PR review + required approvals
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ STAGE 6 — MERGE TO MAIN → STAGING DEPLOY (automatic)                │
│  - Supabase migration apply → staging project                      │
│  - Vercel deploy → staging.weddingplatform.com                      │
│  - Full E2E suite re-run against staging (real staging Redis,       │
│    sandbox payment provider round-trip)                             │
└──────────────────────────────┬──────────────────────────────────┘
                                ▼
                  Manual promotion gate (release manager)
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ STAGE 7 — PRODUCTION RELEASE                                       │
│  - Supabase migration apply → production (expand-only, see §6)     │
│  - Vercel production deploy (atomic, instant-rollback-capable)      │
│  - Post-deploy smoke test (§5.5) against production                 │
│  - Sentry release marked; deploy annotated on Grafana/Better Stack  │
└──────────────────────────────┬──────────────────────────────────┘
                                ▼
              Automated 15-minute post-deploy error-rate watch
              (auto-rollback trigger — see §5.4)
```

### 5.2 Branching & Release Model

```
main                → always deployable; protected branch; staging auto-deploys on merge
feature/*           → PR branches off main
hotfix/*            → emergency fix branches, expedited pipeline (Stage 2+5 only, skips
                       full E2E suite for the fastest safe path to production)
release tags        → vN.N.N tagged at each production promotion, used for rollback reference
```

Production releases are **manually gated** (Stage 6→7), not continuous-deploy-to-prod-on-merge. This is a deliberate trade-off: continuous deployment to production is attractive for velocity, but a billing/payments-bearing platform (PHASE10) benefits from a human checkpoint between "tests passed" and "real money moves through this code" — the gate is a single button click for the release manager, not a heavyweight process, so velocity cost is minimal.

### 5.3 Required Checks Before Merge

| Check | Blocking? |
|---|---|
| TypeScript compiles | ✅ Blocking |
| Lint passes (changed files) | ✅ Blocking |
| Unit + integration tests pass | ✅ Blocking |
| Migration safety lint passes (if applicable) | ✅ Blocking |
| E2E smoke suite passes on preview | ✅ Blocking |
| Lighthouse CI budget met | ✅ Blocking (perf regression) |
| Security/dependency audit (high+ severity) | ✅ Blocking |
| Code review approval (≥1) | ✅ Blocking |
| Visual regression diff reviewed (if UI changed) | ⚠️ Warning only (manual judgment) |

### 5.4 Automated Rollback

```typescript
// scripts/post-deploy-watch.ts
// Runs for 15 minutes after every production deploy, polling Sentry + Vercel.

const ERROR_RATE_THRESHOLD = 0.02;       // 2% of requests erroring
const BASELINE_WINDOW_MINUTES = 15;       // pre-deploy baseline for comparison

async function watchAndRollback(deploymentId: string, previousDeploymentId: string) {
  const baseline = await getErrorRate(previousDeploymentId, BASELINE_WINDOW_MINUTES);
  for (let elapsed = 0; elapsed < 15; elapsed++) {
    await sleep(60_000);
    const current = await getErrorRate(deploymentId, 1);
    if (current > Math.max(ERROR_RATE_THRESHOLD, baseline * 3)) {
      await rollbackToDeployment(previousDeploymentId);  // Vercel instant rollback (atomic alias swap)
      await notifyOnCall(`Auto-rollback triggered: error rate ${current} vs baseline ${baseline}`);
      return;
    }
  }
  await notifyChannel(`Deploy ${deploymentId} stable after 15min watch window.`);
}
```

Because Vercel deployments are immutable and the production alias is just a pointer, rollback is an **alias swap, not a redeploy** — sub-10-second recovery for application-code issues. Database migration rollback is a separate, more careful process (§6.5) since data changes aren't trivially reversible.

### 5.5 Post-Deploy Smoke Test

```typescript
// scripts/smoke-test.ts — runs against the just-deployed environment URL

const checks = [
  { name: 'Homepage loads',              fn: () => expectStatus('/', 200) },
  { name: 'Public invitation page (ISR)', fn: () => expectStatus('/inv/smoke-test-slug', 200) },
  { name: 'Auth endpoint reachable',       fn: () => expectStatus('/api/auth/session', 200) },
  { name: 'DB connectivity (read)',         fn: () => expectStatus('/api/health/db', 200) },
  { name: 'Redis connectivity',              fn: () => expectStatus('/api/health/redis', 200) },
  { name: 'Webhook endpoint reachable (4xx OK)', fn: () => expectStatusIn('/api/webhooks/midtrans', [400, 401]) },
  { name: 'Event ingestion accepts beacon',       fn: () => expectStatus('/api/events/track', 204, { method: 'POST', body: smokeEventPayload }) },
];

// Any failure blocks the release annotation from being marked "healthy" and pages on-call immediately.
```

### 5.6 Infrastructure Drift Detection

```
Nightly cron (GitHub Actions scheduled workflow):
  terraform plan -detailed-exitcode  (per environment)
  → exit code 2 (drift detected) → post diff to #infra-alerts, do NOT auto-apply
  → exit code 0 (no drift) → silent success
  → exit code 1 (error) → page on-call
```

Drift is never auto-corrected — a human reviews the diff (it may be an intentional emergency console change made during an incident) and either codifies it into Terraform or reverts it deliberately.

---

## 6. Database Migration & Release Strategy

### 6.1 Expand/Contract Migration Pattern

All schema changes follow **expand → migrate → contract**, ensuring the database is always compatible with both the currently-deployed and the about-to-deploy application version (since Vercel deploys and Supabase migrations are not perfectly atomic together).

```
EXPAND   — Add new column/table/index. Never remove or rename anything yet.
           Old app code ignores new columns; safe to deploy migration before app code.
MIGRATE  — Backfill data into new structure (batched, idempotent, resumable).
           New app code starts writing to both old and new structure if needed (dual-write).
CONTRACT — Once new app code is fully rolled out and stable, a LATER migration drops the
           old column/table. This happens in a subsequent release, never the same one.
```

This pattern is already implicitly followed throughout PHASE2–11 (e.g. PHASE10 §1.1 "Order vs subscription: separate tables," PHASE11 §3.2 "extends without altering the original table to avoid a breaking migration") — PHASE12 makes it an explicit, enforced policy rather than an emergent convention.

### 6.2 Migration Execution Order

```
1. Migration applied to staging (Stage 6 of CI/CD, §5.1)
2. Staging E2E suite validates application behavior against new schema
3. Manual promotion gate
4. Migration applied to production FIRST (expand-phase migrations are additive and
   backward-compatible by construction, so this is safe even before app code deploys)
5. Application code deployed to production second
6. Post-deploy smoke test confirms both layers are healthy together
```

Contract-phase migrations (drops/renames) are scheduled only after confirming via monitoring (§10) that no production traffic still depends on the old structure — typically one release cycle later, never same-day as the expand phase.

### 6.3 Zero-Downtime DDL Rules

| Operation | Safe? | Rule |
|---|---|---|
| `ADD COLUMN ... DEFAULT NULL` | ✅ Always safe | No table rewrite in modern Postgres |
| `ADD COLUMN ... DEFAULT <non-null>` | ⚠️ Conditional | Safe in Postgres 11+ (no rewrite), but still reviewed — large tables warrant a dry-run timing check |
| `CREATE INDEX` | ⚠️ Conditional | Always `CREATE INDEX CONCURRENTLY` in production migrations to avoid write-locking the table |
| `ALTER COLUMN TYPE` | ❌ Unsafe (usually) | Requires expand/contract: add new-typed column, backfill, swap reads, drop old column |
| `DROP COLUMN` / `DROP TABLE` | ❌ Never in the same release as the read-path change | Contract-phase only, one release after reads have moved off it |
| `RENAME COLUMN` / `RENAME TABLE` | ❌ Never directly | Treated as add-new + backfill + contract-old, exactly like a type change |
| `ALTER TABLE ... ADD CONSTRAINT ... CHECK` | ⚠️ Conditional | Use `NOT VALID` + `VALIDATE CONSTRAINT` as a separate step to avoid a full-table lock (this is the exact pattern PHASE11 §4.1 already uses for the `invitation_events.event_type` CHECK extension) |

### 6.4 Migration Safety Lint (CI Stage 3)

```bash
# scripts/pre-deploy-check.sh
# Greps the migration diff for unsafe patterns before allowing CI to pass.

UNSAFE_PATTERNS=(
  "DROP TABLE"
  "DROP COLUMN"
  "RENAME COLUMN"
  "RENAME TO"
  "ALTER COLUMN .* TYPE"
  "CREATE INDEX [^C]"   # catches CREATE INDEX without CONCURRENTLY (CREATE INDEX CONCURRENTLY won't match)
)

for pattern in "${UNSAFE_PATTERNS[@]}"; do
  if grep -qE "$pattern" "$MIGRATION_DIFF_FILE"; then
    echo "BLOCKED: migration contains potentially unsafe DDL: $pattern"
    echo "If this is an intentional contract-phase migration, add '-- SAFE: <reason>' comment and re-run with --override"
    exit 1
  fi
done
```

An explicit `--override` flag with a mandatory inline justification comment is the only bypass — this makes unsafe migrations visible in code review rather than silently blocked forever.

### 6.5 Migration Rollback Strategy

Unlike application code, database migrations are **not** instantly reversible via alias swap. The rollback strategy is tiered by what changed:

```
Expand-phase migration (additive only) → Rollback = simply don't deploy the app code that
                                          reads the new structure. The extra column/table is
                                          harmless dead weight until a future cleanup migration.

Data backfill migration               → Rollback = re-run a compensating backfill script,
                                          OR restore the affected rows from PITR (§13.3) if
                                          backfill logic was destructive.

Contract-phase migration (drop)       → Rollback = restore from the most recent backup/PITR
                                          point preceding the drop. This is why contract
                                          migrations are never run same-day as their expand
                                          counterpart — there must be a confirmed-stable
                                          window first.
```

---

## 7. Security Architecture

### 7.1 Defense-in-Depth Layers

This section is the **infrastructure security layer**, distinct from and additive to the application-level security already specified: PHASE1 §4.3 RLS, PHASE3 auth, PHASE10 §16 multi-tenant billing security, PHASE11 §16 analytics privacy.

```
Layer 1 — Network edge:        Cloudflare WAF, DDoS mitigation, TLS termination, bot management
Layer 2 — Platform edge:        Vercel Edge Middleware (tenant resolution + JWT pre-validation)
Layer 3 — Application:          Next.js API route auth guards (requireAuth, requireRole — PHASE3/4)
Layer 4 — Database:             Postgres RLS policies (PHASE1 §4.3, and per-domain policies in
                                 PHASE5 §10.2, PHASE8, PHASE9, PHASE10 §15.3, PHASE11 §15.3)
Layer 5 — Service-role containment: createAdminClient() restricted to Edge Functions and
                                 /api/admin/* after explicit role check (PHASE10 §16.5,
                                 PHASE11 §16.2) — audited at deploy time (§7.6)
Layer 6 — Secrets:               Centralized secrets manager, never in git/client bundle (§8)
Layer 7 — Data at rest:          Postgres encryption at rest (provider-managed), Storage
                                 bucket encryption, encrypted backups (§13.2)
Layer 8 — Data in transit:       TLS 1.2+ enforced everywhere, including internal
                                 Vercel↔Supabase calls
```

### 7.2 Network & WAF Configuration

```hcl
# infra/terraform/modules/cloudflare/waf.tf (excerpt)

resource "cloudflare_ruleset" "waf_managed" {
  zone_id = var.zone_id
  name    = "platform-waf-managed"
  kind    = "zone"
  phase   = "http_request_firewall_managed"

  rules {
    action = "execute"
    action_parameters {
      id = "efb7b8c949ac4650a09736fc376e9aee" # Cloudflare Managed Ruleset
    }
    expression  = "true"
    description = "Cloudflare Managed Ruleset — OWASP core rules"
  }
}

resource "cloudflare_rate_limit" "api_global" {
  zone_id   = var.zone_id
  threshold = 300
  period    = 60
  match {
    request {
      url_pattern = "*.weddingplatform.com/api/*"
    }
  }
  action {
    mode    = "challenge"
    timeout = 60
  }
  description = "Coarse edge-level rate limit ahead of app-level Upstash limits (PHASE9 §13.5, PHASE11 §4.5)"
}

resource "cloudflare_rate_limit" "events_track_strict" {
  zone_id   = var.zone_id
  threshold = 100
  period    = 60
  match {
    request {
      url_pattern = "*.weddingplatform.com/api/events/track"
    }
  }
  action {
    mode    = "block"
    timeout = 300
  }
  description = "Public unauthenticated ingestion endpoint (PHASE11 §4.3) gets a tighter edge ceiling"
}
```

This edge-level rate limiting is **coarse and defense-in-depth** — it does not replace the fine-grained, per-IP Upstash limiters already specified in PHASE9 §13.5 and PHASE11 §4.5; it exists to absorb volumetric abuse before it ever reaches a serverless function invocation (which costs money per-invocation even when the request is ultimately rejected).

### 7.3 TLS & Certificate Management

- All traffic terminates TLS at Cloudflare edge (TLS 1.2 minimum, TLS 1.3 preferred), with Cloudflare-managed universal certificates auto-renewed.
- Origin traffic (Cloudflare → Vercel) uses Cloudflare's "Full (Strict)" mode — Vercel's own certificate is validated, not just encrypted-but-unverified.
- Custom reseller domains (PHASE1 §9.2) provision certificates automatically via Vercel's domain API at the time the CNAME is verified — no manual certificate handling.

### 7.4 Dependency & Supply Chain Security

```
- npm audit (high+ severity) blocking in CI (§5.3)
- Renovate/Dependabot: automated weekly dependency PRs, auto-merged for patch-level
  semver-safe updates after CI passes; minor/major require manual review
- Lockfile (package-lock.json) committed and verified in CI (npm ci, never npm install)
- Supabase/Vercel/Cloudflare/Upstash provider versions pinned in Terraform; bumped
  deliberately, not floating
- SBOM (Software Bill of Materials) generated per release (e.g. via `npm sbom`) and
  retained alongside release artifacts for audit purposes
```

### 7.5 Application Security Headers

```typescript
// next.config.ts — security headers applied platform-wide

const securityHeaders = [
  { key: 'X-Frame-Options', value: 'SAMEORIGIN' },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=(self)' },
  {
    key: 'Content-Security-Policy',
    value: [
      "default-src 'self'",
      "img-src 'self' data: https://*.supabase.co https:",
      "script-src 'self' 'unsafe-inline' https://app.midtrans.com",
      "frame-src https://app.midtrans.com https://www.google.com", // payment widget + maps embed (PHASE6)
      "connect-src 'self' https://*.supabase.co https://api.midtrans.com wss://*.supabase.co",
    ].join('; '),
  },
  { key: 'Strict-Transport-Security', value: 'max-age=63072000; includeSubDomains; preload' },
];

export default {
  async headers() {
    return [{ source: '/(.*)', headers: securityHeaders }];
  },
};
```

The public invitation page (`/inv/[slug]`) and reseller white-label subdomains receive a slightly relaxed `frame-src`/`img-src` policy where needed for theme embeds (PHASE6 livestream/map embeds), scoped per-route rather than weakening the platform-wide default.

### 7.6 Service-Role Containment Audit

PHASE10 §16.5 and PHASE11 §16.2 establish that `createAdminClient()` (the service-role Supabase key) must only be instantiated in Edge Functions and `/api/admin/*` routes. This phase adds an **automated enforcement check**, since a policy stated only in documentation drifts over time:

```typescript
// scripts/audit-service-role-usage.ts — runs in CI Stage 1

import { Project } from 'ts-morph';

const ALLOWED_PATH_PATTERNS = [
  /^app\/api\/admin\//,
  /^supabase\/functions\//,
];

const project = new Project();
project.addSourceFilesAtPaths('app/**/*.ts');

let violations: string[] = [];
for (const file of project.getSourceFiles()) {
  const filePath = file.getFilePath();
  const usesAdminClient = file.getText().includes('createAdminClient(');
  const isAllowed = ALLOWED_PATH_PATTERNS.some(p => p.test(filePath));
  if (usesAdminClient && !isAllowed) {
    violations.push(filePath);
  }
}

if (violations.length > 0) {
  console.error('Service-role client used outside allowed paths:', violations);
  process.exit(1);
}
```

This converts a documented architectural invariant (already correctly stated in PHASE10/11) into a CI-blocking guarantee, closing the gap between "the docs say this" and "the codebase actually enforces this."

### 7.7 Penetration Testing & Vulnerability Management

```
Cadence: Annual third-party penetration test (minimum), plus ad-hoc retest after any
         finding remediation.
Scope:   Auth flows, RLS bypass attempts, payment webhook spoofing (PHASE10 §8),
         multi-tenant data leakage (cross-tenant_id probing), reseller impersonation
         boundaries (PHASE1 §8.3).
Internal: Quarterly automated DAST scan (e.g. OWASP ZAP) against staging.
Disclosure: A documented /.well-known/security.txt with a responsible-disclosure
            contact and SLA (acknowledge within 48h, triage within 5 business days).
```

---

## 8. Secrets Management

### 8.1 Secrets Taxonomy

| Class | Examples | Storage | Rotation Cadence |
|---|---|---|---|
| Database credentials | `SUPABASE_SERVICE_ROLE_KEY`, DB connection strings | Secrets vault → Vercel encrypted env | Quarterly, or immediately on suspected exposure |
| Payment gateway keys | `MIDTRANS_SERVER_KEY`, `XENDIT_SECRET_KEY`, webhook tokens | Secrets vault → Vercel encrypted env | On provider's recommended cadence; immediately on staff offboarding with access |
| Third-party API keys | `RESEND_API_KEY`, `SENTRY_DSN`, `UPSTASH_REDIS_REST_TOKEN` | Secrets vault → Vercel encrypted env | Annually or on exposure |
| Application secrets | `ANALYTICS_IP_SALT` (PHASE11 §16.4), JWT signing secrets | Secrets vault → Vercel encrypted env | Documented as rotatable without correctness impact (already specified for IP salt); JWT secret rotation follows a dual-key overlap window to avoid invalidating live sessions |
| Infrastructure credentials | Terraform Cloud API token, Cloudflare API token | Secrets vault, restricted to CI service account only | Quarterly |

### 8.2 Access Principles

- **No secret ever exists only in one place.** The vault (Doppler/1Password) is the source of truth; Vercel/Supabase/Upstash hold synced copies, not independently-managed originals.
- **No secret is ever logged.** Structured logging (§11) explicitly redacts known secret-shaped fields (API keys, tokens, Authorization headers) via a logging middleware allowlist rather than a denylist (allowlist-what's-safe-to-log is the safer default).
- **Least privilege per environment.** Staging and preview environments use entirely separate credential sets from production (separate Supabase projects, separate sandbox payment credentials) — a compromised staging secret cannot touch production data or move real money.
- **Human access is audit-logged.** Vault access (who viewed/exported which secret, when) is logged by the vault provider itself and reviewed quarterly.

### 8.3 Secret Exposure Response

```
1. Revoke/rotate the exposed credential immediately at the provider (don't wait for
   a "proper" rotation window — exposure changes the calculus).
2. Update the vault and propagate to all environments via Terraform apply.
3. Audit logs (PHASE1 audit_logs, PHASE10/11 domain-specific audit actions) reviewed
   for any activity during the exposure window attributable to the leaked credential.
4. Incident written up per §16 regardless of whether misuse is found.
```

---

## 9. Multi-Tenant Deployment Model

### 9.1 Tenant Isolation at the Infrastructure Layer

PHASE1 §2.3 already chose RLS-per-row over schema-per-tenant for cost/simplicity reasons appropriate to a high-tenant-count, low-per-tenant-volume SaaS. PHASE12 confirms this remains correct at the infrastructure layer and adds the operational controls that make shared infrastructure safe for a multi-tenant billing platform:

```
Single shared compute fleet (Vercel Functions)  → stateless; no tenant affinity needed;
                                                   any function instance can serve any tenant
Single shared database (Supabase Postgres)       → RLS is the isolation boundary; reinforced
                                                   by explicit .eq('tenant_id', ...) filters in
                                                   application code (defense-in-depth, already
                                                   mandated in PHASE7 §12.4, PHASE10 §16.1,
                                                   PHASE11 §16.1)
Single shared Redis (Upstash)                     → key-namespaced per tenant
                                                   (e.g. features:{tenantId}:*, rl:events
                                                   per-IP — PHASE5 §12.1, PHASE11 §4.5)
Single shared object storage                       → path-namespaced per tenant
                                                   (e.g. analytics-exports/{tenant_id}/...,
                                                   PHASE11 §19.4)
```

### 9.2 Noisy-Neighbor Mitigation

Shared infrastructure means one tenant's traffic spike must not degrade another tenant's experience. Mitigations already exist throughout the prior phases and are confirmed here as the platform-wide noisy-neighbor defense:

| Risk | Mitigation | Source |
|---|---|---|
| One tenant's public invitation page goes viral | ISR caching means repeat reads never hit a function or DB query — CDN absorbs the spike | PHASE1 §10.5 |
| One tenant spams the event-tracking endpoint | Per-IP rate limiting (not per-tenant — an attacker doesn't get a bigger budget by spreading across tenants) | PHASE9 §13.5, PHASE11 §4.5 |
| One tenant's CSV export is huge | Async export with row-count threshold routes large exports to a background Edge Function, never blocking a shared serverless function for 30+ seconds | PHASE11 §13.1 |
| One tenant's rollup computation is slow | Rollup jobs process one tenant/invitation at a time in a loop with no shared lock, and shard-fan-out is the prepared scaling path once iteration time grows | PHASE11 §5.1, §18.3 |
| A single reseller's many clients overload the dashboard query | Pre-aggregated rollup tables (`tenant_analytics_daily`, `reseller_analytics_daily`) avoid N+1 fan-out queries regardless of how many invitations a tenant or reseller has | PHASE11 §3.3, §3.4 |

### 9.3 Tenant Suspension & Isolation (Operational)

A tenant can be suspended (PHASE1 `tenants.status = 'suspended'`) for billing failure, ToS violation, or abuse investigation, without any infrastructure-level action — RLS-adjacent middleware checks `tenants.status` on every authenticated request and returns a 403 with an explanatory page, while the tenant's data remains intact and un-deleted. This means tenant-level moderation is a data-layer flag, not an infrastructure provisioning/deprovisioning event — critical for keeping suspension fast (seconds) and reversible.

### 9.4 Reseller Custom Domain Isolation

Per PHASE1 §9.2, reseller custom domains are CNAMEd to the platform and resolved via Edge Middleware Host-header lookup. At the infrastructure layer:

```
Reseller adds CNAME: dashboard.resellerbrand.com → cname.vercel-dns.com
  │
  ▼
Vercel automatically provisions and renews a TLS certificate for the verified domain
  │
  ▼
Edge Middleware resolves resellers.custom_domain → reseller_id → branding + tenant scoping
  │
  ▼
All downstream RLS/feature-resolution logic is identical to the primary domain path —
custom domains are purely a routing/branding layer, never a separate deployment or
separate database connection.
```

This means onboarding a new reseller custom domain requires zero infrastructure deploy — it is fully self-service through the existing DNS+Vercel domain API integration already implied by PHASE1 §9.2, confirmed here as requiring no manual ops intervention for the common case.

---

## 10. Monitoring & Observability

### 10.1 Observability Pillars

```
METRICS    → Vercel Analytics (Web Vitals, function invocations/duration/errors) +
             Supabase built-in DB metrics (connections, query latency, replication lag) +
             Upstash metrics (Redis ops/latency) + Grafana Cloud/Better Stack as the
             unified dashboard layer pulling from all of the above
TRACES     → Sentry Performance (distributed tracing across API routes → Supabase calls)
LOGS       → Structured JSON logs (§11), shipped to Better Stack/Grafana Loki
ERRORS     → Sentry (frontend + serverless function + Edge Function error capture)
SYNTHETICS → Scheduled synthetic checks (uptime + critical-path scripted flows)
```

### 10.2 Key Metrics (Golden Signals per Tier)

| Tier | Latency | Traffic | Errors | Saturation |
|---|---|---|---|---|
| Public invitation page | LCP < 1.5s (PHASE1 §10.4) | Views/min, by tenant | 5xx rate | ISR cache hit ratio |
| API routes (dashboard) | P95 < 400ms TTFB | Requests/min | 4xx/5xx rate by route | Function concurrency / cold-start rate |
| Database | P95 query < 100ms (PHASE1 §10.4) | Active connections | Failed queries, deadlocks | Connection pool utilization (PgBouncer), replication lag |
| Webhook processing | P95 < 300ms (PHASE10 §17.4) | Webhook deliveries/min | Signature validation failures, processing errors | `webhook_logs.processed = FALSE` backlog size |
| Rollup/cron jobs | Job duration vs. cron interval | Jobs run/day | Failed job runs (`rollup_job_runs.status='failed'`) | Rows processed per run trend |
| Redis | P95 command latency | Ops/sec | Connection errors | Memory utilization, eviction rate |

### 10.3 Dashboards

```
/dashboards/platform-health        — golden signals across all tiers, single pane of glass
/dashboards/billing                — order success rate, webhook processing latency,
                                      payment_amount_mismatch rate (PHASE10 §16.3 trigger)
/dashboards/analytics-pipeline     — rollup job completion status per tier (PHASE11 §5.1
                                      topology), ingestion endpoint health
/dashboards/multi-tenant           — per-tenant resource usage outliers (noisy-neighbor
                                      detection, §9.2)
/dashboards/infrastructure         — Vercel function cold starts, Supabase connection pool,
                                      Redis saturation, Cloudflare WAF block rate
```

### 10.4 Synthetic Monitoring

```typescript
// Scheduled every 5 minutes from 3 geographic probe locations (Singapore, Jakarta, Sydney)
// to validate both global edge performance and proximity to the primary tenant base.

const syntheticChecks = [
  { name: 'homepage',            url: '/', expectStatus: 200, maxLatencyMs: 800 },
  { name: 'public_invitation',    url: '/inv/__synthetic_probe__', expectStatus: 200, maxLatencyMs: 1500 },
  { name: 'login_page',            url: '/login', expectStatus: 200, maxLatencyMs: 800 },
  { name: 'api_health',             url: '/api/health', expectStatus: 200, maxLatencyMs: 500 },
  { name: 'webhook_endpoint',        url: '/api/webhooks/midtrans', method: 'POST', expectStatusIn: [400, 401], maxLatencyMs: 500 },
];

// Full critical-path E2E synthetic (less frequent — every 15 min, since it has side effects
// and must clean up after itself):
// signup (synthetic tenant) → create invitation → publish → submit RSVP → soft-delete cleanup
```

A failed synthetic check pages on-call **before** real users are likely to notice, closing the gap between "an actual customer files a support ticket" and "we know something is wrong."

### 10.5 Database-Specific Monitoring

```sql
-- Supabase/Postgres-level checks, queried by the monitoring pipeline every minute

-- Replication lag (read replica staleness — relevant to PHASE2 §9.4 / PHASE11 §18.5
-- read-replica-routing decisions; if lag exceeds threshold, routing logic should
-- temporarily prefer primary for consistency-sensitive reads)
SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) AS replica_lag_seconds;

-- Connection pool saturation
SELECT count(*) AS active_connections, max_conn FROM pg_stat_activity, pg_settings WHERE name = 'max_connections';

-- Long-running query detection (catches a runaway rollup query before it blocks others)
SELECT pid, now() - query_start AS duration, query
FROM pg_stat_activity
WHERE state = 'active' AND now() - query_start > interval '30 seconds';

-- Table bloat / vacuum health on high-write tables (invitation_events, webhook_logs,
-- payment_transactions — all append-heavy per PHASE10/11)
SELECT relname, n_dead_tup, last_autovacuum FROM pg_stat_user_tables
WHERE relname IN ('invitation_events', 'webhook_logs', 'payment_transactions')
ORDER BY n_dead_tup DESC;
```

---

## 11. Logging Architecture

### 11.1 Structured Logging Standard

Every log line emitted by any service (API routes, Edge Functions, middleware) is structured JSON, never free-text, to make the log pipeline queryable rather than grep-only.

```typescript
// lib/logging/logger.ts

interface LogEvent {
  timestamp:    string;
  level:        'debug' | 'info' | 'warn' | 'error';
  service:      string;        // e.g. 'api.subscription.purchase', 'edge-fn.rollup-invitation-daily'
  tenant_id?:   string;        // omitted for platform-level/unauthenticated events
  request_id:   string;        // correlates across the request lifecycle
  message:      string;
  context?:     Record<string, unknown>;  // structured extra fields; secrets redacted (§8.2)
  duration_ms?: number;
  error?:       { name: string; message: string; stack?: string };
}

export function logEvent(event: Omit<LogEvent, 'timestamp'>): void {
  const redacted = redactSecrets(event);
  console.log(JSON.stringify({ timestamp: new Date().toISOString(), ...redacted }));
  // Vercel/Supabase log drains ship stdout JSON lines to Better Stack/Grafana Loki automatically
}

const SECRET_FIELD_PATTERNS = [/key$/i, /token$/i, /secret$/i, /password$/i, /authorization/i];
function redactSecrets(obj: Record<string, unknown>): Record<string, unknown> {
  // Recursively walks the object; any key matching a secret pattern is replaced with '[REDACTED]'
  // (allowlist-of-safe-to-log is enforced earlier in the pipeline per §8.2; this is the backstop)
  return deepRedact(obj, SECRET_FIELD_PATTERNS);
}
```

### 11.2 Request Correlation

Every inbound request (browser, webhook, or Edge Function invocation) is assigned a `request_id` at the Edge Middleware layer, propagated through every downstream log line and attached to the Sentry scope, so a single user-reported issue can be traced end-to-end across the function → database → external-webhook boundary without timestamp-guessing.

### 11.3 Log Categories & Retention

| Category | Examples | Hot Retention (queryable) | Cold Retention (archive) |
|---|---|---|---|
| Application logs | Request/response logs, business logic traces | 30 days | 1 year (compressed, object storage) |
| Security logs | Auth failures, RLS denial patterns, WAF blocks | 90 days | 2 years |
| Audit logs (already in DB) | `audit_logs`, billing audit actions (PHASE10 Appendix D), analytics export records | Indefinite (already the policy — PHASE1 `audit_logs`, never purged) | N/A — lives in Postgres, included in standard DB backups |
| Webhook logs (already in DB) | `webhook_logs` (PHASE10 §2.6) | Indefinite per existing design | N/A |
| Infrastructure logs | Terraform apply logs, CI/CD pipeline logs | 90 days | 1 year |

This mirrors the tiered-retention philosophy already established for analytics data in PHASE11 §19.1 — no platform-wide log is retained "forever by accident"; every category has a deliberate, documented window.

### 11.4 PII & Sensitive Data in Logs

Consistent with PHASE9 §13.4 and PHASE11 §16.3's privacy postures: logs never contain raw guest PII (names may appear in business-logic context like "RSVP submitted for invitation X," but phone numbers, emails, and free-text message/wish content are never logged verbatim — only counts, IDs, and statuses). Raw IP addresses are never logged in application logs (mirroring PHASE11 §4.3's hash-only policy for `invitation_events`); infrastructure-layer logs (Cloudflare/Vercel access logs) retain IPs only per those providers' own standard retention, outside this platform's direct control but documented here for completeness.

---

## 12. Alerting & On-Call

### 12.1 Alert Severity Tiers

```
SEV1 — Critical, page immediately, 24/7
  - Production fully down (homepage/auth/DB unreachable)
  - Payment webhook processing fully stalled (webhook_logs backlog growing unbounded)
  - Data breach or confirmed unauthorized cross-tenant data access
  - Auto-rollback triggered (§5.4) — page even though the system self-healed, for review

SEV2 — High, page during business hours, escalate after 30 min unacknowledged
  - Elevated error rate (above threshold but not full outage)
  - A single rollup tier failing repeatedly (PHASE11 §5.6 ledger shows 'failed' status)
  - Read replica lag exceeding threshold
  - Synthetic check failing from 2+ probe regions

SEV3 — Medium, ticket created, addressed next business day
  - Single synthetic check failing from 1 probe region (possibly transient/regional)
  - Non-critical cron job failure with no immediate user impact (e.g. export-purge job)
  - Dependency vulnerability flagged (non-critical severity)

SEV4 — Low, tracked, no urgency
  - Infrastructure drift detected (§5.6)
  - Cost anomaly within tolerance band (§17.3)
```

### 12.2 Alert Routing

```
Sentry (error spike, performance regression)     → PagerDuty (SEV1/2) / Slack #alerts (SEV3/4)
Synthetic monitor failures                         → PagerDuty (SEV1/2 per §12.1 rules)
Database metrics (connection saturation, lag)       → PagerDuty (SEV1/2) / Grafana alert → Slack
Webhook backlog (webhook_logs unprocessed count)     → PagerDuty (SEV1 if backlog > threshold
                                                        for > 10 min — money is on the line)
Rollup job ledger failures (rollup_job_runs)          → Slack #data-pipeline (SEV2/3 depending
                                                        on which tier — platform_daily failing
                                                        is lower urgency than invitation_daily,
                                                        since downstream tiers cascade-defer
                                                        per PHASE11 §5.1's dependency ledger)
Terraform drift                                        → Slack #infra-alerts (SEV4, human review)
Cost anomaly                                            → Slack #infra-alerts (SEV4) → SEV2 if
                                                        anomaly suggests abuse/breach rather
                                                        than organic growth
```

### 12.3 On-Call Structure

```
Primary on-call:    1-week rotation, full-stack engineer, PagerDuty primary escalation
Secondary on-call:  Backup, escalated after 15 min no-ack on SEV1
Escalation:         Engineering lead after 30 min no-ack on SEV1, or on any SEV1 lasting > 1 hour
```

### 12.4 Alert Fatigue Prevention

- Every alert rule has a documented runbook link (§16) — an alert with no corresponding action is a candidate for deletion, not a permanent fixture.
- Thresholds are reviewed quarterly against actual incident history; alerts that fired but never correlated with a real issue are tuned or removed.
- SEV3/4 alerts are batched into a daily digest rather than real-time interruption, to keep real-time paging reserved for things that actually need a human awake at 3am.

---

## 13. Backup & Disaster Recovery

### 13.1 Recovery Objectives

```
RPO (Recovery Point Objective):  ≤ 5 minutes  — via continuous WAL archiving / PITR
RTO (Recovery Time Objective):   ≤ 60 minutes — for a full regional Supabase outage,
                                                 restoring to a new region from backup
RTO (Recovery Time Objective):   ≤ 10 minutes — for application-layer (Vercel) issues,
                                                 via instant alias rollback (§5.4) — this
                                                 is the common case; full-region DB loss
                                                 is the rare, severe case the 60-min target covers
```

These targets are sized for a platform that processes real payments (PHASE10) and holds RSVP/guest data that, once a wedding has passed, cannot be "redone" by the customer — data loss has a uniquely unrecoverable character for life-event customers that justifies a tight RPO even at infrastructure cost.

### 13.2 Backup Architecture

```
┌────────────────────────────────────────────────────────────────┐
│  CONTINUOUS (Point-in-Time Recovery)                              │
│  Supabase WAL archiving → restorable to any point within the      │
│  retention window (PITR window: 7 days minimum, 35 days on        │
│  higher Supabase tiers as the platform scales — PHASE12 budgets   │
│  for the 35-day tier once paid-tenant revenue justifies it)       │
└────────────────────────────────────────────────────────────────┘
┌────────────────────────────────────────────────────────────────┐
│  DAILY LOGICAL BACKUP                                              │
│  Full pg_dump-equivalent snapshot, encrypted, stored in a          │
│  SEPARATE cloud provider/region from the primary database          │
│  (cross-provider, not just cross-region — protects against a       │
│  Supabase-platform-wide incident, not just a Postgres-instance one)│
│  Retention: 30 daily snapshots, then weekly for 1 year             │
└────────────────────────────────────────────────────────────────┘
┌────────────────────────────────────────────────────────────────┐
│  OBJECT STORAGE BACKUP                                              │
│  Gallery photos, theme assets, invoice PDFs (PHASE10 §6),           │
│  analytics exports (PHASE11 §19.4) — replicated to a secondary      │
│  S3-compatible bucket (cross-provider) on a nightly sync             │
└────────────────────────────────────────────────────────────────┘
┌────────────────────────────────────────────────────────────────┐
│  CONFIGURATION / IaC BACKUP                                          │
│  Terraform state (already versioned + remotely stored with          │
│  locking — §3.3) + git history of all migrations and application    │
│  code IS the configuration backup; no separate snapshot needed       │
│  beyond standard git remote redundancy (GitHub + a mirrored remote)  │
└────────────────────────────────────────────────────────────────┘
```

### 13.3 Point-in-Time Recovery Procedure

```
1. Identify the target recovery timestamp (e.g. "just before the bad migration ran"
   or "just before the data corruption event").
2. Provision a new Postgres instance from the WAL archive, replayed up to the target
   timestamp (Supabase-managed PITR restore, or self-managed via `pg_basebackup` +
   WAL replay if self-hosting per the portability path in §3.1).
3. Validate the restored instance against a checklist (row counts on key tables,
   spot-check recent known-good records) BEFORE cutting over.
4. Cut over: update connection strings (via the secrets vault, §8) and redeploy
   the application pointing at the restored instance.
5. Reconcile any writes that happened between the recovery point and the incident
   detection time (this is the "RPO gap") — typically via replaying idempotent
   operations from webhook_logs (PHASE10 §2.6, already append-only and replayable)
   or audit_logs where applicable.
```

### 13.4 Disaster Recovery Drill Cadence

```
Quarterly: Tabletop DR exercise (walk through the runbook without executing it,
           confirm the team knows the steps and the docs are current).
Annually:  Full DR drill — actually restore a backup into an isolated environment,
           measure real RTO/RPO against the targets in §13.1, and update the targets
           or the architecture if reality doesn't match the documented promise.
```

```bash
# scripts/dr-restore.sh — the actual restore automation exercised in drills
# (kept in version control so it is tested, not tribal knowledge)

#!/usr/bin/env bash
set -euo pipefail

TARGET_TIMESTAMP="${1:?Usage: dr-restore.sh <ISO8601 timestamp> <target-environment>}"
TARGET_ENV="${2:?Usage: dr-restore.sh <ISO8601 timestamp> <target-environment>}"

echo "Provisioning restore instance for ${TARGET_ENV} at ${TARGET_TIMESTAMP}..."
# 1. supabase db restore-point or equivalent provider CLI call
# 2. Validation queries against the restored instance (row count sanity checks)
# 3. Output a connection string for manual cutover review — NEVER auto-cutover
#    production traffic without a human confirming the restore looks correct.
echo "Restore complete. Review the instance manually before cutover."
```

### 13.5 Tenant-Level "Undo" (Distinct From Full DR)

Most real-world data-loss requests are not platform disasters but single-tenant mistakes ("I accidentally deleted my invitation"). This is handled at the application/data layer, not via full-database PITR:

- Soft deletes (`deleted_at` columns, already used throughout PHASE7–11) mean accidental deletion is recoverable within the retention window without any infrastructure-level restore.
- Archived (not hard-deleted) excess invitations on downgrade (PHASE5 §1.5, PHASE10 §10.3) follow the same principle.
- Full PITR restore is reserved for incidents where soft-delete/archive recovery is insufficient (e.g. a buggy migration corrupted data across many tenants).

---

## 14. High Availability Architecture

### 14.1 Availability Targets

```
Target platform uptime SLO: 99.9% (≈ 43 minutes downtime budget per month)
Public invitation pages SLO: 99.95% (higher bar — these are time-sensitive, often
                              viewed by guests checking event details on the day of
                              the wedding itself, where downtime has the highest
                              real-world cost relative to the dashboard/admin surfaces)
```

### 14.2 Component-Level HA

| Component | HA Mechanism | Single Point of Failure Eliminated? |
|---|---|---|
| Compute (Vercel Functions) | Auto-scaled, multi-AZ by provider default, stateless | ✅ — any function instance is disposable |
| Public page serving | ISR cache served from CDN edge; survives even a full origin outage for already-cached pages | ✅ for cached content; ⚠️ new/uncached pages still need origin |
| Database (writes) | Single primary (per PHASE1 §2.3 RLS-on-shared-Postgres decision) | ❌ — primary is a SPOF for writes; mitigated by fast PITR restore (§13) and the 60-min RTO target, not eliminated by active failover (documented trade-off, §14.4) |
| Database (reads) | Primary + read replica; replica absorbs read-heavy analytics/dashboard load (PHASE2 §9.4, PHASE11 §18.5) | ✅ for read availability during replica-eligible query degradation; replica can be promoted manually if primary is lost |
| Redis (cache/rate-limit) | Upstash managed, multi-AZ | ✅ — and critically, **the platform is designed to degrade gracefully if Redis is unavailable** (§14.3) |
| Email delivery | Resend's own infra HA; queued retries on transient failure | ✅ provider-level |
| Payment gateway | Dual-provider already by design (Midtrans + Xendit, PHASE10 §4) — a single gateway outage doesn't block all payment methods | ✅ partial — methods route to whichever provider is healthy |
| DNS/Edge | Cloudflare Anycast, inherently globally redundant | ✅ |

### 14.3 Graceful Degradation Design

The platform is explicitly designed so that **non-critical-path dependency failures degrade features rather than cascade into a full outage**:

```
Redis unavailable      → Feature resolution falls back to direct DB query (slower, but
                          correct — PHASE5 §12.1's cache is an optimization layer, not
                          a source of truth) · Rate limiting fails open with a logged
                          warning rather than blocking all traffic (a temporary
                          availability-over-strictness trade-off, reviewed in incident
                          retro if it ever triggers)
Analytics ingestion fails → Public invitation page is completely unaffected by design
                          (PHASE11 §4.6's "fire-and-forget" hard architectural invariant)
Webhook processing delayed → Reconciliation cron (PHASE10 §8.3) catches up within 15
                          minutes; user-visible impact is delayed activation, not a
                          failed payment
Read replica lagging      → Query router falls back to primary for the affected
                          queries rather than serving stale data past a lag threshold
Export generation fails    → Job marked 'failed' in analytics_export_jobs (PHASE11
                          §3.6); user sees a clear error and can retry — does not
                          affect any other part of the dashboard
```

This degradation philosophy is the practical reason the platform can credibly target 99.9%+ uptime on a single-region-write architecture: most things that fail are designed to fail *soft*.

### 14.4 Documented HA Trade-off: Single-Region Writes

**Decision:** The platform does not run an active-active multi-region database. **Reason:** PHASE10's payment-method choices (Indonesian VA banks, QRIS, local e-wallets) and PHASE11's volume projections both confirm a geographically concentrated tenant base where cross-region write latency would add real cost (active-active conflict resolution complexity) for a benefit (surviving a full Singapore-region cloud outage) that is statistically rare relative to the engineering cost of building and correctly operating multi-primary replication. This is revisited as a Year-3+ scaling consideration (§15.5) if/when the tenant base internationalizes meaningfully — not a permanent architectural ceiling, but a deliberate "not yet" rather than an oversight.

---

## 15. Scaling Strategy

### 15.1 Composite Capacity Model

Bringing together the per-domain projections already established (PHASE9 §15.1, PHASE10 §18.1, PHASE11 §18.1):

```
Year 1: ~2,000 paid orders/month · ~25,000 active invitations (steady-state target)
        · ~500 webhook deliveries/day · ~50-60M raw analytics events/year

Year 3: ~25,000 paid orders/month · ~250,000+ active invitations
        · ~8,000 webhook deliveries/day · ~250-300M cumulative raw analytics events
```

Every scaling decision below is sized against the Year 3 column, not Year 1 — the platform should not need an architectural rewrite to absorb 10× growth, only configuration/tier changes.

### 15.2 Compute Scaling

Vercel Functions auto-scale horizontally with no platform-team intervention required — this is the explicit reason serverless was chosen in PHASE1 §2.1. The only scaling concern is **cold-start latency** under sudden traffic spikes (e.g. a viral invitation driving a burst of dashboard signups), mitigated by:
- Keeping function bundle size small (no heavy unused dependencies in the API route bundle).
- Vercel's automatic provisioned-concurrency-like warm-pooling for frequently-hit routes (provider-managed, no app-level work needed).

### 15.3 Database Scaling

```
Vertical:    Supabase compute tier upgrades (more CPU/RAM on the primary) — the first
             lever, requires zero application changes.
Read scaling: Read replica absorbs dashboard/analytics SELECT load (already the
             policy, PHASE2 §9.4 / PHASE11 §18.5); additional replicas added as
             read:write ratio grows, since this workload (RSVP-heavy, analytics-heavy)
             is read-dominant.
Caching:     Redis feature-resolution cache (PHASE5 §12.1) and dashboard query cache
             (PHASE11 §17.3) absorb repeat-read load before it reaches Postgres at all.
Partitioning: invitation_events table partitioning (PHASE2 §9.1, reaffirmed PHASE11
             §18.2) by month — the single largest table, partitioned proactively
             before the >10M row threshold per the existing documented trigger.
Materialized
denormalization: package_feature_snapshot (PHASE5 §12.2) and the *_daily rollup
             tables (PHASE11 §3) are the general pattern: expensive JOIN-heavy
             real-time queries are pre-computed once the underlying table grows
             past the point where on-demand computation is viable.
```

### 15.4 Edge/CDN Scaling

ISR-cached public invitation pages scale to effectively unlimited read throughput regardless of backend capacity, since the CDN serves cached HTML without invoking a function or touching the database for any request within the 60-second revalidation window (PHASE1 §10.5). Multi-region cache distribution is automatic and free at the Vercel Edge Network layer — this is the single highest-leverage scaling property the architecture already has, and the reason public-facing read traffic is the least of the platform's scaling concerns even at Year 3 volume.

### 15.5 Background Job Scaling

The rollup/cron job architecture (PHASE10 §8.3 reconciliation, PHASE11 §5 full rollup topology) already has a documented, prepared scaling path rather than requiring new design at this phase:
- **Shard fan-out** for nightly rollups once per-invitation iteration time threatens Edge Function execution limits (PHASE11 §18.3, given in full there — reused here as the canonical background-job scaling pattern for any future per-tenant batch job, not just analytics rollups).
- **Idempotency ledgers** (`rollup_job_runs`, PHASE11 §5.6) mean retries and overlapping cron triggers are always safe, which is the precondition that makes horizontal sharding safe to introduce later without a correctness redesign.

### 15.6 Multi-Region Write Scaling (Future, Not Built Now)

Documented here as the prepared — not implemented — path, consistent with the deferred-extension documentation style used throughout PHASE2/7/8/10/11:

```
Trigger:        Tenant base internationalizes such that a meaningful fraction of
                 traffic originates far from ap-southeast-1, and latency complaints
                 or a new regional payment-method requirement (e.g. a non-Indonesian
                 market) make single-region writes a real product constraint.
Path:            Postgres logical replication to a second regional primary, with
                 tenant_id-based write routing at the Edge Middleware layer (a tenant
                 is pinned to one write region, avoiding multi-primary conflict
                 resolution entirely) — effectively "schema-per-tenant"'s geography
                 cousin, without revisiting the RLS-per-row decision itself.
Cost:            Requires a tenant→region mapping table, write-routing middleware,
                 and a one-time data migration for tenants reassigned to a new home
                 region. Not undertaken speculatively.
```

### 15.7 Load Testing Cadence

```
Pre-launch:        Full load test simulating Year-1 projected peak (3-5× steady-state
                    average, modeling a viral invitation + concurrent RSVP burst).
Quarterly:          Regression load test after major feature additions, to catch
                    capacity regressions before they reach production.
Pre-major-campaign: Ad-hoc load test before any known traffic-driving event
                    (e.g. a marketing partnership launch).
```

---

## 16. Incident Response & Runbooks

### 16.1 Incident Response Process

```
1. DETECT    — Alert fires (§12) or a report comes in via support/Slack.
2. TRIAGE    — On-call assigns severity (§12.1), opens an incident channel/doc.
3. MITIGATE  — Stop the bleeding first (rollback, feature-flag kill switch via
               PHASE5 §4.1 Priority-1 platform kill switch, scale up a constrained
               resource) — root cause comes after impact is contained.
4. RESOLVE   — Confirm the mitigation actually fixed user-facing impact (synthetic
               checks green, error rate back to baseline).
5. COMMUNICATE — Status updates to affected tenants if customer-visible (especially
               for billing-related incidents, where transparency matters most).
6. POSTMORTEM — Blameless written postmortem within 5 business days for any SEV1/SEV2,
               including a concrete action-item list with owners and due dates.
```

### 16.2 Runbook Index

A living runbook exists for every alert defined in §12 and every failure mode identified across PHASE10/11's own security/reliability sections. Representative entries:

```
runbooks/
├── webhook-backlog-growing.md        — triggered by webhook_logs unprocessed count alert;
│                                        steps: check reconciliation cron health (PHASE10 §8.3),
│                                        check gateway status pages, manually trigger reconciliation
├── payment-amount-mismatch-spike.md  — triggered by PHASE10 §16.3's amount-validation audit
│                                        log entries spiking; steps: check for a gateway-side
│                                        rounding/currency bug, do NOT auto-activate affected orders
├── rollup-job-stuck.md                — a tier in PHASE11 §5.1's topology hasn't completed;
│                                        steps: check rollup_job_runs, check upstream dependency
│                                        per the documented job topology, manual re-trigger
├── replica-lag-high.md                — steps: check replica resource saturation, temporarily
│                                        route affected read traffic to primary (§14.2)
├── service-role-leak-suspected.md     — steps: rotate the service-role key immediately (§8.3),
│                                        audit recent admin-route access logs, re-run the §7.6
│                                        automated containment audit against the current codebase
├── tenant-reports-data-loss.md        — steps: check soft-delete/archive status first (§13.5)
│                                        before considering any PITR restore
├── full-region-outage.md              — steps: execute §13.3's PITR procedure, communicate
│                                        per the RTO target in §13.1
└── auto-rollback-fired.md             — steps: review what the rolled-back deploy changed,
                                          confirm rollback didn't itself cause data inconsistency
                                          for any in-flight request, fix forward before re-attempting
```

### 16.3 Status Page

A public status page (e.g. status.weddingplatform.com, statuspage-as-a-service or self-hosted) is maintained for SEV1/SEV2 incidents affecting customer-visible functionality, particularly billing (PHASE10) and public invitation page availability — both have a direct, time-sensitive impact on a customer's actual wedding day that warrants proactive transparency over silent recovery.

---

## 17. Cost Architecture

### 17.1 Cost Model by Tier

```
Compute (Vercel)        — Pay-per-invocation + bandwidth; scales with traffic, not
                           pre-provisioned capacity. Primary lever for cost control:
                           ISR caching (§15.4) keeps the vast majority of public-page
                           traffic off the metered function tier entirely.
Database (Supabase)     — Tiered by compute size + storage + PITR retention window;
                           the single largest fixed cost as the platform scales,
                           reviewed at each tier upgrade decision point (§15.3).
Redis (Upstash)          — Pay-per-request or fixed tier; cache hit ratio directly
                           determines whether this scales sub-linearly with traffic.
Object storage            — Pay-per-GB-stored + egress; bounded by the retention
                           policies already specified (PHASE11 §19 — exports purged
                           after 7/30 days, preventing unbounded storage growth).
External services          — Resend (per-email), payment gateway fees (PHASE10,
                           a percentage of processed volume — scales with revenue,
                           not a fixed cost risk), Sentry/monitoring (tiered by
                           event volume).
```

### 17.2 Cost Attribution

Where feasible, infrastructure cost is tagged/attributable by environment (production/staging/preview) at minimum, and by major feature domain (billing, analytics, core app) where the provider's billing granularity allows — this is what makes the cost-anomaly alerting in §12.2 meaningful rather than a single opaque monthly number.

### 17.3 Cost Anomaly Detection

```
Nightly job compares each metered service's daily spend against a 7-day trailing
average. A deviation beyond a tolerance band (e.g. +50%) triggers a SEV4 Slack alert
(§12.1) for human review — most commonly an organic growth signal, but occasionally
an indicator of abuse (e.g. the public event-tracking endpoint, §7.2's strict edge
rate limit, being hammered) or an inadvertent infinite-retry bug in a background job.
```

### 17.4 Cost-Aware Architectural Choices Already Made

This phase doesn't introduce new cost-saving mechanisms so much as confirm that several already-made decisions across PHASE10/11 are deliberately cost-aware, not just feature-aware:
- Async export generation only for large datasets (PHASE11 §13.1) avoids paying for long-running serverless function time on the common small-export case.
- Tiered analytics retention (PHASE11 §19) bounds the largest table's growth rather than paying for indefinite raw-event storage.
- Materialized rollup tables (PHASE11 §3, PHASE5 §12.2) trade a small amount of nightly batch compute for avoiding expensive on-demand JOIN queries on every dashboard load — a clear net cost win at any meaningful traffic level.

---

## 18. Compliance & Data Residency

### 18.1 Data Residency

Primary database region is `ap-southeast-1` (Singapore), chosen in PHASE1 §10.1 and reaffirmed here as appropriate given the Indonesian-market-concentrated payment methods (PHASE10 §5) and tenant base. Cross-provider backup copies (§13.2) are stored in a region consistent with the same general data-residency posture (Southeast Asia or a jurisdiction with equivalent data-protection adequacy), not scattered arbitrarily by whichever provider is cheapest that month.

### 18.2 Personal Data Handling Summary (Cross-Reference)

This phase does not redefine privacy policy — it confirms the infrastructure supports what PHASE9 §13 and PHASE11 §16 already committed to:
- Guest PII (names, phone, email, RSVP messages) stored only in application tables already covered by RLS and the retention/purge policies in those phases.
- IP addresses hashed-at-ingestion for analytics (PHASE11 §4.3) and retained transiently with a documented purge commitment for RSVP/guestbook spam-scoring use (PHASE9 §13.4).
- Backups (§13.2) inherit the same data-sensitivity classification as the live database — encrypted at rest, access-restricted to the same on-call/ops roster that can access production secrets (§8.2), not a separate looser-controlled copy.

### 18.3 Right-to-Deletion Operational Path

When a tenant requests full account deletion (a data-subject request under applicable regional data-protection law), the operational path is:
```
1. Tenant data marked for deletion (soft-delete cascade across invitations/guests/
   RSVP/guestbook per existing deleted_at conventions).
2. Hard purge job (extending the existing purge job pattern from PHASE11 §19.2)
   removes the rows after the applicable legal/contractual retention window.
3. Backups naturally roll off the retention window (§13.2) without requiring
   manual backup-surgery — this is why bounded backup retention (30 daily +
   weekly-for-a-year, not "keep everything forever") matters for compliance,
   not just cost.
4. Confirmation sent to the requester once both live-data purge and the backup
   retention window have elapsed.
```

### 18.4 Payment Compliance

PCI-DSS scope is minimized by design: the platform never stores raw card numbers — all card-present data flows through Midtrans/Xendit's own PCI-compliant tokenization (PHASE10 §4), meaning the platform's own infrastructure carries SAQ-A-level (not full PCI) compliance scope. This is confirmed here as an infrastructure-architecture property worth preserving deliberately — any future payment method integration must maintain this property (tokenize-at-gateway, never touch raw PAN data) rather than erode it for convenience.

---

## 19. Pre-Production Launch Checklist

```
INFRASTRUCTURE
[ ] All Terraform modules applied and reconciled (zero drift) across prod/staging
[ ] DNS, WAF, and rate-limit rules verified against §7.2 configuration
[ ] TLS certificates verified (primary domain + wildcard + any reseller test domain)
[ ] Read replica provisioned and replication lag confirmed within threshold

CI/CD
[ ] Full pipeline (§5.1) green on a dry-run release
[ ] Auto-rollback watch script (§5.4) tested against a deliberately-broken staging deploy
[ ] Migration safety lint (§6.4) confirmed blocking on a deliberately unsafe test migration

SECURITY
[ ] Service-role containment audit (§7.6) passing with zero violations
[ ] Secrets fully migrated to vault; zero secrets in git history (verified via a
    history-scanning tool, not just current-state check)
[ ] Security headers (§7.5) verified via an external header-scanning tool
[ ] security.txt published with a working disclosure contact

MONITORING
[ ] All golden-signal dashboards (§10.3) populated with real staging traffic data
[ ] Synthetic checks (§10.4) running from all 3 probe regions against staging
[ ] PagerDuty escalation chain tested with a real (announced) test page

BACKUP & DR
[ ] PITR window confirmed active and a test restore performed successfully (§13.3)
[ ] Cross-provider daily backup confirmed landing and restorable
[ ] DR runbook (§16.2 full-region-outage.md) walked through in a tabletop exercise

LAUNCH READINESS
[ ] Load test (§15.7) executed at projected Year-1 peak with all SLOs met
[ ] Status page live and linked from the support/help surface
[ ] On-call rotation staffed and runbook index (§16.2) reviewed by every on-call engineer
```

---

## 20. Appendices

### Appendix A — Environment Variable Summary (Infra-Specific, New in This Phase)

```bash
# Infrastructure-as-Code
TF_CLOUD_API_TOKEN=                  # Terraform Cloud remote state + run access
CLOUDFLARE_API_TOKEN=
VERCEL_API_TOKEN=
UPSTASH_API_KEY=

# Secrets management
DOPPLER_TOKEN=                       # or 1PASSWORD_SERVICE_ACCOUNT_TOKEN

# Observability
BETTER_STACK_SOURCE_TOKEN=           # or GRAFANA_CLOUD_API_KEY
PAGERDUTY_INTEGRATION_KEY=

# Disaster recovery
DR_BACKUP_SECONDARY_PROVIDER_KEY=    # cross-provider backup destination credentials
DR_BACKUP_ENCRYPTION_KEY=
```

### Appendix B — Cross-Reference: Where Each PHASE12 Section's Inputs Came From

| PHASE12 Section | Primary Source(s) |
|---|---|
| §1 Topology | PHASE1 §2, §10 |
| §6 Migration strategy | PHASE2 (table designs), PHASE10/11 additive-migration conventions |
| §7.6 Service-role audit | PHASE10 §16.5, PHASE11 §16.2 |
| §9.2 Noisy-neighbor table | PHASE1 §10.5, PHASE9 §13.5, PHASE11 §4.5/§13.1/§5.1/§3.3-3.4 |
| §10.5 DB monitoring | PHASE2 §9.4, PHASE11 §18.5 |
| §13.5 Tenant-level undo | PHASE5 §1.5, PHASE7–11 `deleted_at` conventions |
| §14.4 Single-region trade-off | PHASE10 §5 (payment methods), PHASE9 §15.1/PHASE10 §18.1/PHASE11 §18.1 (volume projections) |
| §15.2–15.6 Scaling levers | PHASE1 §10.5, PHASE2 §9.1/§9.4, PHASE5 §12, PHASE11 §17–18 |
| §17.4 Cost-aware choices | PHASE11 §13.1, §19; PHASE5 §12.2 |
| §18.4 Payment compliance | PHASE10 §4 (gateway tokenization) |

### Appendix C — Glossary

```
RPO   — Recovery Point Objective: maximum acceptable data loss, measured in time.
RTO   — Recovery Time Objective: maximum acceptable downtime during recovery.
SLO   — Service Level Objective: an internal target (e.g. 99.9% uptime) used to
        drive engineering decisions, distinct from a customer-facing SLA.
WAL   — Write-Ahead Log: Postgres's durability mechanism, the basis for PITR.
IaC   — Infrastructure as Code.
SBOM  — Software Bill of Materials.
DAST  — Dynamic Application Security Testing.
```

---

*End of PHASE12_DEPLOYMENT.md*
