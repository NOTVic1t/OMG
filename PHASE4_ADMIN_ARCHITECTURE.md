# PHASE4_ADMIN_ARCHITECTURE.md
# Wedding Invitation SaaS Platform — Admin Panel Architecture

> **Version:** 1.0.0
> **Date:** 2026-06-12
> **Status:** Approved for Development
> **Depends on:** PHASE1_ARCHITECTURE.md, PHASE2_DATABASE.md, PHASE3_AUTH.md

---

## Table of Contents

1. [Dashboard Architecture Overview](#1-dashboard-architecture-overview)
2. [Navigation Structure](#2-navigation-structure)
3. [Information Architecture](#3-information-architecture)
4. [Super Admin Dashboard](#4-super-admin-dashboard)
5. [Reseller Dashboard](#5-reseller-dashboard)
6. [User Dashboard](#6-user-dashboard)
7. [Package Management Module](#7-package-management-module)
8. [Feature Toggle Management Module](#8-feature-toggle-management-module)
9. [Theme Management Module](#9-theme-management-module)
10. [User Management Module](#10-user-management-module)
11. [Reseller Management Module](#11-reseller-management-module)
12. [Analytics Dashboard Module](#12-analytics-dashboard-module)
13. [Billing Dashboard Module](#13-billing-dashboard-module)
14. [System Settings Module](#14-system-settings-module)
15. [Audit Logs Module](#15-audit-logs-module)
16. [Permission Mapping](#16-permission-mapping)
17. [UI Layout Architecture](#17-ui-layout-architecture)
18. [Mobile Responsive Strategy](#18-mobile-responsive-strategy)
19. [Future Scalability](#19-future-scalability)

---

## 1. Dashboard Architecture Overview

### 1.1 Three-Portal Model

The platform exposes three distinct portals, each scoped to a role group. All three share the same Next.js application and component library but mount under separate route groups with independent layouts, navigation, and data access boundaries.

```
┌─────────────────────────────────────────────────────────────────────┐
│                     NEXT.JS APPLICATION                              │
│                                                                     │
│  ┌───────────────────┐  ┌──────────────────┐  ┌─────────────────┐  │
│  │  SUPER ADMIN      │  │  RESELLER        │  │  USER           │  │
│  │  /admin/*         │  │  /reseller/*     │  │  /dashboard/*   │  │
│  │                   │  │                  │  │                 │  │
│  │  role=super_admin │  │  role=reseller_  │  │  role=owner     │  │
│  │                   │  │  admin           │  │  role=editor    │  │
│  │  Service-role DB  │  │  RLS-scoped DB   │  │  role=viewer    │  │
│  │  (bypasses RLS)   │  │  (reseller view) │  │  RLS-scoped DB  │  │
│  └───────────────────┘  └──────────────────┘  └─────────────────┘  │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │            SHARED COMPONENT LIBRARY (shadcn/ui)              │   │
│  │  DataTable │ StatCard │ Chart │ Modal │ Form │ Badge         │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 Data Access per Portal

| Portal | Supabase Client | RLS Bypass | Data Scope |
|---|---|---|---|
| Super Admin | `createAdminClient()` (service role) | ✅ Yes | All tenants, all rows |
| Reseller | `createServerClient()` (anon + JWT) | ❌ No | Own reseller + linked tenants |
| User | `createServerClient()` (anon + JWT) | ❌ No | Own tenant only |

### 1.3 Rendering Strategy per Page Type

| Page Type | Strategy | Reason |
|---|---|---|
| Dashboard overview (metrics) | Server Component + ISR 60s | Metrics don't need real-time; ISR reduces DB load |
| Data tables (tenants, users, orders) | Server Component + no-store fetch | Always fresh; admin needs current data |
| Charts and graphs | Client Component + SWR polling | Interactive filters; client-side re-fetch on param change |
| Form pages (create / edit) | Server Action + optimistic UI | Progressive enhancement; works without JS |
| Real-time RSVP feed | Client Component + Supabase Realtime | Live updates required |
| Audit logs | Server Component + cursor pagination | Append-only; cursor pagination handles large sets |

### 1.4 Shared Layout Components

```
components/
├── admin/
│   ├── AdminShell.tsx          # Root layout: sidebar + topbar + main
│   ├── AdminSidebar.tsx        # Collapsible nav with role-scoped items
│   ├── AdminTopbar.tsx         # Breadcrumb + global search + user menu
│   ├── StatCard.tsx            # KPI card (value, delta, trend line)
│   ├── DataTable.tsx           # Sortable, filterable, paginated table
│   ├── DataTableToolbar.tsx    # Search + filter + export controls
│   ├── ConfirmDialog.tsx       # Destructive action confirmation modal
│   ├── AuditBadge.tsx          # Inline "last modified by" display
│   └── EmptyState.tsx          # Zero-data placeholder with CTA
├── reseller/
│   ├── ResellerShell.tsx
│   └── ResellerSidebar.tsx
└── dashboard/
    ├── UserShell.tsx
    └── UserSidebar.tsx
```

---

## 2. Navigation Structure

### 2.1 Super Admin Navigation

```
/admin
├── Dashboard                    /admin/dashboard
├── ── ── ── ── ──
├── Tenants                      /admin/tenants
│   └── Tenant Detail            /admin/tenants/[id]
├── Users                        /admin/users
│   └── User Detail              /admin/users/[id]
├── Resellers                    /admin/resellers
│   └── Reseller Detail          /admin/resellers/[id]
├── ── ── ── ── ──
├── Packages                     /admin/packages
│   └── Package Editor           /admin/packages/[id]
├── Feature Flags                /admin/feature-flags
├── Themes                       /admin/themes
│   └── Theme Editor             /admin/themes/[id]
├── Vouchers                     /admin/vouchers
├── ── ── ── ── ──
├── Analytics                    /admin/analytics
├── Orders & Billing             /admin/orders
├── ── ── ── ── ──
├── Audit Logs                   /admin/audit-logs
├── Email Notifications          /admin/notifications
├── ── ── ── ── ──
└── System Settings              /admin/settings
    ├── General                  /admin/settings/general
    ├── Email Templates          /admin/settings/email-templates
    ├── Payment Providers        /admin/settings/payments
    └── Maintenance              /admin/settings/maintenance
```

### 2.2 Reseller Navigation

```
/reseller
├── Dashboard                    /reseller/dashboard
├── ── ── ── ── ──
├── Clients                      /reseller/clients
│   └── Client Detail            /reseller/clients/[id]
├── ── ── ── ── ──
├── Billing & Commission         /reseller/billing
│   └── Invoice Detail           /reseller/billing/[id]
├── Vouchers                     /reseller/vouchers
├── ── ── ── ── ──
├── Branding                     /reseller/branding
├── Custom Domain                /reseller/domain
├── ── ── ── ── ──
└── Account Settings             /reseller/settings
```

### 2.3 User Navigation

```
/dashboard
├── Dashboard                    /dashboard
├── ── ── ── ── ──
├── Invitations                  /invitations
│   ├── New Invitation           /invitations/new
│   └── Invitation Detail
│       ├── Editor               /invitations/[id]/edit
│       ├── Guests               /invitations/[id]/guests
│       ├── RSVP                 /invitations/[id]/rsvp
│       ├── Guestbook            /invitations/[id]/guestbook
│       ├── QR Codes             /invitations/[id]/qr
│       └── Analytics            /invitations/[id]/analytics
├── ── ── ── ── ──
├── Subscription & Billing       /subscription
├── Team Members                 /team
├── ── ── ── ── ──
└── Settings
    ├── Profile                  /settings/profile
    ├── Security                 /settings/security
    └── Custom Domain            /settings/domain
```

---

## 3. Information Architecture

### 3.1 Super Admin IA

```
PLATFORM HEALTH
  MRR │ ARR │ Active Tenants │ Churn Rate │ RSVP Volume

TENANT MANAGEMENT
  List → Filter by status/package/reseller → Detail
  Detail: Profile │ Subscription │ Invitations │ Usage │ Audit

USER MANAGEMENT
  List → Filter by role/tenant/status → Detail
  Detail: Profile │ Activity │ Sessions │ Role

RESELLER MANAGEMENT
  List → Filter by status │ Approval queue → Detail
  Detail: Profile │ Clients │ Commission │ Domains │ Branding

PRODUCT
  Packages: Tiers │ Feature mapping │ Pricing
  Feature Flags: Platform-wide │ Per-tenant overrides │ Expiry
  Themes: Library │ Upload │ Premium flag │ Sort order
  Vouchers: Create │ Usage tracking │ Expiry

REVENUE
  Orders: All payments │ Filter by provider/status/date
  Commission: Reseller payouts │ Reconciliation CSV

PLATFORM OPS
  Audit Logs: Immutable trail │ Filter │ Export
  Email Notifications: Delivery status │ Retry │ Templates
  System Settings: Maintenance mode │ SMTP │ Payments
```

### 3.2 Reseller IA

```
RESELLER OVERVIEW
  Active Clients │ MRR (own) │ Commission Earned │ Pending Payouts

CLIENT MANAGEMENT
  List → Filter by package/status → Detail
  Detail: Invitations │ Subscription │ Impersonate

REVENUE
  Commission History │ Order Detail │ Export CSV

IDENTITY
  Branding: Logo │ Colors │ Company name │ Support email
  Custom Domain: DNS verification │ SSL status

ACCOUNT
  Profile │ Password │ Notification preferences
```

### 3.3 User IA

```
USER OVERVIEW
  Active Invitations │ Total RSVPs │ Upcoming Events │ Plan usage

INVITATION MANAGEMENT
  List → Status filter (draft/published/archived) → Detail
  Detail: Content Editor │ Guest List │ RSVP Dashboard │ Analytics

SUBSCRIPTION
  Current plan │ Usage meters │ Upgrade CTA │ Invoice history

TEAM
  Members │ Roles │ Invite │ Remove

SETTINGS
  Profile │ Password │ Domain │ Notification preferences
```

---

## 4. Super Admin Dashboard

### 4.1 Pages

#### `/admin/dashboard` — Platform Overview

**Purpose:** Single-glance platform health. First page after login.

**Components:**

```
<AdminDashboard>
  <TopMetricsRow>
    <StatCard label="MRR" value={mrr} delta={mrrDelta} trend="up" />
    <StatCard label="Active Tenants" value={activeTenants} delta={tenantDelta} />
    <StatCard label="RSVP This Month" value={rsvpCount} />
    <StatCard label="Churn Rate" value={churnRate} trend="down" danger />
  </TopMetricsRow>

  <ChartsRow>
    <RevenueChart data={monthlyRevenue} />       {/* Line: MRR over 12mo */}
    <TenantGrowthChart data={tenantGrowth} />    {/* Bar: signups per month */}
    <PackageDistributionChart data={packages} /> {/* Donut: tenants per tier */}
    <RsvpVolumeChart data={rsvpVolume} />        {/* Area: RSVPs per day */}
  </ChartsRow>

  <BottomRow>
    <RecentSignupsTable rows={recentTenants} />
    <RecentOrdersTable rows={recentOrders} />
    <ResellerLeaderboard rows={topResellers} />
  </BottomRow>
</AdminDashboard>
```

**Data Sources:**

```typescript
// app/(admin)/dashboard/page.tsx — server component

const [
  platformMetrics,
  monthlyRevenue,
  tenantGrowth,
  packageDistribution,
  rsvpVolume,
  recentTenants,
  recentOrders,
  topResellers,
] = await Promise.all([
  getPlatformMetrics(),          // orders SUM, tenant COUNT, churn calc
  getMonthlyRevenue(12),         // orders GROUP BY month
  getTenantGrowth(12),           // tenants GROUP BY month
  getPackageDistribution(),      // tenant_subscriptions GROUP BY package
  getRsvpVolume(30),             // rsvp_responses GROUP BY day (last 30d)
  getRecentTenants(5),
  getRecentOrders(5),
  getTopResellers(5),
]);
```

**Actions:** None (read-only overview). Links navigate to detail pages.

**Permissions:** `super_admin` only.

---

#### `/admin/tenants` — Tenant List

**Purpose:** Browse, search, filter, and manage all tenants.

**Components:**

```
<TenantsPage>
  <PageHeader title="Tenants" action={<CreateTenantButton />} />

  <DataTableToolbar>
    <SearchInput placeholder="Search by name, email, slug..." />
    <FilterDropdown label="Status" options={['active','suspended','deleted']} />
    <FilterDropdown label="Package" options={packageSlugs} />
    <FilterDropdown label="Reseller" options={resellerNames} />
    <DateRangePicker label="Created" />
    <ExportButton format="csv" />
  </DataTableToolbar>

  <DataTable
    columns={[
      { key: 'name', label: 'Tenant', sortable: true },
      { key: 'slug', label: 'Slug' },
      { key: 'package', label: 'Package' },
      { key: 'status', label: 'Status', cell: <StatusBadge /> },
      { key: 'invitations', label: 'Invitations' },
      { key: 'rsvp_count', label: 'RSVPs' },
      { key: 'mrr', label: 'MRR' },
      { key: 'created_at', label: 'Joined', sortable: true },
      { key: 'actions', label: '', cell: <TenantRowMenu /> },
    ]}
    data={tenants}
    pagination={pagination}
  />
</TenantsPage>
```

**Row Actions:** View Detail · Impersonate · Suspend · Delete (soft)

**Data Sources:** `tenants` JOIN `tenant_subscriptions` JOIN `packages` — service role client, no RLS.

**Permissions:** `super_admin` only.

---

#### `/admin/tenants/[id]` — Tenant Detail

**Purpose:** Full audit view of a single tenant.

**Components:**

```
<TenantDetailPage>
  <TenantHeader tenant={tenant} />            {/* name, slug, status, created */}

  <TabGroup>
    <Tab label="Overview">
      <TenantProfileCard />                   {/* metadata, locale, contact */}
      <UsageMeterGroup />                     {/* invitations / guests / photos used vs limit */}
      <ActiveSubscriptionCard />              {/* package, billing cycle, renewal date */}
    </Tab>

    <Tab label="Invitations">
      <InvitationsTable tenantId={id} />      {/* read-only list with links */}
    </Tab>

    <Tab label="Users">
      <TenantUsersTable tenantId={id} />      {/* team members, roles, last login */}
    </Tab>

    <Tab label="Orders">
      <OrdersTable tenantId={id} />
    </Tab>

    <Tab label="Feature Flags">
      <TenantFeatureFlagOverrides tenantId={id} />
    </Tab>

    <Tab label="Audit Log">
      <AuditLogTable tenantId={id} />
    </Tab>
  </TabGroup>

  <DangerZone>
    <SuspendTenantButton />
    <ImpersonateTenantButton />
    <DeleteTenantButton />
  </DangerZone>
</TenantDetailPage>
```

**Actions:**

| Action | Confirmation Required | Audit Logged |
|---|---|---|
| Suspend tenant | ✅ Modal with reason field | ✅ |
| Restore tenant | ✅ Modal | ✅ |
| Delete tenant (soft) | ✅ Type tenant name to confirm | ✅ |
| Impersonate tenant | ✅ Modal warning | ✅ |
| Override feature flag | ✅ Form with reason + expiry | ✅ |
| Change subscription package | ✅ Modal | ✅ |

---

### 4.2 Admin CRUD Summary

| Resource | List | Create | Edit | Soft Delete | Hard Delete |
|---|:---:|:---:|:---:|:---:|:---:|
| Tenants | ✅ | ✅ (manual) | ✅ | ✅ | ❌ |
| Users | ✅ | ❌ (via invite) | ✅ (role, active) | ✅ | ❌ |
| Resellers | ✅ | ❌ (self-register) | ✅ | ✅ | ❌ |
| Packages | ✅ | ✅ | ✅ | ❌ | ❌ |
| Feature Flags | ✅ | ✅ | ✅ | ❌ | ✅ |
| Themes | ✅ | ✅ | ✅ | ❌ (deactivate) | ❌ |
| Vouchers | ✅ | ✅ | ✅ (is_active) | ❌ | ❌ |
| Orders | ✅ | ❌ | ✅ (status, refund) | ❌ | ❌ |
| Audit Logs | ✅ | ❌ | ❌ | ❌ | ❌ |

---

## 5. Reseller Dashboard

### 5.1 Pages

#### `/reseller/dashboard` — Reseller Overview

**Purpose:** Revenue and client health at a glance.

**Components:**

```
<ResellerDashboard>
  <TopMetricsRow>
    <StatCard label="Active Clients" value={activeClients} />
    <StatCard label="Commission This Month" value={commissionMTD} currency="IDR" />
    <StatCard label="Total Commission" value={commissionAllTime} currency="IDR" />
    <StatCard label="Pending Payout" value={pendingPayout} />
  </TopMetricsRow>

  <ChartsRow>
    <CommissionTrendChart data={commissionByMonth} />
    <ClientPackageDistribution data={clientsByPackage} />
  </ChartsRow>

  <BottomRow>
    <RecentClientsTable rows={recentClients} />
    <RecentOrdersTable rows={recentOrders} />
  </BottomRow>
</ResellerDashboard>
```

**Data Sources:**

```typescript
// All queries filtered by reseller_id from JWT claim
// Uses RLS policy: reseller_admin can read reseller_tenants + linked orders

const resellerId = user.resellerId;

const [metrics, commissionTrend, recentClients, recentOrders] = await Promise.all([
  getResellerMetrics(resellerId),
  getCommissionByMonth(resellerId, 12),
  getRecentClients(resellerId, 5),
  getRecentOrders(resellerId, 5),
]);
```

---

#### `/reseller/clients` — Client List

**Components:**

```
<ClientsPage>
  <PageHeader title="Clients" action={<InviteClientButton />} />

  <DataTableToolbar>
    <SearchInput placeholder="Search clients..." />
    <FilterDropdown label="Package" />
    <FilterDropdown label="Status" />
  </DataTableToolbar>

  <DataTable
    columns={[
      { key: 'name', label: 'Client Name' },
      { key: 'email', label: 'Email' },
      { key: 'package', label: 'Package' },
      { key: 'invitations', label: 'Invitations' },
      { key: 'status', label: 'Status', cell: <StatusBadge /> },
      { key: 'joined_at', label: 'Joined' },
      { key: 'actions', cell: <ClientRowMenu /> },
    ]}
    data={clients}
  />
</ClientsPage>
```

**Row Actions:** View Detail · Impersonate · Change Package

---

#### `/reseller/clients/[id]` — Client Detail

**Components:**

```
<ClientDetailPage>
  <ClientHeader />

  <TabGroup>
    <Tab label="Overview">
      <ClientSubscriptionCard />
      <UsageMeterGroup />
    </Tab>
    <Tab label="Invitations">
      <InvitationsTable clientId={id} readOnly />
    </Tab>
    <Tab label="Orders">
      <OrdersTable clientId={id} />
    </Tab>
  </TabGroup>

  <ActionBar>
    <ImpersonateClientButton />
    <ChangePackageButton />
  </ActionBar>
</ClientDetailPage>
```

**Actions:** Impersonate (audit-logged) · Assign Package · Suspend Client

---

#### `/reseller/billing` — Commission & Billing

**Components:**

```
<ResellerBillingPage>
  <CommissionSummaryCard
    mtd={commissionMTD}
    lastMonth={commissionLastMonth}
    allTime={commissionAllTime}
    pending={pendingPayout}
  />

  <DataTableToolbar>
    <DateRangePicker />
    <ExportButton format="csv" label="Export Commission CSV" />
  </DataTableToolbar>

  <DataTable
    columns={[
      { key: 'order_date', label: 'Date' },
      { key: 'client_name', label: 'Client' },
      { key: 'package', label: 'Package' },
      { key: 'amount_net', label: 'Order Value' },
      { key: 'commission_amount', label: 'Commission' },
      { key: 'status', label: 'Payment Status' },
    ]}
    data={commissionOrders}
  />
</ResellerBillingPage>
```

---

#### `/reseller/branding` — White-Label Branding

**Components:**

```
<ResellerBrandingPage>
  <BrandingForm>
    <LogoUploader
      current={branding.logo_url}
      bucket="reseller-assets"
      path={`${resellerId}/logo`}
      accept="image/png,image/svg+xml,image/webp"
      maxSizeKB={2048}
    />
    <FaviconUploader />

    <ColorPicker label="Primary Color" field="primary_color" />
    <ColorPicker label="Secondary Color" field="secondary_color" />

    <TextInput label="Company Name" field="company_name" />
    <TextInput label="Support Email" field="support_email" />
    <TextInput label="Support Phone" field="support_phone" />
    <Textarea label="Footer Text" field="footer_text" />

    <Toggle label="Hide Platform Badge" field="hide_platform_badge" />

    <BrandingPreviewPanel branding={formValues} />
  </BrandingForm>
</ResellerBrandingPage>
```

**Actions:** Save Branding (writes to `resellers.branding` JSONB) · Preview Live

---

#### `/reseller/domain` — Custom Domain

**Components:**

```
<CustomDomainPage>
  <CurrentDomainCard domain={primaryDomain} status={sslStatus} />

  <AddDomainForm>
    <TextInput label="Domain" placeholder="dashboard.yourbrand.com" />
    <SubmitButton label="Add Domain" />
  </AddDomainForm>

  <DnsInstructionsPanel>
    <CnameRecord
      name={subdomain}
      value="cname.weddingplatform.com"
    />
    <VerificationStatus verified={dnsVerified} />
  </DnsInstructionsPanel>

  <SslStatusCard status={sslStatus} provisionedAt={sslProvisionedAt} />
</CustomDomainPage>
```

**Actions:** Add Domain · Verify DNS · Remove Domain · Set Primary

---

## 6. User Dashboard

### 6.1 Pages

#### `/dashboard` — User Overview

**Purpose:** Invitation portfolio summary. Primary landing for tenant owners and editors.

**Components:**

```
<UserDashboard>
  <WelcomeBanner user={user} invitation={nextUpcomingInvitation} />

  <QuickStatsRow>
    <StatCard label="Active Invitations" value={publishedCount} />
    <StatCard label="Total RSVPs" value={totalRsvp} />
    <StatCard label="Attending" value={attending} />
    <StatCard label="Plan Usage" value={`${invUsed}/${invLimit}`} />
  </QuickStatsRow>

  <InvitationGrid invitations={recentInvitations}>
    <InvitationCard
      title={inv.title}
      status={inv.status}
      eventDate={inv.event_date}
      rsvpCount={inv.rsvp_count}
      thumbnail={inv.og_image_url}
      actions={['Edit', 'View Live', 'Manage Guests']}
    />
  </InvitationGrid>

  {invitations.length === 0 && (
    <EmptyState
      icon="envelope"
      title="Create your first invitation"
      cta={<CreateInvitationButton />}
    />
  )}

  <PlanUsageSidebar
    invitations={{ used: invUsed, limit: invLimit }}
    guests={{ used: guestUsed, limit: guestLimit }}
    photos={{ used: photoUsed, limit: photoLimit }}
    onUpgrade={() => router.push('/subscription')}
  />
</UserDashboard>
```

**Data Sources:**

```typescript
// app/(app)/dashboard/page.tsx — server component
const user = await requireSession();

const [invitations, rsvpSummary, usage] = await Promise.all([
  getRecentInvitations(user.tenantId, 6),
  getRsvpSummary(user.tenantId),
  getQuotaUsage(user.tenantId),
]);
```

---

#### `/invitations` — Invitation List

**Components:**

```
<InvitationsPage>
  <PageHeader
    title="Invitations"
    action={<CreateInvitationButton disabled={atQuotaLimit} />}
  />

  <FilterTabs options={['All', 'Draft', 'Published', 'Archived']} />

  <InvitationGrid>
    {invitations.map(inv => (
      <InvitationCard key={inv.id} invitation={inv} />
    ))}
  </InvitationGrid>
</InvitationsPage>
```

---

#### `/invitations/new` — Create Invitation

**Multi-step wizard:**

```
Step 1: Choose Theme
  <ThemeGallery>
    <ThemeCard slug="classic" preview={url} isPremium={false} />
    <ThemeCard slug="floral" preview={url} isPremium={true}
      locked={!hasFeature('premium_themes')}
      lockedCta={<UpgradePrompt plan="Premium" />}
    />
  </ThemeGallery>

Step 2: Couple Details
  <CoupleDataForm>
    <TextInput label="Groom's Full Name" field="groom_name" />
    <TextInput label="Bride's Full Name" field="bride_name" />
    <PhotoUploader label="Groom Photo" bucket="invitation-images" />
    <PhotoUploader label="Bride Photo" bucket="invitation-images" />
    <TextInput label="Groom's Parents" field="groom_parents" />
    <TextInput label="Bride's Parents" field="bride_parents" />
  </CoupleDataForm>

Step 3: Event Details
  <EventDetailsForm>
    <DatePicker label="Wedding Date" field="event_date" />
    <TimePicker label="Time" field="event_time" />
    <TextInput label="Venue Name" field="event_venue" />
    <TextInput label="Address" field="event_address" />
    <TextInput label="Google Maps URL" field="event_maps_url" />
  </EventDetailsForm>

Step 4: Invitation Slug
  <SlugForm>
    <SlugInput label="Invitation URL" prefix="inv.weddingplatform.com/" />
    <SlugAvailabilityChecker />
  </SlugForm>
```

**Actions:** Save Draft on each step · Back · Next · Finish → redirect to `/invitations/[id]/edit`

---

#### `/invitations/[id]/edit` — Invitation Editor

**Purpose:** Property-based invitation editor. Not a drag-and-drop canvas — a structured panel-driven editor for performance and mobile compatibility.

**Layout:**

```
┌──────────────────────────────────────────────────────────────┐
│  EDITOR TOPBAR                                               │
│  ← Back to Invitations │ [Title] │ [Save] [Preview] [Publish]│
└────────────────┬─────────────────────────────────────────────┘
│                │                                             │
│  SECTION NAV   │  PROPERTY PANEL         │  LIVE PREVIEW    │
│  (left)        │  (center)               │  (right)         │
│                │                         │                  │
│  ○ Hero        │  [Active section form]  │  <InvitePreview  │
│  ○ Couple      │                         │    section=hero  │
│  ○ Event       │  Hero Section           │    data={...}    │
│  ○ Gallery     │  ─────────────          │  />              │
│  ● Love Story  │  Headline               │                  │
│  ○ Countdown   │  [  input field  ]      │  (iframe or      │
│  ○ Music       │                         │   React render)  │
│  ○ RSVP        │  Background Color       │                  │
│  ○ Guestbook   │  [  color picker ]      │                  │
│  ○ Gift        │                         │                  │
│  ○ Closing     │  Font Family            │                  │
│                │  [  select       ]      │                  │
│  + Add Section │                         │                  │
│                │                         │                  │
└────────────────┴─────────────────────────┴──────────────────┘
```

**Section Property Panels:**

```typescript
// components/invitation/editor/sections/

HeroSectionPanel       // headline, subheadline, bg_image, overlay_opacity, font
CoupleSectionPanel     // groom_name, bride_name, photos, love_story_text
EventSectionPanel      // date, time, venue, address, maps_url, maps_embed
GallerySectionPanel    // photo grid (upload, sort, caption, delete)
CountdownSectionPanel  // target_date, label, style (ring/flip/text)
MusicSectionPanel      // upload or YouTube/Spotify URL, autoplay toggle
RsvpSectionPanel       // deadline, meal_choice toggle, plus_one toggle, form_title
GuestbookSectionPanel  // moderation toggle, display_count, title
GiftSectionPanel       // bank accounts list, QRIS upload, e-wallet list
ClosingSectionPanel    // closing_text, signature, hashtag
```

**Auto-save:** Debounced 2s after last change → `PATCH /api/invitations/[id]` → optimistic UI.

**Actions:** Publish · Unpublish · Preview (opens `/inv/[slug]` in new tab) · Duplicate · Archive

---

#### `/invitations/[id]/guests` — Guest Management

**Components:**

```
<GuestsPage>
  <PageHeader>
    <GuestCount used={guestCount} limit={guestLimit} />
    <ActionGroup>
      <AddGuestButton />
      <ImportCsvButton
        disabled={!hasFeature('guest_import_csv')}
        lockedCta={<UpgradePrompt plan="Premium" />}
      />
      <ExportGuestButton
        disabled={!hasFeature('export_guest_csv')}
      />
      <WhatsappBlastButton
        disabled={!hasFeature('guest_whatsapp_blast')}
      />
    </ActionGroup>
  </PageHeader>

  <DataTableToolbar>
    <SearchInput placeholder="Search guests..." />
    <FilterDropdown label="Group" options={groupLabels} />
    <FilterDropdown label="RSVP Status" options={['Attending','Not Attending','No Response']} />
  </DataTableToolbar>

  <DataTable
    columns={[
      { key: 'name', label: 'Name' },
      { key: 'phone', label: 'Phone' },
      { key: 'group_label', label: 'Group' },
      { key: 'rsvp_status', label: 'RSVP', cell: <RsvpStatusBadge /> },
      { key: 'personal_link', label: 'Link', cell: <CopyLinkButton /> },
      { key: 'actions', cell: <GuestRowMenu /> },
    ]}
    data={guests}
    selectable
    bulkActions={['Delete Selected', 'Send WhatsApp']}
  />
</GuestsPage>
```

**Modals:** Add/Edit Guest Form · CSV Import Preview + Column Mapper · WhatsApp Message Composer

---

#### `/invitations/[id]/rsvp` — RSVP Dashboard

**Components:**

```
<RsvpDashboard>
  <RsvpSummaryRow>
    <StatCard label="Total Responses" value={total} />
    <StatCard label="Attending" value={attending} color="green" />
    <StatCard label="Not Attending" value={notAttending} color="red" />
    <StatCard label="Maybe" value={maybe} color="yellow" />
    <StatCard label="Total Pax" value={totalPax} />
  </RsvpSummaryRow>

  <RsvpControls>
    <Toggle label="RSVP Open" checked={isRsvpOpen} onChange={toggleRsvp} />
    <DatePicker label="RSVP Deadline" value={rsvpDeadline} />
    <ExportButton disabled={!hasFeature('export_rsvp_csv')} />
  </RsvpControls>

  <DataTable
    columns={[
      { key: 'name', label: 'Name' },
      { key: 'attendance', label: 'Status', cell: <AttendanceBadge /> },
      { key: 'pax_count', label: 'Pax' },
      { key: 'meal_choice', label: 'Meal' },
      { key: 'message', label: 'Message' },
      { key: 'submitted_at', label: 'Submitted' },
    ]}
    data={rsvpResponses}
    realtimeChannel="rsvp_responses"
  />
</RsvpDashboard>
```

**Real-time:** Supabase Realtime subscription on `rsvp_responses` for the invitation — new rows animate into the table top.

---

#### `/invitations/[id]/analytics` — Invitation Analytics

**Feature-gated:** Basic (Starter+) · Advanced (Premium+)

**Components:**

```
<InvitationAnalytics>
  {/* Basic — all Starter+ */}
  <BasicMetricsRow>
    <StatCard label="Total Views" value={totalViews} />
    <StatCard label="Unique Visitors" value={uniqueVisitors} />
    <StatCard label="RSVP Rate" value={`${rsvpRate}%`} />
  </BasicMetricsRow>

  <ViewsTrendChart data={dailyViews} range={dateRange} />

  {/* Advanced — Premium+ only */}
  {hasFeature('analytics_advanced') ? (
    <>
      <DeviceBreakdownChart data={deviceData} />
      <ReferrerTable data={referrers} />
      <HourlyHeatmap data={viewsByHour} />
      <GuestEngagementTable data={guestEngagement} />
    </>
  ) : (
    <UpgradePrompt
      feature="Advanced Analytics"
      plan="Premium"
      description="Device breakdown, referrers, hourly heatmap, guest engagement"
    />
  )}
</InvitationAnalytics>
```

---

## 7. Package Management Module

### 7.1 Pages

#### `/admin/packages` — Package List

```
<PackagesPage>
  <PageHeader title="Packages" action={<CreatePackageButton />} />

  <PackageCardGrid>
    {packages.map(pkg => (
      <PackageCard
        key={pkg.id}
        name={pkg.name}
        price={pkg.price_monthly}
        featuresCount={pkg.features.length}
        tenantCount={pkg.tenant_count}
        isActive={pkg.is_active}
        actions={['Edit', 'Duplicate', 'Deactivate']}
      />
    ))}
  </PackageCardGrid>
</PackagesPage>
```

#### `/admin/packages/[id]` — Package Editor

```
<PackageEditorPage>
  <PackageDetailsForm>
    <TextInput label="Name" field="name" />
    <TextInput label="Slug" field="slug" readonly={isExisting} />
    <Textarea label="Description" field="description" />

    <PricingSection>
      <NumberInput label="Monthly Price (IDR)" field="price_monthly" />
      <NumberInput label="Yearly Price (IDR)" field="price_yearly" />
      <SelectInput label="Currency" field="currency" />
    </PricingSection>

    <QuotaSection>
      <QuotaInput label="Max Invitations" field="max_invitations" hint="-1 = unlimited" />
      <QuotaInput label="Max Guests per Invitation" field="max_guests" />
      <QuotaInput label="Max Photos" field="max_photos" />
      <QuotaInput label="Max Team Members" field="max_team_members" />
      <QuotaInput label="Max Music Tracks" field="max_music_tracks" />
    </QuotaSection>

    <FlagsSection>
      <Toggle label="Active" field="is_active" />
      <Toggle label="Reseller-Only" field="is_reseller" />
      <Toggle label="Featured on Pricing Page" field="is_featured" />
      <NumberInput label="Trial Days" field="trial_days" />
    </FlagsSection>
  </PackageDetailsForm>

  <FeatureEntitlementsSection>
    <FeatureEntitlementTable
      packageId={id}
      allFeatureKeys={FEATURES}
      currentEntitlements={packageFeatures}
    />
    {/* Each row: feature_key | is_enabled toggle | config JSON editor */}
  </FeatureEntitlementsSection>
</PackageEditorPage>
```

**Actions:** Save · Duplicate Package · Deactivate · Preview on Pricing Page

**Data Sources:** `packages` + `package_features` — service role client.

**Validation Rules:**
- `slug` must be URL-safe, unique, immutable after first tenant subscribes.
- `price_yearly` should be validated ≤ `price_monthly * 12` (warn, not block).
- Feature keys validated against `FEATURES` enum at schema level (Zod).

---

## 8. Feature Toggle Management Module

### 8.1 Pages

#### `/admin/feature-flags` — Platform & Tenant Flag Overrides

```
<FeatureFlagsPage>
  <TabGroup>
    <Tab label="Platform-Wide Flags">
      <FeatureFlagTable
        flags={platformFlags}        {/* tenant_id IS NULL */}
        description="Affects all tenants regardless of package"
      />
    </Tab>

    <Tab label="Tenant Overrides">
      <DataTableToolbar>
        <TenantSearchInput onSelect={setSelectedTenant} />
      </DataTableToolbar>

      {selectedTenant && (
        <TenantFlagOverrideTable
          tenantId={selectedTenant.id}
          tenantName={selectedTenant.name}
          flags={tenantFlags}
          packageFlags={packageFlags}
        />
      )}
    </Tab>
  </TabGroup>
</FeatureFlagsPage>
```

**Flag Row Component:**

```typescript
// Each row in the feature flag table

<FlagRow>
  <FeatureKeyBadge key={flag.feature_key} />
  <FlagSource source={flag.source} />     {/* 'platform' | 'package' | 'override' */}
  <Toggle
    checked={flag.is_enabled}
    onChange={() => openFlagEditModal(flag)}
  />
  <ExpiryBadge expiresAt={flag.expires_at} />
  <FlagReasonText reason={flag.reason} />
  <EditButton onClick={() => openFlagEditModal(flag)} />
  <DeleteButton onClick={() => deleteFlag(flag.id)} />
</FlagRow>
```

**Create / Edit Flag Modal:**

```
<FlagEditModal>
  <SelectInput label="Feature Key" options={FEATURE_KEYS} />
  <Toggle label="Enabled" />
  <JsonEditor label="Config (optional)" placeholder='{ "max_tracks": 3 }' />
  <Textarea label="Reason" required />
  <DateTimePicker label="Expires At (optional)" />
  <SubmitButton label="Save Flag" />
</FlagEditModal>
```

**Actions:** Create platform flag · Create tenant override · Edit · Delete · Bulk disable (kill switch)

**Priority display:** Each flag row shows its effective resolution source: `platform_kill_switch` > `tenant_override` > `package` > `default`.

---

## 9. Theme Management Module

### 9.1 Pages

#### `/admin/themes` — Theme Library

```
<ThemesPage>
  <PageHeader title="Invitation Themes" action={<UploadThemeButton />} />

  <FilterTabs options={['All', 'Wedding', 'Engagement', 'General']} />
  <FilterToggle label="Premium Only" />

  <ThemeGrid>
    {themes.map(theme => (
      <ThemeAdminCard
        key={theme.id}
        name={theme.name}
        preview={theme.preview_url}
        category={theme.category}
        isPremium={theme.is_premium}
        isActive={theme.is_active}
        usedByTenants={theme.tenant_count}
        actions={['Edit', 'Preview', 'Deactivate']}
      />
    ))}
  </ThemeGrid>
</ThemesPage>
```

#### `/admin/themes/[id]` — Theme Editor

```
<ThemeEditorPage>
  <ThemeMetaForm>
    <TextInput label="Theme Name" field="name" />
    <TextInput label="Slug" field="slug" readonly={isExisting} />
    <SelectInput label="Category" options={['wedding', 'engagement', 'general']} />
    <Toggle label="Is Premium" field="is_premium" />
    <Toggle label="Is Active" field="is_active" />
    <NumberInput label="Sort Order" field="sort_order" />
  </ThemeMetaForm>

  <ThemeAssets>
    <ImageUploader
      label="Preview Image (800×600)"
      field="preview_url"
      bucket="themes"
      path={`${slug}/preview`}
    />
    <ImageUploader
      label="Thumbnail (400×300)"
      field="thumbnail_url"
      bucket="themes"
      path={`${slug}/thumbnail`}
    />
  </ThemeAssets>

  <ConfigSchemaEditor>
    {/* JSON schema editor defining which fields appear in the user's property panel */}
    <JsonEditor
      label="Config Schema"
      value={theme.config_schema}
      schema={ThemeConfigSchemaValidator}
    />
    <SchemaPreviewPanel schema={configSchema} />
  </ConfigSchemaEditor>
</ThemeEditorPage>
```

**Config Schema Shape (example):**

```json
{
  "colors": {
    "primary": { "type": "color", "default": "#8B5CF6", "label": "Primary Color" },
    "background": { "type": "color", "default": "#FDF8F0", "label": "Background" }
  },
  "fonts": {
    "heading": { "type": "font_select", "default": "Playfair Display", "label": "Heading Font" },
    "body": { "type": "font_select", "default": "Lato", "label": "Body Font" }
  },
  "sections": {
    "hero_style": { "type": "select", "options": ["full", "split", "minimal"], "default": "full" }
  }
}
```

---

## 10. User Management Module

### 10.1 Pages

#### `/admin/users` — All Users

```
<UsersPage>
  <DataTableToolbar>
    <SearchInput placeholder="Search by name, email..." />
    <FilterDropdown label="Role" options={['super_admin','reseller_admin','owner','editor','viewer']} />
    <FilterDropdown label="Status" options={['active','inactive','deleted']} />
    <FilterDropdown label="Tenant" options={tenantNames} />
  </DataTableToolbar>

  <DataTable
    columns={[
      { key: 'full_name', label: 'Name' },
      { key: 'email', label: 'Email' },
      { key: 'role', label: 'Role', cell: <RoleBadge /> },
      { key: 'tenant_name', label: 'Tenant' },
      { key: 'is_active', label: 'Status', cell: <ActiveBadge /> },
      { key: 'last_login_at', label: 'Last Login' },
      { key: 'created_at', label: 'Joined' },
      { key: 'actions', cell: <UserRowMenu /> },
    ]}
    data={users}
  />
</UsersPage>
```

**Row Actions:** View Tenant · Edit Role · Deactivate · Force Sign Out · Delete

#### `/admin/users/[id]` — User Detail

```
<UserDetailPage>
  <UserProfileCard user={user} />

  <TabGroup>
    <Tab label="Profile">
      <UserEditForm
        fields={['full_name', 'email', 'role', 'is_active']}
      />
    </Tab>
    <Tab label="Sessions">
      <ActiveSessionsTable userId={id} />
      <ForceSignOutAllButton userId={id} />
    </Tab>
    <Tab label="Audit">
      <AuditLogTable userId={id} />
    </Tab>
  </TabGroup>
</UserDetailPage>
```

**Team Management (User Portal — `/team`):**

```
<TeamPage>
  <PageHeader title="Team Members" action={<InviteTeamMemberButton />} />

  <UsageIndicator used={teamCount} limit={teamLimit} />

  <DataTable
    columns={[
      { key: 'full_name', label: 'Name' },
      { key: 'email', label: 'Email' },
      { key: 'role', label: 'Role', cell: <RoleSelect editable={isOwner} /> },
      { key: 'last_login_at', label: 'Last Active' },
      { key: 'actions', cell: <RemoveMemberButton /> },
    ]}
    data={teamMembers}
  />
</TeamPage>
```

**Invite Modal:**

```
<InviteTeamMemberModal>
  <EmailInput label="Email Address" />
  <RoleSelect label="Role" options={['editor', 'viewer']} />
  <SubmitButton label="Send Invitation" />
</InviteTeamMemberModal>
```

---

## 11. Reseller Management Module

### 11.1 Pages

#### `/admin/resellers` — Reseller List

```
<ResellersPage>
  <TabGroup>
    <Tab label="Active" count={activeCount} />
    <Tab label="Pending Approval" count={pendingCount} badge="warning" />
    <Tab label="Suspended" count={suspendedCount} />
  </TabGroup>

  <DataTable
    columns={[
      { key: 'name', label: 'Reseller Name' },
      { key: 'slug', label: 'Slug' },
      { key: 'owner_email', label: 'Owner Email' },
      { key: 'client_count', label: 'Clients' },
      { key: 'commission_pct', label: 'Commission %' },
      { key: 'commission_total', label: 'Total Commission' },
      { key: 'status', label: 'Status', cell: <StatusBadge /> },
      { key: 'created_at', label: 'Applied' },
      { key: 'actions', cell: <ResellerRowMenu /> },
    ]}
    data={resellers}
  />
</ResellersPage>
```

**Row Actions:** View Detail · Approve (pending) · Suspend · Adjust Commission · Impersonate

#### `/admin/resellers/[id]` — Reseller Detail

```
<ResellerDetailPage>
  <ResellerHeader reseller={reseller} />

  <TabGroup>
    <Tab label="Overview">
      <ResellerMetricsRow
        clientCount={clientCount}
        commissionMTD={commissionMTD}
        commissionAllTime={commissionAllTime}
      />
      <ResellerProfileForm
        fields={['name', 'commission_pct', 'status', 'notes']}
      />
    </Tab>

    <Tab label="Clients">
      <ResellerClientsTable resellerId={id} />
    </Tab>

    <Tab label="Commission">
      <CommissionTable resellerId={id} />
      <ExportCsvButton />
    </Tab>

    <Tab label="Domains">
      <ResellerDomainsTable resellerId={id} />
    </Tab>

    <Tab label="Branding Preview">
      <BrandingPreviewPanel branding={reseller.branding} />
    </Tab>

    <Tab label="Audit">
      <AuditLogTable resellerId={id} />
    </Tab>
  </TabGroup>

  <DangerZone>
    <ApproveResellerButton visible={isPending} />
    <SuspendResellerButton visible={isActive} />
    <DeleteResellerButton />
  </DangerZone>
</ResellerDetailPage>
```

---

## 12. Analytics Dashboard Module

### 12.1 Super Admin Platform Analytics (`/admin/analytics`)

```
<PlatformAnalyticsPage>
  <DateRangeSelector presets={['7d', '30d', '90d', '12m', 'custom']} />

  <MetricsRow>
    <StatCard label="New Signups" value={signups} delta={signupsDelta} />
    <StatCard label="MRR" value={mrr} delta={mrrDelta} />
    <StatCard label="Total RSVPs Processed" value={rsvpTotal} />
    <StatCard label="Invitations Published" value={invPublished} />
    <StatCard label="Churn Rate" value={churnRate} />
    <StatCard label="Avg Revenue Per User" value={arpu} />
  </MetricsRow>

  <ChartsSection>
    <MrrTrendChart />            {/* MRR waterfall: new + expansion - churn */}
    <SignupConversionChart />    {/* Registered → Paid funnel */}
    <PackageDistributionChart />
    <RevenueByResellerChart />
    <RsvpVolumeByDayChart />
    <TopInvitationsByViewsTable />
  </ChartsSection>

  <GeoSection>
    <TopTenantsTable />
    <TopResellersTable />
  </GeoSection>
</PlatformAnalyticsPage>
```

### 12.2 User Invitation Analytics (`/invitations/[id]/analytics`)

See Section 6.1 — `/invitations/[id]/analytics` above.

### 12.3 Reseller Analytics (within `/reseller/dashboard`)

Scoped to the reseller's own clients. Commission trend, client growth, package distribution across client base.

---

## 13. Billing Dashboard Module

### 13.1 Super Admin Orders (`/admin/orders`)

```
<OrdersPage>
  <DataTableToolbar>
    <SearchInput placeholder="Search order ID, tenant, payment ref..." />
    <FilterDropdown label="Status" options={['pending','paid','failed','refunded','expired']} />
    <FilterDropdown label="Provider" options={['midtrans','stripe','manual']} />
    <FilterDropdown label="Package" options={packageSlugs} />
    <FilterDropdown label="Reseller" options={resellerNames} />
    <DateRangePicker label="Paid Date" />
    <ExportButton format="csv" />
  </DataTableToolbar>

  <DataTable
    columns={[
      { key: 'id', label: 'Order ID', cell: <ShortId /> },
      { key: 'tenant_name', label: 'Tenant' },
      { key: 'package_name', label: 'Package' },
      { key: 'billing_cycle', label: 'Cycle' },
      { key: 'amount_net', label: 'Amount', align: 'right' },
      { key: 'commission_amount', label: 'Commission', align: 'right' },
      { key: 'payment_provider', label: 'Provider' },
      { key: 'status', label: 'Status', cell: <OrderStatusBadge /> },
      { key: 'paid_at', label: 'Paid At' },
      { key: 'reseller_name', label: 'Reseller' },
      { key: 'actions', cell: <OrderRowMenu /> },
    ]}
    data={orders}
  />

  <RevenueSummaryFooter
    totalGross={totalGross}
    totalDiscount={totalDiscount}
    totalNet={totalNet}
    totalCommission={totalCommission}
  />
</OrdersPage>
```

**Order Detail Modal:**

```
<OrderDetailModal>
  <OrderMetaSection>
    id │ tenant │ package │ billing_cycle │ provider │ payment_ref
  </OrderMetaSection>
  <OrderAmountsSection>
    amount_gross │ amount_discount │ voucher_code │ amount_net │ commission
  </OrderAmountsSection>
  <PaymentDataSection>
    <JsonViewer data={order.payment_data} />
  </PaymentDataSection>
  <OrderActions>
    <MarkAsPaidButton visible={isPending} />
    <RefundButton visible={isPaid} />
  </OrderActions>
</OrderDetailModal>
```

### 13.2 User Subscription Page (`/subscription`)

```
<SubscriptionPage>
  <CurrentPlanCard>
    <PlanName>{package.name}</PlanName>
    <PlanPrice monthly={package.price_monthly} yearly={package.price_yearly} />
    <BillingCycleBadge cycle={subscription.billing_cycle} />
    <RenewalDate date={subscription.current_period_end} />
    <SubscriptionStatus status={subscription.status} />
  </CurrentPlanCard>

  <UsageMeterGroup>
    <UsageMeter label="Invitations" used={invUsed} limit={invLimit} />
    <UsageMeter label="Guests (max per invitation)" used={guestMax} limit={guestLimit} />
    <UsageMeter label="Photos" used={photoUsed} limit={photoLimit} />
    <UsageMeter label="Team Members" used={teamUsed} limit={teamLimit} />
  </UsageMeterGroup>

  <PricingTable
    packages={availablePackages}
    currentPackageId={subscription.package_id}
    onSelect={openUpgradeModal}
  />

  <VoucherForm
    onApply={applyVoucher}
    applied={appliedVoucher}
  />

  <InvoiceHistoryTable orders={orders} />
</SubscriptionPage>
```

**Upgrade Modal:**

```
<UpgradeModal>
  <PackageSummary package={selectedPackage} />
  <BillingCycleToggle options={['monthly', 'yearly']} />
  <PriceSummary gross={gross} discount={discount} net={net} />
  <VoucherInput />
  <PayButton provider="midtrans" onSuccess={handlePaymentSuccess} />
</UpgradeModal>
```

---

## 14. System Settings Module

### 14.1 Pages

#### `/admin/settings/general`

```
<GeneralSettingsForm>
  <TextInput label="Platform Name" field="platform_name" />
  <TextInput label="Platform Domain" field="platform_domain" />
  <TextInput label="Support Email" field="support_email" />
  <TextInput label="Default From Email" field="default_from_email" />
  <SelectInput label="Default Currency" field="default_currency" options={['IDR','USD']} />
  <SelectInput label="Default Locale" field="default_locale" />
  <Toggle label="Open Registration" field="open_registration"
    hint="Disable to prevent new signups" />
</GeneralSettingsForm>
```

#### `/admin/settings/maintenance`

```
<MaintenanceSettingsPage>
  <MaintenanceModeCard>
    <Toggle
      label="Maintenance Mode"
      checked={maintenanceMode}
      onChange={toggleMaintenanceMode}
    />
    <Textarea label="Maintenance Message" field="maintenance_message" />
    <DateTimePicker label="Estimated End Time" field="maintenance_ends_at" />
  </MaintenanceModeCard>

  <MaintenancePreviewCard message={maintenanceMessage} />
</MaintenanceSettingsPage>
```

**Effect:** When `MAINTENANCE_MODE` feature flag is `true` (platform-wide), Edge Middleware intercepts all non-admin requests and renders the maintenance page.

#### `/admin/settings/email-templates`

```
<EmailTemplatesPage>
  <TemplateList
    templates={[
      'rsvp_confirmation',
      'payment_receipt',
      'invitation_published',
      'team_invite',
      'password_reset',
      'welcome',
    ]}
    onSelect={openTemplateEditor}
  />
</EmailTemplatesPage>

<EmailTemplateEditor>
  <TemplateMetaForm>
    <TextInput label="Subject Line" field="subject" />
    <TextInput label="From Name" field="from_name" />
  </TemplateMetaForm>
  <HtmlEditor label="Email Body (HTML)" field="html_body" />
  <TextEditor label="Plain Text Version" field="text_body" />
  <VariableReference variables={['{{recipient_name}}', '{{invitation_title}}', ...]} />
  <PreviewSendButton />
</EmailTemplateEditor>
```

#### `/admin/settings/payments`

```
<PaymentSettingsPage>
  <ProviderCard label="Midtrans">
    <TextInput label="Server Key" field="midtrans_server_key" type="password" />
    <TextInput label="Client Key" field="midtrans_client_key" type="password" />
    <TextInput label="Webhook Secret" field="midtrans_webhook_secret" type="password" />
    <Toggle label="Production Mode" field="midtrans_production" />
    <TestConnectionButton provider="midtrans" />
  </ProviderCard>

  <ProviderCard label="Stripe" badge="Secondary">
    <TextInput label="Secret Key" field="stripe_secret_key" type="password" />
    <TextInput label="Webhook Secret" field="stripe_webhook_secret" type="password" />
    <Toggle label="Enabled" field="stripe_enabled" />
  </ProviderCard>
</PaymentSettingsPage>
```

---

## 15. Audit Logs Module

### 15.1 Pages

#### `/admin/audit-logs` — Super Admin Audit Log

```
<AuditLogsPage>
  <DataTableToolbar>
    <SearchInput placeholder="Search action, resource, user..." />
    <FilterDropdown label="Action" options={AUDIT_ACTIONS} />
    <FilterDropdown label="Resource Type" options={RESOURCE_TYPES} />
    <TenantSearchInput label="Tenant" />
    <UserSearchInput label="Actor" />
    <DateRangePicker label="Date Range" />
    <ExportButton format="csv" />
  </DataTableToolbar>

  <DataTable
    columns={[
      { key: 'created_at', label: 'Time', sortable: true },
      { key: 'actor', label: 'Actor', cell: <ActorCell /> },
      { key: 'actor_role', label: 'Role', cell: <RoleBadge /> },
      { key: 'action', label: 'Action', cell: <ActionBadge /> },
      { key: 'resource_type', label: 'Resource' },
      { key: 'resource_id', label: 'Resource ID', cell: <ShortId /> },
      { key: 'tenant_name', label: 'Tenant' },
      { key: 'ip_address', label: 'IP' },
      { key: 'actions', cell: <ViewDiffButton /> },
    ]}
    data={auditLogs}
    pagination={cursorPagination}
  />
</AuditLogsPage>
```

**Audit Diff Modal:**

```
<AuditDiffModal>
  <DiffViewer
    before={log.old_data}
    after={log.new_data}
    format="json"
  />
  <MetaSection>
    actor │ role │ action │ ip_address │ user_agent │ timestamp
  </MetaSection>
</AuditDiffModal>
```

### 15.2 Audit Actions Reference

```typescript
// lib/audit/actions.ts

export const AUDIT_ACTIONS = {
  // Tenant lifecycle
  'tenant.create':          'Tenant Created',
  'tenant.update':          'Tenant Updated',
  'tenant.suspend':         'Tenant Suspended',
  'tenant.restore':         'Tenant Restored',
  'tenant.delete':          'Tenant Deleted',

  // Invitation lifecycle
  'invitation.publish':     'Invitation Published',
  'invitation.unpublish':   'Invitation Unpublished',
  'invitation.archive':     'Invitation Archived',
  'invitation.delete':      'Invitation Deleted',

  // Subscription
  'subscription.create':    'Subscription Created',
  'subscription.upgrade':   'Subscription Upgraded',
  'subscription.cancel':    'Subscription Cancelled',

  // Feature flags
  'feature_flag.create':    'Feature Flag Created',
  'feature_flag.update':    'Feature Flag Updated',
  'feature_flag.delete':    'Feature Flag Deleted',

  // Auth
  'auth.impersonation.start':  'Impersonation Started',
  'auth.impersonation.end':    'Impersonation Ended',
  'auth.brute_force_blocked':  'Login Brute Force Blocked',
  'auth.force_signout':        'Force Sign Out',

  // Reseller
  'reseller.approve':       'Reseller Approved',
  'reseller.suspend':       'Reseller Suspended',
  'reseller.commission_update': 'Commission Rate Updated',

  // Orders
  'order.refund':           'Order Refunded',
  'order.mark_paid':        'Order Marked as Paid',
} as const;
```

### 15.3 Audit Log Writer Helper

```typescript
// lib/audit/write.ts

export async function writeAuditLog(
  request: Request,
  action: keyof typeof AUDIT_ACTIONS,
  resourceType: string,
  resourceId: string,
  options?: {
    tenantId?: string;
    userId?: string;
    actorRole?: string;
    oldData?: Record<string, unknown>;
    newData?: Record<string, unknown>;
  }
): Promise<void> {
  const admin = createAdminClient();
  const ip = request.headers.get('x-forwarded-for') ?? 'unknown';
  const ua = request.headers.get('user-agent') ?? '';

  await admin.from('audit_logs').insert({
    action,
    resource_type: resourceType,
    resource_id: resourceId,
    tenant_id: options?.tenantId ?? null,
    user_id: options?.userId ?? null,
    actor_role: options?.actorRole ?? null,
    old_data: options?.oldData ?? null,
    new_data: options?.newData ?? null,
    ip_address: ip,
    user_agent: ua,
  });
}
```

---

## 16. Permission Mapping

### 16.1 Page-Level Access Control

| Route | super_admin | reseller_admin | owner | editor | viewer |
|---|:---:|:---:|:---:|:---:|:---:|
| `/admin/*` | ✅ | ❌ | ❌ | ❌ | ❌ |
| `/reseller/*` | ✅ | ✅ | ❌ | ❌ | ❌ |
| `/dashboard` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `/invitations` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `/invitations/new` | ✅ | ✅ | ✅ | ✅ | ❌ |
| `/invitations/[id]/edit` | ✅ | ✅ | ✅ | ✅ | ❌ |
| `/invitations/[id]/guests` | ✅ | ✅ | ✅ | ✅ | ❌ |
| `/invitations/[id]/rsvp` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `/invitations/[id]/analytics` | ✅ | ✅ | ✅ | ✅ (basic) | ❌ |
| `/subscription` | ✅ | ✅ | ✅ | ❌ | ❌ |
| `/team` | ✅ | ✅ | ✅ | ❌ | ❌ |
| `/settings/*` | ✅ | ✅ | ✅ | ✅ (profile only) | ✅ (profile only) |

### 16.2 Feature-Gated UI Elements

| UI Element | Feature Flag | Fallback |
|---|---|---|
| Import Guests (CSV) button | `guest_import_csv` | Locked with upgrade prompt |
| Export Guest CSV button | `export_guest_csv` | Hidden |
| Export RSVP CSV button | `export_rsvp_csv` | Locked with upgrade prompt |
| WhatsApp Blast button | `guest_whatsapp_blast` | Hidden |
| Music section in editor | `music_player` | Section locked |
| Gift/QRIS section | `gift_registry` | Section locked |
| Guestbook section | `guestbook` | Section locked |
| Advanced analytics tab | `analytics_advanced` | Upgrade prompt banner |
| Premium themes in gallery | `premium_themes` | Theme cards show lock icon |
| Custom domain settings | `custom_domain` | Settings tab hidden |
| Remove branding toggle | `remove_platform_badge` | Toggle hidden |
| QR Code tab | `qr_invitation` | Tab hidden |
| QR Check-in tab | `qr_checkin` | Tab hidden |

### 16.3 API Route Permission Map

| API Route | Method | Required Permission | Feature Gate |
|---|---|---|---|
| `/api/invitations` | POST | `invitation:write` | quota: `max_invitations` |
| `/api/invitations/[id]` | PATCH | `invitation:write` | — |
| `/api/invitations/[id]/publish` | POST | `invitation:publish` | — |
| `/api/invitations/[id]/guests` | GET | `guest:read` | — |
| `/api/invitations/[id]/guests` | POST | `guest:write` | quota: `max_guests` |
| `/api/invitations/[id]/guests/import` | POST | `guest:write` | `guest_import_csv` |
| `/api/invitations/[id]/guests/export` | GET | `guest:read` | `export_guest_csv` |
| `/api/invitations/[id]/rsvp` | GET | `rsvp:read` | — |
| `/api/invitations/[id]/rsvp/export` | GET | `rsvp:read` | `export_rsvp_csv` |
| `/api/invitations/[id]/analytics` | GET | `analytics:read` | `analytics_basic` |
| `/api/invitations/[id]/analytics/advanced` | GET | `analytics:read` | `analytics_advanced` |
| `/api/invitations/[id]/qr` | POST | `invitation:write` | `qr_invitation` |
| `/api/invitations/[id]/checkin` | POST | `guest:write` | `qr_checkin` |
| `/api/team/invite` | POST | `team:write` | quota: `max_team_members` |
| `/api/subscription/upgrade` | POST | `subscription:write` | — |
| `/api/admin/*` | ALL | `super_admin` role | — |
| `/api/reseller/*` | ALL | `reseller_admin` role | — |
| `/api/rsvp` | POST | Public | invitation published + open |
| `/api/guestbook` | POST | Public | invitation published |

---

## 17. UI Layout Architecture

### 17.1 Shell Layout

```
┌────────────────────────────────────────────────────────────────┐
│  TOPBAR (h-16, fixed)                                          │
│  ┌──────────┐  Breadcrumb / Page Title     User Menu  ──────┐ │
│  │  Logo    │                              [Avatar] [Notif]  │ │
│  └──────────┘                                                │ │
└─────────────────────────┬──────────────────────────────────────┘
│                         │                                      │
│  SIDEBAR                │  MAIN CONTENT                        │
│  (w-64 desktop)         │  (flex-1, overflow-y-auto)           │
│  (hidden mobile)        │                                      │
│                         │  <PageHeader />                      │
│  Nav Groups:            │  <PageContent />                     │
│  - Primary nav items    │                                      │
│  - Section dividers     │                                      │
│  - Collapse button      │                                      │
│                         │                                      │
│  Footer:                │                                      │
│  - Plan badge           │                                      │
│  - Upgrade CTA          │                                      │
└─────────────────────────┴──────────────────────────────────────┘
```

### 17.2 Page Layout Zones

```typescript
// Standard page layout

<PageLayout>
  <PageHeader>
    <PageTitle>{title}</PageTitle>
    <PageDescription>{description}</PageDescription>
    <PageActions>{/* Primary CTA buttons */}</PageActions>
  </PageHeader>

  <PageContent>
    {/* Varies by page: DataTable / Grid / Form / Charts */}
  </PageContent>
</PageLayout>
```

### 17.3 Component Library Conventions

Built on **shadcn/ui** + **Tailwind CSS**. No custom UI kit — consistency through design tokens.

```typescript
// Design tokens (tailwind.config.ts)

colors: {
  brand: {
    50:  '#fdf4ff',
    500: '#a855f7',    // primary purple
    600: '#9333ea',
    900: '#581c87',
  },
  danger: {
    50:  '#fff1f2',
    500: '#f43f5e',
  },
}

// Status badge color map
const STATUS_COLORS = {
  active:     'bg-green-100 text-green-800',
  suspended:  'bg-yellow-100 text-yellow-800',
  pending:    'bg-blue-100 text-blue-800',
  deleted:    'bg-gray-100 text-gray-500',
  published:  'bg-green-100 text-green-800',
  draft:      'bg-gray-100 text-gray-600',
  archived:   'bg-gray-100 text-gray-400',
  paid:       'bg-green-100 text-green-800',
  failed:     'bg-red-100 text-red-800',
  refunded:   'bg-orange-100 text-orange-800',
};
```

### 17.4 DataTable Architecture

The `DataTable` component is the backbone of all list views. It handles:

```typescript
// components/admin/DataTable.tsx

interface DataTableProps<T> {
  columns: ColumnDef<T>[];
  data: T[];
  pagination?: {
    page: number;
    pageSize: number;
    total: number;
    onPageChange: (page: number) => void;
  };
  sorting?: {
    column: string;
    direction: 'asc' | 'desc';
    onSort: (column: string) => void;
  };
  selectable?: boolean;
  bulkActions?: BulkAction[];
  loading?: boolean;
  emptyState?: ReactNode;
}
```

Server-side sorting and pagination — no client-side data slicing. URL state via `nuqs` for shareable filtered views.

```
/admin/tenants?page=2&sort=created_at&dir=desc&status=active&package=premium
```

### 17.5 Form Architecture

All create/edit forms use **Server Actions** with Zod validation and React `useFormState` + `useFormStatus` for progressive enhancement.

```typescript
// Pattern for all admin forms

// 1. Define schema
const PackageSchema = z.object({
  name: z.string().min(1).max(100),
  price_monthly: z.coerce.number().min(0),
  // ...
});

// 2. Server action
export async function upsertPackageAction(
  prevState: FormState,
  formData: FormData
): Promise<FormState> {
  const user = await requireRole(['super_admin']);
  const parsed = PackageSchema.safeParse(Object.fromEntries(formData));
  if (!parsed.success) return { errors: parsed.error.flatten().fieldErrors };

  // DB operation
  await writeAuditLog(...);
  revalidatePath('/admin/packages');
  return { success: true };
}

// 3. Client form
const [state, action] = useFormState(upsertPackageAction, {});
```

---

## 18. Mobile Responsive Strategy

### 18.1 Breakpoint Strategy

```
Mobile:   < 768px   (sm)  → Stack layout, bottom nav, sheet drawers
Tablet:   768-1024px (md) → Sidebar collapses to icon rail
Desktop: > 1024px   (lg)  → Full sidebar + split panes
```

### 18.2 Mobile Navigation

On mobile (`< 768px`), the sidebar is replaced by a **bottom navigation bar** for the User Dashboard, and a **hamburger → sheet drawer** for Admin and Reseller portals.

```typescript
// components/dashboard/UserShell.tsx

// Desktop: sidebar nav
// Mobile: bottom tab bar with 5 items max

const MOBILE_NAV_ITEMS = [
  { label: 'Home',        href: '/dashboard',     icon: HomeIcon },
  { label: 'Invitations', href: '/invitations',   icon: EnvelopeIcon },
  { label: 'RSVPs',       href: null,             icon: null, disabled: true },
  { label: 'Plan',        href: '/subscription',  icon: CreditCardIcon },
  { label: 'Settings',    href: '/settings',      icon: CogIcon },
];
```

### 18.3 DataTable Mobile Adaptation

On mobile, DataTable collapses to a **card list** view — each row becomes a card showing 2–3 key fields with a context menu for actions.

```typescript
// DataTable auto-switches rendering based on viewport

function DataTable({ columns, data, ...props }) {
  const isMobile = useMediaQuery('(max-width: 768px)');

  if (isMobile) {
    return <DataCardList columns={columns} data={data} {...props} />;
  }

  return <DataTableDesktop columns={columns} data={data} {...props} />;
}
```

### 18.4 Invitation Editor Mobile Layout

On mobile, the editor switches from a three-column split to a **tab-based layout**:

```
Mobile Editor Tabs:
  [Sections] → section nav list
  [Edit]     → property panel for selected section
  [Preview]  → full-width mobile preview
```

The Preview tab renders the actual invitation component (not an iframe) at `390px` width, matching the dominant WhatsApp-opened viewport.

### 18.5 QR Check-in — Mobile-First

The QR check-in scanner is designed exclusively for mobile use by event ushers:

```typescript
// app/(app)/invitations/[id]/qr/checkin/page.tsx

<QrCheckinPage>
  <QrScannerCamera
    onScan={handleScan}
    facing="environment"    // rear camera
  />
  <CheckinResultCard
    guest={lastCheckedGuest}
    status={checkinStatus}  // 'success' | 'already_checked' | 'not_found'
  />
  <CheckinCountDisplay
    checkedIn={checkedInCount}
    total={totalGuests}
  />
</QrCheckinPage>
```

Full-screen camera view optimized for one-handed operation. Vibration feedback on successful scan.

### 18.6 Responsive Component Rules

| Component | Mobile Behavior |
|---|---|
| `StatCard` | Full width, 2-column grid on sm, 4-column on lg |
| `DataTable` | Switches to `DataCardList` |
| `PageHeader` actions | Stack below title on mobile |
| `TabGroup` | Horizontal scroll on mobile |
| `Modal` | Full-screen sheet on mobile |
| `DateRangePicker` | Stacked inputs (no calendar popover on mobile) |
| `Sidebar` | Bottom nav (user) or drawer (admin/reseller) |
| `InvitationGrid` | 1 column mobile, 2 tablet, 3 desktop |
| `EditorLayout` | Tabbed (mobile) vs 3-column split (desktop) |

---

## 19. Future Scalability

### 19.1 Admin Module Plugin System (Phase 4+)

The current admin panel hard-codes all modules. For Phase 4+, introduce a **module registry** pattern so new modules (SMS notifications, physical print orders, affiliate program) can be added without modifying core layout files:

```typescript
// config/admin-modules.ts

export const ADMIN_MODULES: AdminModule[] = [
  {
    id: 'tenants',
    label: 'Tenants',
    icon: BuildingOffice2Icon,
    href: '/admin/tenants',
    requiredRole: 'super_admin',
    featureFlag: null,
  },
  // ... future modules registered here
  {
    id: 'sms_notifications',
    label: 'SMS Notifications',
    icon: DevicePhoneMobileIcon,
    href: '/admin/sms',
    requiredRole: 'super_admin',
    featureFlag: 'sms_module',        // only shows when flag enabled
  },
];
```

### 19.2 Reseller Sub-Admin (Phase 3+)

Resellers currently have a single `owner_user_id`. Phase 3+ adds a `reseller_staff` role allowing resellers to grant portal access to their own team:

```sql
-- Future: reseller staff table
CREATE TABLE reseller_staff (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reseller_id  UUID NOT NULL REFERENCES resellers(id),
  user_id      UUID NOT NULL REFERENCES users(id),
  staff_role   TEXT NOT NULL DEFAULT 'viewer'
               CHECK (staff_role IN ('manager', 'support', 'viewer')),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### 19.3 White-Label Admin Portal (Phase 3+)

Resellers can already white-label the invitation-facing pages. Phase 3+ extends this to the reseller client portal (`/dashboard`, `/invitations/*`):

- `resellers.branding` JSONB already stores `logo_url`, `primary_color`, `company_name`.
- Middleware injects branding into response headers.
- `UserShell` reads branding from headers and applies CSS variables:

```typescript
// CSS variables injected per request for white-label

:root {
  --brand-primary: ${branding.primary_color ?? '#a855f7'};
  --brand-logo: url(${branding.logo_url});
  --brand-name: "${branding.company_name ?? 'Wedding Platform'}";
}
```

### 19.4 Real-Time Admin Notifications (Phase 4+)

Add a platform-wide notification bell to the admin topbar using Supabase Realtime, subscribing to:

- New reseller registrations (pending approval)
- Failed payments (`orders.status = 'failed'`)
- New tenant signups
- Brute force login alerts (`audit_logs.action = 'auth.brute_force_blocked'`)

```typescript
// hooks/use-admin-notifications.ts

export function useAdminNotifications() {
  const supabase = createBrowserClient();

  useEffect(() => {
    const channel = supabase
      .channel('admin-notifications')
      .on('postgres_changes', {
        event: 'INSERT',
        schema: 'public',
        table: 'resellers',
        filter: 'status=eq.pending',
      }, handleNewReseller)
      .on('postgres_changes', {
        event: 'UPDATE',
        schema: 'public',
        table: 'orders',
        filter: 'status=eq.failed',
      }, handleFailedOrder)
      .subscribe();

    return () => supabase.removeChannel(channel);
  }, []);
}
```

### 19.5 Granular RBAC for Enterprise (Phase 4+)

Current roles are hard-coded. Enterprise tenants may need custom role definitions. The upgrade path:

1. Add `custom_roles` table (tenant-scoped).
2. Add `user_custom_role_id` FK on `users` (nullable).
3. JWT claims hook emits a `permissions[]` array claim.
4. `hasPermission()` helper reads from claim array, not hard-coded map.
5. Admin UI gains a "Roles & Permissions" editor page per tenant.

This is intentionally deferred — the five built-in roles cover all Phase 1–3 use cases without the complexity of a dynamic permission engine.

### 19.6 Observability Integration (Phase 4+)

Future admin panel additions:

- **Error monitoring:** Sentry issue feed embedded in `/admin/settings/monitoring`.
- **Uptime status:** Supabase + Vercel status widgets in admin dashboard.
- **Query performance:** Slow query log viewer pulling from Supabase observability API.
- **PostHog funnel:** Embedded product analytics dashboard showing registration → publish → paid conversion funnel.

---

## Appendix A — Folder Structure (Admin-Specific)

```
app/
├── (admin)/
│   ├── layout.tsx                       # Admin shell + sidebar
│   ├── dashboard/
│   │   └── page.tsx
│   ├── tenants/
│   │   ├── page.tsx                     # List
│   │   ├── [id]/
│   │   │   └── page.tsx                 # Detail + tabs
│   │   └── actions.ts                   # Server actions
│   ├── users/
│   │   ├── page.tsx
│   │   └── [id]/page.tsx
│   ├── resellers/
│   │   ├── page.tsx
│   │   └── [id]/page.tsx
│   ├── packages/
│   │   ├── page.tsx
│   │   └── [id]/page.tsx
│   ├── feature-flags/
│   │   └── page.tsx
│   ├── themes/
│   │   ├── page.tsx
│   │   └── [id]/page.tsx
│   ├── vouchers/
│   │   └── page.tsx
│   ├── orders/
│   │   └── page.tsx
│   ├── analytics/
│   │   └── page.tsx
│   ├── audit-logs/
│   │   └── page.tsx
│   └── settings/
│       ├── general/page.tsx
│       ├── email-templates/page.tsx
│       ├── payments/page.tsx
│       └── maintenance/page.tsx
│
├── (reseller)/
│   ├── layout.tsx
│   ├── dashboard/page.tsx
│   ├── clients/
│   │   ├── page.tsx
│   │   └── [id]/page.tsx
│   ├── billing/page.tsx
│   ├── vouchers/page.tsx
│   ├── branding/page.tsx
│   ├── domain/page.tsx
│   └── settings/page.tsx
│
└── (app)/
    ├── layout.tsx
    ├── dashboard/page.tsx
    ├── invitations/
    │   ├── page.tsx
    │   ├── new/page.tsx
    │   └── [id]/
    │       ├── edit/page.tsx
    │       ├── guests/page.tsx
    │       ├── rsvp/page.tsx
    │       ├── guestbook/page.tsx
    │       ├── qr/page.tsx
    │       └── analytics/page.tsx
    ├── subscription/page.tsx
    ├── team/page.tsx
    └── settings/
        ├── profile/page.tsx
        ├── security/page.tsx
        └── domain/page.tsx
```

---

## Appendix B — Key Component Inventory

| Component | Location | Used By |
|---|---|---|
| `AdminShell` | `components/admin/AdminShell.tsx` | All admin pages |
| `DataTable` | `components/admin/DataTable.tsx` | All list pages |
| `DataTableToolbar` | `components/admin/DataTableToolbar.tsx` | All list pages |
| `StatCard` | `components/admin/StatCard.tsx` | All dashboards |
| `ConfirmDialog` | `components/admin/ConfirmDialog.tsx` | All destructive actions |
| `AuditLogTable` | `components/admin/AuditLogTable.tsx` | Tenant/User detail, audit page |
| `UsageMeter` | `components/dashboard/UsageMeter.tsx` | User dashboard, subscription page |
| `UpgradePrompt` | `components/dashboard/UpgradePrompt.tsx` | Feature-locked UI elements |
| `ThemeGallery` | `components/invitation/ThemeGallery.tsx` | Create invitation wizard |
| `InvitationCard` | `components/invitation/InvitationCard.tsx` | Invitation list/grid |
| `EditorLayout` | `components/invitation/editor/EditorLayout.tsx` | Invitation editor |
| `SectionNavPanel` | `components/invitation/editor/SectionNavPanel.tsx` | Editor section list |
| `PropertyPanel` | `components/invitation/editor/PropertyPanel.tsx` | Editor property forms |
| `InvitationPreview` | `components/invitation/InvitationPreview.tsx` | Editor live preview |
| `RsvpSummaryRow` | `components/rsvp/RsvpSummaryRow.tsx` | RSVP dashboard |
| `QrScannerCamera` | `components/qr/QrScannerCamera.tsx` | QR check-in page |
| `BrandingPreviewPanel` | `components/reseller/BrandingPreviewPanel.tsx` | Reseller branding editor |
| `CommissionTable` | `components/reseller/CommissionTable.tsx` | Reseller billing |
| `PricingTable` | `components/subscription/PricingTable.tsx` | Subscription upgrade page |
| `FeatureEntitlementTable` | `components/admin/FeatureEntitlementTable.tsx` | Package editor |

---

*End of PHASE4_ADMIN_ARCHITECTURE.md*
