-- 10_smoke.sql
-- Validates the Phase 1 spine against a real database. Each test is a DO block
-- that raises on failure (so psql -v ON_ERROR_STOP=1 aborts) and NOTICEs on
-- pass. Negative tests catch the expected error and fail loudly if it does NOT
-- occur. A final notice prints when all tests pass.
--
-- Actors (fixed UUIDs):
--   tenant A = 111...1, tenant B = 222...2
--   alice  (aaa...a) provider: ADMIN of A, PROCESSOR of B   (cross-tenant staff)
--   bob    (bbb...b) client:   PROCESSOR of B only
--   carol  (ccc...c) client:   PROCESSOR of A only

-- Convenience: run a block as an authenticated user.
--   select set_config('request.jwt.claim.sub', '<uuid>', true) inside a tx +
--   set local role authenticated.

-- ===========================================================================
-- Provisioning (as superuser / service_role: bypasses RLS)
-- ===========================================================================
insert into auth.users (id, email) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'alice@provider.example'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'bob@acme.example'),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'carol@globex.example');

insert into public.app_user (id, email, full_name, user_kind) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'alice@provider.example', 'Alice Provider', 'provider'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'bob@acme.example',       'Bob Client',     'client'),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'carol@globex.example',   'Carol Client',   'client');

insert into public.tenant (id, name, code, residency_region, retention_years) values
  ('11111111-1111-1111-1111-111111111111', 'Acme Pharma',   'ACME',  'us', 10),
  ('22222222-2222-2222-2222-222222222222', 'Globex Biotech','GLOBEX','eu', 10);

insert into public.tenant_membership (tenant_id, user_id, role) values
  ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'admin'),
  ('22222222-2222-2222-2222-222222222222', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'processor'),
  ('22222222-2222-2222-2222-222222222222', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'processor'),
  ('11111111-1111-1111-1111-111111111111', 'cccccccc-cccc-cccc-cccc-cccccccccccc', 'processor');

-- ===========================================================================
-- TEST 1: alice (admin of A) can create a case in tenant A
-- ===========================================================================
do $$
declare v_id uuid;
begin
  perform set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
  set local role authenticated;
  insert into public.pv_case (tenant_id, safety_report_id, case_type, seriousness, receipt_date)
  values ('11111111-1111-1111-1111-111111111111', 'US-ACME-2026-0001', 'spontaneous', 'serious', date '2026-10-01')
  returning id into v_id;
  reset role;
  assert v_id is not null, 'TEST 1 FAIL: case not created in tenant A';
  raise notice 'TEST 1 PASS: admin created case in own tenant (A)';
end;
$$;

-- ===========================================================================
-- TEST 2: alice (processor of B) can create a case in tenant B
-- ===========================================================================
do $$
declare v_id uuid;
begin
  perform set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
  set local role authenticated;
  insert into public.pv_case (tenant_id, safety_report_id, case_type, receipt_date)
  values ('22222222-2222-2222-2222-222222222222', 'EU-GLOBEX-2026-0001', 'literature', date '2026-10-05')
  returning id into v_id;
  reset role;
  assert v_id is not null, 'TEST 2 FAIL: cross-tenant provider staff could not create case in B';
  raise notice 'TEST 2 PASS: provider staff created case in assigned tenant (B)';
end;
$$;

-- ===========================================================================
-- TEST 3: tenant isolation on SELECT
--   carol (member of A only) sees exactly 1 case (A's), never B's.
--   bob   (member of B only) sees exactly 1 case (B's), never A's.
--   alice (member of A and B) sees 2.
-- ===========================================================================
do $$
declare n int;
begin
  perform set_config('request.jwt.claim.sub', 'cccccccc-cccc-cccc-cccc-cccccccccccc', true);
  set local role authenticated;
  select count(*) into n from public.pv_case;
  reset role;
  assert n = 1, format('TEST 3a FAIL: carol saw %s cases, expected 1', n);
  raise notice 'TEST 3a PASS: carol (tenant A) sees only A''s case';
end;
$$;

do $$
declare n int;
begin
  perform set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
  set local role authenticated;
  select count(*) into n from public.pv_case;
  reset role;
  assert n = 1, format('TEST 3b FAIL: bob saw %s cases, expected 1', n);
  raise notice 'TEST 3b PASS: bob (tenant B) sees only B''s case';
end;
$$;

do $$
declare n int;
begin
  perform set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
  set local role authenticated;
  select count(*) into n from public.pv_case;
  reset role;
  assert n = 2, format('TEST 3c FAIL: alice saw %s cases, expected 2', n);
  raise notice 'TEST 3c PASS: cross-tenant staff sees both assigned tenants';
end;
$$;

-- ===========================================================================
-- TEST 4 (negative): carol cannot INSERT a case into tenant B (not a member)
-- ===========================================================================
do $$
begin
  perform set_config('request.jwt.claim.sub', 'cccccccc-cccc-cccc-cccc-cccccccccccc', true);
  set local role authenticated;
  begin
    insert into public.pv_case (tenant_id, safety_report_id, case_type, receipt_date)
    values ('22222222-2222-2222-2222-222222222222', 'EU-GLOBEX-2026-9999', 'spontaneous', date '2026-10-06');
    reset role;
    raise exception 'TEST 4 FAIL: carol inserted a case into a tenant she does not belong to';
  exception when insufficient_privilege then
    reset role;
    raise notice 'TEST 4 PASS: cross-tenant insert blocked by RLS';
  end;
end;
$$;

-- ===========================================================================
-- TEST 5: audit trail captures an UPDATE with changed fields, actor, and reason
-- ===========================================================================
do $$
declare
  v_case uuid;
  v_changed text[];
  v_actor uuid;
  v_reason text;
begin
  select id into v_case from public.pv_case
   where tenant_id = '11111111-1111-1111-1111-111111111111'
     and safety_report_id = 'US-ACME-2026-0001';

  perform set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
  perform set_config('pv.change_reason', 'advanced to medical review', true);
  set local role authenticated;
  update public.pv_case set status = 'medical_review' where id = v_case;
  reset role;

  select changed_fields, actor, reason
    into v_changed, v_actor, v_reason
    from audit.audit_log
   where table_name = 'pv_case' and record_id = v_case::text and action = 'update'
   order by id desc limit 1;

  assert v_changed @> array['status'], 'TEST 5 FAIL: changed_fields missing status';
  assert v_actor = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'TEST 5 FAIL: wrong actor recorded';
  assert v_reason = 'advanced to medical review', 'TEST 5 FAIL: reason-for-change not captured';
  raise notice 'TEST 5 PASS: audit captured update (fields=%, actor ok, reason ok)', v_changed;
end;
$$;

-- ===========================================================================
-- TEST 6: e-signature via sign_record(), then prove immutability
-- ===========================================================================
do $$
declare
  v_case uuid;
  v_sig  uuid;
begin
  select id into v_case from public.pv_case
   where tenant_id = '11111111-1111-1111-1111-111111111111'
     and safety_report_id = 'US-ACME-2026-0001';

  perform set_config('request.jwt.claim.sub', 'cccccccc-cccc-cccc-cccc-cccccccccccc', true);
  set local role authenticated;
  v_sig := public.sign_record(
    '11111111-1111-1111-1111-111111111111', 'pv_case', v_case, 1,
    'medical_review_approved',
    jsonb_build_object('case_id', v_case, 'status', 'medical_review'));
  reset role;

  assert v_sig is not null, 'TEST 6 FAIL: signature not created';
  raise notice 'TEST 6 PASS: e-signature recorded';
end;
$$;

do $$
begin
  begin
    update public.e_signature set meaning = 'tampered';  -- as superuser!
    raise exception 'TEST 6b FAIL: e_signature was mutable';
  exception when insufficient_privilege then
    raise notice 'TEST 6b PASS: e_signature is append-only (update blocked even for owner)';
  end;
end;
$$;

-- ===========================================================================
-- TEST 7: audit_log itself is append-only (even for the owner)
-- ===========================================================================
do $$
begin
  begin
    delete from audit.audit_log where id = (select min(id) from audit.audit_log);
    raise exception 'TEST 7 FAIL: audit_log row was deletable';
  exception when insufficient_privilege then
    raise notice 'TEST 7 PASS: audit_log is append-only (delete blocked even for owner)';
  end;
end;
$$;

-- ===========================================================================
-- TEST 8: a locked case cannot be edited by a processing role
-- ===========================================================================
do $$
declare v_case uuid;
begin
  select id into v_case from public.pv_case
   where tenant_id = '11111111-1111-1111-1111-111111111111'
     and safety_report_id = 'US-ACME-2026-0001';

  update public.pv_case set is_locked = true where id = v_case;  -- lock as superuser

  perform set_config('request.jwt.claim.sub', 'cccccccc-cccc-cccc-cccc-cccccccccccc', true);
  set local role authenticated;
  update public.pv_case set status = 'closed' where id = v_case;  -- should affect 0 rows
  if found then
    reset role;
    raise exception 'TEST 8 FAIL: locked case was edited';
  end if;
  reset role;
  raise notice 'TEST 8 PASS: locked case is not editable by processing role';
end;
$$;

-- ===========================================================================
-- TEST 9 (negative): anon sees nothing
-- ===========================================================================
do $$
declare n int;
begin
  perform set_config('request.jwt.claim.sub', '', true);
  set local role anon;
  select count(*) into n from public.pv_case;
  reset role;
  assert n = 0, format('TEST 9 FAIL: anon saw %s cases', n);
  raise notice 'TEST 9 PASS: anonymous role sees no cases';
exception when insufficient_privilege then
  reset role;
  raise notice 'TEST 9 PASS: anonymous role has no access';
end;
$$;

do $$
begin
  raise notice '=====================================';
  raise notice 'ALL PHASE 1 SPINE TESTS PASSED';
  raise notice '=====================================';
end;
$$;
