-- 20261021120200_enums.sql
-- Controlled vocabularies as enums. Kept small in Phase 1; coding dictionaries
-- (MedDRA/WHODrug) and the full E2B value sets arrive in later phases as
-- reference tables, not enums.

-- Distinguishes our own service-provider staff from a client's own users.
create type public.user_kind as enum ('provider', 'client');

-- Roles are scoped WITHIN a tenant (see tenant_membership).
create type public.app_role as enum (
  'intake',
  'processor',
  'medical_reviewer',
  'qppv',
  'qa',
  'admin',
  'auditor'          -- read-only
);

-- Case lifecycle states (§6 of the architecture doc).
create type public.case_status as enum (
  'new',
  'triage',
  'data_entry',
  'medical_review',
  'qc',
  'approved',
  'submitted',
  'closed',
  'rejected'
);

create type public.case_type as enum (
  'spontaneous',
  'study',
  'literature',
  'regulatory_authority',
  'other'
);

create type public.seriousness as enum ('serious', 'non_serious');

create type public.audit_action as enum ('insert', 'update', 'delete');
