-- 20261021120400_audit.sql
-- The append-only audit trail (§4.1). This is the backbone of Part 11 /
-- Annex 11 compliance and is built, not inherited from the platform.
--
-- Properties:
--   * Every INSERT/UPDATE/DELETE on an audited table writes one immutable row.
--   * Before/after images stored as JSONB; changed fields computed on UPDATE.
--   * Server-authoritative timestamp (contemporaneous).
--   * Actor = auth.uid(); db role also captured.
--   * Optional reason-for-change passed via the `pv.change_reason` GUC.
--   * Rows can never be updated or deleted -- enforced by a block trigger
--     (fires even for the table owner) AND by revoked privileges.

create table audit.audit_log (
  id            bigint generated always as identity primary key,
  occurred_at   timestamptz not null default now(),
  tenant_id     uuid,                         -- for per-tenant audit extraction
  table_schema  text        not null,
  table_name    text        not null,
  record_id     text        not null,
  action        public.audit_action not null,
  actor         uuid,                          -- auth.uid(), null for system/provisioning
  actor_db_role text        not null,
  old_data      jsonb,
  new_data      jsonb,
  changed_fields text[],
  reason        text,
  txid          bigint      not null default txid_current()
);

create index audit_log_tenant_idx on audit.audit_log (tenant_id, occurred_at);
create index audit_log_record_idx on audit.audit_log (table_schema, table_name, record_id);

-- Generic capture trigger. Attached per audited table in later migrations.
create or replace function audit.tg_capture()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_old     jsonb;
  v_new     jsonb;
  v_rec_id  text;
  v_tenant  uuid;
  v_changed text[];
begin
  if (tg_op = 'DELETE') then
    v_old := to_jsonb(old);
    v_new := null;
  elsif (tg_op = 'UPDATE') then
    v_old := to_jsonb(old);
    v_new := to_jsonb(new);
  else
    v_old := null;
    v_new := to_jsonb(new);
  end if;

  v_rec_id := coalesce(v_new, v_old) ->> 'id';
  v_tenant := nullif(coalesce(v_new, v_old) ->> 'tenant_id', '')::uuid;

  -- The tenant table has no tenant_id column; its own id IS the tenant.
  if v_tenant is null and tg_table_name = 'tenant' then
    v_tenant := nullif(coalesce(v_new, v_old) ->> 'id', '')::uuid;
  end if;

  if (tg_op = 'UPDATE') then
    select array_agg(k order by k)
      into v_changed
      from jsonb_object_keys(v_new) as k
     where (v_new -> k) is distinct from (v_old -> k);
  end if;

  insert into audit.audit_log (
    occurred_at, tenant_id, table_schema, table_name, record_id, action,
    actor, actor_db_role, old_data, new_data, changed_fields, reason
  )
  values (
    now(), v_tenant, tg_table_schema, tg_table_name, v_rec_id,
    lower(tg_op)::public.audit_action,
    auth.uid(), current_user, v_old, v_new, v_changed,
    nullif(current_setting('pv.change_reason', true), '')
  );

  if (tg_op = 'DELETE') then
    return old;
  else
    return new;
  end if;
end;
$$;

-- Block trigger: audit rows are append-only, no exceptions (owner included).
create or replace function audit.tg_block_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  raise exception 'audit.audit_log is append-only; % is not permitted', tg_op
    using errcode = 'insufficient_privilege';
end;
$$;

create trigger audit_log_no_mutation
  before update or delete on audit.audit_log
  for each row execute function audit.tg_block_mutation();

-- Defence in depth: no app role may touch audit data directly.
revoke all on audit.audit_log from public;
