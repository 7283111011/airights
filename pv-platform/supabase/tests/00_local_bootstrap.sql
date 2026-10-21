-- 00_local_bootstrap.sql
-- LOCAL VALIDATION ONLY. Supabase provides the `auth` schema, auth.uid(), and
-- the anon/authenticated/service_role roles in production. This file stubs them
-- so the migrations can be applied and tested against a vanilla PostgreSQL 16.
-- It is NEVER applied to Supabase.

-- API roles.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end;
$$;

-- Minimal auth schema + identity table.
create schema if not exists auth;

create table if not exists auth.users (
  id    uuid primary key,
  email text
);

-- auth.uid() reads the request sub claim, mirroring Supabase/GoTrue behaviour.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

create or replace function auth.role()
returns text
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.role', true), '')::text;
$$;

-- Supabase grants the API roles access to the auth helpers; mirror that so
-- triggers/policies running as `authenticated` can call auth.uid().
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant execute on function auth.role() to anon, authenticated, service_role;
