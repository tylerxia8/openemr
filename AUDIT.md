# OpenEMR Audit — AgentForge Clinical Co-Pilot

**Scope.** Audit of OpenEMR 7.x (forked from `openemr/openemr` on GitHub) as the host for an AI agent that will read PHI on behalf of authenticated clinicians. Findings are based on the published codebase, OpenEMR documentation, the OpenEMR security advisory history, and inspection of the locally deployed instance. Items marked _[verify]_ must be re-checked against the specific deployment configuration.

---

## Summary of Key Findings (~500 words)

OpenEMR is a mature, broadly-deployed open-source EHR. It is functional, FHIR R4-capable, and has a real authorization model — but it carries the security debt of a 20-year-old PHP monolith, and its data quality assumptions are far weaker than an AI agent can safely trust by default. The audit produced five findings that materially shape the AI integration plan.

**1. The ACL system is the trust boundary, and it is fit for purpose — _if_ the agent never bypasses it.** OpenEMR's `acl_check()` function (`library/acl.inc.php`) gates every authenticated UI and API request. The FHIR R4 endpoint (`/apis/default/fhir`) inherits this via OAuth2. **Decision driver:** the agent service must access patient data exclusively through the FHIR API using the calling clinician's OAuth token. It must not hold a privileged DB connection or service account. This is the single most important architectural decision in the AI plan and traces directly to the case study's authorization requirement.

**2. PHI surfaces are wider than they look.** Patient data is fragmented across at least eight tables (`patient_data`, `lists`, `prescriptions`, `procedure_result`, `form_encounter`, `pnotes`, `immunizations`, `history_data`) plus free-text fields and uploaded documents. The FHIR translation layer covers most but not all of this. **Implication:** the agent will have visibility gaps. The architecture must declare what is and isn't accessible and refuse to speculate beyond it.

**3. Audit logging exists but is not uniformly enforced and is not designed for AI access patterns.** The `log` and `audit_master` tables capture most write operations and many reads, but coverage of FHIR endpoints is incomplete _[verify per deployment]_, and there is no log schema for "an LLM read these N records to answer this query." We must add an application-level audit log in the agent service that records every retrieval, every prompt, every response, and the user who triggered it — and feeds it back into OpenEMR's compliance surface.

**4. Performance is bounded by the FHIR translation layer, not the agent.** OpenEMR's FHIR responses involve PHP-side translation from internal schemas; cold patient queries routinely take 400–1500ms _[verify]_. With multi-tool agent flows, naive implementation produces 5–10s response times — unacceptable for the "90 seconds between rooms" use case. **Mitigation in plan:** parallel tool calls where independent, a thin in-memory cache keyed on `(patient_id, resource_type, user_token_hash)` with short TTL, and prompt caching on the LLM side for the static system prompt and patient summary.

**5. Data quality cannot be assumed; it must be surfaced.** Free-text encounter notes, optional ICD-10 coding on problem lists, drug names not always normalized to RxNorm, and inconsistent lab unit reporting all mean the agent will encounter ambiguous, incomplete, or conflicting data. The verification layer must distinguish "the record says X" from "the record is silent on X" from "two records disagree about X" and must communicate that distinction to the clinician. Hallucination risk in this domain is largely a function of how the agent handles missing data, not how it handles present data.

These five findings are the load-bearing constraints. Everything in `ARCHITECTURE.md` traces back to them.

---

## 1. Security Audit

### 1.1 Authentication

- **Default credentials.** A fresh OpenEMR install ships with a well-known default admin account. The setup wizard prompts for change, but environments where setup is automated may skip this.
  - _Risk:_ High in any deployment where the setup wizard is bypassed.
  - _Mitigation:_ Force credential change in deployment scripts; add a startup check that refuses to serve traffic if the default password hash is detected.
- **Password hashing.** OpenEMR uses bcrypt for user passwords (`users_secure` table) in current versions. _[verify version-specific algorithm]_
- **2FA.** Optional, off by default. The TOTP implementation is functional but enrollment is manual per user.
  - _Recommendation:_ For our deployment, require 2FA for any user assigned a role that can use the AI agent.
- **Session management.** Standard PHP sessions, file-backed by default. Session fixation and session hijacking risks depend on cookie flags (`Secure`, `HttpOnly`, `SameSite`) which are configurable but not always set in default `php.ini`.
  - _Action:_ Verify cookie flags in deployment; force `SameSite=Strict` and `Secure` over HTTPS-only.
- **API authentication.** The FHIR API uses OAuth2 via the built-in authorization server (`src/RestControllers/AuthorizationController.php`). This is the correct surface for the agent.

### 1.2 Authorization

- **ACL system (`acl_check()`).** OpenEMR's authorization is role + permission-based, originally derived from phpGACL. It is enforced at the application layer, not the database. Every controller and API route that handles PHI must call `acl_check()` — and historically, missed calls have been the source of authorization-bypass CVEs. _[verify all FHIR routes call ACL]_
- **Trust boundary.** The ACL is enforced in OpenEMR's PHP layer. _If our agent service queries the database directly with a service account, it bypasses the entire ACL system._ This is unacceptable, and the architecture must prevent it by construction (no DB credentials issued to the agent service).
- **Patient–provider relationship enforcement.** The codebase distinguishes "all patients" vs. "assigned patients" via the `users.access_control` and patient assignment tables. The agent must respect these — so when a clinician asks about a patient they're not assigned to, the FHIR API will return 403 and the agent must surface that gracefully, not hallucinate a refusal.

### 1.3 Data Exposure Vectors

- **Historical CVE classes.** OpenEMR has had a sustained stream of advisories: SQL injection in administrative endpoints, stored XSS in patient demographic fields, IDOR in legacy report exports, and remote code execution via file upload paths. Recent versions have hardened these significantly, but legacy modules under `interface/` are large and not all paths are equally well-reviewed. _[Verify against the `openemr/openemr` Security Advisories on GitHub for the specific version pinned.]_
- **Stored XSS in PHI fields.** Patient names, notes, and free-text fields are rendered into the agent's chat UI. If an attacker (or a sloppily-imported record) puts a `<script>` payload into a name field, the chat UI must not execute it. **Mitigation:** the agent UI treats all retrieved PHI as untrusted text; renders via React's default-escaped JSX, never `dangerouslySetInnerHTML`.
- **File uploads.** Documents attached to patient records are stored on disk. Any agent feature that reads attachments must validate MIME types and never execute or interpret content beyond text extraction. _Out of scope for week 1 but flagged for week 2._

### 1.4 Network & Transport

- **HTTPS.** Not enforced by the application; depends on the reverse proxy (Nginx/Apache) configuration. _Action:_ deployment script terminates TLS at the proxy and redirects HTTP→HTTPS.
- **Database in transit.** MariaDB connection from PHP defaults to local socket or unencrypted TCP. In our containerized deployment, both run inside a private Docker network, mitigating exposure but not eliminating compromise-of-host risk.
- **Encryption at rest.** Not provided by the application. Depends on host disk encryption / volume encryption in the cloud provider.

---

## 2. Performance Audit

### 2.1 Database

- **MariaDB / MySQL** is the backing store. Many tables are wide and not always optimally indexed for AI-style query patterns (e.g., "all medications for patient X over the last 90 days, joined with prescriber info").
- **Known slow paths:**
  - Patient search across the full demographics table — sometimes triggers full table scans on certain configurations.
  - Encounter-list rendering for high-volume patients (long histories).
  - Report generation paths in `interface/reports/`.
- **Index gaps to verify** _[verify on local instance]_: `prescriptions(patient_id, date_added)`, `lists(pid, type, date)`, `procedure_result(procedure_order_id)`. Missing indexes here directly slow agent retrieval.

### 2.2 FHIR Translation Layer

- **The single largest latency contributor for our use case.** OpenEMR's FHIR endpoints translate from internal schemas to FHIR R4 resources at request time. There is no FHIR-native cache.
- Observed latency on a stock local install: cold patient summary queries 400–1500ms, individual resource lookups 80–300ms _[verify on deployed instance]_.
- **Architectural consequence:** the agent will frequently need 4–8 FHIR calls per turn (Patient, Conditions, MedicationRequests, Observations, AllergyIntolerances, Encounters, DocumentReferences). Sequential calls = unworkable latency. Parallelization and caching are required, not optional.

### 2.3 PHP Application Layer

- PHP-FPM with a typical pool of 5–20 workers. Single-threaded per request.
- Smarty template rendering is server-side; some pages do additional DB calls inside templates, creating N+1 patterns in legacy modules.
- For our purposes, the agent does not render through Smarty — it talks to the FHIR API — so this layer mostly matters for the OpenEMR pages the clinician is using when they invoke the agent.

### 2.4 Frontend

- jQuery + Bootstrap-era frontend; not directly relevant to our React-based chat UI module, which will load as a separate bundle inside an OpenEMR module page.

---

## 3. Architecture Audit

### 3.1 High-Level Topology

```
┌─────────────────────────────────────────┐
│ Browser (clinician)                     │
└─────────────┬───────────────────────────┘
              │ HTTPS, session cookie
┌─────────────▼───────────────────────────┐
│ Apache / Nginx → PHP-FPM                │
│ ┌────────────────────────────────────┐  │
│ │ OpenEMR (PHP monolith)             │  │
│ │  - interface/  (UI controllers)    │  │
│ │  - library/    (shared libs, ACL)  │  │
│ │  - src/        (newer namespaced)  │  │
│ │  - apis/       (REST + FHIR)       │  │
│ │  - modules/    (custom modules)    │  │
│ └────────────────────────────────────┘  │
└─────────────┬───────────────────────────┘
              │ MySQL protocol
┌─────────────▼───────────────────────────┐
│ MariaDB                                 │
└─────────────────────────────────────────┘
```

### 3.2 Where Code Lives

- `interface/` — legacy UI controllers and Smarty templates. Big, organic, mixed concerns. **This is where most of the historical code lives.**
- `library/` — shared utility libraries. `acl.inc.php` lives here; it is invoked from `interface/` and `apis/`.
- `src/` — newer, PSR-4 / Composer-managed code. OAuth2 server, FHIR controllers, and recent features tend to live here.
- `apis/` — REST and FHIR routing entry points. `_rest_routes.inc.php` and the FHIR routes file map URLs to controllers in `src/RestControllers/`.
- `interface/modules/custom_modules/` — the supported integration point for third-party modules. **This is where our agent UI module will live.**

### 3.3 Integration Points for the Agent

There are three viable integration surfaces, in increasing order of separation:

1. **PHP module embedded in OpenEMR.** Tightest integration; uses session/ACL directly. Downside: agent code lives in PHP, far from the Python/JS ecosystem we want.
2. **JavaScript module embedded in OpenEMR + external agent service.** UI loads in OpenEMR; backend is a Python sidecar. **This is the chosen path.**
3. **Fully external app with SSO/OAuth.** Cleanest separation but loses OpenEMR's session context and forces clinicians to context-switch.

The chosen architecture (option 2) is detailed in `ARCHITECTURE.md`.

### 3.4 Existing Authentication & API Surfaces We'll Use

- **Session cookie** — passes from OpenEMR to the embedded module's iframe / page automatically.
- **OAuth2 authorization server** — issues short-lived access tokens. The agent UI requests one on load and forwards it on every call to the agent service. The agent service uses it to call FHIR.
- **FHIR R4 API** — the read surface for patient data. Read-only is sufficient for week 1 (no write operations are part of our scope).

---

## 4. Data Quality Audit

### 4.1 Structured Data — Reasonably Reliable but with Gaps

- **Demographics (`patient_data`).** Mandatory fields are filled; many optional fields (preferred language, race, ethnicity) are inconsistently populated.
- **Problem list (`lists` table, `type='medical_problem'`).** ICD-10 coding is _optional_ in the data model. Many problems are present as free text only.
- **Medications (`prescriptions`).** Drug name is captured as free text plus, optionally, RxNorm code. Real records often have the free-text name only, which makes drug-class reasoning and interaction checking unreliable without a normalization step.
- **Allergies (`lists`, `type='allergy'`).** Severity coding inconsistent. Reaction often free text.
- **Lab results (`procedure_result`).** Units of measure are present but not always standardized; reference ranges sometimes missing.

### 4.2 Free-Text — High-Volume, Low-Structure

- **Encounter notes (`form_encounter`, `form_soap`, `pnotes`).** SOAP format is suggested, not enforced. A large fraction of the clinical reasoning that matters for "what changed since last visit" lives in these notes.
- **Implication for the agent:** week 1 we ground primarily in structured data and surface the existence of recent notes without claiming to summarize them. Note summarization is a week 2/3 capability that requires its own verification approach.

### 4.3 Cross-Source Inconsistency

- Hospital discharge medications, refilled prescriptions, and patient-reported medications can disagree. The `prescriptions` table is the system-of-record but is not always reconciled.
- The agent must show its work: when it says "the patient is on Metformin 1000mg BID," it must cite the prescription record date and prescriber, not aggregate silently.

### 4.4 Stale Data

- No automatic data freshness markers. A medication record from 2019 looks the same as one from last week unless the agent inspects timestamps.
- **Mitigation:** every retrieved fact is annotated with its source record's last-modified date. The agent surfaces age explicitly in time-sensitive contexts ("last A1c on file: 8 months ago").

### 4.5 Duplicate Patients

- OpenEMR does not enforce strong patient-matching. Duplicate patient records exist in real-world deployments.
- _Out of scope for week 1; flagged for production._

---

## 5. Compliance & Regulatory Audit

### 5.1 HIPAA Posture of the Stock System

- **Audit log.** `log` and `audit_master` tables exist; coverage is broad but not complete for all FHIR read paths _[verify]_. HIPAA Security Rule §164.312(b) requires audit controls; current coverage is _adequate-with-gaps_.
- **Access controls.** ACL system satisfies §164.312(a)(1) in principle; deployment-specific role configuration is required.
- **Encryption.** The application provides no built-in encryption at rest or in transit; relies on infrastructure (HTTPS proxy, encrypted volumes). HIPAA does not strictly mandate encryption but requires it or an equivalent compensating control.
- **Integrity controls.** Database-level; no application-level tamper-evidence (no signed log chain).
- **Person/entity authentication.** Username/password plus optional 2FA. Adequate; recommend 2FA mandatory for AI-using roles.

### 5.2 Data Retention

- No automatic retention enforcement. Records persist until manually purged. HIPAA does not mandate destruction but state laws and organizational policies often do; this becomes the operator's responsibility.

### 5.3 Breach Notification Readiness

- No built-in tooling for breach detection or notification workflows. In an AI-augmented system this is a higher-stakes question because LLM access patterns are a new exfiltration vector.

### 5.4 BAA Implications of LLM Access

- **PHI is being sent to an LLM provider.** This is a HIPAA-covered transmission and requires a BAA with the LLM provider. The case study instructs us to _act as if_ a BAA is in place; in production we would verify this in writing with Anthropic before any real deployment.
- **Logging at the provider.** Even with a BAA, prompts and completions may be logged for abuse monitoring. The architecture must therefore minimize PHI in prompts where feasible (e.g., reference patient by internal pseudonymous ID where possible, only inline PHI when the model genuinely needs it to reason).
- **Self-hosted observability.** Langfuse self-hosted keeps full prompt/completion traces inside our HIPAA-covered infrastructure, never sending them to a SaaS observability provider. This is a deliberate architectural choice driven by this finding.

### 5.5 Patient Consent

- The data model has no representation of "this patient consented to their data being processed by an AI." For demo data this is moot; for production it is a real gap that must be addressed before clinical deployment.

---

## 6. Findings That Reshape the AI Plan

| Finding | Impact on architecture |
|---|---|
| ACL is the trust boundary | Agent accesses FHIR only, with user's OAuth token. No DB credentials. |
| FHIR translation is slow | Parallel tool calls + short-lived in-process cache + prompt caching mandatory. |
| Free text dominates clinical reasoning | Week 1 grounds in structured data only; surfaces note existence without summarizing. |
| Audit log gaps | Agent service maintains its own append-only audit log of every retrieval and response. |
| BAA / provider logging | Self-hosted Langfuse; minimize unnecessary PHI in prompts. |
| Data quality is inconsistent | Verification layer distinguishes _present_, _absent_, and _conflicting_ data and communicates the difference. |
| Stored XSS risk on PHI | Chat UI uses React default-escaped rendering only. |

---

## 7. Out-of-Scope For Week 1, Flagged for Later

- Free-text note summarization (requires its own verification design).
- Patient consent model for AI processing.
- Duplicate patient detection.
- Document/attachment ingestion.
- Write-back to OpenEMR (orders, notes).
- Real-time CDS during the encounter (vs. pre-visit briefing).

---

## Appendix A — Verification Checklist for Local Deployment

Items marked _[verify]_ above should be confirmed against the running instance:

- [ ] `php.ini` cookie flags: `session.cookie_secure`, `session.cookie_httponly`, `session.cookie_samesite`
- [ ] All FHIR routes in `apis/` invoke ACL checks
- [ ] Pinned OpenEMR version's GitHub Security Advisories reviewed
- [ ] Default admin password rotated; setup wizard re-disabled
- [ ] Indexes confirmed on hot-path tables (`prescriptions`, `lists`, `procedure_result`)
- [ ] FHIR cold-query latency measured on the deployed instance
- [ ] `log`/`audit_master` coverage of FHIR endpoints inspected

---
