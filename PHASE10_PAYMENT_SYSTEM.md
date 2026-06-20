# PHASE10_PAYMENT_SYSTEM.md
# Wedding Invitation SaaS Platform — Payment System Architecture

> **Version:** 1.0.0
> **Date:** 2026-06-16
> **Status:** Approved for Development
> **Depends on:** PHASE1_ARCHITECTURE.md, PHASE2_DATABASE.md, PHASE3_AUTH.md, PHASE4_ADMIN_ARCHITECTURE.md, PHASE5_PACKAGE_FEATURE_SYSTEM.md, PHASE6_THEME_SYSTEM.md, PHASE7_INVITATION_MANAGEMENT.md, PHASE8_GUEST_MANAGEMENT.md, PHASE9_RSVP_GUESTBOOK.md

---

## Table of Contents

1. [Payment Architecture Overview](#1-payment-architecture-overview)
2. [Billing Data Model](#2-billing-data-model)
3. [Package Purchase System](#3-package-purchase-system)
4. [Payment Gateway Architecture](#4-payment-gateway-architecture)
5. [Supported Payment Methods](#5-supported-payment-methods)
6. [Invoice System](#6-invoice-system)
7. [Transaction Management](#7-transaction-management)
8. [Webhook Architecture](#8-webhook-architecture)
9. [Subscription Lifecycle Management](#9-subscription-lifecycle-management)
10. [Upgrade and Downgrade Flows](#10-upgrade-and-downgrade-flows)
11. [Renewal and Expiration Handling](#11-renewal-and-expiration-handling)
12. [Refund Architecture](#12-refund-architecture)
13. [Reseller Commission System](#13-reseller-commission-system)
14. [Admin Payment Management](#14-admin-payment-management)
15. [Permission Rules](#15-permission-rules)
16. [Multi-Tenant Security](#16-multi-tenant-security)
17. [Performance Optimization](#17-performance-optimization)
18. [Scalability Considerations](#18-scalability-considerations)

---

## 1. Payment Architecture Overview

### 1.1 Design Philosophy

The payment system is **gateway-agnostic and database-driven**. All pricing, quota limits, and billing rules live in the database — no hardcoded amounts, no hardcoded tier names in business logic. Adding a new gateway, changing pricing, or reconfiguring payment methods requires only database updates and a new adapter class; no changes to the billing orchestration layer.

**Key trade-off decisions:**

| Decision | Options | Choice | Reason |
|---|---|---|---|
| Gateway abstraction | Single Midtrans integration vs adapter interface | Adapter interface | Vendor lock-in risk; Xendit/Stripe become drop-in additions |
| Webhook idempotency | DB unique constraint vs application key | SHA256 idempotency key + DB unique | Prevents race on concurrent duplicate webhooks |
| Order vs subscription | Single orders table vs separate subscription lifecycle | Separate tables | Subscription needs grace/pause/downgrade states orders do not |
| Invoice numbering | UUID vs sequential | Sequential `INV-YYYYMM-NNNNN` | Indonesian accounting/tax compliance requirement |
| Proration on upgrade | None vs full-month vs remaining-days | Remaining-days daily-rate credit | Fairest for tenants; industry standard |
| Webhook retry | Return 4xx (provider retries) vs 200 + internal queue | Always 200 + reconciliation cron | Avoids provider hammering on application-layer bugs |

### 1.2 System Layers

```
┌─────────────────────────────────────────────────────────────────────┐
│                       PAYMENT SYSTEM LAYERS                          │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  1. INITIATION LAYER  (auth-required, tenant-scoped)         │   │
│  │     Package select → Proration calc → Order create           │   │
│  │     → Invoice generate → GatewayAdapter.createPayment()      │   │
│  └──────────────────────────────┬──────────────────────────────┘   │
│                                 │                                   │
│  ┌──────────────────────────────▼──────────────────────────────┐   │
│  │  2. GATEWAY ABSTRACTION LAYER                                │   │
│  │     GatewayAdapter interface · Midtrans · Xendit · Manual    │   │
│  │     Method-to-provider routing · VA / QRIS / e-wallet        │   │
│  └──────────────────────────────┬──────────────────────────────┘   │
│                                 │                                   │
│  ┌──────────────────────────────▼──────────────────────────────┐   │
│  │  3. WEBHOOK PROCESSING LAYER                                 │   │
│  │     Signature validation · Idempotency key · State machine   │   │
│  │     Cascade: transaction → order → invoice                   │   │
│  └──────────────────────────────┬──────────────────────────────┘   │
│                                 │                                   │
│  ┌──────────────────────────────▼──────────────────────────────┐   │
│  │  4. ACTIVATION LAYER                                         │   │
│  │     Subscription upsert · Feature cache invalidation (Redis) │   │
│  │     JWT refresh · Audit log · Email notification queue       │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.3 End-to-End Billing Flow

```
Tenant selects package + billing cycle
  │
  ▼
Server: validatePackageAccess()
  - Package exists, is_public=TRUE, status='active'
  - If upgrade: calculateUpgradePricing() for proration
  - Resolve voucher discount if provided
  │
  ▼
Server: createOrder()
  - orders row (status='pending')
  - invoices row (status='unpaid', sequential invoice number)
  │
  ▼
Server: GatewayAdapter.createPayment()
  - payment_transactions row (status='initiated')
  - Returns VA number / QRIS image / redirect URL
  │
  ▼
Client: renders payment instructions or redirects to provider checkout
  │
  ▼
Provider: user completes payment
  │
  ▼
Provider → POST /api/webhooks/[provider]
  - Validate HMAC signature
  - Check idempotency key (skip if already processed)
  - Log to webhook_logs (append-only, always)
  - applyTransactionStatus(): payment_transactions → orders → invoices
  │
  ├─ status='paid' → activateSubscriptionFromOrder()
  │     Update tenant_subscriptions
  │     Invalidate feature cache (Redis)
  │     Queue payment_receipt email
  │     Write audit_log
  │
  └─ status='failed'/'expired' → update order; no activation
```

### 1.4 Order Lifecycle

```
PENDING ──────────────────── PAID            (webhook: payment confirmed)
   │                          │
   │                          ├──────────── REFUNDED       (full refund)
   │                          └──────────── PARTIALLY_REFUNDED
   │
   ├─────────────────────── FAILED           (webhook: rejected)
   ├─────────────────────── EXPIRED          (24h window elapsed)
   └─────────────────────── CANCELLED        (explicit cancellation)
```

### 1.5 Transaction Lifecycle

```
INITIATED → PENDING    (gateway accepted; user sees payment screen)
PENDING   → PAID       (user completed payment; webhook confirmed)
PENDING   → FAILED     (payment rejected at provider)
PENDING   → EXPIRED    (payment window elapsed at provider)
PAID      → REFUNDED   (refund processed at gateway)
```

---

## 2. Billing Data Model

### 2.1 Complete ERD — Billing Domain

```
tenants ──────────────────────────────────────────────────────────────
   │
   ▼ (1:many)
orders ──────────────────────────────────────────────────────────────
   │  (tenant_id, package_id OR add_on_id, reseller_id?)
   │
   ├──── payment_transactions   (1:many — multiple retry attempts)
   │
   ├──── invoices               (1:1 — one invoice per order)
   │         └── invoice_sequences  (month-scoped atomic counter)
   │
   ├──── refund_requests        (1:many)
   │
   └──── voucher_redemptions    (0:1 if voucher applied)
              └── vouchers

packages / add_ons ───────────────────────────────────────────────────
resellers ────────────────────────────────────────────────────────────
   └── commission_ledger   (1:many — per paid order with reseller)
   └── commission_payouts  (1:many — monthly batches)

webhook_logs  (append-only audit; no FK to orders for resilience)
```

### 2.2 `orders` Table

```sql
CREATE TABLE orders (
  id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Ownership
  tenant_id             UUID          NOT NULL REFERENCES tenants(id),
  reseller_id           UUID          REFERENCES resellers(id),
  created_by            UUID          REFERENCES users(id),

  -- Line item: exactly one of package_id or add_on_id must be non-null
  package_id            UUID          REFERENCES packages(id),
  add_on_id             UUID          REFERENCES add_ons(id),
  subscription_id       UUID          REFERENCES tenant_subscriptions(id),
  -- Populated after activation; links order to the resulting subscription
  billing_cycle         TEXT          NOT NULL
                                      CHECK (billing_cycle IN (
                                        'monthly','yearly','lifetime','one_time'
                                      )),

  -- Pricing (NUMERIC for exact decimal accounting; no floating point)
  currency              TEXT          NOT NULL DEFAULT 'IDR',
  amount_gross          NUMERIC(14,2) NOT NULL,
  -- Full list price before any reductions
  amount_discount       NUMERIC(14,2) NOT NULL DEFAULT 0,
  -- Voucher discount
  amount_proration      NUMERIC(14,2) NOT NULL DEFAULT 0,
  -- Credit from remaining days on current plan (upgrade only)
  amount_net            NUMERIC(14,2) NOT NULL,
  -- Tenant actually pays: gross - discount - proration
  voucher_id            UUID          REFERENCES vouchers(id),

  -- Commission frozen at order creation (never recalculated retroactively)
  commission_amount     NUMERIC(14,2),
  commission_pct        NUMERIC(5,2),

  -- Lifecycle
  status                TEXT          NOT NULL DEFAULT 'pending'
                                      CHECK (status IN (
                                        'pending','paid','failed','expired',
                                        'cancelled','refunded','partially_refunded'
                                      )),

  -- Gateway tracking
  payment_provider      TEXT          CHECK (payment_provider IN (
                                        'midtrans','xendit','manual'
                                      )),
  payment_ref           TEXT,

  notes                 TEXT,
  metadata              JSONB         NOT NULL DEFAULT '{}',

  -- Timestamps
  paid_at               TIMESTAMPTZ,
  expires_at            TIMESTAMPTZ,
  created_at            TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_order_item CHECK (
    (package_id IS NOT NULL AND add_on_id IS NULL) OR
    (package_id IS NULL     AND add_on_id IS NOT NULL)
  )
);

CREATE TRIGGER trg_orders_updated_at
  BEFORE UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_orders_tenant_id       ON orders(tenant_id);
CREATE INDEX idx_orders_status          ON orders(status, created_at DESC);
CREATE INDEX idx_orders_reseller_id     ON orders(reseller_id) WHERE reseller_id IS NOT NULL;
CREATE INDEX idx_orders_payment_ref     ON orders(payment_ref) WHERE payment_ref IS NOT NULL;
CREATE INDEX idx_orders_paid_at         ON orders(paid_at DESC) WHERE paid_at IS NOT NULL;
CREATE INDEX idx_orders_expires_pending ON orders(expires_at ASC) WHERE status = 'pending';
CREATE INDEX idx_orders_subscription    ON orders(subscription_id)
  WHERE subscription_id IS NOT NULL;
```

### 2.3 `payment_transactions` Table

One order may have multiple transaction attempts (user retries with a different method). Each attempt is one row.

```sql
CREATE TABLE payment_transactions (
  id                UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id          UUID          NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  tenant_id         UUID          NOT NULL REFERENCES tenants(id),

  -- Gateway identifiers
  provider          TEXT          NOT NULL
                                  CHECK (provider IN ('midtrans','xendit','manual')),
  provider_tx_id    TEXT          NOT NULL,
  provider_order_id TEXT,

  -- Payment method used
  payment_method    TEXT,
  -- 'qris'|'va_bca'|'va_bni'|'va_mandiri'|'va_bri'|'va_permata'
  -- |'gopay'|'ovo'|'dana'|'shopeepay'|'linkaja'|'manual'

  -- Amounts
  amount            NUMERIC(14,2) NOT NULL,
  currency          TEXT          NOT NULL DEFAULT 'IDR',

  -- Payment delivery details (method-specific)
  va_number         TEXT,
  va_bank           TEXT,
  qris_url          TEXT,
  qris_string       TEXT,
  deeplink_url      TEXT,
  payment_url       TEXT,

  -- Status
  status            TEXT          NOT NULL DEFAULT 'initiated'
                                  CHECK (status IN (
                                    'initiated','pending','paid',
                                    'failed','expired','refunded'
                                  )),

  -- Raw gateway data (immutable after write for auditability)
  gateway_request   JSONB         NOT NULL DEFAULT '{}',
  gateway_response  JSONB         NOT NULL DEFAULT '{}',
  webhook_payload   JSONB,

  -- Timestamps
  initiated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  paid_at           TIMESTAMPTZ,
  failed_at         TIMESTAMPTZ,
  expires_at        TIMESTAMPTZ,
  created_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  UNIQUE (provider, provider_tx_id)
);

CREATE TRIGGER trg_payment_transactions_updated_at
  BEFORE UPDATE ON payment_transactions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_ptx_order_id       ON payment_transactions(order_id);
CREATE INDEX idx_ptx_tenant_id      ON payment_transactions(tenant_id);
CREATE INDEX idx_ptx_provider_tx    ON payment_transactions(provider, provider_tx_id);
CREATE INDEX idx_ptx_pending        ON payment_transactions(status, initiated_at)
  WHERE status IN ('initiated','pending');
CREATE INDEX idx_ptx_expires        ON payment_transactions(expires_at)
  WHERE status IN ('initiated','pending');
```

### 2.4 `invoices` Table

```sql
CREATE TABLE invoices (
  id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id         UUID          NOT NULL UNIQUE REFERENCES orders(id),
  tenant_id        UUID          NOT NULL REFERENCES tenants(id),

  -- Sequential human-readable number (Indonesian tax/accounting requirement)
  invoice_number   TEXT          NOT NULL UNIQUE,
  -- Format: INV-YYYYMM-NNNNN  e.g. INV-202606-00042

  -- Amounts (snapshot of order at generation time; immutable thereafter)
  currency         TEXT          NOT NULL DEFAULT 'IDR',
  subtotal         NUMERIC(14,2) NOT NULL,
  discount_amount  NUMERIC(14,2) NOT NULL DEFAULT 0,
  proration_credit NUMERIC(14,2) NOT NULL DEFAULT 0,
  total_amount     NUMERIC(14,2) NOT NULL,

  -- Voucher snapshot
  voucher_code     TEXT,
  voucher_desc     TEXT,

  -- Line items snapshot (preserves purchase description even if package is later renamed)
  line_items       JSONB         NOT NULL DEFAULT '[]',
  -- [{ description, quantity, unit_price, amount }]

  -- Billing party snapshot
  billed_to        JSONB         NOT NULL DEFAULT '{}',
  -- { name, email, address, tax_id }

  status           TEXT          NOT NULL DEFAULT 'unpaid'
                                 CHECK (status IN ('unpaid','paid','void','refunded')),

  issued_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  due_at           TIMESTAMPTZ   NOT NULL,
  paid_at          TIMESTAMPTZ,
  voided_at        TIMESTAMPTZ,

  pdf_url          TEXT,

  created_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_invoices_updated_at
  BEFORE UPDATE ON invoices
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_invoices_tenant    ON invoices(tenant_id, issued_at DESC);
CREATE INDEX idx_invoices_status    ON invoices(status);
CREATE INDEX idx_invoices_number    ON invoices(invoice_number);
CREATE INDEX idx_invoices_due       ON invoices(due_at) WHERE status = 'unpaid';
```

### 2.5 `invoice_sequences` Table

```sql
-- Per-month atomic counter; prevents gaps and races in invoice numbering

CREATE TABLE invoice_sequences (
  year_month  TEXT    PRIMARY KEY,   -- e.g. '202606'
  last_seq    INTEGER NOT NULL DEFAULT 0
);

CREATE OR REPLACE FUNCTION next_invoice_number(p_year_month TEXT)
RETURNS TEXT AS $$
DECLARE v_seq INTEGER;
BEGIN
  INSERT INTO invoice_sequences (year_month, last_seq)
  VALUES (p_year_month, 1)
  ON CONFLICT (year_month)
  DO UPDATE SET last_seq = invoice_sequences.last_seq + 1
  RETURNING last_seq INTO v_seq;

  RETURN 'INV-' || p_year_month || '-' || LPAD(v_seq::TEXT, 5, '0');
END;
$$ LANGUAGE plpgsql;
```

### 2.6 `webhook_logs` Table

```sql
-- Append-only immutable log of every inbound webhook event.
-- Not FK-linked to orders/transactions intentionally —
-- gateway may send events before our order is created (race).

CREATE TABLE webhook_logs (
  id              BIGSERIAL   PRIMARY KEY,
  provider        TEXT        NOT NULL,
  event_type      TEXT,
  provider_tx_id  TEXT,
  idempotency_key TEXT        NOT NULL UNIQUE,
  -- SHA256(provider + ':' + provider_tx_id + ':' + status)
  raw_payload     JSONB       NOT NULL,
  signature_valid BOOLEAN     NOT NULL,
  processed       BOOLEAN     NOT NULL DEFAULT FALSE,
  processing_error TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_webhook_provider    ON webhook_logs(provider, created_at DESC);
CREATE INDEX idx_webhook_tx_id       ON webhook_logs(provider_tx_id)
  WHERE provider_tx_id IS NOT NULL;
CREATE INDEX idx_webhook_unprocessed ON webhook_logs(processed)
  WHERE processed = FALSE;
```

### 2.7 `refund_requests` Table

```sql
CREATE TABLE refund_requests (
  id                 UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id           UUID        NOT NULL REFERENCES orders(id),
  tenant_id          UUID        NOT NULL REFERENCES tenants(id),
  requested_by       UUID        REFERENCES users(id),

  amount             NUMERIC(14,2) NOT NULL,
  currency           TEXT        NOT NULL DEFAULT 'IDR',
  is_full_refund     BOOLEAN     NOT NULL DEFAULT TRUE,

  reason             TEXT        NOT NULL,
  category           TEXT        NOT NULL DEFAULT 'other'
                                 CHECK (category IN (
                                   'duplicate_payment','service_issue',
                                   'plan_not_needed','billing_error','other'
                                 )),

  status             TEXT        NOT NULL DEFAULT 'pending'
                                 CHECK (status IN (
                                   'pending','approved','rejected',
                                   'processing','completed','failed'
                                 )),
  reviewed_by        UUID        REFERENCES users(id),
  reviewed_at        TIMESTAMPTZ,
  rejection_note     TEXT,

  provider_refund_id TEXT,
  refunded_at        TIMESTAMPTZ,

  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_refund_requests_updated_at
  BEFORE UPDATE ON refund_requests
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_refunds_tenant_id ON refund_requests(tenant_id);
CREATE INDEX idx_refunds_order_id  ON refund_requests(order_id);
CREATE INDEX idx_refunds_pending   ON refund_requests(status)
  WHERE status IN ('pending','approved','processing');
```

### 2.8 TypeScript Type Definitions

```typescript
// types/billing.ts

export type OrderStatus =
  | 'pending' | 'paid' | 'failed' | 'expired'
  | 'cancelled' | 'refunded' | 'partially_refunded';

export type TransactionStatus =
  | 'initiated' | 'pending' | 'paid'
  | 'failed' | 'expired' | 'refunded';

export type InvoiceStatus = 'unpaid' | 'paid' | 'void' | 'refunded';

export type PaymentProvider = 'midtrans' | 'xendit' | 'manual';

export type PaymentMethod =
  | 'qris'
  | 'va_bca' | 'va_bni' | 'va_mandiri' | 'va_bri' | 'va_permata'
  | 'gopay' | 'ovo' | 'dana' | 'shopeepay' | 'linkaja'
  | 'bank_transfer' | 'manual';

export interface Order {
  id:                string;
  tenant_id:         string;
  reseller_id:       string | null;
  created_by:        string | null;
  package_id:        string | null;
  add_on_id:         string | null;
  subscription_id:   string | null;
  billing_cycle:     'monthly' | 'yearly' | 'lifetime' | 'one_time';
  currency:          string;
  amount_gross:      number;
  amount_discount:   number;
  amount_proration:  number;
  amount_net:        number;
  voucher_id:        string | null;
  commission_amount: number | null;
  commission_pct:    number | null;
  status:            OrderStatus;
  payment_provider:  PaymentProvider | null;
  payment_ref:       string | null;
  paid_at:           string | null;
  expires_at:        string | null;
  created_at:        string;
}

export interface PaymentTransaction {
  id:             string;
  order_id:       string;
  tenant_id:      string;
  provider:       PaymentProvider;
  provider_tx_id: string;
  payment_method: PaymentMethod | null;
  amount:         number;
  currency:       string;
  va_number:      string | null;
  va_bank:        string | null;
  qris_url:       string | null;
  deeplink_url:   string | null;
  payment_url:    string | null;
  status:         TransactionStatus;
  initiated_at:   string;
  paid_at:        string | null;
  expires_at:     string | null;
}

export interface Invoice {
  id:               string;
  order_id:         string;
  tenant_id:        string;
  invoice_number:   string;
  currency:         string;
  subtotal:         number;
  discount_amount:  number;
  proration_credit: number;
  total_amount:     number;
  voucher_code:     string | null;
  line_items:       InvoiceLineItem[];
  billed_to:        BilledTo;
  status:           InvoiceStatus;
  issued_at:        string;
  due_at:           string;
  paid_at:          string | null;
  pdf_url:          string | null;
}

export interface InvoiceLineItem {
  description: string;
  quantity:    number;
  unit_price:  number;
  amount:      number;
}

export interface BilledTo {
  name:    string;
  email:   string;
  address: string | null;
  tax_id:  string | null;
}

export interface PriceCalculation {
  base_price:          number;
  discount_amount:     number;
  proration_credit:    number;
  final_price:         number;
  currency:            string;
  savings_vs_monthly?: number;
}
```

---

## 3. Package Purchase System

### 3.1 Pricing Calculation

```typescript
// lib/billing/pricing.ts

export function calculatePrice(
  pkg:             Package,
  billingCycle:    'monthly' | 'yearly' | 'lifetime',
  voucherDiscount?: { type: 'percentage' | 'fixed'; value: number }
): PriceCalculation {
  const basePrice =
    billingCycle === 'yearly'   ? pkg.price_yearly :
    billingCycle === 'lifetime' ? (pkg.price_lifetime ?? pkg.price_monthly * 24) :
                                   pkg.price_monthly;

  let discountAmount = 0;
  if (voucherDiscount) {
    discountAmount = voucherDiscount.type === 'percentage'
      ? Math.floor(basePrice * (voucherDiscount.value / 100))
      : Math.min(voucherDiscount.value, basePrice);
  }

  return {
    base_price:          basePrice,
    discount_amount:     discountAmount,
    proration_credit:    0,
    final_price:         Math.max(0, basePrice - discountAmount),
    currency:            pkg.currency,
    savings_vs_monthly:  billingCycle === 'yearly'
                           ? (pkg.price_monthly * 12) - pkg.price_yearly
                           : undefined,
  };
}
```

### 3.2 `createOrder` Helper

```typescript
// lib/billing/orders.ts

interface CreateOrderInput {
  tenantId:        string;
  resellerId:      string | null;
  createdBy:       string | null;
  packageId?:      string;
  addOnId?:        string;
  billingCycle:    string;
  currency:        string;
  amountGross:     number;
  amountDiscount:  number;
  amountProration: number;
  amountNet:       number;
  voucherId?:      string | null;
  commissionAmount?: number | null;
  commissionPct?:    number | null;
  expiresAt:       string;
}

export async function createOrder(input: CreateOrderInput): Promise<Order> {
  const supabase = createServerClient();
  const { data, error } = await supabase
    .from('orders')
    .insert({
      tenant_id:         input.tenantId,
      reseller_id:       input.resellerId,
      created_by:        input.createdBy,
      package_id:        input.packageId ?? null,
      add_on_id:         input.addOnId ?? null,
      billing_cycle:     input.billingCycle,
      currency:          input.currency,
      amount_gross:      input.amountGross,
      amount_discount:   input.amountDiscount,
      amount_proration:  input.amountProration,
      amount_net:        input.amountNet,
      voucher_id:        input.voucherId ?? null,
      commission_amount: input.commissionAmount ?? null,
      commission_pct:    input.commissionPct ?? null,
      status:            'pending',
      expires_at:        input.expiresAt,
    })
    .select()
    .single();

  if (error || !data) throw new Error(`createOrder failed: ${error?.message}`);
  return data as Order;
}
```

### 3.3 New Subscription Purchase API

```typescript
// app/api/subscription/purchase/route.ts

import { z } from 'zod';
import { requireAuth } from '@/lib/auth/api-guard';
import { createServerClient } from '@/lib/supabase/server';
import { calculatePrice } from '@/lib/billing/pricing';
import { resolveVoucher } from '@/lib/billing/vouchers';
import { createOrder } from '@/lib/billing/orders';
import { generateInvoice } from '@/lib/billing/invoices';
import { getGatewayAdapter } from '@/lib/billing/gateway';
import { createTransaction } from '@/lib/billing/transactions';
import { writeAuditLog } from '@/lib/audit/write';

const PurchaseSchema = z.object({
  package_id:     z.string().uuid(),
  billing_cycle:  z.enum(['monthly', 'yearly', 'lifetime']),
  payment_method: z.string(),
  voucher_code:   z.string().optional(),
});

export async function POST(request: Request) {
  const auth = await requireAuth(request, 'subscription:write');
  if (auth instanceof NextResponse) return auth;

  const parsed = PurchaseSchema.safeParse(await request.json());
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.flatten() }, { status: 422 });
  }

  const supabase = createServerClient();

  // Validate package
  const { data: pkg } = await supabase
    .from('packages')
    .select('*')
    .eq('id', parsed.data.package_id)
    .eq('status', 'active')
    .eq('is_public', true)
    .single();

  if (!pkg) return NextResponse.json({ error: 'Package not found.' }, { status: 404 });

  // Route to upgrade if already subscribed
  const { data: currentSub } = await supabase
    .from('tenant_subscriptions')
    .select('*, package:packages(*)')
    .eq('tenant_id', auth.user.tenantId)
    .in('status', ['active', 'trialing'])
    .maybeSingle();

  if (currentSub) {
    return handleSubscriptionChange(request, auth.user, currentSub, pkg, parsed.data);
  }

  // Resolve voucher
  let voucherResult: Awaited<ReturnType<typeof resolveVoucher>> | null = null;
  if (parsed.data.voucher_code) {
    voucherResult = await resolveVoucher(
      parsed.data.voucher_code,
      pkg.id,
      parsed.data.billing_cycle,
      auth.user.tenantId
    );
    if (!voucherResult.valid) {
      return NextResponse.json({ error: voucherResult.reason }, { status: 422 });
    }
  }

  const pricing = calculatePrice(pkg, parsed.data.billing_cycle, voucherResult?.discount);

  // Commission (frozen at creation time)
  let commissionAmount: number | null = null;
  let commissionPct: number | null = null;
  if (auth.user.resellerId) {
    const { data: reseller } = await supabase
      .from('resellers').select('commission_pct').eq('id', auth.user.resellerId).single();
    commissionPct    = reseller?.commission_pct ?? 0;
    commissionAmount = (pricing.final_price * commissionPct) / 100;
  }

  const order   = await createOrder({
    tenantId:        auth.user.tenantId,
    resellerId:      auth.user.resellerId ?? null,
    createdBy:       auth.user.id,
    packageId:       pkg.id,
    billingCycle:    parsed.data.billing_cycle,
    currency:        pkg.currency,
    amountGross:     pricing.base_price,
    amountDiscount:  pricing.discount_amount,
    amountProration: 0,
    amountNet:       pricing.final_price,
    voucherId:       voucherResult?.voucherId ?? null,
    commissionAmount,
    commissionPct,
    expiresAt:       new Date(Date.now() + 24 * 3600 * 1000).toISOString(),
  });

  const invoice = await generateInvoice(order, pkg, auth.user);
  const gateway = getGatewayAdapter(parsed.data.payment_method);

  const paymentInit = await gateway.createPayment({
    orderId:       order.id,
    amount:        pricing.final_price,
    currency:      pkg.currency,
    method:        parsed.data.payment_method as PaymentMethod,
    customerName:  auth.user.fullName,
    customerEmail: auth.user.email,
    description:   `${pkg.name} — ${parsed.data.billing_cycle}`,
    metadata: {
      invoice_number: invoice.invoiceNumber,
      tenant_id:      auth.user.tenantId,
    },
  });

  await createTransaction(supabase, order.id, auth.user.tenantId, gateway.provider, paymentInit);

  // Increment voucher used_count
  if (voucherResult?.voucherId) {
    await supabase.rpc('increment_voucher_used_count', { p_voucher_id: voucherResult.voucherId });
    await supabase.from('voucher_redemptions').insert({
      voucher_id:       voucherResult.voucherId,
      order_id:         order.id,
      tenant_id:        auth.user.tenantId,
      discount_applied: pricing.discount_amount,
    });
  }

  await writeAuditLog(request, 'order.create', 'order', order.id, {
    tenantId: auth.user.tenantId,
    userId:   auth.user.id,
    newData:  { package_id: pkg.id, amount_net: pricing.final_price },
  });

  return NextResponse.json({
    order_id:       order.id,
    invoice_number: invoice.invoiceNumber,
    amount_net:     pricing.final_price,
    currency:       pkg.currency,
    payment_url:    paymentInit.payment_url   ?? null,
    va_number:      paymentInit.va_number     ?? null,
    va_bank:        paymentInit.va_bank       ?? null,
    qris_url:       paymentInit.qris_url      ?? null,
    deeplink_url:   paymentInit.deeplink_url  ?? null,
    expires_at:     paymentInit.expires_at,
  });
}
```

### 3.4 Add-On Purchase API

```typescript
// app/api/add-ons/purchase/route.ts

const AddOnPurchaseSchema = z.object({
  add_on_id:      z.string().uuid(),
  quantity:       z.coerce.number().int().min(1).max(10).default(1),
  payment_method: z.string(),
});

export async function POST(request: Request) {
  const auth = await requireAuth(request, 'subscription:write');
  if (auth instanceof NextResponse) return auth;

  const parsed = AddOnPurchaseSchema.safeParse(await request.json());
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.flatten() }, { status: 422 });
  }

  const supabase = createServerClient();

  const { data: addOn } = await supabase
    .from('add_ons').select('*').eq('id', parsed.data.add_on_id).eq('is_active', true).single();

  if (!addOn) return NextResponse.json({ error: 'Add-on not found.' }, { status: 404 });

  if (!addOn.is_stackable && parsed.data.quantity > 1) {
    return NextResponse.json({ error: 'This add-on cannot be purchased in multiple units.' }, { status: 422 });
  }

  if (!addOn.is_stackable) {
    const { data: existing } = await supabase
      .from('tenant_add_ons')
      .select('id').eq('tenant_id', auth.user.tenantId)
      .eq('add_on_id', addOn.id).eq('status', 'active').maybeSingle();
    if (existing) return NextResponse.json({ error: 'Add-on already active.' }, { status: 409 });
  }

  const totalAmount = addOn.price * parsed.data.quantity;

  const order    = await createOrder({
    tenantId: auth.user.tenantId, resellerId: null, createdBy: auth.user.id,
    addOnId: addOn.id, billingCycle: addOn.billing_cycle,
    currency: addOn.currency, amountGross: totalAmount,
    amountDiscount: 0, amountProration: 0, amountNet: totalAmount,
    expiresAt: new Date(Date.now() + 24 * 3600 * 1000).toISOString(),
  });

  const invoice     = await generateInvoice(order, null, auth.user, addOn);
  const gateway     = getGatewayAdapter(parsed.data.payment_method);
  const paymentInit = await gateway.createPayment({
    orderId: order.id, amount: totalAmount, currency: addOn.currency,
    method: parsed.data.payment_method as PaymentMethod,
    customerName: auth.user.fullName, customerEmail: auth.user.email,
    description: `${addOn.name} ×${parsed.data.quantity}`,
    metadata: { invoice_number: invoice.invoiceNumber, tenant_id: auth.user.tenantId },
  });

  await createTransaction(supabase, order.id, auth.user.tenantId, gateway.provider, paymentInit);

  return NextResponse.json({
    order_id: order.id, invoice_number: invoice.invoiceNumber,
    amount_net: totalAmount,
    payment_url: paymentInit.payment_url ?? null,
    va_number: paymentInit.va_number ?? null,
    qris_url: paymentInit.qris_url ?? null,
    expires_at: paymentInit.expires_at,
  });
}
```

### 3.5 Voucher Resolution

```typescript
// lib/billing/vouchers.ts

export interface VoucherResolution {
  valid:      boolean;
  reason?:    string;
  voucherId?: string;
  discount?:  { type: 'percentage' | 'fixed'; value: number };
}

export async function resolveVoucher(
  code:         string,
  packageId:    string,
  billingCycle: string,
  tenantId:     string
): Promise<VoucherResolution> {
  const supabase = createServerClient();
  const now = new Date().toISOString();

  const { data: voucher } = await supabase
    .from('vouchers')
    .select('*')
    .eq('code', code.toUpperCase().trim())
    .eq('is_active', true)
    .lte('valid_from', now)
    .single();

  if (!voucher) return { valid: false, reason: 'Voucher not found or not active.' };
  if (voucher.valid_until && voucher.valid_until < now) {
    return { valid: false, reason: 'This voucher has expired.' };
  }
  if (voucher.max_uses !== null && voucher.used_count >= voucher.max_uses) {
    return { valid: false, reason: 'This voucher has reached its usage limit.' };
  }

  if (voucher.applicable_packages?.length > 0) {
    const { data: pkg } = await supabase
      .from('packages').select('slug').eq('id', packageId).single();
    if (!voucher.applicable_packages.includes(pkg?.slug)) {
      return { valid: false, reason: 'Voucher does not apply to the selected package.' };
    }
  }

  if (voucher.applicable_cycles?.length > 0 && !voucher.applicable_cycles.includes(billingCycle)) {
    return { valid: false, reason: `Voucher is only valid for ${voucher.applicable_cycles.join(' or ')} billing.` };
  }

  const { count } = await supabase
    .from('voucher_redemptions')
    .select('id', { count: 'exact', head: true })
    .eq('voucher_id', voucher.id).eq('tenant_id', tenantId);

  if ((count ?? 0) > 0) {
    return { valid: false, reason: 'You have already used this voucher.' };
  }

  return {
    valid: true,
    voucherId: voucher.id,
    discount: { type: voucher.discount_type, value: voucher.discount_value },
  };
}
```

---

## 4. Payment Gateway Architecture

### 4.1 GatewayAdapter Interface

```typescript
// lib/billing/gateway/interface.ts

export interface CreatePaymentRequest {
  orderId:       string;
  amount:        number;
  currency:      string;
  method:        PaymentMethod;
  customerName:  string;
  customerEmail: string;
  description:   string;
  metadata:      Record<string, string>;
  redirectUrl?:  string;
}

export interface CreatePaymentResponse {
  provider_tx_id: string;
  payment_url?:   string;
  va_number?:     string;
  va_bank?:       string;
  qris_url?:      string;
  qris_string?:   string;
  deeplink_url?:  string;
  expires_at:     string;
  raw_response:   Record<string, unknown>;
}

export interface WebhookValidationResult {
  valid:          boolean;
  provider_tx_id: string | null;
  status:         TransactionStatus | null;
  amount:         number | null;
  raw_payload:    Record<string, unknown>;
}

export interface RefundRequest {
  provider_tx_id: string;
  amount:         number;
  reason:         string;
}

export interface RefundResponse {
  refund_id:    string;
  status:       'success' | 'pending' | 'failed';
  raw_response: Record<string, unknown>;
}

export interface GatewayAdapter {
  readonly provider:         PaymentProvider;
  readonly supportedMethods: PaymentMethod[];

  createPayment(req: CreatePaymentRequest): Promise<CreatePaymentResponse>;
  validateWebhook(headers: Record<string, string>, body: string): Promise<WebhookValidationResult>;
  getTransactionStatus(providerTxId: string): Promise<TransactionStatus>;
  refund(req: RefundRequest): Promise<RefundResponse>;
}
```

### 4.2 Gateway Registry

```typescript
// lib/billing/gateway/index.ts

import { MidtransAdapter } from './midtrans';
import { XenditAdapter }   from './xendit';
import { ManualAdapter }   from './manual';

const ADAPTERS: Record<string, GatewayAdapter> = {
  midtrans: new MidtransAdapter(),
  xendit:   new XenditAdapter(),
  manual:   new ManualAdapter(),
};

// Method-to-provider routing (change config here; no business logic changes needed)
const METHOD_TO_PROVIDER: Record<PaymentMethod, PaymentProvider> = {
  qris:          'midtrans',
  va_bca:        'midtrans',
  va_bni:        'midtrans',
  va_mandiri:    'midtrans',
  va_bri:        'midtrans',
  va_permata:    'xendit',
  gopay:         'midtrans',
  shopeepay:     'midtrans',
  ovo:           'xendit',
  dana:          'xendit',
  linkaja:       'xendit',
  bank_transfer: 'midtrans',
  manual:        'manual',
};

export function getGatewayAdapter(method: string): GatewayAdapter {
  const provider = METHOD_TO_PROVIDER[method as PaymentMethod] ?? 'midtrans';
  return ADAPTERS[provider];
}

export function getAdapterByProvider(provider: PaymentProvider): GatewayAdapter {
  return ADAPTERS[provider];
}
```

### 4.3 Midtrans Adapter

```typescript
// lib/billing/gateway/midtrans.ts

import crypto from 'crypto';

export class MidtransAdapter implements GatewayAdapter {
  readonly provider          = 'midtrans' as const;
  readonly supportedMethods: PaymentMethod[] = [
    'qris','va_bca','va_bni','va_mandiri','va_bri','gopay','shopeepay','bank_transfer',
  ];

  private get baseUrl(): string {
    return process.env.MIDTRANS_IS_PRODUCTION === 'true'
      ? 'https://api.midtrans.com/v2'
      : 'https://api.sandbox.midtrans.com/v2';
  }

  private get authHeader(): string {
    return 'Basic ' + Buffer.from(process.env.MIDTRANS_SERVER_KEY! + ':').toString('base64');
  }

  async createPayment(req: CreatePaymentRequest): Promise<CreatePaymentResponse> {
    const payload = this.buildChargePayload(req);
    const res = await fetch(`${this.baseUrl}/charge`, {
      method: 'POST',
      headers: { Authorization: this.authHeader, 'Content-Type': 'application/json' },
      body:    JSON.stringify(payload),
    });
    if (!res.ok) {
      const err = await res.json();
      throw new Error(`Midtrans charge failed: ${JSON.stringify(err)}`);
    }
    const data = await res.json();
    return this.mapResponse(data);
  }

  async validateWebhook(headers: Record<string, string>, body: string): Promise<WebhookValidationResult> {
    const payload = JSON.parse(body);
    const { order_id, status_code, gross_amount, signature_key,
            transaction_id, transaction_status, fraud_status } = payload;

    // SHA512(order_id + status_code + gross_amount + ServerKey)
    const expected = crypto.createHash('sha512')
      .update(`${order_id}${status_code}${gross_amount}${process.env.MIDTRANS_SERVER_KEY}`)
      .digest('hex');

    return {
      valid:          expected === signature_key,
      provider_tx_id: transaction_id ?? null,
      status:         this.mapTxStatus(transaction_status, fraud_status),
      amount:         parseFloat(gross_amount),
      raw_payload:    payload,
    };
  }

  async getTransactionStatus(providerTxId: string): Promise<TransactionStatus> {
    const res = await fetch(`${this.baseUrl}/${providerTxId}/status`, {
      headers: { Authorization: this.authHeader },
    });
    const data = await res.json();
    return this.mapTxStatus(data.transaction_status, data.fraud_status);
  }

  async refund(req: RefundRequest): Promise<RefundResponse> {
    const res = await fetch(`${this.baseUrl}/${req.provider_tx_id}/refund`, {
      method: 'POST',
      headers: { Authorization: this.authHeader, 'Content-Type': 'application/json' },
      body:   JSON.stringify({ refund_amount: req.amount, reason: req.reason }),
    });
    const data = await res.json();
    return { refund_id: data.refund_key ?? data.transaction_id, status: 'pending', raw_response: data };
  }

  private mapTxStatus(txStatus: string, fraudStatus?: string): TransactionStatus {
    if (fraudStatus === 'deny') return 'failed';
    switch (txStatus) {
      case 'capture': case 'settlement': return 'paid';
      case 'pending':                    return 'pending';
      case 'deny': case 'cancel': case 'failure': return 'failed';
      case 'expire':                     return 'expired';
      case 'refund':                     return 'refunded';
      default:                           return 'pending';
    }
  }

  private buildChargePayload(req: CreatePaymentRequest): Record<string, unknown> {
    const base = {
      transaction_details: { order_id: req.orderId, gross_amount: req.amount },
      customer_details:    { first_name: req.customerName, email: req.customerEmail },
      custom_field1:       req.metadata.tenant_id,
      custom_field2:       req.metadata.invoice_number,
    };
    switch (req.method) {
      case 'qris':
        return { ...base, payment_type: 'qris', qris: { acquirer: 'gopay' } };
      case 'va_bca':
        return { ...base, payment_type: 'bank_transfer', bank_transfer: { bank: 'bca' } };
      case 'va_bni':
        return { ...base, payment_type: 'bank_transfer', bank_transfer: { bank: 'bni' } };
      case 'va_mandiri':
        return { ...base, payment_type: 'echannel',
          echannel: { bill_info1: 'Payment', bill_info2: req.description } };
      case 'va_bri':
        return { ...base, payment_type: 'bank_transfer', bank_transfer: { bank: 'bri' } };
      case 'gopay':
        return { ...base, payment_type: 'gopay', gopay: { enable_callback: true } };
      case 'shopeepay':
        return { ...base, payment_type: 'shopeepay',
          shopeepay: { callback_url: req.redirectUrl
            ?? `${process.env.NEXT_PUBLIC_APP_URL}/subscription/complete` } };
      default:
        return { ...base, payment_type: 'bank_transfer', bank_transfer: { bank: 'bca' } };
    }
  }

  private mapResponse(data: any): CreatePaymentResponse {
    return {
      provider_tx_id: data.transaction_id,
      payment_url:    data.redirect_url ?? undefined,
      va_number:      data.va_numbers?.[0]?.va_number ?? data.account_number ?? undefined,
      va_bank:        data.va_numbers?.[0]?.bank ?? undefined,
      qris_url:       data.qr_string ?? undefined,
      deeplink_url:   data.actions?.find((a: any) => a.name === 'deeplink-redirect')?.url ?? undefined,
      expires_at:     data.expiry_time ?? new Date(Date.now() + 24 * 3600 * 1000).toISOString(),
      raw_response:   data,
    };
  }
}
```

### 4.4 Xendit Adapter

```typescript
// lib/billing/gateway/xendit.ts

export class XenditAdapter implements GatewayAdapter {
  readonly provider          = 'xendit' as const;
  readonly supportedMethods: PaymentMethod[] = ['va_permata','ovo','dana','linkaja'];

  private get authHeader(): string {
    return 'Basic ' + Buffer.from(process.env.XENDIT_SECRET_KEY! + ':').toString('base64');
  }

  async createPayment(req: CreatePaymentRequest): Promise<CreatePaymentResponse> {
    const isEwallet = ['ovo','dana','linkaja'].includes(req.method);
    const endpoint  = isEwallet ? '/ewallets/charges' : '/callback_virtual_accounts';
    const payload   = isEwallet ? this.buildEwalletPayload(req) : this.buildVAPayload(req);

    const res = await fetch(`https://api.xendit.co${endpoint}`, {
      method: 'POST',
      headers: { Authorization: this.authHeader, 'Content-Type': 'application/json' },
      body:   JSON.stringify(payload),
    });
    if (!res.ok) {
      const err = await res.json();
      throw new Error(`Xendit charge failed: ${JSON.stringify(err)}`);
    }
    const data = await res.json();
    return {
      provider_tx_id: data.id,
      payment_url:    data.actions?.desktop_web_checkout_url ?? undefined,
      va_number:      data.account_number ?? undefined,
      deeplink_url:   data.actions?.mobile_deeplink_checkout_url ?? undefined,
      expires_at:     data.expiration_date ?? data.expires
                        ?? new Date(Date.now() + 24 * 3600 * 1000).toISOString(),
      raw_response:   data,
    };
  }

  async validateWebhook(headers: Record<string, string>, body: string): Promise<WebhookValidationResult> {
    const callbackToken = headers['x-callback-token'];
    const valid   = callbackToken === process.env.XENDIT_WEBHOOK_TOKEN;
    const payload = JSON.parse(body);
    return {
      valid,
      provider_tx_id: payload.id ?? null,
      status:         this.mapStatus(payload.status),
      amount:         payload.paid_amount ?? payload.amount ?? null,
      raw_payload:    payload,
    };
  }

  async getTransactionStatus(providerTxId: string): Promise<TransactionStatus> {
    const res = await fetch(`https://api.xendit.co/payment_requests/${providerTxId}`, {
      headers: { Authorization: this.authHeader },
    });
    const data = await res.json();
    return this.mapStatus(data.status);
  }

  async refund(req: RefundRequest): Promise<RefundResponse> {
    const res = await fetch('https://api.xendit.co/refunds', {
      method: 'POST',
      headers: { Authorization: this.authHeader, 'Content-Type': 'application/json' },
      body:   JSON.stringify({
        payment_request_id: req.provider_tx_id,
        amount:             req.amount,
        reason:             req.reason,
      }),
    });
    const data = await res.json();
    return { refund_id: data.id, status: 'pending', raw_response: data };
  }

  private mapStatus(status: string): TransactionStatus {
    switch (status?.toUpperCase()) {
      case 'PAID': case 'SETTLED': case 'SUCCEEDED': return 'paid';
      case 'PENDING':   return 'pending';
      case 'FAILED':    return 'failed';
      case 'EXPIRED':   return 'expired';
      case 'REFUNDED':  return 'refunded';
      default:          return 'pending';
    }
  }

  private buildEwalletPayload(req: CreatePaymentRequest): Record<string, unknown> {
    const channelMap: Partial<Record<PaymentMethod, string>> = {
      ovo: 'OVO', dana: 'DANA', linkaja: 'LINKAJA',
    };
    return {
      reference_id:    req.orderId,
      currency:        req.currency,
      amount:          req.amount,
      checkout_method: 'ONE_TIME_PAYMENT',
      channel_code:    channelMap[req.method],
      channel_properties: {
        success_redirect_url: req.redirectUrl
          ?? `${process.env.NEXT_PUBLIC_APP_URL}/subscription/complete`,
      },
      metadata: req.metadata,
    };
  }

  private buildVAPayload(req: CreatePaymentRequest): Record<string, unknown> {
    return {
      external_id:     req.orderId,
      bank_code:       'PERMATA',
      name:            req.customerName,
      expected_amount: req.amount,
      expiration_date: new Date(Date.now() + 24 * 3600 * 1000).toISOString(),
    };
  }
}
```

### 4.5 Manual Adapter

```typescript
// lib/billing/gateway/manual.ts

export class ManualAdapter implements GatewayAdapter {
  readonly provider          = 'manual' as const;
  readonly supportedMethods: PaymentMethod[] = ['manual','bank_transfer'];

  async createPayment(req: CreatePaymentRequest): Promise<CreatePaymentResponse> {
    return {
      provider_tx_id: `MANUAL-${req.orderId}`,
      va_number:      process.env.PLATFORM_BANK_ACCOUNT_NUMBER,
      va_bank:        process.env.PLATFORM_BANK_NAME,
      // Manual payments: 3-day window for bank transfer
      expires_at:     new Date(Date.now() + 3 * 86400 * 1000).toISOString(),
      raw_response:   { method: 'manual', order_id: req.orderId },
    };
  }

  async validateWebhook(): Promise<WebhookValidationResult> {
    // Manual payments have no webhooks; admin marks paid via dashboard
    return { valid: false, provider_tx_id: null, status: null, amount: null, raw_payload: {} };
  }

  async getTransactionStatus(): Promise<TransactionStatus> {
    return 'pending'; // Stays pending until admin confirms
  }

  async refund(): Promise<RefundResponse> {
    return { refund_id: '', status: 'pending', raw_response: { note: 'Manual refund required' } };
  }
}
```

---

## 5. Supported Payment Methods

### 5.1 Payment Method Registry

```typescript
// config/payment-methods.ts

export interface PaymentMethodDefinition {
  key:         PaymentMethod;
  label:       string;
  provider:    PaymentProvider;
  category:    'qris' | 'virtual_account' | 'ewallet' | 'bank_transfer';
  logo_url:    string;
  is_active:   boolean;
  sort_order:  number;
}

export const PAYMENT_METHODS: PaymentMethodDefinition[] = [
  { key: 'qris',       label: 'QRIS',                    provider: 'midtrans', category: 'qris',           logo_url: '/icons/qris.svg',      is_active: true,  sort_order: 0  },
  { key: 'va_bca',     label: 'BCA Virtual Account',     provider: 'midtrans', category: 'virtual_account', logo_url: '/icons/bca.svg',       is_active: true,  sort_order: 1  },
  { key: 'va_mandiri', label: 'Mandiri Virtual Account', provider: 'midtrans', category: 'virtual_account', logo_url: '/icons/mandiri.svg',   is_active: true,  sort_order: 2  },
  { key: 'va_bni',     label: 'BNI Virtual Account',     provider: 'midtrans', category: 'virtual_account', logo_url: '/icons/bni.svg',       is_active: true,  sort_order: 3  },
  { key: 'va_bri',     label: 'BRI Virtual Account',     provider: 'midtrans', category: 'virtual_account', logo_url: '/icons/bri.svg',       is_active: true,  sort_order: 4  },
  { key: 'va_permata', label: 'Permata Virtual Account', provider: 'xendit',   category: 'virtual_account', logo_url: '/icons/permata.svg',   is_active: true,  sort_order: 5  },
  { key: 'gopay',      label: 'GoPay',                   provider: 'midtrans', category: 'ewallet',         logo_url: '/icons/gopay.svg',     is_active: true,  sort_order: 6  },
  { key: 'shopeepay',  label: 'ShopeePay',               provider: 'midtrans', category: 'ewallet',         logo_url: '/icons/shopeepay.svg', is_active: true,  sort_order: 7  },
  { key: 'ovo',        label: 'OVO',                     provider: 'xendit',   category: 'ewallet',         logo_url: '/icons/ovo.svg',       is_active: true,  sort_order: 8  },
  { key: 'dana',       label: 'DANA',                    provider: 'xendit',   category: 'ewallet',         logo_url: '/icons/dana.svg',      is_active: true,  sort_order: 9  },
  { key: 'linkaja',    label: 'LinkAja',                 provider: 'xendit',   category: 'ewallet',         logo_url: '/icons/linkaja.svg',   is_active: false, sort_order: 10 },
  { key: 'manual',     label: 'Transfer Bank (Manual)',  provider: 'manual',   category: 'bank_transfer',   logo_url: '/icons/bank.svg',      is_active: true,  sort_order: 11 },
];

export const CATEGORY_LABELS: Record<string, string> = {
  qris:            'QRIS',
  virtual_account: 'Transfer Virtual Account',
  ewallet:         'Dompet Digital',
  bank_transfer:   'Transfer Bank',
};

export function getActivePaymentMethods(): PaymentMethodDefinition[] {
  return PAYMENT_METHODS.filter(m => m.is_active).sort((a, b) => a.sort_order - b.sort_order);
}

export function groupMethodsByCategory(): Record<string, PaymentMethodDefinition[]> {
  return getActivePaymentMethods().reduce((acc, m) => {
    if (!acc[m.category]) acc[m.category] = [];
    acc[m.category].push(m);
    return acc;
  }, {} as Record<string, PaymentMethodDefinition[]>);
}
```

### 5.2 Payment Method Selector Component

```typescript
// components/billing/PaymentMethodSelector.tsx
'use client';

interface PaymentMethodSelectorProps {
  selected?: PaymentMethod | null;
  onSelect:  (method: PaymentMethod) => void;
}

export function PaymentMethodSelector({ selected, onSelect }: PaymentMethodSelectorProps) {
  const grouped = groupMethodsByCategory();

  return (
    <div className="space-y-5">
      {Object.entries(grouped).map(([category, methods]) => (
        <div key={category}>
          <p className="mb-2 text-xs font-semibold uppercase tracking-wider text-gray-400">
            {CATEGORY_LABELS[category] ?? category}
          </p>
          <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
            {methods.map(method => (
              <button
                key={method.key}
                type="button"
                onClick={() => onSelect(method.key)}
                className={`flex items-center gap-3 rounded-xl border-2 p-3 text-left transition
                  ${selected === method.key
                    ? 'border-purple-500 bg-purple-50'
                    : 'border-gray-200 hover:border-gray-300'}`}
              >
                <img src={method.logo_url} alt={method.label} className="h-6 w-6 object-contain" />
                <span className="text-sm font-medium text-gray-700">{method.label}</span>
              </button>
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}
```

---

## 6. Invoice System

### 6.1 Invoice Generation

```typescript
// lib/billing/invoices.ts

export async function generateInvoice(
  order:  Order,
  pkg:    Package | null,
  user:   AuthUser,
  addOn?: AddOn
): Promise<{ invoiceNumber: string; invoiceId: string }> {
  const supabase  = createServerClient();
  const yearMonth = new Date().toISOString().slice(0, 7).replace('-', '');

  const { data: invoiceNumber } = await supabase
    .rpc('next_invoice_number', { p_year_month: yearMonth });

  const lineItems: InvoiceLineItem[] = [];

  if (pkg) {
    lineItems.push({
      description: `${pkg.name} Plan — ${formatBillingCycle(order.billing_cycle)}`,
      quantity: 1, unit_price: order.amount_gross, amount: order.amount_gross,
    });
    if (order.amount_proration > 0) {
      lineItems.push({
        description: 'Proration credit (remaining days on current plan)',
        quantity: 1, unit_price: -order.amount_proration, amount: -order.amount_proration,
      });
    }
    if (order.amount_discount > 0) {
      lineItems.push({
        description: 'Voucher discount',
        quantity: 1, unit_price: -order.amount_discount, amount: -order.amount_discount,
      });
    }
  } else if (addOn) {
    lineItems.push({
      description: `${addOn.name} Add-On`,
      quantity: 1, unit_price: order.amount_gross, amount: order.amount_gross,
    });
  }

  const { data: tenant } = await supabase
    .from('tenants').select('name, metadata').eq('id', order.tenant_id).single();

  const billedTo: BilledTo = {
    name:    tenant?.name ?? user.fullName,
    email:   user.email,
    address: (tenant?.metadata as any)?.billing_address ?? null,
    tax_id:  (tenant?.metadata as any)?.tax_id ?? null,
  };

  let voucherCode: string | null = null;
  let voucherDesc: string | null = null;
  if (order.voucher_id) {
    const { data: v } = await supabase
      .from('vouchers').select('code, description').eq('id', order.voucher_id).single();
    voucherCode = v?.code ?? null;
    voucherDesc = v?.description ?? null;
  }

  const dueAt = order.expires_at ?? new Date(Date.now() + 24 * 3600 * 1000).toISOString();

  const { data: invoice, error } = await supabase
    .from('invoices')
    .insert({
      order_id:         order.id,
      tenant_id:        order.tenant_id,
      invoice_number:   invoiceNumber,
      currency:         order.currency,
      subtotal:         order.amount_gross,
      discount_amount:  order.amount_discount,
      proration_credit: order.amount_proration,
      total_amount:     order.amount_net,
      voucher_code:     voucherCode,
      voucher_desc:     voucherDesc,
      line_items:       lineItems,
      billed_to:        billedTo,
      status:           'unpaid',
      issued_at:        new Date().toISOString(),
      due_at:           dueAt,
    })
    .select('id, invoice_number')
    .single();

  if (error || !invoice) throw new Error(`Invoice generation failed: ${error?.message}`);
  return { invoiceNumber: invoice.invoice_number, invoiceId: invoice.id };
}

function formatBillingCycle(cycle: string): string {
  const map: Record<string, string> = {
    monthly:  'Bulanan (Monthly)',
    yearly:   'Tahunan (Yearly)',
    lifetime: 'Seumur Hidup (Lifetime)',
    one_time: 'Satu Kali (One Time)',
  };
  return map[cycle] ?? cycle;
}
```

### 6.2 Invoice PDF API

```typescript
// app/api/invoices/[id]/pdf/route.ts

export async function GET(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'subscription:read');
  if (auth instanceof NextResponse) return auth;

  const supabase = createServerClient();

  const { data: invoice } = await supabase
    .from('invoices')
    .select('id, invoice_number, pdf_url')
    .eq('id', params.id)
    .eq('tenant_id', auth.user.tenantId)
    .single();

  if (!invoice) return NextResponse.json({ error: 'Not found' }, { status: 404 });

  if (invoice.pdf_url) {
    // Return cached signed URL
    const { data: signed } = await supabase
      .storage.from('invoices')
      .createSignedUrl(invoice.pdf_url, 3600);
    return NextResponse.json({ pdf_url: signed?.signedUrl ?? null });
  }

  // Trigger async PDF generation
  await supabase.functions.invoke('generate-invoice-pdf', {
    body: { invoice_id: invoice.id },
  });

  return NextResponse.json({
    pdf_url: null,
    message: 'PDF is being generated. Retry in a few seconds.',
  });
}
```

### 6.3 Invoice Expiry Cron

```typescript
// supabase/functions/expire-invoices/index.ts

Deno.serve(async () => {
  const admin = createAdminClient();
  const now   = new Date().toISOString();

  const { count: voided } = await admin
    .from('invoices')
    .update({ status: 'void', voided_at: now })
    .eq('status', 'unpaid')
    .lt('due_at', now);

  const { count: expired } = await admin
    .from('orders')
    .update({ status: 'expired' })
    .eq('status', 'pending')
    .lt('expires_at', now);

  return new Response(JSON.stringify({ voided, expired }));
});
```

---

## 7. Transaction Management

### 7.1 Transaction State Machine

```
INITIATED ──► PENDING ──────────────► PAID ──► REFUNDED
                 │
                 ├──► FAILED
                 └──► EXPIRED
```

### 7.2 Transaction Creation Helper

```typescript
// lib/billing/transactions.ts

export async function createTransaction(
  supabase:  SupabaseClient,
  orderId:   string,
  tenantId:  string,
  provider:  PaymentProvider,
  init:      CreatePaymentResponse
): Promise<string> {
  const { data, error } = await supabase
    .from('payment_transactions')
    .insert({
      order_id:         orderId,
      tenant_id:        tenantId,
      provider,
      provider_tx_id:   init.provider_tx_id,
      amount:           0,             // set from order amount; patched on webhook
      currency:         'IDR',
      va_number:        init.va_number     ?? null,
      va_bank:          init.va_bank       ?? null,
      qris_url:         init.qris_url      ?? null,
      qris_string:      init.qris_string   ?? null,
      deeplink_url:     init.deeplink_url  ?? null,
      payment_url:      init.payment_url   ?? null,
      status:           'initiated',
      gateway_request:  {},
      gateway_response: init.raw_response,
      expires_at:       init.expires_at,
    })
    .select('id')
    .single();

  if (error || !data) throw new Error(`createTransaction failed: ${error?.message}`);
  return data.id;
}
```

### 7.3 Transaction Status Cascade

```typescript
// lib/billing/transaction-updater.ts

export async function applyTransactionStatus(
  admin:          SupabaseClient,
  providerTxId:   string,
  provider:       PaymentProvider,
  newStatus:      TransactionStatus,
  webhookPayload: Record<string, unknown>
): Promise<{ orderId: string; tenantId: string } | null> {

  const { data: tx } = await admin
    .from('payment_transactions')
    .select('id, order_id, tenant_id, status, amount')
    .eq('provider', provider)
    .eq('provider_tx_id', providerTxId)
    .single();

  if (!tx)                     return null;
  if (tx.status === newStatus) return null;   // idempotent
  if (tx.status === 'refunded') return null;  // terminal

  const now = new Date().toISOString();

  await admin.from('payment_transactions').update({
    status:          newStatus,
    webhook_payload: webhookPayload,
    ...(newStatus === 'paid'   ? { paid_at: now }   : {}),
    ...(newStatus === 'failed' ? { failed_at: now } : {}),
  }).eq('id', tx.id);

  // Cascade to order
  const orderStatus = txToOrderStatus(newStatus);
  if (orderStatus) {
    await admin.from('orders').update({
      status:  orderStatus,
      ...(newStatus === 'paid' ? { paid_at: now } : {}),
    }).eq('id', tx.order_id);
  }

  // Cascade to invoice
  const invoiceStatus = orderToInvoiceStatus(orderStatus);
  if (invoiceStatus) {
    await admin.from('invoices').update({
      status:  invoiceStatus,
      ...(newStatus === 'paid' ? { paid_at: now } : {}),
    }).eq('order_id', tx.order_id);
  }

  return { orderId: tx.order_id, tenantId: tx.tenant_id };
}

function txToOrderStatus(s: TransactionStatus): OrderStatus | null {
  switch (s) {
    case 'paid':     return 'paid';
    case 'failed':   return 'failed';
    case 'expired':  return 'expired';
    case 'refunded': return 'refunded';
    default:         return null;
  }
}

function orderToInvoiceStatus(s: OrderStatus | null): InvoiceStatus | null {
  switch (s) {
    case 'paid':                       return 'paid';
    case 'refunded':                   return 'refunded';
    case 'expired': case 'cancelled':  return 'void';
    default:                           return null;
  }
}
```

---

## 8. Webhook Architecture

### 8.1 Webhook Endpoint

```typescript
// app/api/webhooks/[provider]/route.ts

import crypto from 'crypto';

export async function POST(
  request: Request,
  { params }: { params: { provider: string } }
) {
  const provider = params.provider as PaymentProvider;
  const body     = await request.text();
  const hdrs     = Object.fromEntries(request.headers.entries());

  const adapter = getAdapterByProvider(provider);
  if (!adapter) return new Response('Unknown provider', { status: 400 });

  // 1. Validate signature FIRST — before any DB writes
  const validation = await adapter.validateWebhook(hdrs, body);

  // 2. Idempotency key prevents double-processing
  const idempotencyKey = crypto
    .createHash('sha256')
    .update(`${provider}:${validation.provider_tx_id}:${validation.status}`)
    .digest('hex');

  const admin = createAdminClient();

  // 3. Check for duplicate delivery
  const { data: existing } = await admin
    .from('webhook_logs')
    .select('id, processed')
    .eq('idempotency_key', idempotencyKey)
    .maybeSingle();

  if (existing?.processed) {
    return new Response('OK', { status: 200 }); // Already handled
  }

  // 4. Log ALL webhooks (even invalid signatures) — immutable audit trail
  const { data: logRow } = await admin
    .from('webhook_logs')
    .insert({
      provider,
      event_type:       hdrs['x-event-type'] ?? null,
      provider_tx_id:   validation.provider_tx_id,
      idempotency_key:  idempotencyKey,
      raw_payload:      JSON.parse(body),
      signature_valid:  validation.valid,
      processed:        false,
    })
    .select('id')
    .single();

  if (!validation.valid) {
    return new Response('Invalid signature', { status: 401 });
  }

  // 5. Amount validation — prevent underpayment from triggering activation
  if (validation.amount !== null && validation.provider_tx_id) {
    const { data: storedTx } = await admin
      .from('payment_transactions')
      .select('amount')
      .eq('provider', provider)
      .eq('provider_tx_id', validation.provider_tx_id)
      .maybeSingle();

    if (storedTx && Math.abs(validation.amount - storedTx.amount) > 100) {
      await admin.from('audit_logs').insert({
        action: 'payment.amount_mismatch', resource_type: 'payment_transaction',
        resource_id: validation.provider_tx_id,
        new_data: { expected: storedTx.amount, received: validation.amount },
      });
      await admin.from('webhook_logs').update({ processed: true }).eq('id', logRow?.id);
      return new Response('OK', { status: 200 });
    }
  }

  // 6. Process state transition
  try {
    if (validation.provider_tx_id && validation.status) {
      const result = await applyTransactionStatus(
        admin, validation.provider_tx_id, provider,
        validation.status, validation.raw_payload
      );
      if (result && validation.status === 'paid') {
        await activateSubscriptionFromOrder(admin, result.orderId, result.tenantId);
      }
    }
    await admin.from('webhook_logs').update({ processed: true }).eq('id', logRow?.id);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await admin.from('webhook_logs')
      .update({ processing_error: message }).eq('id', logRow?.id);
    // Return 200 to prevent provider retry — our reconciliation cron handles retries
  }

  return new Response('OK', { status: 200 });
}
```

### 8.2 Signature Validation Reference

| Provider | Method |
|---|---|
| Midtrans | `SHA512(order_id + status_code + gross_amount + ServerKey)` vs `signature_key` in payload |
| Xendit | `X-CALLBACK-TOKEN` header vs `XENDIT_WEBHOOK_TOKEN` env var |
| Manual | No webhooks; admin-only `mark-paid` guarded by `super_admin` role |

### 8.3 Reconciliation Cron

```typescript
// supabase/functions/reconcile-payments/index.ts
// Schedule: every 15 minutes

Deno.serve(async () => {
  const admin  = createAdminClient();
  const cutoff = new Date(Date.now() - 15 * 60 * 1000).toISOString();
  const now    = new Date().toISOString();

  // Pending transactions older than 15 min, not yet expired
  const { data: staleTxs } = await admin
    .from('payment_transactions')
    .select('id, provider, provider_tx_id, order_id, tenant_id')
    .in('status', ['initiated', 'pending'])
    .lt('initiated_at', cutoff)
    .gt('expires_at', now);

  let reconciled = 0;
  for (const tx of staleTxs ?? []) {
    try {
      const adapter    = getAdapterByProvider(tx.provider as PaymentProvider);
      const liveStatus = await adapter.getTransactionStatus(tx.provider_tx_id);

      if (liveStatus === 'pending' || liveStatus === 'initiated') continue;

      const ikey = crypto.createHash('sha256')
        .update(`${tx.provider}:${tx.provider_tx_id}:${liveStatus}:reconcile`)
        .digest('hex');

      const { data: dup } = await admin
        .from('webhook_logs').select('id').eq('idempotency_key', ikey).maybeSingle();
      if (dup) continue;

      const result = await applyTransactionStatus(
        admin, tx.provider_tx_id, tx.provider as PaymentProvider,
        liveStatus, { source: 'reconciliation' }
      );
      if (result && liveStatus === 'paid') {
        await activateSubscriptionFromOrder(admin, result.orderId, result.tenantId);
      }

      await admin.from('webhook_logs').insert({
        provider: tx.provider, provider_tx_id: tx.provider_tx_id,
        idempotency_key: ikey,
        raw_payload: { source: 'reconciliation', status: liveStatus },
        signature_valid: true, processed: true,
      });
      reconciled++;
    } catch (_) { /* best-effort */ }
  }

  return new Response(JSON.stringify({ stale: staleTxs?.length ?? 0, reconciled }));
});
```

---

## 9. Subscription Lifecycle Management

### 9.1 Activation After Payment

```typescript
// lib/billing/activation.ts

export async function activateSubscriptionFromOrder(
  admin:    SupabaseClient,
  orderId:  string,
  tenantId: string
): Promise<void> {
  const { data: order } = await admin
    .from('orders')
    .select('*, package:packages(*), add_on:add_ons(*)')
    .eq('id', orderId)
    .single();

  if (!order || order.status !== 'paid') return;

  if (order.package_id) {
    await activatePackage(admin, tenantId, order as any);
  } else if (order.add_on_id) {
    await activateAddOn(admin, tenantId, order as any);
  }

  if (order.reseller_id && (order.commission_amount ?? 0) > 0) {
    await recordCommission(admin, order as Order);
  }

  const { data: inv } = await admin
    .from('invoices').select('invoice_number').eq('order_id', orderId).single();

  await admin.from('email_notifications').insert({
    tenant_id:    tenantId,
    template_key: 'payment_receipt',
    status:       'pending',
    metadata:     {
      order_id:       orderId,
      invoice_number: inv?.invoice_number,
      amount:         order.amount_net,
      currency:       order.currency,
    },
  });

  await admin.from('audit_logs').insert({
    tenant_id:     tenantId,
    action:        'subscription.activated',
    resource_type: 'order',
    resource_id:   orderId,
    actor_role:    'system',
    new_data:      { package_id: order.package_id, billing_cycle: order.billing_cycle },
  });
}

async function activatePackage(
  admin:    SupabaseClient,
  tenantId: string,
  order:    Order & { package: Package }
): Promise<void> {
  const now       = new Date();
  const periodEnd = computePeriodEnd(now, order.billing_cycle);

  const { data: existingSub } = await admin
    .from('tenant_subscriptions')
    .select('id')
    .eq('tenant_id', tenantId)
    .in('status', ['active', 'trialing', 'past_due'])
    .maybeSingle();

  if (existingSub) {
    await admin.from('tenant_subscriptions').update({
      package_id:                   order.package_id,
      billing_cycle:                order.billing_cycle,
      status:                       'active',
      current_period_start:         now.toISOString(),
      current_period_end:           periodEnd.toISOString(),
      trial_ends_at:                null,
      grace_ends_at:                null,
      pending_downgrade_package_id: null,
      payment_provider:             order.payment_provider,
      payment_ref:                  order.payment_ref,
    }).eq('id', existingSub.id);

    await admin.from('orders')
      .update({ subscription_id: existingSub.id })
      .eq('id', order.id);
  } else {
    const { data: newSub } = await admin
      .from('tenant_subscriptions')
      .insert({
        tenant_id:            tenantId,
        package_id:           order.package_id,
        reseller_id:          order.reseller_id ?? null,
        billing_cycle:        order.billing_cycle,
        status:               'active',
        current_period_start: now.toISOString(),
        current_period_end:   periodEnd.toISOString(),
        auto_renew:           order.billing_cycle !== 'lifetime',
        payment_provider:     order.payment_provider,
        payment_ref:          order.payment_ref,
      })
      .select('id')
      .single();

    if (newSub) {
      await admin.from('orders')
        .update({ subscription_id: newSub.id })
        .eq('id', order.id);
    }
  }

  await invalidateFeatureCache(tenantId);
}

async function activateAddOn(
  admin:    SupabaseClient,
  tenantId: string,
  order:    Order & { add_on: AddOn }
): Promise<void> {
  const addOn = order.add_on;
  const now   = new Date();

  const expiresAt =
    addOn.billing_cycle === 'monthly' ? addMonths(now, 1).toISOString() :
    addOn.billing_cycle === 'yearly'  ? addYears(now, 1).toISOString()  : null;

  await admin.from('tenant_add_ons').insert({
    tenant_id:  tenantId,
    add_on_id:  addOn.id,
    quantity:   1,
    status:     'active',
    starts_at:  now.toISOString(),
    expires_at: expiresAt,
    order_id:   order.id,
  });

  await invalidateFeatureCache(tenantId);
}

function computePeriodEnd(from: Date, cycle: string): Date {
  const end = new Date(from);
  if (cycle === 'monthly')  end.setMonth(end.getMonth() + 1);
  if (cycle === 'yearly')   end.setFullYear(end.getFullYear() + 1);
  if (cycle === 'lifetime') end.setFullYear(end.getFullYear() + 100);
  return end;
}

async function invalidateFeatureCache(tenantId: string): Promise<void> {
  const redis = Redis.fromEnv();
  const keys  = await redis.keys(`features:${tenantId}:*`);
  if (keys.length > 0) await redis.del(...keys);
}
```

### 9.2 JWT Refresh After Activation

```typescript
// app/subscription/complete/page.tsx
'use client';

import { useEffect } from 'react';
import { createBrowserClient } from '@/lib/supabase/client';
import { useRouter } from 'next/navigation';

export default function SubscriptionCompletePage({
  searchParams,
}: {
  searchParams: { order_id?: string };
}) {
  const supabase = createBrowserClient();
  const router   = useRouter();

  useEffect(() => {
    // Refresh session so JWT picks up new package_id claim immediately
    supabase.auth.refreshSession().then(() => {
      router.replace(`/dashboard?payment=success&order=${searchParams.order_id ?? ''}`);
    });
  }, []);

  return (
    <div className="flex min-h-screen items-center justify-center">
      <div className="text-center">
        <div className="mx-auto mb-4 h-12 w-12 animate-spin rounded-full border-4 border-purple-200 border-t-purple-600" />
        <p className="text-sm text-gray-500">Mengaktifkan paket Anda...</p>
      </div>
    </div>
  );
}
```

---

## 10. Upgrade and Downgrade Flows

### 10.1 Upgrade With Proration

```typescript
// lib/billing/upgrade.ts

export interface UpgradeCalculation {
  prorationCredit: number;
  amountGross:     number;
  amountNet:       number;
}

export function calculateUpgradePricing(
  currentSub:   TenantSubscription,
  currentPkg:   Package,
  newPkg:       Package,
  billingCycle: 'monthly' | 'yearly' | 'lifetime'
): UpgradeCalculation {
  const now           = Date.now();
  const periodEnd     = new Date(currentSub.current_period_end).getTime();
  const periodStart   = new Date(currentSub.current_period_start).getTime();
  const totalMs       = periodEnd - periodStart;
  const remainingMs   = Math.max(0, periodEnd - now);
  const remainingDays = remainingMs / 86_400_000;

  // Daily rate from current plan's monthly price
  const dailyRate       = currentPkg.price_monthly / 30;
  const prorationCredit = Math.floor(remainingDays * dailyRate);

  const amountGross =
    billingCycle === 'yearly'   ? newPkg.price_yearly :
    billingCycle === 'lifetime' ? (newPkg.price_lifetime ?? newPkg.price_monthly * 24) :
                                   newPkg.price_monthly;

  return {
    prorationCredit,
    amountGross,
    amountNet: Math.max(0, amountGross - prorationCredit),
  };
}
```

### 10.2 Subscription Change API

```typescript
// app/api/subscription/change/route.ts

export async function POST(request: Request) {
  const auth = await requireAuth(request, 'subscription:write');
  if (auth instanceof NextResponse) return auth;

  const { package_id, billing_cycle, payment_method } = await request.json();
  const supabase = createServerClient();

  const [{ data: newPkg }, { data: currentSub }] = await Promise.all([
    supabase.from('packages').select('*').eq('id', package_id)
      .eq('status', 'active').eq('is_public', true).single(),
    supabase.from('tenant_subscriptions')
      .select('*, package:packages(*)')
      .eq('tenant_id', auth.user.tenantId)
      .in('status', ['active', 'trialing'])
      .maybeSingle(),
  ]);

  if (!newPkg) return NextResponse.json({ error: 'Package not found.' }, { status: 404 });

  const currentSortOrder = (currentSub?.package as any)?.sort_order ?? -1;
  const isUpgrade        = (newPkg.sort_order ?? 0) > currentSortOrder;

  if (isUpgrade && currentSub) {
    const calc = calculateUpgradePricing(
      currentSub as any, currentSub.package as Package, newPkg, billing_cycle
    );

    const order = await createOrder({
      tenantId: auth.user.tenantId, resellerId: null, createdBy: auth.user.id,
      packageId: newPkg.id, billingCycle: billing_cycle, currency: newPkg.currency,
      amountGross: calc.amountGross, amountDiscount: 0,
      amountProration: calc.prorationCredit, amountNet: calc.amountNet,
      expiresAt: new Date(Date.now() + 24 * 3600 * 1000).toISOString(),
    });

    const invoice     = await generateInvoice(order, newPkg, auth.user);
    const gateway     = getGatewayAdapter(payment_method);
    const paymentInit = await gateway.createPayment({
      orderId: order.id, amount: calc.amountNet, currency: newPkg.currency,
      method: payment_method, customerName: auth.user.fullName,
      customerEmail: auth.user.email,
      description: `Upgrade to ${newPkg.name} — ${billing_cycle}`,
      metadata: { invoice_number: invoice.invoiceNumber, tenant_id: auth.user.tenantId },
    });

    await createTransaction(supabase, order.id, auth.user.tenantId, gateway.provider, paymentInit);

    return NextResponse.json({
      type: 'upgrade',
      order_id:         order.id,
      invoice_number:   invoice.invoiceNumber,
      proration_credit: calc.prorationCredit,
      amount_net:       calc.amountNet,
      payment_url:      paymentInit.payment_url  ?? null,
      va_number:        paymentInit.va_number    ?? null,
      qris_url:         paymentInit.qris_url     ?? null,
      expires_at:       paymentInit.expires_at,
    });
  }

  // Downgrade — schedule for end of current period (no immediate charge)
  if (currentSub) {
    await supabase.from('tenant_subscriptions')
      .update({ pending_downgrade_package_id: newPkg.id })
      .eq('id', (currentSub as any).id);

    await writeAuditLog(request, 'subscription.downgrade_scheduled',
      'tenant_subscription', (currentSub as any).id, {
        tenantId: auth.user.tenantId, userId: auth.user.id,
        newData: { pending_downgrade_package_id: newPkg.id },
      });

    return NextResponse.json({
      type:           'downgrade_scheduled',
      effective_date: (currentSub as any).current_period_end,
      package:        newPkg.name,
    });
  }

  return NextResponse.json({ error: 'No active subscription found.' }, { status: 404 });
}
```

### 10.3 Downgrade Quota Enforcement

When a downgrade takes effect at period end, the cron applies quota limits gracefully — archiving excess invitations rather than deleting them:

```typescript
// lib/billing/downgrade-enforcer.ts

export async function enforceQuotaLimitsAfterDowngrade(
  admin:     SupabaseClient,
  tenantId:  string,
  newPkgId:  string
): Promise<void> {
  const { data: pkg } = await admin
    .from('packages').select('*').eq('id', newPkgId).single();
  if (!pkg) return;

  // Archive excess invitations (oldest first; preserve newest)
  if (pkg.max_invitations !== -1) {
    const { data: excess } = await admin
      .from('invitations')
      .select('id')
      .eq('tenant_id', tenantId)
      .in('status', ['draft', 'published'])
      .is('deleted_at', null)
      .order('created_at', { ascending: true })
      .range(pkg.max_invitations, 9999);

    if (excess?.length) {
      await admin.from('invitations')
        .update({ status: 'archived' })
        .in('id', excess.map(i => i.id));
    }
  }

  // Deactivate excess team members (keep owner; deactivate newest editors/viewers)
  if (pkg.max_team_members !== -1) {
    const { data: excess } = await admin
      .from('users')
      .select('id')
      .eq('tenant_id', tenantId)
      .neq('role', 'owner')
      .order('created_at', { ascending: false })
      .range(pkg.max_team_members - 1, 9999);

    if (excess?.length) {
      await admin.from('users')
        .update({ is_active: false })
        .in('id', excess.map(u => u.id));
    }
  }

  await admin.from('email_notifications').insert({
    tenant_id:    tenantId,
    template_key: 'subscription_downgraded',
    status:       'pending',
    metadata:     { package_name: pkg.name },
  });
}
```

---

## 11. Renewal and Expiration Handling

### 11.1 Grace Period Logic

```
Subscription current_period_end reached
  │
  ├─ auto_renew = TRUE
  │     Cron creates renewal order + invoice
  │     status → 'past_due'; grace_ends_at = period_end + 7 days
  │     │
  │     ├─ Payment received within grace → new period starts; status = 'active'
  │     └─ Grace period expires (no payment) → status = 'expired'
  │           package → Free; enforceQuotaLimitsAfterDowngrade()
  │
  └─ auto_renew = FALSE
        status → 'cancelled'; same 7-day grace applies
        tenant can manually pay to restore within grace window
```

### 11.2 Renewal Processing Cron

```typescript
// supabase/functions/process-renewals/index.ts
// Schedule: daily at 00:05 UTC+7 (17:05 UTC previous day)

Deno.serve(async () => {
  const admin = createAdminClient();
  const now   = new Date();

  // 1. Apply pending downgrades for subscriptions whose period just ended
  const { data: pendingDowngrades } = await admin
    .from('tenant_subscriptions')
    .select('id, tenant_id, pending_downgrade_package_id, billing_cycle')
    .not('pending_downgrade_package_id', 'is', null)
    .lte('current_period_end', now.toISOString())
    .eq('status', 'active');

  for (const sub of pendingDowngrades ?? []) {
    const newPeriodEnd = computePeriodEnd(now, sub.billing_cycle);
    await admin.from('tenant_subscriptions').update({
      package_id:                   sub.pending_downgrade_package_id,
      pending_downgrade_package_id: null,
      current_period_start:         now.toISOString(),
      current_period_end:           newPeriodEnd.toISOString(),
    }).eq('id', sub.id);

    await enforceQuotaLimitsAfterDowngrade(admin, sub.tenant_id, sub.pending_downgrade_package_id!);
    await invalidateFeatureCache(sub.tenant_id);
  }

  // 2. Expire grace-period-exhausted subscriptions → downgrade to Free
  const { data: expiredGrace } = await admin
    .from('tenant_subscriptions')
    .select('id, tenant_id')
    .lte('grace_ends_at', now.toISOString())
    .eq('status', 'past_due');

  for (const sub of expiredGrace ?? []) {
    const { data: freePkg } = await admin
      .from('packages').select('id').eq('slug', 'free').single();

    await admin.from('tenant_subscriptions').update({
      status: 'expired', package_id: freePkg!.id,
    }).eq('id', sub.id);

    await enforceQuotaLimitsAfterDowngrade(admin, sub.tenant_id, freePkg!.id);
    await invalidateFeatureCache(sub.tenant_id);

    await admin.from('email_notifications').insert({
      tenant_id: sub.tenant_id, template_key: 'subscription_expired', status: 'pending',
    });
  }

  // 3. Create auto-renewal orders for subscriptions expiring in < 7 days
  const sevenDaysOut = new Date(now.getTime() + 7 * 86_400_000).toISOString();
  const { data: autoRenewSubs } = await admin
    .from('tenant_subscriptions')
    .select('*, package:packages(*)')
    .eq('auto_renew', true)
    .eq('status', 'active')
    .neq('billing_cycle', 'lifetime')
    .lte('current_period_end', sevenDaysOut)
    .gt('current_period_end', now.toISOString());

  for (const sub of autoRenewSubs ?? []) {
    const pkg    = sub.package as Package;
    const amount = sub.billing_cycle === 'yearly' ? pkg.price_yearly : pkg.price_monthly;

    const order = await createOrder({
      tenantId: sub.tenant_id, resellerId: sub.reseller_id ?? null,
      createdBy: null, packageId: sub.package_id, billingCycle: sub.billing_cycle,
      currency: pkg.currency, amountGross: amount,
      amountDiscount: 0, amountProration: 0, amountNet: amount,
      expiresAt: new Date(new Date(sub.current_period_end).getTime() + 3 * 86_400_000).toISOString(),
    });

    const invoice = await generateInvoice(order, pkg, { tenantId: sub.tenant_id } as any);

    await admin.from('email_notifications').insert({
      tenant_id: sub.tenant_id, template_key: 'renewal_invoice', status: 'pending',
      metadata: { order_id: order.id, invoice_number: invoice.invoiceNumber, amount },
    });
  }

  // 4. Transition active subscriptions past period_end → past_due
  const { data: pastDueSubs } = await admin
    .from('tenant_subscriptions')
    .select('id, tenant_id, current_period_end')
    .eq('status', 'active')
    .lt('current_period_end', now.toISOString());

  for (const sub of pastDueSubs ?? []) {
    const graceEnd = new Date(new Date(sub.current_period_end).getTime() + 7 * 86_400_000);
    await admin.from('tenant_subscriptions').update({
      status:        'past_due',
      grace_ends_at: graceEnd.toISOString(),
    }).eq('id', sub.id);
  }

  return new Response(JSON.stringify({
    downgrades_applied: pendingDowngrades?.length ?? 0,
    expired:            expiredGrace?.length ?? 0,
    renewal_orders:     autoRenewSubs?.length ?? 0,
  }));
});
```

---

## 12. Refund Architecture

### 12.1 Refund Eligibility

```typescript
// lib/billing/refund-eligibility.ts

const REFUND_WINDOW_DAYS = 7;

export async function checkRefundEligibility(
  supabase: SupabaseClient,
  orderId:  string
): Promise<{ eligible: boolean; reason?: string }> {
  const { data: order } = await supabase
    .from('orders').select('status, paid_at').eq('id', orderId).single();

  if (!order)                    return { eligible: false, reason: 'Order not found.' };
  if (order.status !== 'paid')   return { eligible: false, reason: 'Order was not paid.' };
  if (!order.paid_at)            return { eligible: false, reason: 'Missing payment date.' };

  const daysSincePaid = (Date.now() - new Date(order.paid_at).getTime()) / 86_400_000;
  if (daysSincePaid > REFUND_WINDOW_DAYS) {
    return { eligible: false, reason: `Refund window of ${REFUND_WINDOW_DAYS} days has passed.` };
  }

  const { data: existingRefund } = await supabase
    .from('refund_requests')
    .select('id')
    .eq('order_id', orderId)
    .in('status', ['pending', 'approved', 'processed'])
    .maybeSingle();

  if (existingRefund) return { eligible: false, reason: 'A refund request already exists for this order.' };

  return { eligible: true };
}
```

### 12.2 Refund Request API

```typescript
// app/api/orders/[id]/refund-request/route.ts

const RefundRequestSchema = z.object({
  category: z.enum(['accidental_purchase', 'service_issue', 'duplicate_charge', 'other']),
  reason:   z.string().min(10).max(1000),
});

export async function POST(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request, 'subscription:write');
  if (auth instanceof NextResponse) return auth;

  const parsed = RefundRequestSchema.safeParse(await request.json());
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.flatten() }, { status: 422 });
  }

  const supabase = createServerClient();

  const { data: order } = await supabase
    .from('orders').select('id, tenant_id, amount_net')
    .eq('id', params.id).eq('tenant_id', auth.user.tenantId).single();

  if (!order) return NextResponse.json({ error: 'Order not found.' }, { status: 404 });

  const eligibility = await checkRefundEligibility(supabase, params.id);
  if (!eligibility.eligible) {
    return NextResponse.json({ error: eligibility.reason }, { status: 422 });
  }

  const { data: refund, error } = await supabase
    .from('refund_requests')
    .insert({
      order_id:        order.id,
      tenant_id:        auth.user.tenantId,
      requested_by:     auth.user.id,
      category:         parsed.data.category,
      reason:           parsed.data.reason,
      requested_amount: order.amount_net,
      status:           'pending',
    })
    .select('id')
    .single();

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  await writeAuditLog(request, 'refund.requested', 'refund_request', refund!.id, {
    tenantId: auth.user.tenantId, userId: auth.user.id,
    newData: { order_id: order.id, category: parsed.data.category },
  });

  return NextResponse.json(refund, { status: 201 });
}
```

### 12.3 Admin Refund Processing

```typescript
// app/api/admin/refund-requests/[id]/process/route.ts

const ProcessRefundSchema = z.object({
  decision:        z.enum(['approve', 'reject']),
  approved_amount: z.coerce.number().min(0).optional(),
  admin_note:      z.string().max(1000).optional(),
});

export async function POST(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request);
  if (auth instanceof NextResponse) return auth;
  if (auth.user.role !== 'super_admin') {
    return NextResponse.json({ error: 'Forbidden' }, { status: 403 });
  }

  const parsed = ProcessRefundSchema.safeParse(await request.json());
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.flatten() }, { status: 422 });
  }

  const admin = createAdminClient();

  const { data: refund } = await admin
    .from('refund_requests')
    .select('*, order:orders(*)')
    .eq('id', params.id)
    .eq('status', 'pending')
    .single();

  if (!refund) return NextResponse.json({ error: 'Refund request not found or already processed.' }, { status: 404 });

  if (parsed.data.decision === 'reject') {
    await admin.from('refund_requests').update({
      status:        'rejected',
      admin_note:    parsed.data.admin_note ?? null,
      processed_by:  auth.user.id,
      processed_at:  new Date().toISOString(),
    }).eq('id', params.id);

    await writeAuditLog(request, 'refund.rejected', 'refund_request', params.id, {
      userId: auth.user.id, newData: { admin_note: parsed.data.admin_note },
    });

    return NextResponse.json({ status: 'rejected' });
  }

  const order        = refund.order as Order;
  const refundAmount = parsed.data.approved_amount ?? refund.requested_amount;

  const { data: tx } = await admin
    .from('payment_transactions')
    .select('provider, provider_tx_id')
    .eq('order_id', order.id).eq('status', 'paid').single();

  if (!tx) return NextResponse.json({ error: 'No paid transaction found for this order.' }, { status: 422 });

  const gateway      = getAdapterByProvider(tx.provider as PaymentProvider);
  const refundResult = await gateway.refund(tx.provider_tx_id, refundAmount);

  await admin.from('refund_requests').update({
    status:            'processed',
    approved_amount:   refundAmount,
    provider_refund_id: refundResult.refund_id,
    admin_note:         parsed.data.admin_note ?? null,
    processed_by:       auth.user.id,
    processed_at:       new Date().toISOString(),
  }).eq('id', params.id);

  await admin.from('orders').update({ status: 'refunded' }).eq('id', order.id);
  await admin.from('payment_transactions')
    .update({ status: 'refunded' }).eq('order_id', order.id).eq('status', 'paid');
  await admin.from('invoices').update({ status: 'refunded' }).eq('order_id', order.id);

  // Full refund on a package order cancels the subscription
  if (order.package_id && refundAmount >= order.amount_net) {
    await admin.from('tenant_subscriptions')
      .update({ status: 'cancelled', cancelled_at: new Date().toISOString(), cancel_reason: 'refunded' })
      .eq('tenant_id', order.tenant_id)
      .in('status', ['active', 'trialing', 'past_due']);
    await invalidateFeatureCache(order.tenant_id);
  }

  await writeAuditLog(request, 'refund.processed', 'refund_request', params.id, {
    userId: auth.user.id, newData: { refund_amount: refundAmount, provider_refund_id: refundResult.refund_id },
  });

  return NextResponse.json({ status: 'processed', refund_id: refundResult.refund_id });
}
```

---

## 13. Reseller Commission System

### 13.1 Commission Ledger Schema

```sql
CREATE TABLE commission_ledger (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reseller_id       UUID        NOT NULL REFERENCES resellers(id),
  order_id          UUID        NOT NULL REFERENCES orders(id),
  tenant_id         UUID        NOT NULL REFERENCES tenants(id),
  commission_amount NUMERIC(12,2) NOT NULL,
  commission_pct    NUMERIC(5,2)  NOT NULL,
  -- Frozen at the time of order creation — never recalculated retroactively
  order_amount_net  NUMERIC(12,2) NOT NULL,
  status            TEXT        NOT NULL DEFAULT 'accrued'
                                CHECK (status IN ('accrued', 'paid_out', 'reversed')),
  payout_id         UUID        REFERENCES commission_payouts(id),
  reversed_reason   TEXT,
  -- populated when status = 'reversed' (e.g. underlying order refunded)
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_commission_ledger_reseller ON commission_ledger(reseller_id, status);
CREATE INDEX idx_commission_ledger_order    ON commission_ledger(order_id);
CREATE INDEX idx_commission_ledger_payout   ON commission_ledger(payout_id) WHERE payout_id IS NOT NULL;

CREATE TABLE commission_payouts (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reseller_id     UUID        NOT NULL REFERENCES resellers(id),
  period_start    DATE        NOT NULL,
  period_end      DATE        NOT NULL,
  total_amount    NUMERIC(12,2) NOT NULL,
  status          TEXT        NOT NULL DEFAULT 'pending'
                              CHECK (status IN ('pending', 'paid', 'failed')),
  payout_method   TEXT,
  -- 'bank_transfer' | 'manual'
  payout_ref      TEXT,
  paid_at         TIMESTAMPTZ,
  created_by      UUID        REFERENCES users(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_commission_payouts_reseller ON commission_payouts(reseller_id, status);
```

### 13.2 Commission Recording

```typescript
// lib/billing/commission.ts

export async function recordCommission(
  admin: SupabaseClient,
  order: Order
): Promise<void> {
  if (!order.reseller_id || !order.commission_amount) return;

  const { data: reseller } = await admin
    .from('resellers').select('commission_pct').eq('id', order.reseller_id).single();

  await admin.from('commission_ledger').insert({
    reseller_id:       order.reseller_id,
    order_id:          order.id,
    tenant_id:         order.tenant_id,
    commission_amount: order.commission_amount,
    commission_pct:    reseller?.commission_pct ?? 0,
    order_amount_net:  order.amount_net,
    status:            'accrued',
  });
}

export async function reverseCommissionForRefund(
  admin:   SupabaseClient,
  orderId: string,
  reason:  string
): Promise<void> {
  await admin.from('commission_ledger')
    .update({ status: 'reversed', reversed_reason: reason })
    .eq('order_id', orderId)
    .eq('status', 'accrued');
}
```

### 13.3 Reseller Commission Dashboard API

```typescript
// app/api/reseller/commission/route.ts

export async function GET(request: Request) {
  const auth = await requireAuth(request, 'reseller:billing:read');
  if (auth instanceof NextResponse) return auth;
  if (!auth.user.resellerId) return NextResponse.json({ error: 'Forbidden' }, { status: 403 });

  const supabase   = createServerClient();
  const url        = new URL(request.url);
  const periodFrom = url.searchParams.get('from') ?? new Date(Date.now() - 30 * 86_400_000).toISOString();
  const periodTo   = url.searchParams.get('to')   ?? new Date().toISOString();

  const [{ data: accrued }, { data: paidOut }, { data: entries }] = await Promise.all([
    supabase.from('commission_ledger')
      .select('commission_amount').eq('reseller_id', auth.user.resellerId).eq('status', 'accrued'),
    supabase.from('commission_ledger')
      .select('commission_amount').eq('reseller_id', auth.user.resellerId).eq('status', 'paid_out'),
    supabase.from('commission_ledger')
      .select('*, order:orders(tenant_id, package_id, amount_net, paid_at), tenant:tenants(name)')
      .eq('reseller_id', auth.user.resellerId)
      .gte('created_at', periodFrom).lte('created_at', periodTo)
      .order('created_at', { ascending: false }),
  ]);

  const pendingPayout = (accrued ?? []).reduce((sum, r) => sum + Number(r.commission_amount), 0);
  const totalPaidOut  = (paidOut  ?? []).reduce((sum, r) => sum + Number(r.commission_amount), 0);

  return NextResponse.json({
    pending_payout: pendingPayout,
    total_paid_out: totalPaidOut,
    entries,
  });
}
```

---

## 14. Admin Payment Management

### 14.1 Admin Orders Module Structure

```
/admin/orders
├── List view: filter by status / provider / package / reseller / date range
├── Order detail modal: amounts breakdown, payment_data JSON viewer, refund button
└── /admin/orders/[id]/mark-paid     (manual provider only)

/admin/refund-requests
├── Pending queue (default view)
└── /admin/refund-requests/[id]      (approve/reject)

/admin/webhooks
└── webhook_logs viewer: filter by provider / signature_valid / processed
```

### 14.2 Manual Payment Verification

```typescript
// app/api/admin/orders/[id]/mark-paid/route.ts

export async function POST(
  request: Request,
  { params }: { params: { id: string } }
) {
  const auth = await requireAuth(request);
  if (auth instanceof NextResponse) return auth;
  if (auth.user.role !== 'super_admin') {
    return NextResponse.json({ error: 'Forbidden' }, { status: 403 });
  }

  const { proof_reference } = await request.json();
  const admin = createAdminClient();

  const { data: order } = await admin
    .from('orders').select('*').eq('id', params.id).eq('status', 'pending').single();

  if (!order) return NextResponse.json({ error: 'Order not found or not pending.' }, { status: 404 });

  const { data: tx } = await admin
    .from('payment_transactions')
    .select('id, provider_tx_id')
    .eq('order_id', order.id).eq('provider', 'manual').single();

  if (!tx) return NextResponse.json({ error: 'No manual transaction record found.' }, { status: 422 });

  await applyTransactionStatus(
    admin, tx.provider_tx_id, 'manual', 'paid',
    { verified_by: auth.user.id, proof_reference }
  );
  await activateSubscriptionFromOrder(admin, order.id, order.tenant_id);

  await writeAuditLog(request, 'order.mark_paid', 'order', order.id, {
    userId: auth.user.id, tenantId: order.tenant_id,
    newData: { proof_reference, verified_by: auth.user.id },
  });

  return NextResponse.json({ status: 'paid' });
}
```

### 14.3 Platform Revenue Summary

```sql
CREATE OR REPLACE FUNCTION get_platform_billing_summary(
  p_from TIMESTAMPTZ, p_to TIMESTAMPTZ
)
RETURNS JSONB AS $$
DECLARE v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'gross_revenue',     COALESCE(SUM(amount_gross) FILTER (WHERE status = 'paid'), 0),
    'net_revenue',       COALESCE(SUM(amount_net)   FILTER (WHERE status = 'paid'), 0),
    'total_discounts',   COALESCE(SUM(amount_discount) FILTER (WHERE status = 'paid'), 0),
    'total_commission',  COALESCE(SUM(commission_amount) FILTER (WHERE status = 'paid'), 0),
    'paid_order_count',  COUNT(*) FILTER (WHERE status = 'paid'),
    'failed_order_count',COUNT(*) FILTER (WHERE status = 'failed'),
    'refunded_amount',   COALESCE(SUM(amount_net) FILTER (WHERE status = 'refunded'), 0)
  ) INTO v_result
  FROM orders
  WHERE created_at BETWEEN p_from AND p_to;

  RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;
```

### 14.4 Webhook Log Viewer Query

```typescript
// app/api/admin/webhooks/route.ts — GET list with filters

const { data } = await admin
  .from('webhook_logs')
  .select('id, provider, event_type, provider_tx_id, signature_valid, processed, processing_error, created_at')
  .order('created_at', { ascending: false })
  .range(offset, offset + pageSize - 1);
// Filters applied via .eq() for provider / signature_valid / processed when present in query params
```

---

## 15. Permission Rules

### 15.1 Billing Permission Matrix

| Action | super_admin | reseller_admin | owner | editor | viewer |
|---|:---:|:---:|:---:|:---:|:---:|
| View own subscription / invoices | ✅ | ✅ | ✅ | ❌ | ❌ |
| Purchase / upgrade / downgrade plan | ✅ | ✅ | ✅ | ❌ | ❌ |
| Purchase add-on | ✅ | ✅ (for clients) | ✅ | ❌ | ❌ |
| Apply voucher | ✅ | ✅ | ✅ | ❌ | ❌ |
| Request refund | ✅ | ✅ | ✅ | ❌ | ❌ |
| View client subscriptions / billing | ✅ | ✅ (own clients) | ❌ | ❌ | ❌ |
| View own commission ledger | ✅ | ✅ | ❌ | ❌ | ❌ |
| Manage reseller voucher codes | ✅ | ✅ | ❌ | ❌ | ❌ |
| View all platform orders/revenue | ✅ | ❌ | ❌ | ❌ | ❌ |
| Mark manual order as paid | ✅ | ❌ | ❌ | ❌ | ❌ |
| Approve / reject refund requests | ✅ | ❌ | ❌ | ❌ | ❌ |
| View webhook logs | ✅ | ❌ | ❌ | ❌ | ❌ |
| Process commission payouts | ✅ | ❌ | ❌ | ❌ | ❌ |
| Manage payment gateway settings | ✅ | ❌ | ❌ | ❌ | ❌ |

### 15.2 API Route Permission Map

| Route | Method | Permission |
|---|---|---|
| `/api/subscription/purchase` | POST | `subscription:write` |
| `/api/subscription/change` | POST | `subscription:write` |
| `/api/add-ons/purchase` | POST | `subscription:write` |
| `/api/orders/[id]/refund-request` | POST | `subscription:write` (own tenant) |
| `/api/invoices/[id]/pdf` | GET | `subscription:read` |
| `/api/reseller/commission` | GET | `reseller:billing:read` |
| `/api/webhooks/[provider]` | POST | Public, signature-verified |
| `/api/admin/orders/*` | ALL | `super_admin` |
| `/api/admin/refund-requests/*` | ALL | `super_admin` |
| `/api/admin/webhooks` | GET | `super_admin` |

### 15.3 RLS Policies

```sql
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY "orders_read_tenant" ON orders FOR SELECT USING (tenant_id = auth_tenant_id());
CREATE POLICY "orders_read_reseller" ON orders FOR SELECT USING (
  tenant_id IN (SELECT tenant_id FROM reseller_tenants WHERE reseller_id = auth_reseller_id())
);

ALTER TABLE payment_transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "tx_read_tenant" ON payment_transactions FOR SELECT USING (tenant_id = auth_tenant_id());

ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;
CREATE POLICY "invoices_read_tenant" ON invoices FOR SELECT USING (tenant_id = auth_tenant_id());

ALTER TABLE refund_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY "refunds_read_tenant" ON refund_requests FOR SELECT USING (tenant_id = auth_tenant_id());
CREATE POLICY "refunds_insert_tenant" ON refund_requests FOR INSERT WITH CHECK (
  tenant_id = auth_tenant_id() AND auth_role() IN ('owner')
);

ALTER TABLE commission_ledger ENABLE ROW LEVEL SECURITY;
CREATE POLICY "commission_read_own_reseller" ON commission_ledger
  FOR SELECT USING (reseller_id = auth_reseller_id());

ALTER TABLE commission_payouts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "payouts_read_own_reseller" ON commission_payouts
  FOR SELECT USING (reseller_id = auth_reseller_id());

-- webhook_logs: service-role only, no public/tenant RLS policy defined (default deny)
ALTER TABLE webhook_logs ENABLE ROW LEVEL SECURITY;
```

---

## 16. Multi-Tenant Security

### 16.1 Defense-in-Depth Pattern

Every billing query enforces tenant isolation at two layers: RLS policy (`tenant_id = auth_tenant_id()`) plus an explicit `.eq('tenant_id', ...)` filter in application code. Neither layer is trusted alone — a missing application-layer filter is still caught by RLS; a misconfigured policy is still bounded by the explicit filter.

### 16.2 Webhook Security Summary

- Signature validated before any DB write.
- All webhooks logged (including invalid signatures) to `webhook_logs` for forensic review.
- Idempotency key prevents double-activation from provider retry storms.
- Always returns HTTP 200 once logged, to stop provider retry loops — actual processing failures are caught by the reconciliation cron, not provider redelivery.

### 16.3 Amount Validation

The webhook handler rejects any state transition where the provider-reported amount differs from the stored transaction amount by more than Rp 100 (floating-point/rounding tolerance). Mismatches are logged to `audit_logs` and the order is **not** activated, requiring manual admin review.

### 16.4 Manual Payment Security

The `manual` provider has no public webhook endpoint. Activation only occurs via `/api/admin/orders/[id]/mark-paid`, which is `super_admin`-gated and requires a `proof_reference` string, written to `audit_logs` for accountability.

### 16.5 Service Role Containment

`createAdminClient()` (service role key) is only instantiated inside: webhook handlers, Edge Functions (cron jobs), and `/api/admin/*` routes after an explicit `role === 'super_admin'` check. It is never exposed to client bundles and never used in tenant-facing API routes.

---

## 17. Performance Optimization

### 17.1 Indexing Strategy

```sql
-- orders
CREATE INDEX idx_orders_tenant_status   ON orders(tenant_id, status);
CREATE INDEX idx_orders_reseller_status ON orders(reseller_id, status) WHERE reseller_id IS NOT NULL;
CREATE INDEX idx_orders_expires_at      ON orders(expires_at) WHERE status = 'pending';
CREATE INDEX idx_orders_paid_at         ON orders(paid_at DESC) WHERE status = 'paid';

-- payment_transactions
CREATE UNIQUE INDEX idx_tx_provider_txid ON payment_transactions(provider, provider_tx_id);
CREATE INDEX idx_tx_order                ON payment_transactions(order_id);
CREATE INDEX idx_tx_stale_pending         ON payment_transactions(status, initiated_at)
  WHERE status IN ('initiated', 'pending');

-- invoices
CREATE UNIQUE INDEX idx_invoices_number  ON invoices(invoice_number);
CREATE INDEX idx_invoices_tenant         ON invoices(tenant_id, issued_at DESC);
CREATE INDEX idx_invoices_unpaid_due     ON invoices(due_at) WHERE status = 'unpaid';

-- webhook_logs
CREATE UNIQUE INDEX idx_webhook_idempotency ON webhook_logs(idempotency_key);
CREATE INDEX idx_webhook_unprocessed        ON webhook_logs(processed, created_at) WHERE processed = FALSE;

-- commission_ledger
CREATE INDEX idx_commission_reseller_status ON commission_ledger(reseller_id, status);
```

### 17.2 Caching Strategy

| Data | Cache | TTL | Invalidation |
|---|---|---|---|
| Public pricing page packages | Redis | 5 min | On package edit (admin) |
| Invoice PDF signed URL | Storage signed URL | 1 hr | Regenerated on expiry |
| Resolved feature flags | Redis | 60 s | On subscription change, add-on purchase |
| Platform revenue summary | Redis | 5 min | Time-based only (admin dashboard) |

### 17.3 Query Optimization

Subscription + package + commission data load in `Promise.all()` parallel fetches wherever the route needs more than one independent lookup (see `/api/reseller/commission` and `/api/subscription/change` above) — never sequential awaits for independent queries.

### 17.4 Webhook Processing Latency Target

| Stage | Target |
|---|---|
| Signature validation | < 10ms |
| Webhook log insert | < 30ms |
| State cascade (tx→order→invoice) | < 100ms |
| Total webhook response time | < 300ms |

---

## 18. Scalability Considerations

### 18.1 Volume Projections

```
Year 1: ~2,000 paid orders/month, ~500 webhook deliveries/day
Year 3: ~25,000 paid orders/month, ~8,000 webhook deliveries/day
```

### 18.2 High-Volume Webhook Handling

At Year 3 volume, webhook endpoints remain stateless Vercel serverless functions — horizontally scalable by default. The bottleneck is Postgres write throughput on `webhook_logs` and `payment_transactions`; both are narrow, indexed tables designed for high insert rates with minimal lock contention (no wide JSONB scans on the hot path).

### 18.3 Invoice Sequence Concurrency

`next_invoice_number()` uses an atomic `UPDATE ... RETURNING` on `invoice_sequences` keyed by year-month, avoiding race conditions under concurrent order creation without requiring a table-level lock.

### 18.4 Multi-Currency Preparation

`currency` is already a column on `orders`, `payment_transactions`, and `invoices`. Stripe (secondary provider, USD-capable) can be added to the gateway registry without schema changes — only a new `StripeAdapter` implementing `GatewayAdapter`.

### 18.5 Reseller Billing at Scale

For resellers with hundreds of clients, `commission_ledger` aggregate queries should migrate to a nightly materialized view (`reseller_commission_daily_summary`) once per-reseller row counts exceed ~50,000, following the same materialized-view refresh pattern used for `package_feature_snapshot` in PHASE5.

### 18.6 Future Extensions

| Feature | Extension |
|---|---|
| Stripe support | New `StripeAdapter`, no schema change |
| Installment / split payments | New `payment_installments` table referencing `orders.id` |
| Dunning email sequences | Extend `email_notifications.template_key` set; no schema change |
| Tax invoice (PPN) compliance | Add `tax_amount`, `tax_rate` columns to `invoices` |
| Automated payout transfers | `commission_payouts.payout_method = 'bank_transfer_api'` + provider integration |

---

## Appendix A — Migration Order

```
091_orders_v2.sql                 -- orders table (extends PHASE2 orders with full billing fields)
092_payment_transactions.sql      -- payment_transactions table + unique provider_tx_id index
093_invoices.sql                  -- invoices table
094_invoice_sequences.sql         -- invoice_sequences table + next_invoice_number() function
095_webhook_logs.sql              -- webhook_logs table
096_refund_requests.sql           -- refund_requests table
097_commission_ledger.sql         -- commission_ledger table
098_commission_payouts.sql        -- commission_payouts table
099_billing_indexes.sql           -- all indexes from Section 17.1
100_rls_orders_tx_invoices.sql    -- RLS policies for orders/payment_transactions/invoices
101_rls_refunds_commission.sql    -- RLS policies for refund_requests/commission_ledger/payouts
102_get_rsvp_summary_billing.sql  -- get_platform_billing_summary() function
103_seed_payment_methods.sql      -- no-op seed (payment methods are config-driven, not DB-driven)
104_billing_audit_actions.sql     -- reference seed for audit action labels (optional lookup table)
105_billing_email_templates.sql   -- email_notifications.template_key additions for billing events
```

## Appendix B — API Route Summary

```
── SUBSCRIPTION & PURCHASE ────────────────────────────────────────────
POST   /api/subscription/purchase            New subscription purchase
POST   /api/subscription/change              Upgrade (immediate) / downgrade (scheduled)
POST   /api/add-ons/purchase                  Purchase add-on

── INVOICES ────────────────────────────────────────────────────────────
GET    /api/invoices/[id]/pdf                 Get/generate invoice PDF

── REFUNDS ──────────────────────────────────────────────────────────────
POST   /api/orders/[id]/refund-request        Tenant requests refund
POST   /api/admin/refund-requests/[id]/process Admin approve/reject refund

── RESELLER ────────────────────────────────────────────────────────────
GET    /api/reseller/commission               Commission ledger + summary

── WEBHOOKS ─────────────────────────────────────────────────────────────
POST   /api/webhooks/[provider]               Gateway webhook receiver

── ADMIN ────────────────────────────────────────────────────────────────
GET    /api/admin/orders                       List all orders
POST   /api/admin/orders/[id]/mark-paid        Manual payment verification
GET    /api/admin/webhooks                     Webhook log viewer
GET    /api/admin/billing-summary              Platform revenue summary
```

## Appendix C — Billing Environment Variables

```bash
# Midtrans
MIDTRANS_SERVER_KEY=
MIDTRANS_CLIENT_KEY=
MIDTRANS_IS_PRODUCTION=false

# Xendit
XENDIT_SECRET_KEY=
XENDIT_WEBHOOK_TOKEN=

# Invoicing
INVOICE_PDF_BUCKET=invoices
INVOICE_DUE_HOURS=24

# Refunds
REFUND_WINDOW_DAYS=7
```

## Appendix D — Billing Audit Action Reference

```typescript
export const BILLING_AUDIT_ACTIONS = {
  'subscription.activated':            'Subscription Activated',
  'subscription.downgrade_scheduled':  'Downgrade Scheduled',
  'order.mark_paid':                   'Order Manually Marked Paid',
  'payment.amount_mismatch':           'Payment Amount Mismatch Detected',
  'refund.requested':                  'Refund Requested',
  'refund.rejected':                   'Refund Rejected',
  'refund.processed':                  'Refund Processed',
} as const;
```

---

*End of PHASE10_PAYMENT_SYSTEM.md*
