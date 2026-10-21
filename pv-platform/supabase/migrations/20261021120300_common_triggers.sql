-- 20261021120300_common_triggers.sql
-- Shared trigger functions for attributability (ALCOA+ "Attributable" and
-- "Contemporaneous"). Server time only; actor from auth.uid(). Never trust
-- client-supplied timestamps or user ids.

-- For tables carrying the 4 actor columns: created_at/by, updated_at/by.
create or replace function public.tg_set_row_actor()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if (tg_op = 'INSERT') then
    new.created_at := now();
    new.created_by := auth.uid();
    new.updated_at := now();
    new.updated_by := auth.uid();
  elsif (tg_op = 'UPDATE') then
    -- creation metadata is immutable
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    new.updated_at := now();
    new.updated_by := auth.uid();
  end if;
  return new;
end;
$$;

-- For tables carrying only updated_at (e.g. profile rows).
create or replace function public.tg_touch_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
