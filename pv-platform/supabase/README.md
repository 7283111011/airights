# Database (Supabase / PostgreSQL)

Phase 1 — the compliance **spine**: tenancy, the ICSR case envelope, an
append-only audit trail, electronic signatures, and Row-Level Security tenant
isolation. This is the foundation the rest of the data model (patient, drug,
event, assessment, narrative, submission) will hang off in Phase 2.

## Layout

```
supabase/
  migrations/   ordered SQL migrations (applied in filename order)
  tests/        local validation harness (NOT applied to Supabase)
```

### Migrations (apply in order)

| File | What it creates |
|---|---|
| `…120100_extensions.sql`       | `pgcrypto`, `citext`, and the non-exposed `audit` schema |
| `…120200_enums.sql`            | controlled vocabularies (roles, case status/type, seriousness) |
| `…120300_common_triggers.sql`  | attributability triggers (created/updated by/at) |
| `…120400_audit.sql`            | append-only `audit.audit_log` + generic capture trigger |
| `…120500_tenancy.sql`          | `app_user`, `tenant`, `tenant_membership` |
| `…120600_access_functions.sql` | `is_tenant_member()`, `has_tenant_role()` (used by RLS) |
| `…120700_case.sql`             | `pv_case` (the ICSR envelope) |
| `…120800_esignature.sql`       | `e_signature` + `sign_record()` |
| `…120900_rls.sql`              | enables RLS and all tenant-isolation / role policies |

## What the spine guarantees (and is tested)

- **Tenant isolation** — every regulated table carries `tenant_id`; RLS is
  default-deny. A member of tenant A cannot see or write tenant B's data.
- **Cross-tenant provider staff** — a user with memberships in several tenants
  sees exactly the union of those tenants, nothing more.
- **Audit trail** — every insert/update/delete is captured with before/after
  images, changed fields, actor (`auth.uid()`), server timestamp, and an
  optional reason-for-change (`SET pv.change_reason = '…'`). Audit rows cannot
  be updated or deleted, even by the table owner.
- **E-signatures** — `sign_record()` binds who/what/why/when with a SHA-256 hash
  of the signed payload; rows are immutable.
- **Case locking** — a locked case cannot be edited by processing roles.

## Running the local validation

Requires PostgreSQL 16 server binaries (`initdb`, `pg_ctl`) and must run as a
non-root OS user. The harness spins up a throwaway cluster, applies the local
auth stub + all migrations, runs the smoke tests, and tears down.

```bash
# as an unprivileged user with postgres binaries on PATH:
pv-platform/supabase/tests/run_local.sh
```

Expected tail: `ALL PHASE 1 SPINE TESTS PASSED`.

> `tests/00_local_bootstrap.sql` stubs the `auth` schema, `auth.uid()`, and the
> `anon`/`authenticated`/`service_role` roles that **Supabase provides in
> production**. It is for local validation only and is never applied to Supabase.

## Deploying to Supabase

1. Keep PostgREST exposed to the `public` schema **only** — never expose
   `audit`.
2. Apply `migrations/` via the Supabase CLI (`supabase db push`) or the SQL
   editor, in filename order. Do **not** apply anything under `tests/`.
3. Tenant onboarding (creating a `tenant` row and seeding its first `admin`
   membership) is a **provisioning action** performed with the `service_role`
   key from a trusted backend — never from the browser.
4. Enforce MFA and least-privilege on all accounts (§9 of the architecture doc).

## Not yet built (by design, later phases)

Patient/drug/event/assessment/narrative/submission tables, the compliance
clocks (`pg_cron`), E2B(R3) build/validate, gateways, and the AI-suggestion
governance tables. Phase 1 proves the hard compliance mechanics first.
