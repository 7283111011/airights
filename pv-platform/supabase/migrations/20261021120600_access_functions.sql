-- 20261021120600_access_functions.sql
-- Access-decision helpers used inside RLS policies. All are SECURITY DEFINER
-- and owned by the migration role, so they read tenant_membership without being
-- re-filtered by RLS -- this both avoids policy recursion and keeps the
-- membership table itself locked down to normal callers.

-- Does the current user have an active membership in this tenant (any role)?
create or replace function public.is_tenant_member(p_tenant uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
      from public.tenant_membership m
     where m.tenant_id = p_tenant
       and m.user_id = auth.uid()
       and m.is_active
  );
$$;

-- Does the current user hold any of the given roles in this tenant?
create or replace function public.has_tenant_role(p_tenant uuid, p_roles public.app_role[])
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
      from public.tenant_membership m
     where m.tenant_id = p_tenant
       and m.user_id = auth.uid()
       and m.is_active
       and m.role = any (p_roles)
  );
$$;

-- Keep execution available to API roles (default is PUBLIC, stated explicitly).
grant execute on function public.is_tenant_member(uuid) to authenticated;
grant execute on function public.has_tenant_role(uuid, public.app_role[]) to authenticated;
