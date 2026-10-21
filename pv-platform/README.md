# PV Platform

A **multi-tenant** AI-enabled pharmacovigilance (PV) case-management and reporting
platform, built on Supabase Cloud, designed to serve multiple client companies (MAHs)
on one validated system and submit compliant E2B(R3) reports to **FDA (FAERS)**,
**EMA (EudraVigilance)**, and **MHRA (UK Gateway)** under each client's own registrations.

This is a separate project from the AIrights website that shares this repository; it
lives entirely under `pv-platform/`.

## Where to start

- [`docs/architecture.md`](docs/architecture.md) — the system design (v0.2). Start here.
  Review §2 (regulatory accuracy) and answer the open decisions in §12.
- [`supabase/`](supabase/) — the database. Phase 1 compliance spine, with migrations
  and a local validation harness. See [`supabase/README.md`](supabase/README.md).

## Status

**Phase 1 — Core data model & audit spine: built and validated.** Tenancy, the ICSR
case envelope, an append-only audit trail, e-signatures, and RLS tenant isolation are
implemented as Supabase migrations and pass a full smoke-test suite against a real
PostgreSQL 16 instance.

Next: Phase 2 (case lifecycle + the clinical sub-entities) — pending the open decisions
in architecture §12.
