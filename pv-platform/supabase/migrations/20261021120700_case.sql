-- 20261021120700_case.sql
-- The ICSR envelope. Named `pv_case` because `case` is a reserved SQL keyword.
-- Phase 1 carries only the envelope-level fields needed to prove the lifecycle
-- and the compliance spine; patient/drug/event/assessment/narrative tables
-- arrive in Phase 2 and all hang off this row.

create table public.pv_case (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenant (id) on delete restrict,

  -- Worldwide unique case identifier (maps to E2B(R3) C.1.1).
  safety_report_id   text not null,
  case_version       int  not null default 1 check (case_version >= 1),

  case_type          public.case_type   not null,
  seriousness        public.seriousness,
  status             public.case_status not null default 'new',

  -- Day zero = first receipt with the 4 validity criteria met.
  receipt_date       date not null,
  -- Most recent information receipt (follow-up).
  latest_receipt_date date,

  source_country              text,   -- ISO 3166 alpha-2
  primary_source_qualification text,  -- reporter qualification (coded later)

  -- A locked case is version-sealed; further change creates a new version.
  is_locked          boolean not null default false,

  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,

  unique (tenant_id, safety_report_id, case_version),
  check (latest_receipt_date is null or latest_receipt_date >= receipt_date)
);

create index pv_case_tenant_status_idx on public.pv_case (tenant_id, status);

create trigger pv_case_set_actor
  before insert or update on public.pv_case
  for each row execute function public.tg_set_row_actor();

create trigger pv_case_audit
  after insert or update or delete on public.pv_case
  for each row execute function audit.tg_capture();
