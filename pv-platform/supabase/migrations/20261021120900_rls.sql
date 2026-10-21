-- 20261021120900_rls.sql
-- Row-Level Security: tenant isolation as the primary security boundary (§3.2,
-- §9). Default-deny everywhere; access is granted only through explicit
-- policies keyed on tenant membership and role.
--
-- Role model (Supabase): `anon` (unauthenticated) gets nothing; `authenticated`
-- is gated by these policies; `service_role` bypasses RLS and is used only for
-- platform provisioning (tenant onboarding, seeding the first admin).

-- ---------------------------------------------------------------------------
-- Enable RLS
-- ---------------------------------------------------------------------------
alter table public.app_user          enable row level security;
alter table public.tenant            enable row level security;
alter table public.tenant_membership enable row level security;
alter table public.pv_case           enable row level security;
alter table public.e_signature       enable row level security;

-- ---------------------------------------------------------------------------
-- Table privileges (RLS still filters rows; grants are the outer gate)
-- ---------------------------------------------------------------------------
grant usage on schema public to authenticated;

grant select, update            on public.app_user          to authenticated;
grant select, update            on public.tenant            to authenticated;
grant select, insert, update, delete on public.tenant_membership to authenticated;
grant select, insert, update    on public.pv_case           to authenticated;
grant select, insert            on public.e_signature       to authenticated;

-- Platform provisioning role has full table access (and bypasses RLS).
grant all on all tables    in schema public to service_role;
grant all on all routines  in schema public to service_role;
grant all on all sequences in schema public to service_role;

-- ---------------------------------------------------------------------------
-- app_user: a user sees and edits only their own profile row.
-- ---------------------------------------------------------------------------
create policy app_user_select_self on public.app_user
  for select to authenticated
  using (id = auth.uid());

create policy app_user_update_self on public.app_user
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- ---------------------------------------------------------------------------
-- tenant: visible to members; editable by a tenant admin. Creation is a
-- provisioning action (service_role) -- no authenticated INSERT policy exists.
-- ---------------------------------------------------------------------------
create policy tenant_select on public.tenant
  for select to authenticated
  using (public.is_tenant_member(id));

create policy tenant_update on public.tenant
  for update to authenticated
  using (public.has_tenant_role(id, array['admin']::public.app_role[]))
  with check (public.has_tenant_role(id, array['admin']::public.app_role[]));

-- ---------------------------------------------------------------------------
-- tenant_membership: a user sees their own memberships; a tenant admin manages
-- memberships for that tenant. (First admin is seeded via service_role.)
-- ---------------------------------------------------------------------------
create policy tm_select on public.tenant_membership
  for select to authenticated
  using (
    user_id = auth.uid()
    or public.has_tenant_role(tenant_id, array['admin']::public.app_role[])
  );

create policy tm_insert on public.tenant_membership
  for insert to authenticated
  with check (public.has_tenant_role(tenant_id, array['admin']::public.app_role[]));

create policy tm_update on public.tenant_membership
  for update to authenticated
  using (public.has_tenant_role(tenant_id, array['admin']::public.app_role[]))
  with check (public.has_tenant_role(tenant_id, array['admin']::public.app_role[]));

create policy tm_delete on public.tenant_membership
  for delete to authenticated
  using (public.has_tenant_role(tenant_id, array['admin']::public.app_role[]));

-- ---------------------------------------------------------------------------
-- pv_case: tenant-isolated. Read by any member; created by intake/processor/
-- admin; edited by processing roles while unlocked. No DELETE policy -- cases
-- are never hard-deleted by app roles (nullification/versioning instead).
-- ---------------------------------------------------------------------------
create policy case_select on public.pv_case
  for select to authenticated
  using (public.is_tenant_member(tenant_id));

create policy case_insert on public.pv_case
  for insert to authenticated
  with check (
    public.has_tenant_role(tenant_id, array['intake','processor','admin']::public.app_role[])
  );

create policy case_update on public.pv_case
  for update to authenticated
  using (
    public.has_tenant_role(
      tenant_id,
      array['intake','processor','medical_reviewer','qa','admin']::public.app_role[]
    )
    and is_locked = false
  )
  with check (
    public.has_tenant_role(
      tenant_id,
      array['intake','processor','medical_reviewer','qa','admin']::public.app_role[]
    )
  );

-- ---------------------------------------------------------------------------
-- e_signature: tenant-isolated, insert-only for members (immutability also
-- enforced by the block trigger). Signer must be the acting user.
-- ---------------------------------------------------------------------------
create policy sig_select on public.e_signature
  for select to authenticated
  using (public.is_tenant_member(tenant_id));

create policy sig_insert on public.e_signature
  for insert to authenticated
  with check (signer = auth.uid() and public.is_tenant_member(tenant_id));
