# Clinic-demo interactive row-action / view-button audit
**Live app:** http://127.0.0.1:4000 (experience v2, basic catalog) · **Method:** Playwright 1280×800, deep shadow-DOM walks (a2ui lit components), before/after screenshots + DOM/text diffs + websocket frame capture; cross-checked against `lib/clinic_demo_web/a2ui/*.ex`, `deps/ash_a2ui/lib/ash_a2ui/action_handler.ex`, `experience.ex`, `encoder/v0_9_1.ex`.
**Actor states:** anon (fresh session) and actor-set (banner flow → `/a2ui/actor?id=…`; verified via the "No one is acting." banner clearing with a valid clinician).

Key coordinates of the failure space: the only feedback surface in the basic catalog is one `status_text` line at the **very bottom** of the page (`A2UI-BASIC-TEXT` bound to `/ui/feedback/message`). Measured y positions: /worklist y≈699 (visible), /schedule y≈1164, /patients y≈1100+, /intake y≈1649 (all **below the 800px fold**).

## The catalog

| surface | button | behavior | panel mode | visible? | verdict |
|---|---|---|---|---|---|
| / (Board) | View (per card) | click → server writes `/form`+`/ui/panel`, nothing renders (no form_slot emitted on form-less surfaces); zero DOM/text change | none | n/a | **dead** |
| / (Board) | Check in (via facade, scheduled cards) | not exercisable live (upstream booking broken, no scheduled rows); same delegate+feedback path as Discharge | n/a | n/a | other(untestable-live, feedback model broken as Discharge) |
| / (Board) | Complete (per checked-in card) | prompt modal (notes) — same modal contract as schedule; success feedback invisible | modal (prompt) | modal yes; feedback no | missing-save-contract→ other(see schedule/Complete) |
| / (Board) | Mark no-show (via facade, scheduled) | as Check in | n/a | n/a | other(untestable-live) |
| / (Board) | Cancel (per scheduled/checked-in card) | prompt modal (reason); confirm → invoke; success invisible | modal (prompt) | modal yes | missing-save-contract (feedback half) |
| / (Board) | Discharge (per completed card) | **actor:** invoke succeeds (`/records` refresh on the wire) but row looks identical (`:discharge` sets only `discharged_at`, not displayed; button stays) and success text written to `/ui/status`, which the v2 status Text (bound to `/ui/feedback/message`) never shows. **anon:** "You are not authorized…" at page bottom y≈1164 | n/a | **no** (success invisible; refusal offscreen) | **offscreen** (+ no-op-looking success) |
| /schedule | View (per row) | DEAD — as Board View (verified: 0 change) | none | n/a | **dead** |
| /schedule | Check in (via facade) | untestable live (no scheduled rows reachable); via-delegate path verified working for Discharge | n/a | n/a | other(untestable-live) |
| /schedule | Complete (checked_in rows) | prompt modal (notes): fields+Confirm render correctly; confirm → invoke; validation errors render inline in modal + bottom text; success invisible | modal (prompt) | modal yes; success no | missing-save-contract (feedback half) |
| /schedule | Mark no-show (via facade) | as Check in | n/a | n/a | other(untestable-live) |
| /schedule | Cancel (scheduled/checked-in rows) | prompt modal (reason); same as Complete | modal (prompt) | modal yes | missing-save-contract (feedback half) |
| /schedule | Discharge (completed rows) | verified on the wire: TX invoke → RX `/records`,`/query`,`/form`,`/errors`,`/ui/status="Action :discharge completed."` — DOM shows **nothing** (no visible field changed; status text not rendered by v2 binding); anon refusal at y≈1164 offscreen | n/a | **no** | **offscreen** |
| /worklist | A2ui complete (open/claimed tasks) | modal (outcome+comment) opens with correct contract (inline "is invalid", values retained, Confirm/Cancel/×). Confirm → **server crash**: host action pipes `record_id` into `Ash.get!/3` as the resource → `ArgumentError` → LiveView GenServer dies, surface remounts, client logs `A2uiStateError: Surface clinic_worklist already exists`. User sees nothing. **anon:** refusal "You are not authorized…" @y699 VISIBLE (short page) | modal (prompt) | modal yes; crash invisible | **dead** (500 masquerading as no-op) |
| /worklist | View (per row) | DEAD | none | n/a | **dead** |
| /visits | View (per row) | DEAD (verified) | none | n/a | **dead** |
| /patients | View (per row) | panel opens top-of-page (in viewport) with heading "View patient", record **populated into the standard editable form** (7 inputs, 0 disabled/readOnly), submit hidden, Cancel shown | panel — nominal **view**, actual **edit-minus-save** | yes (top) | **view-opens-edit** |
| /patients | Create patient | panel create mode: empty editable form + "Create patient" submit + Cancel — proper pair | panel create | yes | **correct** (but see anon-write gap) |
| /patients | Record weight (per row) | prompt modal (weight_kg) opens; Confirm → invoke **succeeds even with no actor** (Patient has no policies — Biscuit weight mutated 11.4→77.7 across anon probes); success feedback invisible | modal (prompt) | modal yes; feedback no | missing-save-contract (feedback half) + other(no-policy write gate gap) |
| /clinicians | View (per row) | same as patients: "View clinician" + populated editable form (name/license/role), no submit, Cancel | panel view≡edit | yes | **view-opens-edit** |
| /clinicians | Create clinician | proper create panel (submit+Cancel) | panel create | yes | **correct** |
| /clinicians | Retire (active rows) | invoke succeeds (Active flipped true→false on screen; button left the row — the row text change IS the only feedback); no success message; also authorized **anon** (no policies — demo data mutated by probe) | n/a | row change yes; message no | other(barely-visible success; no anon gate) |
| /processes | View (per row) | DEAD | none | n/a | **dead** |
| /decisions | View (per row) | DEAD | none | n/a | **dead** |
| /evaluations | View (per row) | DEAD | none | n/a | **dead** |
| /emergencies | View (per row) | DEAD | none | n/a | **dead** |
| /intake | Create appointment | panel opens top-of-page, create mode, submit+Cancel — good contract; BUT Patient picker renders as bare TextField ("Type to search…") with **no options UI ever appearing** (option_search composite does not materialize) → booking an existing patient impossible; Clinician = native select (works); failed submit shows "Validation failed…" at y≈1649 **offscreen** | panel create | panel yes; errors offscreen | other(broken picker) + **offscreen**(errors) |
| /intake | View (recent-appointments row) | opens the **booking create form** populated with the clicked appointment (patient/clinician/when/reason/severity + nested new-patient section with Add/Remove), all editable, submit hidden, Cancel shown | panel view≡create-form | yes | **view-opens-edit** (worst case: a create form as viewer) |
| /events | (no row buttons — zero rows) | renders header+search only; the promised empty-state message ("No Event records yet.") **does not render** | n/a | n/a | other(empty state missing) |
| /acting-as | clinician links | click on a stale roster entry (retired mid-session) → raw `422 "unknown actor"` plain-text page; valid pick → 302, banner clears on next surface (verified); pill "Acting as…" **never shows the current actor** | n/a | yes (banner) | other(stale-roster 422; no actor display) |
| /operator | — (links only, no buttons) | hub page | n/a | n/a | correct |
| /operator/rules | Edit/Remove/Add fact/Add rule/New/Draft/Validate/Approve/Activate/Compile bundle/Activate bundle | ruleset editor (custom LiveView, 23 inputs) — outside a2ui panel scope; inventoried for the follow-up lane | n/a | yes | other(out of a2ui scope) |
| /operator/instances/:id | — (no buttons) | read-only BPMN viewer | n/a | n/a | correct |
| /canvas | Graph / Inspector + 5 unlabeled buttons | separate canvas UI; no a2ui row actions | n/a | yes | other(out of scope) |
| /agent | Ask + surface links | chat surface; composed surfaces reuse the same a2ui row-action machinery | n/a | yes | other(inherits findings above) |

**Anonymous vs actor:** the banner gate works only where policies check `actor_present` (Appointment, HumanTask/engine). Patient & Clinician declare **no policies**, so Record weight / Retire / Create succeed with nobody acting (verified: anon Record weight persisted 77.7 kg; anon Retire flipped Active→false). The per-surface "No one is acting." banner (Board/Schedule/Visits variants) honestly warns before the click — good — but the gate it advertises doesn't exist on 2 of 5 writable surfaces.

## Counts
- **View buttons:** 9 surfaces emit them; **7 dead** (board, schedule, worklist, visits, processes, decisions, evaluations, emergencies + intake-recent); **2 open an edit-form-without-save** (patients, clinicians).
- **Edit buttons:** zero anywhere (no form declares `update_action`; Patient/Clinician have no default update) — `start_edit` is unreachable in this app.
- **Prompt modals (Complete/Cancel/A2ui complete/Record weight):** best contract in the app (fields, inline errors, Confirm/Cancel/×, retained values) — but 1 of 4 crashes server-side (worklist), and none can show success.
- **Feedback:** every row-action success is written to `/ui/status`, which nothing renders under v2 (status Text binds `/ui/feedback/message`; `task_success/2` writes feedback only for `submit_form`, never for `invoke`). Refusals render only in the bottom-of-page line — offscreen on every tall surface (y=1164 schedule/board, y=1649 intake).

*Probe artifacts: /tmp/opencode/audit/{inventory.mjs,probe.mjs…probe5.mjs,micro*.msj…micro9.mjs, results*.json, frames_discharge.json, shots*/}.*
