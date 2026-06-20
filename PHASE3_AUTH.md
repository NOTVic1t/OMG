# PHASE3_AUTH.md
# Wedding Invitation SaaS Platform — Authentication & Authorization Architecture

> **Version:** 1.0.0
> **Date:** 2026-06-12
> **Status:** Approved for Development
> **Depends on:** PHASE1_ARCHITECTURE.md, PHASE2_DATABASE.md

---

## Table of Contents

1. [Authentication Architecture](#1-authentication-architecture)
2. [Authorization Architecture](#2-authorization-architecture)
3. [User Registration](#3-user-registration)
4. [Login System](#4-login-system)
5. [Password Management](#5-password-management)
6. [Role System & Permission Matrix](#6-role-system--permission-matrix)
7. [Route Protection](#7-route-protection)
8. [Middleware Architecture](#8-middleware-architecture)
9. [Session Management](#9-session-management)
10. [Security Architecture](#10-security-architecture)
11. [Supabase Integration](#11-supabase-integration)
12. [Future Scalability](#12-future-scalability)

---

## 1. Authentication Architecture

### 1.1 System Overview

Authentication is handled entirely by **Supabase Auth**, which manages the `auth.users` table, token issuance, OAuth flows, and session persistence. The application layer never stores raw passwords or manages raw JWTs — it only reads and validates what Supabase provides.

The custom `users` table in the public schema mirrors `auth.users` and stores application-level profile data (role, tenant_id, is_active). The two are kept in sync via a Postgres trigger on `auth.users`.

```
┌───────────────────────────────────────────────────────────────┐
│                        CLIENT                                  │
│  Browser / Mobile PWA                                         │
└──────────────┬────────────────────────────────────────────────┘
               │
               │  1. Login / Register request
               ▼
┌───────────────────────────────────────────────────────────────┐
│                  NEXT.JS EDGE MIDDLEWARE                        │
│  - Reads Supabase session cookie                              │
│  - Validates JWT signature                                    │
│  - Extracts custom claims (tenant_id, role, package_id)       │
│  - Routes or rejects based on role + path                     │
└──────────────┬────────────────────────────────────────────────┘
               │
               │  2. Token validation
               ▼
┌───────────────────────────────────────────────────────────────┐
│                    SUPABASE AUTH                               │
│  - Email/Password authentication                              │
│  - Google OAuth 2.0                                           │
│  - JWT issuance with custom claims hook                       │
│  - Session refresh (auto via Supabase JS client)              │
│  - Email verification + password reset emails                 │
└──────────────┬────────────────────────────────────────────────┘
               │
               │  3. User profile lookup
               ▼
┌───────────────────────────────────────────────────────────────┐
│                    POSTGRESQL (Supabase)                        │
│  auth.users          → Supabase-managed identity              │
│  public.users        → App profile (role, tenant_id, active)  │
│  public.tenants      → Tenant record                          │
│  public.resellers    → Reseller record (if applicable)        │
└───────────────────────────────────────────────────────────────┘
```

### 1.2 Login Flow

```
User submits email + password
  │
  ▼
supabase.auth.signInWithPassword({ email, password })
  │
  ├─ FAILURE → Return error (invalid credentials / unverified email)
  │
  └─ SUCCESS
       │
       ▼
  Supabase Auth Hook fires: auth.custom_claims()
       │
       ▼
  JWT issued with custom claims:
  { sub, tenant_id, role, reseller_id?, package_id, exp }
       │
       ▼
  Session cookie set (httpOnly, Secure, SameSite=Lax)
       │
       ▼
  Next.js middleware reads session on next request
       │
       ▼
  Role-based redirect:
    super_admin   → /admin/dashboard
    reseller_admin → /reseller/dashboard
    owner/editor/viewer → /dashboard
```

### 1.3 Register Flow

```
User submits registration form
  │
  ▼
Server Action: validateRegistrationInput()
  │
  ├─ INVALID → Return field-level errors (Zod)
  │
  └─ VALID
       │
       ▼
  Check: email already exists in auth.users?
  │
  ├─ EXISTS → Return "email already registered"
  │
  └─ NEW
       │
       ▼
  supabase.auth.signUp({ email, password, options: { emailRedirectTo } })
       │
       ▼
  Postgres trigger fires: handle_new_user()
       │  Creates:
       │  - tenants row (slug = slugify(email prefix))
       │  - users row (role = 'owner', tenant_id = new tenant)
       │  - tenant_subscriptions row (package = 'free', status = 'trialing')
       │
       ▼
  Verification email sent by Supabase (Resend SMTP)
       │
       ▼
  User redirected to /register/verify-email
```

### 1.4 Logout Flow

```
User clicks "Sign Out"
  │
  ▼
Client: supabase.auth.signOut()
  │
  ▼
Supabase invalidates refresh token server-side
  │
  ▼
Session cookie cleared (httpOnly, expires = past date)
  │
  ▼
Next.js middleware detects no session on next request
  │
  ▼
Redirect to /login
```

### 1.5 Session Flow

```
Request arrives at Next.js
  │
  ▼
Edge Middleware reads cookie: sb-[project-ref]-auth-token
  │
  ├─ No cookie → redirect /login (protected routes)
  │              pass through (public routes)
  │
  └─ Cookie found
       │
       ▼
  createServerClient() from @supabase/ssr
       │
       ▼
  supabase.auth.getUser()   ← always validates server-side, not just JWT decode
       │
       ├─ Invalid / expired → attempt refresh (see 1.6)
       │
       └─ Valid
            │
            ▼
       Extract custom claims from JWT:
       { tenant_id, role, reseller_id, package_id }
            │
            ▼
       Inject into request headers for downstream server components
```

### 1.6 Refresh Token Flow

```
Access token expires (1 hour default)
  │
  ▼
Supabase JS client detects expiry (via onAuthStateChange)
  │
  ▼
Client: automatic supabase.auth.refreshSession()
  │   Uses httpOnly refresh token cookie
  │
  ├─ Refresh token valid (30 days)
  │     │
  │     └─ New access token + refresh token issued
  │         Session cookie updated
  │         Custom claims hook re-runs (picks up role changes)
  │
  └─ Refresh token expired / revoked
        │
        └─ Session terminated → redirect /login
```

### 1.7 Password Reset Flow

```
User clicks "Forgot Password"
  │
  ▼
Submit email to /api/auth/reset-password
  │
  ▼
Server: supabase.auth.resetPasswordForEmail(email, {
  redirectTo: 'https://app.weddingplatform.com/auth/reset-password'
})
  │   Always returns 200 (prevents email enumeration)
  │
  ▼
User receives email with one-time reset link (1 hour TTL)
  │
  ▼
User clicks link → lands on /auth/reset-password?code=...
  │
  ▼
supabase.auth.exchangeCodeForSession(code)
  │
  ├─ Invalid / expired → show error, link to request new reset
  │
  └─ Valid → session established temporarily
       │
       ▼
  User enters new password
       │
       ▼
  supabase.auth.updateUser({ password: newPassword })
       │
       ▼
  All existing sessions revoked (Supabase behavior)
       │
       ▼
  Redirect /login with success toast
```

### 1.8 Email Verification Flow

```
User registers → verification email sent
  │
  ▼
User clicks link in email
  │
  ▼
Supabase confirms email → auth.users.email_confirmed_at set
  │
  ▼
User redirected to /auth/callback?code=...
  │
  ▼
/app/auth/callback/route.ts:
  supabase.auth.exchangeCodeForSession(code)
  │
  ▼
Session established → redirect /dashboard
  │
  ▼
(If user tries to access dashboard before verifying:
  middleware checks auth.users.email_confirmed_at
  → redirect /register/verify-email with notice)
```

---

## 2. Authorization Architecture

### 2.1 Strategy Overview

Authorization operates at **three layers**:

| Layer | Mechanism | Enforces |
|---|---|---|
| Edge Middleware | JWT custom claims check | Route-level access (before React renders) |
| Server Components / API Routes | Permission helpers | Action-level access (what can be done) |
| Database RLS | Postgres policies | Data-level access (what rows can be touched) |

No single layer is trusted alone. A compromised JWT still cannot read another tenant's data because RLS operates on the DB connection independently. A misconfigured RLS policy still cannot expose admin routes because middleware blocks them before any query runs.

### 2.2 Permission Strategy

Permissions are derived from a single source of truth: the `role` claim in the JWT. No separate permissions table exists in Phase 1 — roles map to fixed capability sets defined in code.

```typescript
// lib/auth/permissions.ts

export const ROLE_PERMISSIONS = {
  super_admin: ['*'],   // wildcard — checked first, bypasses all other checks

  reseller_admin: [
    'reseller:read', 'reseller:write',
    'reseller:clients:read', 'reseller:clients:write',
    'reseller:billing:read',
    'invitation:read', 'invitation:write', 'invitation:publish',
    'guest:read', 'guest:write',
    'rsvp:read',
    'analytics:read',
    'subscription:read', 'subscription:write',
    'team:read', 'team:write',
  ],

  owner: [
    'invitation:read', 'invitation:write', 'invitation:publish',
    'guest:read', 'guest:write',
    'rsvp:read',
    'analytics:read',
    'subscription:read', 'subscription:write',
    'team:read', 'team:write',
    'settings:read', 'settings:write',
  ],

  editor: [
    'invitation:read', 'invitation:write',
    'guest:read', 'guest:write',
    'rsvp:read',
  ],

  viewer: [
    'invitation:read',
    'rsvp:read',
  ],
} as const;

export type Permission = typeof ROLE_PERMISSIONS[keyof typeof ROLE_PERMISSIONS][number];
export type Role = keyof typeof ROLE_PERMISSIONS;

export function hasPermission(role: Role, permission: string): boolean {
  const perms = ROLE_PERMISSIONS[role] as readonly string[];
  return perms.includes('*') || perms.includes(permission);
}
```

### 2.3 Route Protection Strategy

```
Route Pattern                   Required Role / Condition
─────────────────────────────────────────────────────────────────
/                               Public
/pricing                        Public
/inv/[slug]                     Public (published invitations only)
/login                          Unauthenticated only (redirect if session exists)
/register                       Unauthenticated only
/auth/callback                  Public (OAuth/email callback handler)
/dashboard                      Authenticated, any tenant role
/invitations/*                  Authenticated, owner | editor (write), viewer (read)
/settings/*                     Authenticated, owner only
/packages/*                     Authenticated, owner only
/admin/*                        Authenticated, super_admin only
/reseller/*                     Authenticated, reseller_admin only
/api/admin/*                    super_admin (service role client)
/api/reseller/*                 reseller_admin
/api/invitations/*              owner | editor (mutate), viewer (GET)
/api/rsvp/*                     Public (POST), owner (GET)
/api/webhooks/*                 Signature-verified, no user session required
```

### 2.4 API Protection

Every `/api/*` route follows this pattern:

```typescript
// lib/auth/api-guard.ts

import { createServerClient } from '@/lib/supabase/server';
import { hasPermission, type Role } from './permissions';
import { NextResponse } from 'next/server';

export async function requireAuth(
  request: Request,
  requiredPermission?: string
): Promise<{ user: AuthUser } | NextResponse> {
  const supabase = createServerClient();
  const { data: { user }, error } = await supabase.auth.getUser();

  if (error || !user) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  const role = user.app_metadata?.role as Role;
  const tenantId = user.app_metadata?.tenant_id;

  if (!tenantId || !role) {
    return NextResponse.json({ error: 'Invalid session' }, { status: 401 });
  }

  if (requiredPermission && !hasPermission(role, requiredPermission)) {
    return NextResponse.json({ error: 'Forbidden' }, { status: 403 });
  }

  return {
    user: { id: user.id, role, tenantId, resellerId: user.app_metadata?.reseller_id }
  };
}
```

Usage in an API route:

```typescript
// app/api/invitations/route.ts

export async function POST(request: Request) {
  const result = await requireAuth(request, 'invitation:write');
  if (result instanceof NextResponse) return result;   // 401/403 short-circuit

  const { user } = result;
  // user.tenantId, user.role are now safe to use
  // RLS enforces tenant isolation at the DB level regardless
}
```

---

## 3. User Registration

### 3.1 Registration Input Validation

```typescript
// lib/auth/schemas.ts

import { z } from 'zod';

export const RegisterSchema = z.object({
  full_name: z.string().min(2).max(100).trim(),
  email: z.string().email().toLowerCase().trim(),
  password: z
    .string()
    .min(8)
    .max(72)                          // bcrypt limit
    .regex(/[A-Z]/, 'Must contain uppercase')
    .regex(/[0-9]/, 'Must contain number'),
  terms_accepted: z.literal(true, {
    errorMap: () => ({ message: 'You must accept the terms' })
  }),
});

export type RegisterInput = z.infer<typeof RegisterSchema>;
```

### 3.2 Account Creation Server Action

```typescript
// app/(auth)/register/actions.ts
'use server';

import { createServerClient } from '@/lib/supabase/server';
import { RegisterSchema } from '@/lib/auth/schemas';

export async function registerAction(formData: FormData) {
  const parsed = RegisterSchema.safeParse(Object.fromEntries(formData));
  if (!parsed.success) {
    return { error: parsed.error.flatten().fieldErrors };
  }

  const { email, password, full_name } = parsed.data;
  const supabase = createServerClient();

  const { data, error } = await supabase.auth.signUp({
    email,
    password,
    options: {
      data: { full_name },           // stored in auth.users.raw_user_meta_data
      emailRedirectTo: `${process.env.NEXT_PUBLIC_APP_URL}/auth/callback`,
    },
  });

  if (error) {
    // Never reveal whether email exists — return generic message
    return { error: { _form: ['Registration failed. Please try again.'] } };
  }

  // Postgres trigger handle_new_user() fires here automatically
  // It creates: tenants, users (public), tenant_subscriptions rows

  return { success: true };
}
```

### 3.3 New User Trigger (Postgres)

This trigger fires immediately after Supabase creates a row in `auth.users`. It bootstraps the full tenant context with zero round-trips from the application.

```sql
-- supabase/migrations/004_users.sql

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
DECLARE
  v_tenant_id   UUID;
  v_tenant_slug TEXT;
  v_package_id  UUID;
  v_full_name   TEXT;
BEGIN
  -- Build a unique slug from email prefix
  v_tenant_slug := LOWER(REGEXP_REPLACE(
    SPLIT_PART(NEW.email, '@', 1),
    '[^a-z0-9]', '-', 'g'
  ));

  -- Ensure uniqueness by appending random suffix if collision
  WHILE EXISTS (SELECT 1 FROM tenants WHERE slug = v_tenant_slug) LOOP
    v_tenant_slug := v_tenant_slug || '-' || SUBSTR(gen_random_uuid()::TEXT, 1, 6);
  END LOOP;

  -- Extract full_name from metadata (set during signUp)
  v_full_name := NEW.raw_user_meta_data ->> 'full_name';

  -- 1. Create tenant
  INSERT INTO tenants (slug, name, status)
  VALUES (v_tenant_slug, COALESCE(v_full_name, v_tenant_slug), 'active')
  RETURNING id INTO v_tenant_id;

  -- 2. Create user profile
  INSERT INTO users (id, tenant_id, email, full_name, role, is_active)
  VALUES (NEW.id, v_tenant_id, NEW.email, v_full_name, 'owner', TRUE);

  -- 3. Assign Free package subscription
  SELECT id INTO v_package_id FROM packages WHERE slug = 'free' LIMIT 1;

  INSERT INTO tenant_subscriptions (
    tenant_id, package_id, billing_cycle, status,
    current_period_start, current_period_end
  ) VALUES (
    v_tenant_id, v_package_id, 'monthly', 'trialing',
    NOW(), NOW() + INTERVAL '14 days'
  );

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();
```

### 3.4 Tenant Assignment for Team Members

When an owner invites a team member, the flow differs — the invited user joins an **existing** tenant, not a new one:

```typescript
// app/api/team/invite/route.ts

export async function POST(request: Request) {
  const result = await requireAuth(request, 'team:write');
  if (result instanceof NextResponse) return result;

  const { email, role } = await request.json();
  const adminClient = createAdminClient();  // service role

  // Create auth user without triggering the normal tenant-creation flow
  // We use admin.createUser so we can set tenant_id immediately
  const { data, error } = await adminClient.auth.admin.inviteUserByEmail(email, {
    data: { invited_by_tenant: result.user.tenantId, assigned_role: role }
  });

  // A separate trigger handles invitations differently:
  // handle_invited_user() checks raw_user_meta_data.invited_by_tenant
  // and assigns the user to the existing tenant instead of creating a new one
}
```

---

## 4. Login System

### 4.1 Email & Password Login

```typescript
// app/(auth)/login/actions.ts
'use server';

import { createServerClient } from '@/lib/supabase/server';
import { LoginSchema } from '@/lib/auth/schemas';
import { redirect } from 'next/navigation';
import { headers } from 'next/headers';
import { checkLoginRateLimit } from '@/lib/auth/rate-limit';

export async function loginAction(formData: FormData) {
  const ip = headers().get('x-forwarded-for') ?? 'unknown';

  // Rate limit: 10 attempts per IP per 15 minutes
  const limited = await checkLoginRateLimit(ip);
  if (limited) {
    return { error: { _form: ['Too many attempts. Please wait 15 minutes.'] } };
  }

  const parsed = LoginSchema.safeParse(Object.fromEntries(formData));
  if (!parsed.success) {
    return { error: parsed.error.flatten().fieldErrors };
  }

  const { email, password } = parsed.data;
  const supabase = createServerClient();

  const { data, error } = await supabase.auth.signInWithPassword({
    email,
    password,
  });

  if (error) {
    // Increment rate limit counter on failure
    await incrementLoginAttempt(ip);
    // Generic message — never reveal if account exists
    return { error: { _form: ['Invalid email or password.'] } };
  }

  // Reset counter on success
  await resetLoginAttempts(ip);

  // Role-based redirect
  const role = data.user.app_metadata?.role;
  if (role === 'super_admin') redirect('/admin/dashboard');
  if (role === 'reseller_admin') redirect('/reseller/dashboard');
  redirect('/dashboard');
}
```

### 4.2 Google OAuth Login

```typescript
// app/(auth)/login/page.tsx  (client component trigger)

async function handleGoogleLogin() {
  const supabase = createBrowserClient();
  await supabase.auth.signInWithOAuth({
    provider: 'google',
    options: {
      redirectTo: `${window.location.origin}/auth/callback`,
      queryParams: {
        access_type: 'offline',
        prompt: 'consent',
      },
    },
  });
}
```

```typescript
// app/auth/callback/route.ts

import { createServerClient } from '@/lib/supabase/server';
import { NextResponse } from 'next/server';

export async function GET(request: Request) {
  const { searchParams, origin } = new URL(request.url);
  const code = searchParams.get('code');

  if (!code) {
    return NextResponse.redirect(`${origin}/login?error=missing_code`);
  }

  const supabase = createServerClient();
  const { data, error } = await supabase.auth.exchangeCodeForSession(code);

  if (error) {
    return NextResponse.redirect(`${origin}/login?error=auth_failed`);
  }

  // For OAuth: check if public.users row exists (first OAuth sign-in)
  // handle_new_user() trigger fires on first OAuth login automatically
  // because Supabase inserts into auth.users on first OAuth sign-in

  const role = data.user?.app_metadata?.role;
  if (role === 'super_admin') {
    return NextResponse.redirect(`${origin}/admin/dashboard`);
  }
  if (role === 'reseller_admin') {
    return NextResponse.redirect(`${origin}/reseller/dashboard`);
  }

  return NextResponse.redirect(`${origin}/dashboard`);
}
```

### 4.3 Session Management Configuration

```typescript
// lib/supabase/client.ts

import { createBrowserClient as createSupabaseBrowserClient } from '@supabase/ssr';

export function createBrowserClient() {
  return createSupabaseBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
        storageKey: 'sb-session',
        // Storage is handled via cookies in SSR context, not localStorage
      },
      cookieOptions: {
        name: 'sb-session',
        lifetime: 60 * 60 * 24 * 7,   // 7 days
        domain: process.env.NEXT_PUBLIC_APP_DOMAIN,
        path: '/',
        sameSite: 'lax',
        secure: process.env.NODE_ENV === 'production',
      },
    }
  );
}
```

### 4.4 Remember Me Strategy

Supabase does not natively support a "remember me" checkbox that extends session duration. We handle this by adjusting cookie lifetime server-side based on the user's choice:

```typescript
// app/(auth)/login/actions.ts

// In loginAction, after successful sign-in:
const rememberMe = formData.get('remember_me') === 'true';
const cookieLifetime = rememberMe
  ? 60 * 60 * 24 * 30   // 30 days
  : 60 * 60 * 24;        // 1 day (browser session)

// Set cookie lifetime via Supabase SSR cookie options
// Passed through createServerClient({ cookieOptions: { lifetime } })
```

---

## 5. Password Management

### 5.1 Password Security Rules

All passwords are enforced with Zod on input and bcrypt-hashed by Supabase Auth before storage. The application never sees the plain-text password after submission.

```typescript
export const PasswordSchema = z
  .string()
  .min(8, 'Minimum 8 characters')
  .max(72, 'Maximum 72 characters')     // bcrypt truncates at 72 bytes
  .regex(/[A-Z]/, 'At least one uppercase letter')
  .regex(/[a-z]/, 'At least one lowercase letter')
  .regex(/[0-9]/, 'At least one number')
  .regex(/[^A-Za-z0-9]/, 'At least one special character');

// Supabase Auth project settings (set in dashboard + config.toml):
// minimum_password_length: 8
// password_requirements: upper_lower_letters_digits
```

### 5.2 Forgot Password

```typescript
// app/api/auth/forgot-password/route.ts

export async function POST(request: Request) {
  const { email } = await request.json();

  // Rate limit: 3 reset emails per email per hour
  const limited = await checkResetRateLimit(email);
  if (limited) {
    // Return 200 regardless — prevents timing attacks
    return NextResponse.json({ success: true });
  }

  const supabase = createServerClient();

  // Always return 200 regardless of whether email exists
  await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: `${process.env.NEXT_PUBLIC_APP_URL}/auth/reset-password`,
  });

  return NextResponse.json({ success: true });
}
```

### 5.3 Reset Password Page

```typescript
// app/(auth)/auth/reset-password/page.tsx

// This page is reached after user clicks the email link
// Supabase has already exchanged the code in the callback handler
// The user has a temporary session scoped only to password update

export async function resetPasswordAction(formData: FormData) {
  'use server';

  const password = formData.get('password') as string;
  const confirm = formData.get('confirm_password') as string;

  const validation = PasswordSchema.safeParse(password);
  if (!validation.success) {
    return { error: validation.error.flatten() };
  }
  if (password !== confirm) {
    return { error: { _form: ['Passwords do not match'] } };
  }

  const supabase = createServerClient();
  const { error } = await supabase.auth.updateUser({ password });

  if (error) {
    return { error: { _form: ['Reset failed. The link may have expired.'] } };
  }

  // Supabase revokes all other sessions on password change
  redirect('/login?message=password_updated');
}
```

### 5.4 Change Password (Authenticated)

```typescript
// app/(app)/settings/security/actions.ts
'use server';

export async function changePasswordAction(formData: FormData) {
  const supabase = createServerClient();

  // Verify current password first by re-authenticating
  const { data: { user } } = await supabase.auth.getUser();
  if (!user?.email) redirect('/login');

  const currentPassword = formData.get('current_password') as string;
  const { error: verifyError } = await supabase.auth.signInWithPassword({
    email: user.email,
    password: currentPassword,
  });

  if (verifyError) {
    return { error: { current_password: ['Incorrect current password'] } };
  }

  const newPassword = formData.get('new_password') as string;
  const validation = PasswordSchema.safeParse(newPassword);
  if (!validation.success) {
    return { error: validation.error.flatten() };
  }

  const { error } = await supabase.auth.updateUser({ password: newPassword });
  if (error) return { error: { _form: ['Change failed. Please try again.'] } };

  return { success: true };
}
```

---

## 6. Role System & Permission Matrix

### 6.1 Role Definitions

```
SUPER_ADMIN
  ├── Full unrestricted access to all platform data
  ├── Uses service_role Supabase client (bypasses RLS)
  ├── Can impersonate any tenant or reseller
  └── Manages packages, feature flags, resellers, themes

RESELLER_ADMIN
  ├── Manages own reseller account + branding
  ├── Manages own client tenants (create, suspend, assign packages)
  ├── Views own commission and billing data
  └── Can impersonate own clients (audit-logged)

OWNER (tenant_owner)
  ├── Full control over own tenant
  ├── Creates and publishes invitations
  ├── Manages guests and views RSVP data
  ├── Manages team members (invite editor/viewer)
  └── Manages subscription and billing

EDITOR (tenant_editor)
  ├── Creates and edits invitations (cannot publish)
  ├── Manages guests
  └── Views RSVP responses

VIEWER (tenant_viewer)
  ├── Read-only access to invitations
  └── Views RSVP responses (no export)
```

### 6.2 Complete Permission Matrix

| Permission | super_admin | reseller_admin | owner | editor | viewer |
|---|:---:|:---:|:---:|:---:|:---:|
| **PLATFORM** | | | | | |
| Manage all tenants | ✅ | ❌ | ❌ | ❌ | ❌ |
| Suspend / delete tenants | ✅ | ❌ | ❌ | ❌ | ❌ |
| Manage packages & pricing | ✅ | ❌ | ❌ | ❌ | ❌ |
| Manage platform feature flags | ✅ | ❌ | ❌ | ❌ | ❌ |
| Manage invitation themes | ✅ | ❌ | ❌ | ❌ | ❌ |
| View platform analytics (MRR, churn) | ✅ | ❌ | ❌ | ❌ | ❌ |
| Impersonate any tenant | ✅ | ❌ | ❌ | ❌ | ❌ |
| Manage voucher codes (platform) | ✅ | ❌ | ❌ | ❌ | ❌ |
| View all orders / revenue | ✅ | ❌ | ❌ | ❌ | ❌ |
| **RESELLER** | | | | | |
| Manage own reseller branding | ✅ | ✅ | ❌ | ❌ | ❌ |
| Manage own client tenants | ✅ | ✅ | ❌ | ❌ | ❌ |
| View own commission + billing | ✅ | ✅ | ❌ | ❌ | ❌ |
| Impersonate own clients | ✅ | ✅ | ❌ | ❌ | ❌ |
| Create voucher codes (reseller) | ✅ | ✅ | ❌ | ❌ | ❌ |
| View reseller analytics | ✅ | ✅ | ❌ | ❌ | ❌ |
| Manage custom reseller domain | ✅ | ✅ | ❌ | ❌ | ❌ |
| **INVITATIONS** | | | | | |
| View own invitations | ✅ | ✅ | ✅ | ✅ | ✅ |
| Create invitation | ✅ | ✅ | ✅ | ✅ | ❌ |
| Edit invitation content | ✅ | ✅ | ✅ | ✅ | ❌ |
| Publish / unpublish invitation | ✅ | ✅ | ✅ | ❌ | ❌ |
| Archive / delete invitation | ✅ | ✅ | ✅ | ❌ | ❌ |
| Duplicate invitation | ✅ | ✅ | ✅ | ❌ | ❌ |
| Manage invitation password | ✅ | ✅ | ✅ | ❌ | ❌ |
| **GUESTS** | | | | | |
| View guests | ✅ | ✅ | ✅ | ✅ | ❌ |
| Add / edit guests (manual) | ✅ | ✅ | ✅ | ✅ | ❌ |
| Import guests (CSV) | ✅ | ✅ | ✅ | ❌ | ❌ |
| Delete guests | ✅ | ✅ | ✅ | ❌ | ❌ |
| Send WhatsApp blast | ✅ | ✅ | ✅ | ✅ | ❌ |
| Export guest CSV | ✅ | ✅ | ✅ | ❌ | ❌ |
| **RSVP** | | | | | |
| View RSVP responses | ✅ | ✅ | ✅ | ✅ | ✅ |
| Export RSVP CSV | ✅ | ✅ | ✅ | ❌ | ❌ |
| Open / close RSVP | ✅ | ✅ | ✅ | ❌ | ❌ |
| **GUESTBOOK** | | | | | |
| View guestbook entries | ✅ | ✅ | ✅ | ✅ | ✅ |
| Moderate / delete entries | ✅ | ✅ | ✅ | ✅ | ❌ |
| **QR** | | | | | |
| Generate QR codes | ✅ | ✅ | ✅ | ✅ | ❌ |
| Perform QR check-in | ✅ | ✅ | ✅ | ✅ | ❌ |
| View check-in log | ✅ | ✅ | ✅ | ✅ | ✅ |
| **ANALYTICS** | | | | | |
| View basic analytics | ✅ | ✅ | ✅ | ✅ | ❌ |
| View advanced analytics | ✅ | ✅ | ✅ (Premium+) | ❌ | ❌ |
| **SUBSCRIPTION & BILLING** | | | | | |
| View current plan | ✅ | ✅ | ✅ | ❌ | ❌ |
| Upgrade / downgrade plan | ✅ | ✅ | ✅ | ❌ | ❌ |
| View invoice history | ✅ | ✅ | ✅ | ❌ | ❌ |
| Apply voucher | ✅ | ✅ | ✅ | ❌ | ❌ |
| **TEAM** | | | | | |
| View team members | ✅ | ✅ | ✅ | ❌ | ❌ |
| Invite team members | ✅ | ✅ | ✅ | ❌ | ❌ |
| Change member role | ✅ | ✅ | ✅ | ❌ | ❌ |
| Remove team member | ✅ | ✅ | ✅ | ❌ | ❌ |
| **SETTINGS** | | | | | |
| Update profile | ✅ | ✅ | ✅ | ✅ | ✅ |
| Change password | ✅ | ✅ | ✅ | ✅ | ✅ |
| Manage custom domain | ✅ | ✅ | ✅ (Premium+) | ❌ | ❌ |
| Delete account / tenant | ✅ | ✅ | ✅ | ❌ | ❌ |

### 6.3 Feature-Gated Permissions

Some permissions are available to a role only if the tenant's active package includes the relevant feature flag. These are evaluated at the **application layer** after the role check:

```typescript
// lib/auth/permissions.ts

export async function canUseFeature(
  tenantId: string,
  role: Role,
  featureKey: string
): Promise<boolean> {
  // super_admin and reseller_admin bypass feature gating
  if (role === 'super_admin' || role === 'reseller_admin') return true;

  const resolution = await resolveFeature(tenantId, featureKey);
  return resolution.enabled;
}

// Usage:
const canImportCSV = await canUseFeature(tenantId, role, FEATURES.GUEST_IMPORT_CSV);
if (!canImportCSV) return <UpgradePrompt feature="CSV Import" requiredPlan="Premium" />;
```

---

## 7. Route Protection

### 7.1 Route Classification

```typescript
// middleware.ts

// Routes that are always public — no session check
const PUBLIC_ROUTES = [
  '/',
  '/pricing',
  '/about',
  '/terms',
  '/privacy',
  /^\/inv\/.+/,          // public invitation pages
  '/auth/callback',
];

// Routes that redirect authenticated users away
const AUTH_ONLY_ROUTES = [
  '/login',
  '/register',
  '/auth/reset-password',
  '/auth/forgot-password',
];

// Routes requiring super_admin role
const ADMIN_ROUTES = /^\/admin(\/.*)?$/;

// Routes requiring reseller_admin role
const RESELLER_ROUTES = /^\/reseller(\/.*)?$/;

// Routes requiring any authenticated role
const PROTECTED_ROUTES = /^\/(dashboard|invitations|guests|settings|packages)(\/.*)?$/;

// API routes and their required permissions (enforced by API guards, not middleware)
// Middleware only confirms a valid session exists for /api/* routes
const API_ROUTES = /^\/api\/.+/;
```

### 7.2 Complete Middleware Decision Tree

```typescript
// middleware.ts

import { createServerClient } from '@supabase/ssr';
import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';

export async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;
  const response = NextResponse.next();

  // 1. Always pass public routes through
  if (isPublicRoute(pathname)) return response;

  // 2. Create Supabase server client (reads cookies)
  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        get: (name) => request.cookies.get(name)?.value,
        set: (name, value, options) => response.cookies.set(name, value, options),
        remove: (name, options) => response.cookies.set(name, '', options),
      },
    }
  );

  // 3. Validate session (getUser() — not getSession() — calls Supabase server)
  const { data: { user }, error } = await supabase.auth.getUser();

  // 4. No session — enforce auth
  if (!user || error) {
    if (isApiRoute(pathname)) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }
    if (isAuthOnlyRoute(pathname)) return response;  // let /login through
    return redirectToLogin(request);
  }

  // 5. Authenticated — redirect away from auth-only pages
  if (isAuthOnlyRoute(pathname)) {
    return redirectToDashboard(user, request);
  }

  // 6. Admin route guard
  if (ADMIN_ROUTES.test(pathname)) {
    const role = user.app_metadata?.role;
    if (role !== 'super_admin') {
      return NextResponse.redirect(new URL('/dashboard', request.url));
    }
  }

  // 7. Reseller route guard
  if (RESELLER_ROUTES.test(pathname)) {
    const role = user.app_metadata?.role;
    if (role !== 'reseller_admin' && role !== 'super_admin') {
      return NextResponse.redirect(new URL('/dashboard', request.url));
    }
  }

  // 8. Check tenant status (suspended tenants are locked out)
  const tenantId = user.app_metadata?.tenant_id;
  if (tenantId && isProtectedRoute(pathname)) {
    const tenantStatus = await getTenantStatus(supabase, tenantId);
    if (tenantStatus === 'suspended') {
      return NextResponse.redirect(new URL('/suspended', request.url));
    }
  }

  // 9. Forward auth context in headers for server components
  response.headers.set('x-user-id', user.id);
  response.headers.set('x-tenant-id', tenantId ?? '');
  response.headers.set('x-user-role', user.app_metadata?.role ?? '');

  return response;
}

export const config = {
  matcher: [
    '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)',
  ],
};
```

### 7.3 Server Component Auth Pattern

```typescript
// lib/auth/session.ts

import { createServerClient } from '@/lib/supabase/server';
import { redirect } from 'next/navigation';
import type { Role } from './permissions';

export interface AuthUser {
  id: string;
  tenantId: string;
  role: Role;
  packageId: string;
  resellerId?: string;
}

export async function requireSession(): Promise<AuthUser> {
  const supabase = createServerClient();
  const { data: { user } } = await supabase.auth.getUser();

  if (!user) redirect('/login');

  return {
    id: user.id,
    tenantId: user.app_metadata.tenant_id,
    role: user.app_metadata.role as Role,
    packageId: user.app_metadata.package_id,
    resellerId: user.app_metadata.reseller_id,
  };
}

export async function requireRole(
  allowedRoles: Role[]
): Promise<AuthUser> {
  const user = await requireSession();
  if (!allowedRoles.includes(user.role)) redirect('/dashboard');
  return user;
}

// Usage in server components:
// const user = await requireRole(['super_admin']);
// const user = await requireSession(); // any authenticated user
```

---

## 8. Middleware Architecture

### 8.1 Middleware Stack

```
Incoming Request
       │
       ▼
┌─────────────────────────────────────────┐
│  1. TENANT RESOLUTION                   │
│  Read Host header → resolve reseller    │
│  or platform subdomain → set context    │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  2. AUTHENTICATION                      │
│  Read session cookie → getUser()        │
│  Validate JWT → extract claims          │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  3. ROUTE AUTHORIZATION                 │
│  Match role to route pattern            │
│  Reject or pass through                 │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  4. TENANT STATUS CHECK                 │
│  Check tenants.status !== 'suspended'   │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  5. HEADER INJECTION                    │
│  x-user-id, x-tenant-id, x-user-role   │
│  Available to all server components     │
└────────────────┬────────────────────────┘
                 │
                 ▼
          Next.js Handler
```

### 8.2 Tenant Resolution in Middleware

```typescript
// lib/tenant/resolver.ts

export async function resolveTenant(
  request: NextRequest,
  supabase: SupabaseClient
): Promise<{ tenantSlug: string; resellerId: string | null } | null> {
  const host = request.headers.get('host') ?? '';
  const appDomain = process.env.NEXT_PUBLIC_APP_DOMAIN!;

  // Case 1: Platform subdomain (tenant.weddingplatform.com)
  if (host.endsWith(`.${appDomain}`)) {
    const slug = host.replace(`.${appDomain}`, '');
    if (['admin', 'app', 'www', 'inv'].includes(slug)) return null;
    return { tenantSlug: slug, resellerId: null };
  }

  // Case 2: Custom reseller domain
  if (!host.includes(appDomain)) {
    const { data: reseller } = await supabase
      .from('reseller_domains')
      .select('reseller_id')
      .eq('domain', host)
      .eq('dns_verified', true)
      .single();

    if (reseller) {
      return { tenantSlug: '', resellerId: reseller.reseller_id };
    }
  }

  return null;
}
```

### 8.3 Permission Validation Helper

```typescript
// lib/auth/guard.ts

import { hasPermission, type Role } from './permissions';

type GuardOptions = {
  role: Role;
  permission?: string;
  tenantId?: string;
  featureKey?: string;
};

export async function guard(options: GuardOptions): Promise<void> {
  const { role, permission, tenantId, featureKey } = options;

  if (role === 'super_admin') return;   // always passes

  if (permission && !hasPermission(role, permission)) {
    throw new ForbiddenError(`Role '${role}' lacks permission '${permission}'`);
  }

  if (featureKey && tenantId) {
    const { enabled } = await resolveFeature(tenantId, featureKey);
    if (!enabled) {
      throw new UpgradeRequiredError(`Feature '${featureKey}' not available on current plan`);
    }
  }
}

// Usage in server actions:
// await guard({ role: user.role, permission: 'invitation:publish' });
// await guard({ role: user.role, tenantId: user.tenantId, featureKey: FEATURES.GUEST_IMPORT_CSV });
```

---

## 9. Session Management

### 9.1 Session Lifecycle

```
Sign In
  │
  ├── Access Token issued (JWT, 1 hour TTL)
  │    └── Contains: sub, tenant_id, role, reseller_id, package_id, exp
  │
  └── Refresh Token issued (opaque, 30 days TTL, stored server-side)

Active Use
  │
  ├── Access Token auto-refreshed 60s before expiry (Supabase JS client)
  └── Refresh Token rotated on every refresh (one-time use)

Inactivity (30 days no refresh)
  │
  └── Refresh token expires → user must re-authenticate

Explicit Sign Out
  │
  └── Refresh token revoked server-side → all sessions invalidated

Password Change
  │
  └── All refresh tokens revoked → all devices signed out

Account Suspension
  │
  └── Middleware detects tenant status → all requests blocked at route level
      (Supabase session still technically valid, but app blocks access)
```

### 9.2 Token Expiry Configuration

```toml
# supabase/config.toml

[auth]
  # Access token lifetime
  jwt_expiry = 3600          # 1 hour

  # Refresh token behavior
  refresh_token_rotation_enabled = true
  refresh_token_reuse_interval = 10   # seconds grace period for concurrent requests

  # Email verification requirement
  enable_email_confirmations = true

  # Session limits (Phase 3+ — not enforced in Phase 1)
  # max_sessions_per_user = 5
```

### 9.3 Multi-Device Handling

In Phase 1, users can be signed in on multiple devices simultaneously. Each device gets its own refresh token (Supabase supports multiple active refresh tokens per user). Signing out on one device does not sign out others by default.

**Admin force sign-out:** The admin panel can revoke all sessions for a user or tenant via `supabase.auth.admin.signOut(userId, 'global')`.

```typescript
// app/api/admin/tenants/[id]/suspend/route.ts

export async function POST(request: Request, { params }: { params: { id: string } }) {
  const admin = createAdminClient();

  // 1. Update tenant status
  await admin.from('tenants').update({ status: 'suspended' }).eq('id', params.id);

  // 2. Sign out all users in this tenant
  const { data: users } = await admin
    .from('users')
    .select('id')
    .eq('tenant_id', params.id);

  for (const user of users ?? []) {
    await admin.auth.admin.signOut(user.id, 'global');
  }

  await writeAuditLog(request, 'tenant.suspend', 'tenant', params.id);
  return NextResponse.json({ success: true });
}
```

### 9.4 Impersonation Session

```typescript
// app/api/admin/impersonate/route.ts

export async function POST(request: Request) {
  const guard = await requireAuth(request);
  if (guard instanceof NextResponse) return guard;
  if (guard.user.role !== 'super_admin') {
    return NextResponse.json({ error: 'Forbidden' }, { status: 403 });
  }

  const { targetUserId } = await request.json();
  const admin = createAdminClient();

  // Generate a short-lived impersonation token (uses Supabase admin link)
  const { data, error } = await admin.auth.admin.generateLink({
    type: 'magiclink',
    email: targetUserEmail,
    options: { expiresIn: 60 * 60 * 24 }   // 24 hours max
  });

  // Log impersonation before issuing token
  await writeAuditLog(request, 'impersonation.start', 'user', targetUserId, {
    impersonated_by: guard.user.id,
    impersonated_role: 'tenant_owner',
  });

  return NextResponse.json({ link: data.properties?.action_link });
}
```

---

## 10. Security Architecture

### 10.1 CSRF Protection

Next.js App Router Server Actions and API Routes are protected against CSRF by the framework's same-origin enforcement. Additionally:

```typescript
// lib/auth/csrf.ts

// For any sensitive state-mutating API routes not using Server Actions:
export function validateOrigin(request: Request): boolean {
  const origin = request.headers.get('origin');
  const allowedOrigins = [
    process.env.NEXT_PUBLIC_APP_URL!,
    `https://${process.env.NEXT_PUBLIC_APP_DOMAIN}`,
  ];
  return !!origin && allowedOrigins.some(o => origin.startsWith(o));
}

// Webhook routes use HMAC signature validation instead:
export function validateWebhookSignature(
  payload: string,
  signature: string,
  secret: string
): boolean {
  const expected = crypto
    .createHmac('sha256', secret)
    .update(payload)
    .digest('hex');
  return crypto.timingSafeEqual(
    Buffer.from(signature),
    Buffer.from(`sha256=${expected}`)
  );
}
```

### 10.2 XSS Prevention

- All user-generated content is rendered via React's default escaping (no `dangerouslySetInnerHTML` on user content).
- Invitation `customization` JSONB is sanitized before rendering on the public invitation page.
- Content-Security-Policy header set on all responses:

```typescript
// next.config.ts

const securityHeaders = [
  {
    key: 'Content-Security-Policy',
    value: [
      "default-src 'self'",
      "script-src 'self' 'unsafe-inline' https://js.midtrans.com",
      "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
      "img-src 'self' data: blob: https://*.supabase.co",
      "media-src 'self' https://*.supabase.co",
      "font-src 'self' https://fonts.gstatic.com",
      "connect-src 'self' https://*.supabase.co wss://*.supabase.co",
      "frame-ancestors 'none'",
    ].join('; '),
  },
  { key: 'X-Frame-Options', value: 'DENY' },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
];
```

### 10.3 Rate Limiting

All rate limiting uses **Upstash Redis** with a sliding window algorithm:

```typescript
// lib/auth/rate-limit.ts

import { Ratelimit } from '@upstash/ratelimit';
import { Redis } from '@upstash/redis';

const redis = Redis.fromEnv();

export const loginRateLimit = new Ratelimit({
  redis,
  limiter: Ratelimit.slidingWindow(10, '15 m'),
  prefix: 'rl:login',
  analytics: true,
});

export const registerRateLimit = new Ratelimit({
  redis,
  limiter: Ratelimit.slidingWindow(5, '1 h'),
  prefix: 'rl:register',
});

export const passwordResetRateLimit = new Ratelimit({
  redis,
  limiter: Ratelimit.slidingWindow(3, '1 h'),
  prefix: 'rl:reset',
});

export const rsvpRateLimit = new Ratelimit({
  redis,
  limiter: Ratelimit.slidingWindow(10, '1 m'),
  prefix: 'rl:rsvp',
});

export const apiRateLimit = new Ratelimit({
  redis,
  limiter: Ratelimit.slidingWindow(120, '1 m'),
  prefix: 'rl:api',
});
```

Rate limit reference table:

| Endpoint | Limit | Window | Key |
|---|---|---|---|
| POST /api/auth/login | 10 attempts | 15 minutes | IP |
| POST /api/auth/register | 5 attempts | 1 hour | IP |
| POST /api/auth/forgot-password | 3 attempts | 1 hour | email |
| POST /api/rsvp | 10 submissions | 1 minute | IP |
| POST /api/guestbook | 5 submissions | 1 minute | IP |
| All authenticated /api/* | 120 requests | 1 minute | user_id |
| Admin /api/admin/* | 60 requests | 1 minute | user_id |

### 10.4 Brute Force Protection

```typescript
// lib/auth/brute-force.ts

const MAX_ATTEMPTS = 10;
const LOCKOUT_DURATION = 15 * 60;   // 15 minutes in seconds

export async function checkLoginRateLimit(ip: string): Promise<boolean> {
  const key = `bf:login:${ip}`;
  const attempts = await redis.incr(key);

  if (attempts === 1) {
    await redis.expire(key, LOCKOUT_DURATION);
  }

  return attempts > MAX_ATTEMPTS;
}

export async function resetLoginAttempts(ip: string): Promise<void> {
  await redis.del(`bf:login:${ip}`);
}

// After 10 failed attempts from same IP:
// - Login blocked for 15 minutes
// - Audit log entry written (action: 'auth.brute_force_blocked')
// - (Phase 3+) Alert sent to admin email if >50 attempts/hour from same IP
```

### 10.5 Secure Cookies

All session cookies are configured with:

```
httpOnly:  true    — inaccessible to JavaScript (XSS mitigation)
secure:    true    — HTTPS only in production
sameSite:  lax     — CSRF mitigation while allowing OAuth redirects
domain:    .weddingplatform.com  — shared across subdomains
path:      /
```

### 10.6 Input Validation

All inputs are validated with **Zod** at the earliest entry point (Server Action or API route), before any database operation:

```typescript
// lib/auth/schemas.ts — all auth-related schemas

export const LoginSchema = z.object({
  email: z.string().email().toLowerCase().trim().max(254),
  password: z.string().min(1).max(72),
});

export const InvitationSlugSchema = z
  .string()
  .min(3)
  .max(60)
  .regex(/^[a-z0-9-]+$/, 'Only lowercase letters, numbers, and hyphens');

export const UUIDSchema = z.string().uuid();

// Route params are always validated before use:
export function validateId(id: unknown): string {
  return UUIDSchema.parse(id);
}
```

---

## 11. Supabase Integration

### 11.1 Auth Configuration (`config.toml`)

```toml
[auth]
  enabled = true
  site_url = "https://app.weddingplatform.com"
  additional_redirect_urls = [
    "https://app.weddingplatform.com/auth/callback",
    "http://localhost:3000/auth/callback",
  ]
  jwt_expiry = 3600
  enable_refresh_token_rotation = true
  refresh_token_reuse_interval = 10
  enable_signup = true
  enable_email_confirmations = true
  minimum_password_length = 8
  password_requirements = "upper_lower_letters_digits"

[auth.email]
  enable_signup = true
  double_confirm_changes = true
  enable_confirmations = true
  smtp_host = "smtp.resend.com"
  smtp_port = 587
  smtp_user = "resend"
  smtp_pass = "env(RESEND_API_KEY)"
  smtp_sender_name = "Wedding Platform"
  smtp_admin_email = "no-reply@weddingplatform.com"

[auth.external.google]
  enabled = true
  client_id = "env(GOOGLE_CLIENT_ID)"
  secret = "env(GOOGLE_CLIENT_SECRET)"
  redirect_uri = "https://your-project.supabase.co/auth/v1/callback"
```

### 11.2 JWT Custom Claims Hook

The hook fires on every sign-in and token refresh, injecting application-level claims into the JWT so middleware and RLS policies can use them without additional DB queries:

```sql
-- supabase/migrations/002_functions.sql

CREATE OR REPLACE FUNCTION auth.custom_claims(event JSONB)
RETURNS JSONB AS $$
DECLARE
  v_user_record  RECORD;
  v_sub_record   RECORD;
  v_reseller_rec RECORD;
  v_claims       JSONB;
BEGIN
  -- Fetch user profile + role + tenant
  SELECT u.tenant_id, u.role, u.is_active
    INTO v_user_record
    FROM public.users u
   WHERE u.id = (event->>'userId')::UUID;

  -- User profile not yet created (race condition on first OAuth login)
  -- Return event unchanged; trigger will create profile asynchronously
  IF NOT FOUND THEN
    RETURN event;
  END IF;

  -- Block suspended / deleted users
  IF NOT v_user_record.is_active THEN
    RAISE EXCEPTION 'Account is inactive';
  END IF;

  -- Fetch active subscription package
  SELECT ts.package_id
    INTO v_sub_record
    FROM public.tenant_subscriptions ts
   WHERE ts.tenant_id = v_user_record.tenant_id
     AND ts.status IN ('active', 'trialing')
   ORDER BY ts.created_at DESC
   LIMIT 1;

  -- Fetch reseller_id if applicable
  IF v_user_record.role = 'reseller_admin' THEN
    SELECT r.id
      INTO v_reseller_rec
      FROM public.resellers r
     WHERE r.owner_user_id = (event->>'userId')::UUID
       AND r.status = 'active'
     LIMIT 1;
  END IF;

  -- Build claims
  v_claims := event->'claims';
  v_claims := jsonb_set(v_claims, '{tenant_id}',
    to_jsonb(v_user_record.tenant_id::TEXT));
  v_claims := jsonb_set(v_claims, '{role}',
    to_jsonb(v_user_record.role));
  v_claims := jsonb_set(v_claims, '{package_id}',
    to_jsonb(COALESCE(v_sub_record.package_id::TEXT, '')));

  IF v_reseller_rec.id IS NOT NULL THEN
    v_claims := jsonb_set(v_claims, '{reseller_id}',
      to_jsonb(v_reseller_rec.id::TEXT));
  END IF;

  RETURN jsonb_set(event, '{claims}', v_claims);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

Register the hook in the Supabase dashboard:
**Authentication → Hooks → Custom Access Token Hook → `auth.custom_claims`**

### 11.3 Supabase Client Factories

```typescript
// lib/supabase/server.ts
// Used in Server Components, Server Actions, API Routes

import { createServerClient as createSupabaseServerClient } from '@supabase/ssr';
import { cookies } from 'next/headers';
import type { Database } from '@/types/database';

export function createServerClient() {
  const cookieStore = cookies();
  return createSupabaseServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        get: (name) => cookieStore.get(name)?.value,
        set: (name, value, options) => cookieStore.set(name, value, options),
        remove: (name, options) => cookieStore.set(name, '', options),
      },
    }
  );
}

// Uses SERVICE_ROLE key — NEVER expose to client bundle
// Only instantiate inside /api/admin/* routes after super_admin check
export function createAdminClient() {
  return createSupabaseServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    {
      auth: { persistSession: false, autoRefreshToken: false },
    }
  );
}
```

```typescript
// lib/supabase/client.ts
// Used in Client Components only

import { createBrowserClient as createSupabaseBrowserClient } from '@supabase/ssr';
import type { Database } from '@/types/database';

export function createBrowserClient() {
  return createSupabaseBrowserClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
  );
}
```

### 11.4 User Sync Strategy

The `auth.users` table (Supabase-managed) and `public.users` table (app-managed) stay in sync via Postgres triggers. The application **never** writes directly to `auth.users` — it always uses the Supabase Auth Admin API.

| Event | Trigger | Action |
|---|---|---|
| New email/password registration | `handle_new_user()` | Create `tenants`, `users`, `tenant_subscriptions` |
| New OAuth sign-in (first time) | `handle_new_user()` | Same as above |
| Email confirmed | `handle_email_confirmed()` | Set `users.email_verified_at` |
| User deleted from auth.users | `ON DELETE CASCADE` | `public.users` row deleted |
| Auth metadata update | Not synced | App reads from JWT claims |

```sql
-- Email confirmed sync trigger
CREATE OR REPLACE FUNCTION handle_email_confirmed()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.email_confirmed_at IS NULL AND NEW.email_confirmed_at IS NOT NULL THEN
    UPDATE public.users
    SET updated_at = NOW()
    WHERE id = NEW.id;
    -- (Phase 2+) could trigger a welcome email here
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_email_confirmed
  AFTER UPDATE OF email_confirmed_at ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_email_confirmed();
```

---

## 12. Future Scalability

### 12.1 Multi-Tenant Auth Isolation (Phase 3+)

The current architecture is already multi-tenant ready via RLS. Future enhancements:

**Per-tenant SSO (SAML / OIDC).** Enterprise tenants may require their own identity provider. Supabase does not natively support per-tenant SSO in Phase 1. Architecture to add:
- A `tenant_sso_config` table storing provider metadata per tenant.
- Middleware reads the tenant slug and redirects to the appropriate SSO endpoint.
- An `sso_provider` column on `users` tracks the identity source.

**Custom JWT secret per tenant.** Currently all JWTs share the platform's JWT secret. For tenants requiring data residency, a custom JWT signing key per tenant can be layered on top of Supabase using an external auth gateway in Phase 4.

### 12.2 White-Label Auth Pages (Reseller Support)

The current middleware resolves reseller branding from `resellers.branding` JSONB on every request. The auth pages (`/login`, `/register`) should read this context and render the reseller's logo and colors:

```typescript
// app/(auth)/login/page.tsx

export default async function LoginPage() {
  const headersList = headers();
  const resellerId = headersList.get('x-reseller-id');  // set by middleware

  let branding = null;
  if (resellerId) {
    branding = await getResellerBranding(resellerId);
  }

  return <LoginForm branding={branding} />;
}
```

The `emailRedirectTo` URL in auth flows must also use the reseller's domain when operating under white-label:

```typescript
const redirectBase = resellerId
  ? `https://${resellerDomain}`
  : process.env.NEXT_PUBLIC_APP_URL;

await supabase.auth.signUp({
  email, password,
  options: { emailRedirectTo: `${redirectBase}/auth/callback` }
});
```

### 12.3 Advanced Role Customization (Enterprise, Phase 4+)

The current RBAC model uses hard-coded role capability sets. For enterprise tenants requiring custom roles:

- A `custom_roles` table (tenant-scoped) storing role name + array of permission keys.
- A `user_custom_role_id` FK on `users` (nullable; falls back to built-in role if null).
- The JWT custom claims hook includes the custom role's permissions in the token.
- RLS policies would need to be extended or replaced by application-layer permission checks.

This is intentionally deferred — hard-coded roles cover 95% of use cases and avoid the complexity of a dynamic permission engine.

### 12.4 Audit Log Enhancements

The current `audit_logs` table records all destructive actions. For Phase 4+:

- **Real-time alerts:** An Edge Function subscribes to `audit_logs` inserts matching high-risk actions (e.g., `tenant.suspend`, `impersonation.start`) and sends Slack / email alerts.
- **Export API:** Super admin can export audit logs as CSV filtered by tenant, user, action, or date range.
- **Retention policy:** Audit logs are retained for 2 years by default. A nightly cron archives logs older than the retention window to Supabase Storage as gzipped JSONL.

### 12.5 Session Concurrency Controls (Phase 3+)

Currently unlimited concurrent sessions are allowed. Future controls:

```sql
-- Phase 3: track active sessions
CREATE TABLE user_sessions (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  tenant_id    UUID NOT NULL REFERENCES tenants(id),
  device_name  TEXT,
  ip_address   INET,
  user_agent   TEXT,
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

This enables the `/settings/security` page to list active sessions and allow users to remotely revoke individual devices — a standard enterprise security feature.

---

## Appendix A — Auth Environment Variables

```bash
# Supabase (required)
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJ...
SUPABASE_SERVICE_ROLE_KEY=eyJ...          # server-only, NEVER prefix NEXT_PUBLIC_

# OAuth
GOOGLE_CLIENT_ID=...
GOOGLE_CLIENT_SECRET=...

# App URLs
NEXT_PUBLIC_APP_URL=https://app.weddingplatform.com
NEXT_PUBLIC_APP_DOMAIN=weddingplatform.com

# Rate limiting
UPSTASH_REDIS_REST_URL=https://...
UPSTASH_REDIS_REST_TOKEN=...

# Email (Resend SMTP)
RESEND_API_KEY=re_...
EMAIL_FROM=no-reply@weddingplatform.com
```

---

## Appendix B — Auth Flow Summary Table

| Flow | Primary Actor | Method | Session Created |
|---|---|---|---|
| Email/password login | User | `signInWithPassword()` | ✅ |
| Google OAuth login | User | `signInWithOAuth()` | ✅ |
| Email/password register | User | `signUp()` | ❌ (pending email verify) |
| Email verification | System | `exchangeCodeForSession()` | ✅ |
| Password reset request | User | `resetPasswordForEmail()` | ❌ |
| Password reset confirm | User | `exchangeCodeForSession()` + `updateUser()` | ✅ (temporary) |
| Token refresh | System (auto) | `refreshSession()` | ✅ (renewed) |
| Logout | User | `signOut()` | ❌ (revoked) |
| Admin force logout | Super Admin | `admin.signOut(userId, 'global')` | ❌ (all revoked) |
| Admin impersonation | Super Admin | `admin.generateLink('magiclink')` | ✅ (scoped 24h) |

---

## Appendix C — Security Checklist

- [ ] `SUPABASE_SERVICE_ROLE_KEY` never in `NEXT_PUBLIC_` env var
- [ ] `createAdminClient()` only instantiated in `/api/admin/*` server routes
- [ ] `getUser()` used in middleware (not `getSession()` — validates server-side)
- [ ] JWT claims hook registered in Supabase dashboard
- [ ] `handle_new_user()` trigger tested for email collision and race conditions
- [ ] Rate limiting applied to all auth endpoints (login, register, reset)
- [ ] Login brute force counter resets on success
- [ ] Password validation enforced client-side (UX) AND server-side (Zod + Supabase)
- [ ] All cookies: `httpOnly`, `secure`, `sameSite=lax`
- [ ] CSP header set on all responses
- [ ] `X-Frame-Options: DENY` set
- [ ] OAuth redirect URIs locked to known domains in Supabase dashboard
- [ ] Impersonation always writes to `audit_logs` before token is issued
- [ ] Tenant suspension signs out all users in that tenant
- [ ] Email verification required before dashboard access
- [ ] Webhook endpoints validate HMAC signature before processing
- [ ] RLS enabled on all tables (tested with `SELECT * FROM pg_policies`)

---

*End of PHASE3_AUTH.md*
