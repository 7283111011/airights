-- 20261021120800_esignature.sql
-- Electronic signatures (§4.2, 21 CFR Part 11 Subpart C / Annex 11).
--
-- A signature binds who / what / why / when and is cryptographically linked to
-- the signed content via a SHA-256 hash of the payload, so it cannot be copied
-- onto a different record. Signatures are immutable.
--
-- NOTE: the Part 11 requirement that signing be a distinct RE-AUTHENTICATED act
-- (password re-entry or step-up MFA at the moment of signing) is enforced at the
-- application/Edge-Function layer; this table is the durable, auditable record
-- of the act. sign_record() is the only supported write path.

create table public.e_signature (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant (id) on delete restrict,
  table_name     text not null,
  record_id      uuid not null,
  record_version int,
  record_hash    text not null,          -- hex sha256 of the signed payload
  meaning        text not null,          -- e.g. 'medical_review_approved'
  signer         uuid not null,          -- auth.uid() at signing time
  signer_name    text,
  signed_at      timestamptz not null default now(),
  created_at     timestamptz not null default now()
);

create index e_signature_record_idx on public.e_signature (table_name, record_id);
create index e_signature_tenant_idx on public.e_signature (tenant_id, signed_at);

-- Signatures are append-only (owner included).
create trigger e_signature_no_mutation
  before update or delete on public.e_signature
  for each row execute function audit.tg_block_mutation();

-- The supported signing path. SECURITY DEFINER so it can write the row, but it
-- independently verifies membership and that a real user is signing.
create or replace function public.sign_record(
  p_tenant         uuid,
  p_table          text,
  p_record_id      uuid,
  p_record_version int,
  p_meaning        text,
  p_payload        jsonb
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid  uuid := auth.uid();
  v_name text;
  v_hash text;
  v_sig  uuid;
begin
  if v_uid is null then
    raise exception 'signing requires an authenticated user'
      using errcode = 'insufficient_privilege';
  end if;

  if not public.is_tenant_member(p_tenant) then
    raise exception 'not a member of tenant %', p_tenant
      using errcode = 'insufficient_privilege';
  end if;

  v_hash := encode(digest(convert_to(p_payload::text, 'UTF8'), 'sha256'), 'hex');
  select full_name into v_name from public.app_user where id = v_uid;

  insert into public.e_signature (
    tenant_id, table_name, record_id, record_version,
    record_hash, meaning, signer, signer_name
  )
  values (
    p_tenant, p_table, p_record_id, p_record_version,
    v_hash, p_meaning, v_uid, v_name
  )
  returning id into v_sig;

  return v_sig;
end;
$$;

grant execute on function public.sign_record(uuid, text, uuid, int, text, jsonb) to authenticated;
