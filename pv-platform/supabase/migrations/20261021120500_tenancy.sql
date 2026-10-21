-- 20261021120500_tenancy.sql
-- Tenancy foundation (§3.2). A `tenant` is one client company (MAH).
-- `app_user` mirrors the auth.users identity with PV-specific attributes.
-- `tenant_membership` grants a user a role within a tenant and is what lets a
-- provider user be assigned to several clients while isolation still holds.

-- Profile row, 1:1 with auth.users.
create table public.app_user (
  id         uuid primary key references auth.users (id) on delete restrict,
  email      citext not null,
  full_name  text,
  user_kind  public.user_kind not null default 'provider',
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger app_user_touch
  before update on public.app_user
  for each row execute function public.tg_touch_updated_at();

-- One client company.
create table public.tenant (
  id               uuid primary key default gen_random_uuid(),
  name             text   not null,
  code             citext not null unique,          -- short handle, e.g. 'ACME'
  status           text   not null default 'active' check (status in ('active','suspended','offboarded')),
  qppv_name        text,
  qppv_contact     text,
  psmf_reference   text,
  residency_region text check (residency_region in ('eu','us','uk')),
  retention_years  int    check (retention_years is null or retention_years > 0),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create trigger tenant_set_actor
  before insert or update on public.tenant
  for each row execute function public.tg_set_row_actor();

create trigger tenant_audit
  after insert or update or delete on public.tenant
  for each row execute function audit.tg_capture();

-- A user's role within a tenant. A provider user may have many rows across
-- tenants; a client user typically has rows within a single tenant.
create table public.tenant_membership (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant (id) on delete cascade,
  user_id    uuid not null references public.app_user (id) on delete cascade,
  role       public.app_role not null,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  unique (tenant_id, user_id, role)
);

create index tenant_membership_user_idx on public.tenant_membership (user_id) where is_active;

create trigger tenant_membership_set_actor
  before insert or update on public.tenant_membership
  for each row execute function public.tg_set_row_actor();

create trigger tenant_membership_audit
  after insert or update or delete on public.tenant_membership
  for each row execute function audit.tg_capture();

create trigger app_user_audit
  after insert or update or delete on public.app_user
  for each row execute function audit.tg_capture();
