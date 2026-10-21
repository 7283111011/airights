# AI-Enabled Pharmacovigilance Platform — System Architecture (v0.2)

**Status:** Draft for review · **Date:** 2026-10-21
**Audience:** Regulatory/compliance lead (owns requirements) + engineering (owns build)
**Scope of this version:** Target architecture and build roadmap. Not a validated specification — this is the design we align on *before* writing the schema.

**Decisions locked so far:** Architecture-doc-first · regimes **FDA + EMA + MHRA** · hosting **Supabase Cloud** · **multi-tenant service platform** (one validated platform serving many client MAHs — see §3.2).

**Changelog:** v0.2 — added multi-tenancy as a core architectural concern (§3.2) after confirming this is a service platform, not a single-company tool; updated data model, security, and open decisions accordingly.

> **Reading note for the compliance owner:** This document owns the *technical* side. Where a decision is really yours (a regulatory interpretation, a timeline, an SOP), it's flagged **[REG DECISION]**. Where it's mine, it's flagged **[ENG DECISION]**. Open items are collected in §12.

---

## 1. Executive summary

We are building a modern, lean pharmacovigilance (PV) case management and reporting platform on **Supabase Cloud** (managed PostgreSQL + auth + storage + APIs), with AI assistance woven into the workflow to reduce manual drudgery — **not** to remove the qualified human decisions that regulators require.

The design target is a **multi-tenant service platform**: a single validated system that serves **many client companies (MAHs)** at once, each isolated from the others, that can intake adverse event reports, manage Individual Case Safety Reports (ICSRs) through the full case lifecycle, and submit compliant **E2B(R3)** files to **FDA (FAERS)**, **EMA (EudraVigilance)**, and **MHRA (UK Gateway)** — under each client's own registrations. Build and validate once; onboard a new client as configuration, not a new system.

Three principles drive every decision below:

1. **Compliance is a property of the validated system, not the platform.** Supabase gives us a strong, standards-based foundation; 21 CFR Part 11 / EU Annex 11 compliance is something *we build and validate on top of it*.
2. **AI augments, a qualified human decides.** Every regulatory decision (seriousness, expectedness, causality, final MedDRA coding, submission) has a named human owner captured in the audit trail. AI produces *suggestions*, never *approvals*.
3. **Design for the hardest regime from day one.** Supporting FDA + EMA + MHRA simultaneously means E2B(R3), multi-region data handling, and three gateways are first-class concerns, not bolt-ons.

**Headcount reality:** AI meaningfully shrinks the team needed per case volume by automating intake, coding suggestions, duplicate detection, narrative drafting, translation, literature screening, and QC. It does **not** eliminate the need for qualified assessors and a QPPV. The honest pitch is "a small team doing the work of a large one," and that framing is what survives an inspection.

---

## 2. Regulatory context (what each regime demands)

This section is the compliance owner's domain — included so engineering shares the same mental model. Corrections welcome; this is my working understanding.

### 2.1 Cross-cutting standards

| Standard | What it governs | Implication for the build |
|---|---|---|
| **ICH E2B(R3)** | ISO/HL7 ICSR message format for electronic case interchange | Our canonical internal data model must map cleanly to E2B(R3). We store structured fields + the generated XML. |
| **MedDRA** | Coding of adverse events, indications, medical history | **Licensed** from the ICH MSSO — cannot be bundled. We integrate; customer holds the license. |
| **WHODrug** | Drug/substance dictionary | **Licensed** from Uppsala Monitoring Centre (UMC). Same pattern. |
| **21 CFR Part 11** (US) / **EU Annex 11** (EU) | Electronic records & electronic signatures | Audit trails, e-signatures, access control, validation — all built by us. See §4. |
| **ICH E2D / GVP Module VI** | Case management, collection, follow-up, reporting | Drives the case lifecycle state machine (§6). |
| **GVP Module IX** | Signal management | Phase 3+ feature; schema should not preclude it. |
| **GAMP 5 (2nd ed.) / CSA** | Computerised system validation | Risk-based validation approach; defines our IQ/OQ/PQ effort. |
| **ALCOA+** | Data integrity principles | Attributable, Legible, Contemporaneous, Original, Accurate + Complete, Consistent, Enduring, Available. Baked into the data layer (§4.3). |

### 2.2 Regime-specific

**FDA (United States)**
- Postmarketing reporting under **21 CFR 314.80** (drugs) / **600.80** (biologics).
- Submission of E2B(R3) to **FAERS** via the **FDA Electronic Submissions Gateway (ESG)**.
- **15-calendar-day** expedited reports for serious + unexpected; periodic (PADER/PBRER) on schedule.
- 21 CFR Part 11 for all electronic records and signatures.

**EMA (European Union)**
- Submission to **EudraVigilance** (EVPM/EVCTM) in E2B(R3).
- **EU GVP** modules, especially Module VI (management/reporting) and Module VI Addendum.
- **EU QPPV** must be designated and reachable; the system must support their oversight.
- **XEVMPD / Article 57** product data (medicinal product dictionary) — separate submission stream.
- Timelines: **15 days** (serious) / **90 days** (non-serious) from day zero.
- GDPR + **data residency** in the EU for personal data (see §7.3).

**MHRA (United Kingdom, post-Brexit)**
- Independent UK regime; ICSRs submitted via the **MHRA Gateway** / ICSR Submissions portal in E2B(R3).
- **UK QPPV** requirement.
- Timelines broadly mirror EU (15/90 day), but tracked on a separate clock.
- UK GDPR applies.

**[REG DECISION]** Confirm the exact reporting obligations in scope for launch (e.g. are we doing periodic reports — PBRER/PADER — in v1, or ICSR expedited only?). This materially changes scope.

---

## 3. High-level architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                          USERS (role-based)                           │
│   Intake · Case Processors · Medical Reviewers · QPPV · QA · Admin     │
└───────────────┬───────────────────────────────────────┬─────────────┘
                │ HTTPS                                   │
        ┌───────▼────────┐                       ┌────────▼─────────┐
        │  Web app (SPA) │                       │  Intake channels │
        │  React/Next.js │                       │  email · forms · │
        │                │                       │  API · uploads   │
        └───────┬────────┘                       └────────┬─────────┘
                │ supabase-js / PostgREST                  │
┌───────────────▼──────────────────────────────────────────▼──────────┐
│                          SUPABASE CLOUD                                │
│                                                                        │
│  ┌──────────┐  ┌───────────┐  ┌──────────┐  ┌─────────────────────┐  │
│  │  Auth    │  │ PostgREST │  │ Realtime │  │  Storage (buckets)   │  │
│  │ (GoTrue) │  │  auto API │  │          │  │  source docs, E2B XML│  │
│  └────┬─────┘  └─────┬─────┘  └────┬─────┘  └──────────┬──────────┘  │
│       │              │             │                   │             │
│  ┌────▼──────────────▼─────────────▼───────────────────▼──────────┐  │
│  │                   PostgreSQL (the system of record)             │  │
│  │   core schema · audit schema (append-only) · RLS policies       │  │
│  │   triggers (audit, clocks) · pgcrypto · pg_cron                 │  │
│  └─────────────────────────────┬──────────────────────────────────┘  │
│                                 │                                      │
│  ┌──────────────────────────────▼─────────────────────────────────┐  │
│  │              Edge Functions (Deno) — orchestration              │  │
│  │  E2B(R3) build/validate · gateway submit · AI calls (HITL)      │  │
│  └──────────────────────────────┬─────────────────────────────────┘  │
└─────────────────────────────────┼────────────────────────────────────┘
                                   │ outbound (brokered, audited)
         ┌─────────────────────────┼─────────────────────────┐
         ▼                         ▼                         ▼
   ┌───────────┐            ┌──────────────┐          ┌─────────────┐
   │ FDA ESG   │            │ EudraVigilance│          │ MHRA Gateway│
   │ (FAERS)   │            │   (EMA)       │          │   (UK)      │
   └───────────┘            └──────────────┘          └─────────────┘

   External dictionaries/services (licensed/brokered):
   MedDRA (MSSO) · WHODrug (UMC) · LLM provider (Claude) · literature sources
```

### 3.1 Why Supabase Cloud (and its honest limits)

**Strengths we're leveraging**
- Real **PostgreSQL** — case data is deeply relational; Postgres models it natively and gives us JSONB for E2B payloads and flexible metadata.
- **Row-Level Security (RLS)** enforced in the database, not just the app — the right place for "who can see/do what."
- Built-in **Auth** (incl. MFA/SSO on paid plans), **Storage** for source documents, **auto-generated APIs**, and **Edge Functions** for orchestration.
- **pg_cron** for compliance-clock jobs; **triggers** for audit capture.
- SOC 2 Type II; HIPAA terms available on paid plans (US). **[REG DECISION]** Confirm whether a BAA/DPA with Supabase is required and acceptable.

**Limits we must engineer around**
- Supabase being SOC 2 / HIPAA-capable does **not** confer Part 11 / Annex 11 compliance — that's on us (§4).
- **Data residency:** Supabase Cloud hosts a project in one region. For EU personal data we likely need an **EU-region project** (see §7.3), which may push toward a two-project (US/EU) topology — **[ENG DECISION, pending §12]**.
- It's a managed service: we don't control the OS layer, so our validation treats the platform as a GAMP infrastructure/supplier component and relies on their attestations + our qualification of the configured application.

### 3.2 Multi-tenancy — a service platform for many clients

We are building a platform that serves **multiple client companies (each an MAH)** on one validated system — the model used by PV service providers (CROs/BPOs) and SaaS safety vendors. This is a core architectural property, decided up front, not a later feature.

**The isolation boundary (security-critical).**
- A **`tenant`** = one client company. **Every regulated table carries a `tenant_id`**, and **Row-Level Security enforces default-deny tenant isolation** at the database — a query with no tenant context returns nothing.
- Cross-tenant leakage (Client A seeing Client B's data) is treated as a **catastrophic security event**, not a bug: it ends client trust and may itself be reportable. Isolation therefore gets dedicated test coverage, negative tests ("prove A cannot reach B"), and penetration testing before go-live.

**Two user populations — the defining design problem.**
- **Client users** (a client's own staff): scoped to exactly one tenant; they never see anything else.
- **Provider users** (our operations team): a single processor may be *assigned to several clients* and work Client A's cases one day, Client B's the next. We model this with a **`tenant_membership`** table (user × tenant × role). A provider user's reach is the set of tenants they're assigned; the **audit trail records every action per tenant** regardless. Least-privilege still applies — nobody gets all tenants by default.

**Almost everything is per-tenant configuration.** Each client is a distinct MAH with its own:
- **QPPV** and **PSMF** (Pharmacovigilance System Master File) — the platform supports per-tenant QPPV and must produce per-tenant audit trails, metrics, and records for *that client's* PSMF and inspections.
- **Reference safety information** (CCDS/CCSI/label) per product — so **expectedness is tenant-and-product-specific**, never global.
- **Gateway registrations and credentials** — we submit to FAERS/EudraVigilance/MHRA **under each client's own identity/registration**, brokered by the platform and governed by that client's **SDEA/PVA**. Credentials are per-tenant secrets, never shared.
- **Reporting rules, workflows, retention, dictionary versions, and (potentially) data residency.**

**Operational / commercial surface this enables.**
- Per-tenant **SLA + compliance dashboards** (on-time submission rate per client — the metric clients and regulators judge).
- **Tenant onboarding/offboarding**: a client is configured in, and on exit their data is **exportable and removable** (clients own their data) — designed in, not retrofitted.

**Implications that ripple into other sections** (noted so they aren't lost):
- *Validation (§4.4):* the platform is validated once, but **per-tenant configuration needs its own change control and qualification**.
- *Residency (§7.3):* different clients may have different residency obligations — this interacts with the US/EU topology decision (D2).
- *Risk (§11):* tenant isolation is now the single highest-consequence failure mode.

---

## 4. Compliance architecture (the part no BaaS gives you)

This is where a PV system earns inspector trust. All of this is *built*, not inherited.

### 4.1 Audit trail (ALCOA+ by construction)

- A dedicated **append-only `audit` schema**. Every INSERT/UPDATE/DELETE on regulated tables fires a trigger that writes a row capturing: table, record id, operation, **before** and **after** values (JSONB), the acting user, timestamp (server UTC, contemporaneous), and the reason-for-change where required.
- Audit rows are **immutable**: no UPDATE/DELETE grants to any application role; RLS + revoked privileges enforce this. Even service roles cannot rewrite history.
- Time is **server-authoritative** (never client clocks) — satisfies *Contemporaneous*.
- Retention: audit data kept for the full regulatory retention period and never hard-deleted. **[REG DECISION]** Confirm retention duration per regime.

### 4.2 Electronic signatures (21 CFR Part 11 Subpart C / Annex 11)

- A signature is a distinct, **re-authenticated** act (not just a logged-in session): the signer re-enters credentials (or passes step-up MFA) at the moment of signing.
- Each signature record binds: **who**, **what** (record + version hash), **why** (meaning — e.g. "medical review approved"), and **when**, and is **cryptographically linked** to the signed record so it cannot be transferred or copied.
- Signature manifestation is visible on screen and in exports.
- Signed records become **version-locked**; further changes create a new version requiring a new signature.

### 4.3 Data integrity controls

- **Attributable:** every row carries created_by / updated_by; no shared accounts (enforced by Auth policy).
- **Original & Accurate:** source documents stored immutably in Storage with checksums; links from case to source preserved.
- **Complete/Consistent/Enduring/Available:** foreign keys + check constraints; point-in-time recovery (PITR) backups; documented restore drills.

### 4.4 Validation (GAMP 5 / CSA)

- Risk-based: the AI-suggestion components are **lower-impact** (human confirms output); the audit trail, e-signature, clock, and submission components are **high-impact** and get the most rigorous OQ/PQ.
- Deliverables: Validation Plan → URS (your requirements) → FS/DS (this doc, matured) → IQ/OQ/PQ → Traceability Matrix → Validation Summary Report.
- **Environments:** strict separation of **Dev → Validation (QA) → Production**, with change control between them. Production changes only via controlled releases.
- **[REG DECISION]** You own the URS and the validation deliverables content; I own the technical test scripts and system documentation.

### 4.5 AI-specific governance

- Every AI output is stored with: model/version, prompt inputs, timestamp, and a **human disposition** (accepted / edited / rejected + by whom). This makes AI assistance fully auditable.
- AI never writes directly to a regulated field as "final"; it writes to a *suggestion* field that a human promotes. The promotion is the auditable event.
- PHI/PII sent to any LLM is governed by a documented data-handling policy and the provider's terms (no training on data; appropriate DPA). **[REG DECISION]** Approve the AI data-handling policy and provider terms.

---

## 5. AI touchpoints (augment, don't replace)

| # | Capability | What AI does | Human decision retained | Headcount effect |
|---|---|---|---|---|
| 1 | **Case intake extraction** | Parse emails, PDFs, call transcripts, forms → draft structured ICSR fields | Processor confirms/corrects every field | High — removes manual data entry |
| 2 | **MedDRA/WHODrug coding suggestions** | Propose LLT/PT codes and drug matches with confidence | Coder confirms; final code is signed | High — coding is slow manual work |
| 3 | **Duplicate & follow-up detection** | Flag likely duplicates/follow-ups across the database | Processor confirms the link | Medium |
| 4 | **Seriousness / expectedness first pass** | Draft seriousness criteria + expectedness vs. reference safety info | Medical reviewer decides and signs | Medium — speeds triage |
| 5 | **Narrative drafting** | Generate the case narrative from structured data | Reviewer edits and approves | High — narratives are time-consuming |
| 6 | **Translation** | Translate source material and narratives | Reviewer verifies clinical accuracy | Medium |
| 7 | **Literature screening** | Screen literature hits for ICSR relevance | Human confirms relevance | High for lit-heavy products |
| 8 | **Pre-submission QC** | Business-rule + E2B(R3) validation, completeness, consistency checks | QA reviews flags | Medium — reduces rework |
| 9 | **Signal detection assist** (Phase 3+) | Disproportionality + pattern surfacing | Safety physician assesses | Future |

**Hard line:** items that constitute a regulatory decision (4, 8-sign-off, and all submissions) always end in a named human + e-signature. This is both a compliance requirement and the thing that keeps the system defensible.

---

## 6. Case lifecycle (state machine)

The case moves through explicit, auditable states. Transitions are permissioned and often require e-signature.

```
   NEW ──► TRIAGE ──► DATA ENTRY ──► MEDICAL REVIEW ──► QC ──► APPROVED ──► SUBMITTED ──► CLOSED
    │         │           │               │             │         │            │
    │         └───────────┴───────────────┴─────────────┴─────────┘            │
    │                        (follow-up re-opens / new version)                │
    └──────────────────────────► REJECTED / NOT A VALID CASE ◄─────────────────┘
```

- **Day-zero** is captured at intake and drives the **reporting clock** per regime (a case may have different clocks for FDA/EMA/MHRA simultaneously).
- `pg_cron` jobs evaluate clocks and surface **due/overdue** warnings; nothing auto-submits without human authorization.
- Follow-up information creates a **new case version**, preserving the prior state (versioning + audit).

---

## 7. Data model (overview — detailed DDL comes in the schema phase)

Aligned to E2B(R3) so export is a mapping, not a translation. **Every regulated table below carries a `tenant_id`** (§3.2) — omitted from each line for brevity but assumed throughout, and enforced by RLS.

### 7.1 Core entities

- **tenant** — one client company (MAH): name, QPPV details, PSMF reference, residency/region, status, SDEA metadata, retention policy.
- **case** — the ICSR envelope: safety report id, case version, type (spontaneous/study/literature), seriousness, day-zero, status, source country, per-regime clock state.
- **reporter** — primary source(s), qualification, consent flags.
- **patient** — de-identified demographics, age/age-group, sex, relevant medical history, pregnancy status.
- **drug** — suspect/concomitant/interacting; WHODrug coding; dosage, route, dates, action taken, dechallenge/rechallenge, causality per drug-event pair.
- **adverse_event** (reaction) — reported term + MedDRA LLT/PT coding; onset/outcome; seriousness criteria; expectedness.
- **assessment** — causality, seriousness, expectedness decisions with author + signature.
- **narrative** — versioned free text (and the AI-draft lineage).
- **source_document** — immutable stored originals (Storage) + checksums, linked to case.
- **submission** — one row per (case version × destination regime): payload, ack (E2B ACK/MDN), status, timestamps.
- **product** / **substance** — product dictionary (links to XEVMPD/Article 57 data for EU).

### 7.2 Supporting / compliance entities

- **audit_log** (append-only, audit schema) — §4.1.
- **e_signature** — §4.2.
- **ai_suggestion** — model, version, inputs, output, human disposition — §4.5.
- **tenant_membership** — user × tenant × role (§3.2); lets a provider user be assigned to several clients while isolation and per-tenant audit hold.
- **tenant_config** — per-tenant settings: reporting rules, gateway credentials (as secret references, not values), dictionary versions, workflow options, reference-safety-information pointers.
- **user_role** / **permission** — RBAC backing RLS.
- **coding_cache** — licensed dictionary lookups (MedDRA/WHODrug) kept within license terms.

### 7.3 Data residency & GDPR

- EU/UK personal data points toward an **EU-region Supabase project**. Two candidate topologies — decision in §12:
  - **(A) Single EU-region project** serving all regimes (simplest; US data also resides in EU — confirm acceptability).
  - **(B) Two projects (US + EU)** with a shared app layer and careful cross-border controls (cleaner residency story, more ops + more validation surface).
- Either way: documented **data map**, DPAs with Supabase and the LLM provider, pseudonymisation of patient data (PV already minimises identifiers), and defined data-subject-rights handling.
- **[REG DECISION]** Residency acceptability and the lawful basis / DPA posture are yours to confirm.

---

## 8. Integrations

| Integration | Direction | Notes |
|---|---|---|
| **E2B(R3) build & validate** | internal | Edge Function generates the ISO/HL7 ICSR XML from the data model and validates against the schema + business rules *before* anything leaves. |
| **FDA ESG → FAERS** | outbound | AS2/gateway submission; handle ACK and MDN; store receipts. |
| **EudraVigilance (EMA)** | outbound | EVWEB/gateway; EV-specific acknowledgements; registration/OMS considerations. |
| **MHRA Gateway** | outbound | UK ICSR submission; separate credentials/clock. |
| **MedDRA (MSSO)** | inbound ref | Licensed dictionary import; version management (MedDRA updates twice yearly). |
| **WHODrug (UMC)** | inbound ref | Licensed drug dictionary; version management. |
| **LLM (Claude)** | brokered | All AI calls go through an Edge Function so inputs/outputs are logged (§4.5) and data-handling policy is enforced. |

**[REG DECISION]** Gateway accounts/registrations (ESG, EudraVigilance, MHRA) and dictionary licenses are organisational/regulatory prerequisites you'll need to procure — I can't provision these.

---

## 9. Security & access control

- **Tenant isolation (§3.2) is the primary security boundary.** RLS enforces default-deny by `tenant_id`; provider users reach only their assigned tenants via `tenant_membership`; client users reach only their own. Negative tests ("A cannot reach B") are part of the test suite, and tenant isolation is an explicit pen-test objective.
- **RBAC** roles (Intake, Processor, Medical Reviewer, QPPV, QA, Admin, read-only Auditor) backing **RLS** policies in Postgres — roles are scoped *within* a tenant.
- **MFA** mandatory for all users; **SSO** for enterprise (Supabase paid).
- Principle of least privilege; **no shared accounts** (attributability).
- Secrets (gateway creds, LLM keys) in Edge Function secrets / a managed secret store — never in the database or client.
- All access and security-relevant events captured in the audit trail.
- Penetration test + security review before production (and after material change).

---

## 10. Build roadmap (phased, validation-aware)

Each phase ends with something concrete and keeps the validation story coherent.

- **Phase 0 — Foundations (this doc + URS).** Align architecture ↔ your URS; confirm the §12 decisions. *Exit: signed-off design + validation plan outline.*
- **Phase 1 — Core data model & audit spine.** PostgreSQL schema, append-only audit, RLS, e-signature primitive, versioning. *Exit: a case can be created, edited, and every change is auditable.*
- **Phase 2 — Case lifecycle + intake UI.** The state machine, manual intake, document upload, basic case processing screens. *Exit: a case goes NEW → APPROVED by hand.*
- **Phase 3 — E2B(R3) + first gateway.** Build/validate E2B(R3); wire **one** gateway end-to-end (likely FAERS or MHRA as simplest first). *Exit: a validated submission with stored ACK.*
- **Phase 4 — Remaining gateways + clocks.** EudraVigilance + the third gateway; per-regime compliance clocks and due/overdue surfacing. *Exit: tri-regime reporting.*
- **Phase 5 — AI assist (incremental).** Intake extraction → coding suggestions → narrative drafting → QC, each with human-in-the-loop and full AI-governance logging. *Exit: measurable manual-effort reduction.*
- **Phase 6 — Validation & go-live.** IQ/OQ/PQ, traceability, security test, SOPs, training, Validation Summary Report. *Exit: production, validated.*
- **Phase 7+ — Periodic reports, signal management (GVP IX), analytics.**

---

## 11. Honest risks & trade-offs

- **Validation effort dominates.** The software is maybe 40% of the work; validation, SOPs, and documentation are the rest. Budget for it.
- **Gateways are finicky and their test environments are gatekept.** Real integration testing requires regulator sandbox access and registrations that take lead time — start procurement early.
- **MedDRA/WHODrug licensing + versioning** is an ongoing operational commitment, not a one-off.
- **"Reduce personnel" has a floor.** QPPV and qualified assessors are non-negotiable. AI reduces headcount by removing drudgery; it cannot remove accountable humans. Over-claiming here is a reputational and inspection risk.
- **Managed-service lock-in / control trade-off.** Supabase Cloud is fast to build on but we don't own the infra; self-hosting later is possible (it's open source) but is a migration, not a flip of a switch.

---

## 12. Open decisions (need your input to proceed)

| # | Decision | Owner | Why it matters now |
|---|---|---|---|
| D1 | Launch reporting scope: ICSR expedited only, or also periodic (PBRER/PADER) in v1? | REG | Sizes Phase 3-4. |
| D2 | Data residency topology: single EU-region project (A) vs US+EU split (B)? Now also: can *different tenants* have different residency needs? | REG + ENG | Shapes the whole deployment and validation surface; interacts with multi-tenancy. |
| D8 | Client-user access: do client companies' own staff log into the platform (self-service), or is it provider-staff-only (pure BPO)? | REG/BIZ | Changes how much client-facing UI and per-tenant RBAC we build. |
| D9 | Tenant offboarding: required data export format and deletion/retention rules on client exit. | REG | Clients own their data; must be designed in. |
| D3 | Is a Supabase BAA/DPA required and acceptable for your data? | REG | Gate on using Supabase Cloud at all. |
| D4 | AI data-handling policy + LLM provider terms approval. | REG | Gate on any AI feature touching case data. |
| D5 | Which gateway do we wire first (FAERS / EudraVigilance / MHRA)? | REG + ENG | Determines Phase 3 target. |
| D6 | Retention periods per regime. | REG | Audit + storage design. |
| D7 | Expected case volume / concurrency at launch and in 2 yrs. | REG/BIZ | Sizing + plan tier. |

---

## Appendix A — Glossary (selected)

- **ICSR** — Individual Case Safety Report.
- **E2B(R3)** — ICH standard (ISO/HL7-based) for electronic transmission of ICSRs.
- **FAERS** — FDA Adverse Event Reporting System.
- **EudraVigilance** — EMA's EU ICSR database/system.
- **QPPV** — Qualified Person for Pharmacovigilance.
- **MedDRA / WHODrug** — licensed dictionaries for event / drug coding.
- **ALCOA+** — data-integrity principles.
- **GAMP 5 / CSA** — computerised-system validation framework / FDA's risk-based assurance approach.
- **RLS** — PostgreSQL Row-Level Security.

---

*This is v0.1 — a design to react to, not a finished spec. The most useful next thing you can do is mark up §2 (regulatory accuracy) and answer §12. Then we move to Phase 1: the data model.*
