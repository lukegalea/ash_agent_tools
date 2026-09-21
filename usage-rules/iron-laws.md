# Rules for working with AshAgentTools: iron-laws (the 26 Iron Laws + judge)

The codified **26 Iron Laws** — adapted from the phxagents project's
published set (phxagents.dev/iron-laws, MIT; "every Iron Law is a scar",
audited against production Phoenix codebases and 1,351 session transcripts)
— plus the deterministic judge that checks code against them. They govern
Phoenix/Ecto/Oban/OTP work in general; `AshAgentTools.Laws` mechanically
enforces the subset that can be detected from source text.

## The judge

Given a snippet, a file's content, or a unified diff, the judge reports
violations only, tiered by pattern certainty:

- **definite** — the matched text is the violation (e.g. `String.to_atom(`)
- **likely** — the matched shape is almost always the violation (e.g.
  `Repo.all/1` inside `def mount`)
- **review** — the matched shape deserves a look (e.g. `cast_assoc/3`)

```elixir
# in-VM (attached session, no mix boot):
report = AshAgentTools.judge_laws(source)
# %{source: "inline", laws_checked: 26, violations: [...], counts: %{...},
#   clean?: false, laws_without_detectors: [...]}

AshAgentTools.judge_laws(source, min_tier: :review)  # include review-tier hits
AshAgentTools.judge_laws(source, laws: ["10", "04"]) # restrict by law id
AshAgentTools.judge_laws(diff_text, diff?: true)     # judge only added (+) lines
AshAgentTools.Laws.laws()                            # the full registry
```

```sh
# from the shell (pure text processing: no boot, no compile):
mix ash_agent.laws                            # the law registry as JSON
mix ash_agent.laws FILE [FILE...]             # judge files
mix ash_agent.laws --code 'SNIPPET'           # judge a snippet
git diff main | mix ash_agent.laws - --diff   # judge only added lines
mix ash_agent.laws FILE --min-tier review     # definite|likely|review floor
```

Default floor is `likely`: review-tier hits stay out of `violations` but are
always visible in `counts`. Seven laws are behavioral (see
`laws_without_detectors`) — apply them as a review checklist; the judge is
grep-tier, not a parser, so read a hit's `hint` and judge context (a
compile-time-constant `String.to_atom` is the documented exception).

## The laws

### LiveView

- **#01 — No unconditional DB queries in mount.** Mount runs twice (dead
  render + connected render); the dead render is crawler HTML. Query in
  `handle_params/3`, or `assign_async`/`stream` so data arrives on the
  connected render.
- **#02 — Streams for lists over ~100 items.** Assigns copy into every
  LiveView process; `stream/3` + `phx-update="stream"` keeps DOM and memory
  flat.
- **#03 — Check `connected?(socket)` before PubSub.** Subscribing in mount
  leaks a subscription from the dead render.
- **#18 — Check changeset errors before debugging the UI.** A form that
  "does nothing" is usually a failed changeset, not broken markup.
- **#21 — Never `assign_new` for per-mount values.** It re-runs per mount
  and hides state; assign directly. (Sanctioned home: LiveComponents.)
- **#24 — Match `{:error, %Ecto.Changeset{}}` explicitly.** Catch-all
  `{:error, _}` clauses swallow validation errors before they reach the form.

### Ecto

- **#04 — Never `:float` for money.** Floats round; use `:decimal`/`:money`.
- **#05 — Pin external values with `^` in queries.** Interpolation bypasses
  parameterization: injection and cache misses.
- **#06 — Separate queries for `has_many`; JOIN for `belongs_to`.** Per-row
  queries N+1; joining a has_many multiplies rows.
- **#15 — No implicit cross joins.** Every `join:` needs an explicit `on:`.
- **#17 — Deduplicate before `cast_assoc`.** It replays every embedded
  change and duplicates rows at scale.
- **#19 — Hidden inputs for required embedded fields.** Forms over embeds
  must round-trip the required PKs or the embed silently drops on submit.

### Oban

- **#07 — Jobs are idempotent.** They run at-least-once (retries, rescue);
  declare `unique:` and make `perform/1` replay-safe.
- **#08 — Args are string-keyed.** Oban serializes through JSON; atom keys
  come back as strings and `perform/1` pattern matches silently miss.
- **#09 — Store IDs, not structs.** Structs freeze state at enqueue time;
  pass the id and re-read fresh.

### Security

- **#10 — No `String.to_atom` on user input.** The atom table never GCs:
  DoS. `String.to_existing_atom/1` or a fixed allow-list.
- **#11 — Authorize in EVERY `handle_event`.** An event handler is a public
  endpoint; route through Ash actions with policies or check `Ash.can?`.
- **#12 — Never `raw/1` untrusted content.** `raw/1` marks content safe
  HTML: stored XSS. Sanitize first or drop it.

### OTP

- **#13 — No process without a runtime reason.** Processes exist to outlive
  calls (state, concurrency, fault isolation); a process per page view dies
  meaningless.
- **#14 — Supervise all long-lived processes.** Anything that must survive
  belongs in a supervision tree; `Task.start/1` leaks on crash.

### Elixir

- **#16 — `@external_resource` for compile-time files.** A module reading a
  file at compile time must declare the path or edits will not recompile it.
- **#20 — Wrap third-party APIs.** One façade module per external service;
  retries, timeouts, and shape-drift get a single home.
- **#23 — Mix tasks start only what they need.** `app.start` boots queues,
  projectors, and endpoints; prefer `app.config` + `ensure_started` of the
  apps the task actually uses.
- **#25 — Capture locale before spawning.** Spawned tasks do not inherit the
  process dictionary; capture (and restore) locale and Process-store context.

### Verification & style

- **#22 — Verify before claiming done.** Compile, test, show the output. No
  exceptions; the judge's existence is this law mechanized for style.
- **#26 — Comments aren't commit messages.** Only durable facts in code;
  narrative belongs to the commit.

## Why this section exists

Prose rules fire unreliably; mechanical checks fire always. Run the judge on
proposed diffs before applying them (`git diff main |
mix ash_agent.laws - --diff`) and treat a non-clean report as work the
diff isn't done with.
