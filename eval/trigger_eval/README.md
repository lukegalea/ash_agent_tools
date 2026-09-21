# Trigger-eval gate for `mix ash_agent.serve` (DX-2 §2.4)

This directory is the **pre-launch gate scaffold** for the MCP daemon's tool
surface: `eval_set.json` holds the should-trigger and should-not-neighbor
queries; this README is the runbook. **The gate is deliberately not wired
into CI** — it runs locally before merge, with results posted to the PR.

## What it checks

Not correctness of the tools (the unit suite covers that), but **trigger
quality**: does a real client, pointed at the daemon's `tools/list` cards,
reach for the right tool for a natural-language question — and *not* reach
for it when the question belongs to a neighbor (SQL, file edits, routes,
shell)?

Failures are labeled with the phxagents taxonomy:

| Label | Meaning |
|---|---|
| `missing_term` | The phrasing never triggers the intended tool — the tool card is missing a term agents actually use. Fix: extend the card description. |
| `too_broad` | The tool triggered where it should not have — the card overclaims. Fix: narrow the description (the read-only posture goes in it for a reason). |
| `neighbor_collision` | Right intent, wrong surface — the query was answered by tidewave's `project_eval`, an edit tool, or the shell instead. Fix: sharpen the boundary wording in the card, or accept and document the boundary. |

## Gate

**75% per tool, pre-merge.** A tool whose cards miss the gate blocks the
merge; iterate on the descriptions (not the eval set) until green. Changing
an eval query to make it pass is kaizen-heresy — record it as a design
decision instead.

## How to run

1. Boot the daemon on a scratch port (so it cannot collide with a running
   one):

   ```sh
   mix ash_agent.serve --port 4199
   ```

2. Drive the eval set with any MCP-speaking client harness. The minimal
   loop per query: `tools/list` once, then for each query ask the client
   model to pick a tool from the cards and record
   `{query, picked_tool, should_trigger, pass?}`. The repo's skill_eval
   machinery (`skill_eval` with `evalSetPath` pointed at `eval_set.json`,
   `skillPath` at the package root) does this out of the box against the
   packaged usage rules + tool cards; a standalone harness only needs to
   replay the same two-request shape:

   ```sh
   curl -s -X POST http://127.0.0.1:4199 \
     -H 'content-type: application/json' \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq
   ```

3. Score per tool: `passes / queries targeting that tool`. The should-not
   rows count against the tool they must *not* trigger (a `too_broad` hit)
   or are attributed as `neighbor_collision` when another surface answered.

4. Post the table (tool → score → failing queries → labels) to the PR.

## Maintenance

* New tool → new cards → add ≥2 should-trigger queries and 1–2 neighbors
  here before merge.
* Post-launch, the kaizen loop (`mix ash_agent.gaps`) is the fire-rate
  metric: recurring tool-gap questions that *look* like they should have
  triggered become new eval rows — that is how this set grows honest.
