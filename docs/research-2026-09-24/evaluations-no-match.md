# CLIN-7: /evaluations shows "no rules matched" — root cause + fix plan

**Date**: 2026-09-23 · **Mode**: READ-ONLY diagnosis · **Verdict: FRAMEWORK (engine + ash_decisions), not host**

---

## TL;DR

Every Evaluation row has real outputs (`"urgent"`, `"routine"`, `"emergency"`), so the DMN
engine **did** match rules. The `matched_rule_ids` column is empty because
`AshDecisions.Evaluator.record/5` **hard-codes `matched_rule_ids: []`** (and never sets
`hit_policy`) — because the Boxic DMN engine's public API
(`Boxic.DMN.evaluate/3,4`) returns only `{:ok, value}` and **discards the matched-rule
provenance it computes internally**. The host surface (`EvaluationUI`) faithfully renders
whatever is in the record; an empty list renders as a blank cell beside the "Matched rules"
caption. **No "no rules matched" default exists anywhere in any repo** — the phrase is a
human/agent description of that blank cell, not a code string.

Per the mandate: the engine's verdict lacks matched-rule provenance at its API boundary, and
ash_decisions persists the resulting empty list. **The fix is framework-side** (boxic_dmn
upstream + ash_decisions), with zero required host changes.

---

## 1. The data (live, seeded DB via docker `mix run`)

Query: `ClinicDemo.Decisions.Evaluation` (7 rows total). Sample (5 of 6 newest):

```
key=appointment.triage v1 decision=AppointmentTriage
  inputs=%{"ageBand" => "adult", "severity" => "2", "species" => "dog"}
  outputs=%{"value" => "urgent"}          matched_rule_ids=[]  hit_policy=nil error=nil
  inputs=%{"ageBand" => "adult", "severity" => "1", "species" => "dog"}
  outputs=%{"value" => "routine"}         matched_rule_ids=[]  hit_policy=nil error=nil
  inputs=%{"ageBand" => "", "severity" => "3", "species" => "rabbit"}
  outputs=%{"value" => "emergency"}       matched_rule_ids=[]  hit_policy=nil error=nil
  ... (all 7 rows identical in shape: outputs present, matched_rule_ids=[], hit_policy=nil)
```

**Conclusion**: evaluation genuinely *matched* (non-nil outputs, no errors). The surface
fails to render nothing — there is nothing to render. The data is empty at write time.

The published definition (`dmn_definitions`, `appointment.triage` v1, status `published`,
hit policy `PRIORITY`) has **7 named rules** — exactly the ids that should populate
`matched_rule_ids`:

```
rule_critical, rule_fragile_age, rule_prey_species,
rule_moderate, rule_mild_fragile_age, rule_mild_prey_species, rule_routine
```

E.g. row 1 (`severity=2, dog, adult → "urgent"`) should record `["rule_moderate"]` with
`hit_policy: "PRIORITY"`.

## 2. The plumbing (framework — `ash_decisions`)

`~/ast-forks/ash_decisions/lib/ash_decisions/evaluator.ex`:

- **Lines 31–36 (moduledoc)** — the smoking gun, self-documented:

  > **Which rule fired is not recorded**, and the reason is a limitation rather than an
  > oversight: `Boxic.DMN.evaluate/3` returns the decision's value and nothing about how it
  > reached it. We could re-evaluate every input entry against the inputs ourselves and
  > report the rules *we* think matched — and that second opinion could disagree with the
  > engine's, which is worse than not answering. The field stays empty until the engine can
  > say, and the moment it can, the column is already there.

- **Lines 226–229 (`record/5`)** — the hard-coded write:

  ```elixir
  # See the moduledoc: the engine does not report which rules matched, and a second
  # opinion computed here could disagree with the one that actually decided.
  matched_rule_ids: [],
  ```

  (`hit_policy` is simply omitted from `attrs`, so it persists as `nil`.)

- **Lines 197–209 (`run/4`)** — the engine call site: `Boxic.DMN.evaluate(model, decision,
  context)` inside a timeout `Task`; `{:ok, outputs}` is the only success shape consumed.

The storage layer is **ready**: `AshDecisions.Resources.Evaluation` already declares
`matched_rule_ids, {:array, :string}, default []` (resources/evaluation.ex:142–145, comment
at 139–141: "It is the difference between 'the answer was 12%' and 'the answer was 12%
because rule 7 matched'") and `hit_policy, :string` (147–149); both are accepted by the
`create` action (191–205). The column exists in the host migration too. The resource macro
and the host are fine — **nothing ever writes a non-empty value**.

## 3. The engine (`boxic_dmn`, hex dep `~> 0.3`)

`deps/boxic_dmn/lib/boxic/dmn/decision_table.ex` — the engine **computes** the provenance
and then throws it away:

- **Lines 142–150 (`matching_rules/3`)** — collects the matched rules:
  `{:ok, matches ++ [rule]}` where `rule` is a `%Boxic.DMN.Model.DecisionRule{}` — which
  has an `:id` (model.ex:354–362: `defstruct [:id, :input_entries, :output_entries]`).
- **Line 6–12 (`DecisionTable.evaluate/2`)** — `matches` is in hand, handed to
  `reduce_hit_policy(table, matches, results, context)`.
- **Lines 23–67 (`reduce_hit_policy/4`)** — every clause returns only the reduced *value*
  (`{:ok, result}` / `{:ok, results}`); the matched-rule list is dropped. (Ironically, the
  UNIQUE/ANY violation errors at lines 30/40 DO return `Enum.map(rules, & &1.id)` — the
  ids are right there.)
- **Public API boundary** — `Boxic.DMN.Evaluator.evaluate/3`
  (evaluator.ex:29–37): `{:ok, value, _memo} <- evaluate_decision(...)` → returns
  `{:ok, value}`. `Boxic.DMN.evaluate/3,4` (dmn.ex:134–148) is typed
  `{:ok, term()} | {:error, evaluation_error()}`. No trace, no opt-in.

`boxic_dmn` is an **upstream Hex dependency** of ash_decisions
(ash_decions/mix.exs:75 `{:boxic_dmn, "~> 0.3"}`), adopted-not-written per the ash_decisions
README ("The engine is adopted, not written" / Boxic, Apache-2.0). There is no local fork
under `~/ast-forks/`.

## 4. The surface (host — `clinic-demo`) — exonerated

- `lib/clinic_demo_web/a2ui/evaluation_ui.ex:26–44` — the table declares
  `:matched_rule_ids` in `fields` and in `row_layout.meta`, and `field :matched_rule_ids,
  label "Matched rules"` (54–56). It renders exactly what the record carries.
- Verified by headless probe (playwright, shadow-DOM-piercing) against
  http://127.0.0.1:4000/evaluations (`ClinicDemoWeb.A2ui.EvaluationsLive` →
  `AshA2ui.LiveRenderer`, `EvaluationUI`): every card shows the caption **"Matched rules"**
  with a **blank value**, and **"Hit policy"** likewise blank. Screenshot:
  `/tmp/opencode/evaluations.png`.
- **There is no "no rules matched" default.** Grepped the literal (and variants) across
  `clinic-demo` (lib/, assets/, priv/), `ash_decisions`, `ash_a2ui` (lib + priv/js), the
  built bundle `priv/static/assets/js/app.js`, and `assets/node_modules/@a2ui/` — zero
  hits. The only "…rules matched" string in the bundle is `"none of the block rules
  matched"`, which belongs to the unrelated `ash_compliance` guard path. The
  a2ui encoder serializes `[]` as `[]` (v0_9_1.ex:2938–2946 `field_value/3` → `json_safe/1`
  lists pass through) and nil as empty; the lit client renders an empty list as an empty
  text node. A reader (human or AI agent) sees a blank "Matched rules" cell and reports
  "no rules matched".

## Definitive causal chain

```
boxic_dmn DecisionTable.matching_rules/3   computes matched %DecisionRule{} (with .id)
        ↓  reduce_hit_policy/4 keeps only the value          ← ENGINE DROPS IT (API boundary)
Boxic.DMN.evaluate/3,4  →  {:ok, value}                     ← no provenance in the contract
        ↓
AshDecisions.Evaluator.run/4  gets {:ok, outputs} only
        ↓  record/5 hard-codes matched_rule_ids: [], omits hit_policy   ← FRAMEWORK DROPS IT
dmn_evaluations row: outputs ✓, matched_rule_ids [], hit_policy nil    ← DATA IS EMPTY
        ↓  host reads it verbatim (AshA2ui query → encoder → wire: [])
EvaluationUI card: "Matched rules" caption + blank value               ← SURFACE IS HONEST
        ↓
Viewer reports: "no rules matched"                                     ← the symptom
```

Not a data bug (rules genuinely matched), not a host/rendering bug (faithful render of
empty data). It is a **missing engine capability consumed as a documented framework
limitation**, visible through an honest surface.

---

## Fix plan

### A. `boxic_dmn` (upstream) — make the engine report what matched

1. In `Boxic.DMN.DecisionTable.evaluate/2` (lib/boxic/dmn/decision_table.ex:6–12): thread
   a trace alongside the value. `matches` (matched `%DecisionRule{}`s) and `results` are
   already index-aligned; each `reduce_hit_policy/4` clause returns `{value, trace}`
   internally, where `trace = %{rule_ids: Enum.map(matches, & &1.id), hit_policy:
   table.hit_policy, aggregation: table.aggregation}`. The default-output clause
   (lines 23–25, no match) traces `rule_ids: []`.
2. Expose it without breaking `evaluate/3`'s `{:ok, term()}` contract — pick one:
   - an opt in the existing `evaluate/4` (lib/boxic/dmn/evaluator.ex:39–46), e.g.
     `trace: true` → success becomes `{:ok, %{value: value, trace: trace}}`; or
   - a sibling `Boxic.DMN.evaluate_with_trace/3,4` returning `{:ok, value, trace}`,
     delegating to the same internals.
   Thread the trace of the *requested* decision up through `evaluate_decision`'s
   `{:ok, value, memo}` (memo can carry `{value, trace}` per decision id; only the final
   decision's trace is surfaced).
3. Ship as a minor (`~> 0.4`); add TCK-neutral tests (trace must not change values).

### B. `ash_decisions` — consume the trace and persist it

1. `mix.exs:75`: bump to `{:boxic_dmn, "~> 0.4"}`.
2. `lib/ash_decisions/evaluator.ex`:
   - `run/4` (197–209): call with the trace option; success shape gains the trace.
   - `result` map (78–84): add `matched_rule_ids` and `hit_policy` from the trace.
     (`hit_policy` fallback, if the engine returns only rule ids: read it off the cached
     `%Boxic.DMN.Model{}` already in hand — `model.decisions[name].expression.hit_policy`
     when that expression is a `%DecisionTable{}`; nil otherwise.)
   - `record/5` (219–232): replace `matched_rule_ids: []` with the real list; add
     `hit_policy: ...`.
   - Delete the now-stale moduledoc paragraph (31–36) and the inline comment (226–227);
     document the new contract ("the engine reports which rules fired; we record it").
3. Tests: extend `test/ash_decisions/resources_test.exs` (which already exercises
   `matched_rule_ids: ["rule_gold_large"]` at 199/205 — those tests write it manually; add
   an `Evaluator.evaluate` end-to-end assertion). Keep the resources/TCK surface unchanged.

### C. `clinic-demo` (host) — nothing required; two optional touches

- **Required: none.** `EvaluationUI` (lib/clinic_demo_web/a2ui/evaluation_ui.ex:29,41,54)
  and the `Evaluation` resource (lib/clinic_demo/decisions/evaluation.ex) already declare
  everything; once the framework writes real values, cards render them (the wire encoder
  passes lists through).
- Optional 1 (cosmetic): an empty-state for legacy rows — a `badge_text`-style mapping or
  a field display hint so `[]` reads as "—" rather than blank. Only matters for old rows.
- Optional 2: after upgrading, re-run the seed (or trigger a triage) so the live DB
  demonstrates populated rows. The 7 existing rows have `matched_rule_ids: []` and the
  resource is deliberately append-only (create/read only, resources/evaluation.ex:184–206),
  so they cannot be back-filled in place — regenerate via seed or accept them as
  pre-fix history.

### Verification

1. After A+B: `docker run ... mix run -e` — evaluate `appointment.triage` with
   `severity=2, dog, adult`; assert the new Evaluation row has
   `matched_rule_ids == ["rule_moderate"]` and `hit_policy == "PRIORITY"`.
2. Headless probe of `/evaluations` (script pattern kept at
   `/tmp/opencode/probe_evaluations.mjs`): each card shows the rule id text next to
   "Matched rules" and `PRIORITY` beside "Hit policy".

### Evidence artifacts

- Record dumps: §1 above (live docker queries).
- Screenshot of the rendered surface: `/tmp/opencode/evaluations.png`
  (blank "Matched rules"/"Hit policy" cells on every card).
- Probe script: `/tmp/opencode/probe_evaluations.mjs`.
