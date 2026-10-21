-- 20261021120100_extensions.sql
-- Extensions and non-exposed schemas.
--
-- pgcrypto  -> gen_random_uuid(), digest() (used for e-signature hashing)
-- citext    -> case-insensitive text for emails / tenant codes
--
-- The `audit` schema is deliberately NOT added to Supabase's exposed schemas
-- (keep PostgREST pointed at `public` only). Audit data is never served over
-- the auto API; it is read via controlled reporting paths later.

create extension if not exists pgcrypto;
create extension if not exists citext;

create schema if not exists audit;
