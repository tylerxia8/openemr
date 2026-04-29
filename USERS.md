# Users — Clinical Co-Pilot

This document defines the target user, the moment in their day when the Co-Pilot enters, and the specific use cases the agent will serve. Per the case study, every capability built in `ARCHITECTURE.md` must trace back to a use case here. Capabilities not justified by a use case are not built.

---

## Target User

**Dr. Maya Chen, MD — Primary Care Physician at a mid-sized outpatient clinic.**

- 8 years post-residency, internal medicine, 0.8 FTE clinical.
- Panel of ~1,400 patients; sees about 20 per clinic day.
- Patients skew older (median age 58), multi-comorbid, polypharmacy common.
- Uses OpenEMR daily. Comfortable with computers, not interested in tools that require special training.
- Has been burned by a previous "AI scribe" pilot that hallucinated a medication. Trust is the whole game for her.

Why this persona and not the others (ED resident, hospitalist):

- **PCPs see the same patients repeatedly.** "What changed since last visit" is a question that has a meaningful answer, and the agent's job is well-defined: surface the delta. For an ED resident seeing undifferentiated patients for the first time, the question is "what is this person?" — a fundamentally harder retrieval problem with a different evidence base.
- **The 90-second window is real and recurring.** A PCP hits this gap 20 times a day. A hospitalist hits it 12 times a morning. An ED resident hits a different problem (acute triage). The PCP's pain is the most directly addressable with structured data retrieval, which is what we have.
- **The data model favors us.** Outpatient continuity data — meds, labs, problem list, last visit — is exactly the data OpenEMR's FHIR API exposes well. Inpatient hospital course data is poorly modeled in OpenEMR; ED triage data isn't really represented.

This persona maximizes the alignment between the case study's "90 seconds between rooms" framing, the data we can actually retrieve cleanly, and the user's reason to trust a verified-grounded agent.

---

## A Day in Dr. Chen's Workflow

### 7:30 AM — Arrive

Coffee, check today's schedule. 22 patients, including 3 same-day add-ons, 1 new patient, and 18 returning. She has not seen 9 of these returning patients in over six months.

### 7:45–8:15 AM — Chart Prep ("Pre-Visit Planning")

Currently, she opens each chart, scans the last note, eyeballs the medication list, looks for any new labs or messages. She gets through about half the panel before the first patient arrives. The half she didn't pre-prep, she'll prep in the 90 seconds before the room.

**This is where the Co-Pilot earns its keep.**

### 8:15 AM — First Patient

She walks toward exam room 3, taps the patient's name in OpenEMR, and has 60–90 seconds before opening the door. Her question is rarely "tell me everything." It is one of:
- "Why are they here today?"
- "Anything important happen since I last saw them?"
- "Is there anything I'm going to forget to address?"

### Throughout the Day

Between every patient: a similar 60–90 second window. Every visit produces follow-ups (orders, refills, referrals). Documentation accrues. By 5 PM she has 8 unfinished notes; by 7 PM, "pajama time" — finishing notes from home.

### Pain Points the Co-Pilot Targets

| Pain | Frequency | Current workaround |
|---|---|---|
| Can't remember what changed since last visit | Every patient | Read the last note; hope she wrote it well |
| Lab trends require flipping screens | 5–10× per day | Open separate tab to flowsheet |
| Med list shows what's prescribed, not what's actually being taken | Every visit | Ask the patient |
| Overnight ED visits surface late or not at all | 2–3× per week | Catch-up at a later visit |
| Specialist letters buried in documents tab | Multiple per day | Skip unless something prompts her to look |

### Pain Points Explicitly Out of Scope

- Note documentation / scribe functionality. (Different agent, different verification model.)
- Order entry. Anything that writes back to the EMR is week 2/3.
- Generic medical reference ("what's the dose of metformin?"). UpToDate exists; we don't compete with it.
- Real-time clinical decision support during the visit. The Co-Pilot is for the moment _before_ the room, not for inside the room.

---

## Use Cases

Each use case below specifies (a) the trigger, (b) what the agent does, (c) why a conversational agent is the right shape — and not a dashboard, sorted list, or chart-view improvement.

### UC-1: Pre-Visit Briefing

**Trigger.** Dr. Chen clicks the patient on her schedule and types "brief me" or simply opens the Co-Pilot panel for that patient. Time budget: ~5 seconds to first useful content; ~15 seconds to complete answer.

**What the agent does.** Returns a 4–6 line briefing covering: reason for today's visit (from appointment), most recent encounter date and gist, problem list highlights (filtered by what's most likely relevant to today), any new labs since last visit, current med list with any changes since last visit, and any flags (overdue screening, missed appointment, ED visit).

**Why an agent and not a dashboard.** A dashboard requires Dr. Chen to know what to look for. The clinically-relevant signal differs per patient: for a diabetic with a new A1c, the A1c is the headline; for a CHF patient with weight changes, weight is the headline; for a stable hypertensive, "nothing changed" is the headline and is itself useful. A static dashboard treats every field as equally important and forces her to scan. The agent's job is the triage.

**Why this can't just be a "summary" generated server-side and shown statically.** Because she will follow up. ("What was that A1c again? Trend over the last year?") That follow-up is the agent's reason for being conversational.

**Tools required.** `get_patient_summary`, `get_problem_list`, `get_medication_list`, `get_recent_labs`, `get_recent_encounters`, `get_appointment_for_today`. Several are parallelizable.

**Verification requirements.** Every fact in the briefing must be source-attributed (patient record id + retrieval timestamp). The "any flags" section must distinguish between "data says X" and "data is silent on X."

### UC-2: What Changed Since Last Visit

**Trigger.** "What's new since I last saw her?" — typed or follow-up after UC-1.

**What the agent does.** Identifies the date of the last encounter the user (or any clinician) had with this patient. Surfaces only changes since that date: new diagnoses, new/stopped medications, new labs (with reference range delta), new specialist letters, new ED or hospital encounters.

**Why an agent.** This requires reasoning over time and across data types. A "recent activity" feed dumps everything chronologically; the agent decides what counts as a meaningful change. A med dose adjustment is a change; a med refill is not. A lab outside reference range is a change worth noting; one inside isn't.

**Tools required.** `get_recent_encounters` (filtered by date), `get_medication_changes_since`, `get_lab_changes_since`, `get_problem_list_changes_since`, `get_external_records_since` (if available).

**Verification requirements.** Date filtering is itself a verifiable claim ("since [date]"). Any "change" claim must reference both the prior and current state record. Refills must be excluded from "changes" by definition, with that decision explicit in the verification log.

### UC-3: Lab Interpretation in Context

**Trigger.** "Is this A1c trend concerning?" or "What's been happening with her creatinine?"

**What the agent does.** Pulls the time series for the named lab(s), shows the values with dates and reference ranges, and provides a constrained interpretation: direction, magnitude relative to normal, and any correlated changes (new medication, new diagnosis) that might explain it. The agent does **not** issue clinical recommendations.

**Why an agent.** The interpretation requires correlating multiple data sources (labs + meds + problems) and applying domain rules (what counts as a meaningful change for A1c vs. creatinine). A static graph shows the values but not their meaning. The clinician still owns the interpretation; the agent provides the evidence packet.

**Tools required.** `get_lab_history`, `get_medication_history`, `get_problem_list`, `evaluate_clinical_thresholds` (a deterministic rule-engine tool, not an LLM).

**Verification requirements.** Direction claims ("trending up") are verifiable from the data points. Threshold claims ("above goal for diabetic patients") use a rule table and cite which rule applied. The agent refuses to make recommendations; it provides evidence.

### UC-4: Medication Reconciliation

**Trigger.** "What is she actually on?"

**What the agent does.** Synthesizes the active medication list from prescriptions, flags any disagreements with recently imported records (hospital discharge, specialist letters), and surfaces the date and prescriber for each medication. If a medication appears in one source but not another, that conflict is shown explicitly.

**Why an agent.** Medication reconciliation is fundamentally a reasoning-over-conflicting-sources problem. The current EMR shows the prescription list; it does not surface that the discharge summary lists a different dose. A list view treats every entry as authoritative; the agent reasons about provenance and conflict.

**Tools required.** `get_active_medications`, `get_recent_documents` (for discharge summaries), `get_medication_history`. RxNorm normalization is a stretch goal — without it, name-string matching is brittle.

**Verification requirements.** Every medication claim cites its source record and source date. Conflicts must be explicit, not silently resolved. If a medication can't be confirmed in a structured record, the agent says so.

### UC-5: Authorization Boundary (Refusal Test)

**Trigger.** A user (e.g., a medical assistant role with limited patient access) asks the agent about a patient outside their assigned panel, or asks about data they aren't permitted to see.

**What the agent does.** The FHIR API returns 403; the agent surfaces a refusal that explains _that_ access was denied without leaking _what_ would have been there. It does not retry, does not infer, does not synthesize from cached context.

**Why this is a use case, not just a test.** The case study explicitly calls out multi-user environments as the norm. Demonstrating that the auth boundary holds — visibly, in the product — is part of the trust model the user (and a hospital CTO) must see working. This use case has zero LLM cleverness; it is mostly a UX problem (how to refuse helpfully) and an architectural one (the agent never sees data it shouldn't).

**Tools required.** Any retrieval tool, all of which propagate the 403.

**Verification requirements.** The verification layer must catch any attempted response that includes information from a denied resource — even if cached from an earlier turn under a different identity. Session boundaries must be enforced.

---

## Capability → Use Case Trace

| Capability | Justifying use cases |
|---|---|
| Multi-turn conversation | UC-1 → UC-2 → UC-3 (briefing, then drill-downs) |
| Tool chaining | UC-2 (date-filter then change-detect), UC-3 (labs + meds correlation) |
| Source attribution | All use cases |
| Domain rule engine | UC-3, UC-4 |
| Refusal handling | UC-5; also UC-1–4 when data is missing |
| Streaming responses | UC-1 (first content < 5 seconds) |
| Conversation memory within session | UC-2, UC-3 (follow-ups) |

If `ARCHITECTURE.md` proposes a capability not in this table, it gets cut.

---

## Out of Scope (Capabilities Not Justified)

These are tempting but do not yet have a use case:

- **Multi-patient queries** ("show me all my diabetics with rising A1c"). Powerful but a different product surface; needs its own user research.
- **Long-term memory across sessions.** The agent is per-conversation. Cross-conversation memory introduces consent, retention, and stale-context risks not addressed in the data model.
- **Proactive notifications.** "Push" surface, different UX, different consent model.
- **Voice input.** Until measured, we don't know whether 90-second-window users prefer typing or talking. Default: typing, because typing is silent and the room is across the hall.

---

## Acceptance Criteria for Each Use Case

Each use case must, in evaluation:

1. Return a response in which every clinical claim is source-attributed.
2. Distinguish present / absent / conflicting data.
3. Refuse — visibly — when data is unavailable or access is denied.
4. Hit latency targets: first content < 5s for UC-1; full response < 15s for any use case.
5. Pass adversarial prompts that try to extract data outside the user's authorization scope.

These criteria become the eval suite specified in `ARCHITECTURE.md`.

---
