<!-- SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools> -->
<!-- SPDX-License-Identifier: MIT -->

# AshAgentTools

**Read-only [Ash](https://ash-hq.org) introspection for AI agents.**

`ash_agent_tools` answers the questions an agent asks while composing Ash
actions on your behalf — *what resources exist? what does this action
accept? is this input valid? why was I forbidden?* — as plain,
JSON-encodable maps, without executing anything.

```elixir
AshAgentTools.list_domains()
AshAgentTools.describe_resource(MyApp.Post)
AshAgentTools.describe_action(MyApp.Post, :create)

report = AshAgentTools.validate_input(MyApp.Post, :create, %{"title" => "Hi", "score" => "7"})
report.valid?          #=> true
report.normalized_inputs["score"]  #=> 7

AshAgentTools.explain_forbidden(MyApp.Post, :create)

AshAgentTools.semantic_search("tag")   #=> [%{resource: MyApp.Post, kind: :action, name: :by_tag, ...}]
AshAgentTools.diff_manifest("old.json", "new.json")  #=> %{summary: %{added: 1, ...}, ...}

{:ok, ctx} = AshAgentTools.context("lib/my_app/accounts/post.ex", 42)
ctx.module.name        #=> "MyApp.Post"
ctx.match.name         #=> :title  (the symbol whose declaration covers line 42)
ctx.references         #=> actions that accept it, interfaces that call it, ...

report = AshAgentTools.explain_trace(spans)  #=> errors innermost first,
                                             #=> queries with N+1 flagged, policies, ...
AshAgentTools.Runtime.top(20)          #=> the busiest processes, JSON-safe
AshAgentTools.Runtime.tree("MyApp")    #=> your supervision tree
AshAgentTools.Kaizen.attach()          #=> fold every tool miss into an ETS aggregate
```

**Already attached to a running node?** Don't pay a mix boot per query —
evaluate the API directly (via `project_eval`, Livebook, `iex --server`).
`AshAgentTools.eval_docs()` returns the exact snippet to evaluate: the
facade module, every public function with an example, and a worked loop.

Or from the shell, no code execution required:

```sh
mix ash_agent.describe                       # discovery summary
mix ash_agent.describe MyApp.Post            # resource description
mix ash_agent.describe MyApp.Post create     # action contract
mix ash_agent.validate MyApp.Post create '{"title": "Hi"}'
mix ash_agent.validate MyApp.Post create '{"title": "Hi"}' --out report.json
mix ash_agent.search tag                     # find symbols by name substring
mix ash_agent.context lib/my_app/accounts/post.ex:42  # what lives at this position
mix ash_agent.diff manifest-old.json manifest-new.json
mix ash_agent.runtime snapshot               # also: top 20 | tree MyApp
mix ash_agent.gaps                           # the kaizen tool-gap digest
mix ash_agent.laws lib/foo_live.ex           # the iron-law judge (also: --code, --diff, stdin)
mix ash_agent.edit replace MyApp.Post/attributes/score \
  --body "attribute :score, :integer, allow_nil?: false"   # dry-run; add --write --expected-digest D to apply
```

Both tasks emit **pure JSON on stdout** (application logger noise is
suppressed; `--verbose` keeps it) so output pipes straight into a JSON
parser.

## Why plain functions and Mix tasks?

Because that is the pattern upstream accepts for agent-facing libraries:
**regular, introspectable code plus a `usage-rules.md` file**, which agents
read and compose themselves — via `project_eval`, Livebook, or the bundled
Mix tasks. This package deliberately does *not* register MCP tools or any
other editor-side tool surface (that approach has been rejected upstream;
see the discussion in [Tidewave PR #215](https://github.com/tidewave/tidewave_phoenix/pull/215)
for the tool-definition API this package is positioned to map onto).

Keeping the API plain has two more benefits:

- **Zero context cost.** Agents read one small `usage-rules.md` instead of a
  tool registry.
- **Forward compatibility.** Plain data-in/data-out functions wrap trivially
  into whatever tool-definition mechanism eventually settles.

## Features

- **Discovery** — `list_domains/0`, `list_resources/0` over loaded modules.
- **Resource descriptions** — fields (types, constraints, nullability,
  defaults), relationships, actions with typed arguments, and source
  locations lifted from Spark annotations.
- **Action contracts** — required/optional/private input keys with
  normalized types, return shapes, and code interfaces (resource-level and
  domain-level `define`s).
- **Input validation without execution** — casts each param with
  `Ash.Type.cast_input/3` (the same machinery Ash uses at runtime), reports
  missing/unknown/invalid inputs, and returns JSON-safe normalized values.
  The changeset/query is built with `error?: false` and never run.
- **Authorization guidance** — `explain_forbidden/2` lists an action's
  policies (bypass flags, conditions, checks) in human-readable form via
  `Ash.Policy.Check.describe/2`, with hints for reasoning about them.
- **Symbol search** — `semantic_search/2` finds attributes, actions,
  calculations, and relationships across loaded resources by name substring
  (case-insensitive, optional kind filter), each hit with its normalized
  type and Spark source location.
- **Custom extension sections** — Spark extension sections beyond Ash's
  core DSL (an `a2ui do … end` block, a rules DSL's `fact_schema`) are
  projected into the symbol index generically: each becomes a namespaced
  kind `<extension>_<section>` (e.g. `MyApp.Rules.Dsl` + `fact_schema` →
  `rules_fact_schema`), with entity names from `:name`/`:id`/`:tag` and a
  positional fallback for entities that expose none — so search, context,
  name paths, and semantic edits reach custom DSL entities with no
  per-DSL code.
- **Position context** — `context/3` takes a file path and 1-based line and
  returns which loaded Ash resource/domain declares there, the symbol whose
  declaration span covers the line, the nearest symbols, what references
  the matched symbol (actions that accept an attribute, code interfaces
  that call an action, relationships wired through it), and — when
  `priv/semantic/**/*.json` manifests exist — manifest-derived relations.
  One call replaces the grep → read → re-grep loop; misses are graceful.
- **In-VM bootstrap** — `eval_docs/0` returns the exact snippets an agent
  attached to a running node should evaluate to use every function
  instantly, skipping the seconds-to-minutes per-query mix boot.
- **Manifest diffing** — `diff_manifest/2` structurally diffs two
  semantic-manifest JSON documents by stable symbol id (the
  `ash:v0:<Module>#<dsl_path>/<name>` grammar proposed in the *Spark/Ash
  Semantic Manifest, v0* RFC) into added/removed/changed symbol sets.
  Works on hand-authored fixtures today; the RFC's `--semantic` exporter is
  future work.
- **Trace reduction** — `explain_trace/2` turns an OpenTelemetry span list
  into a budget-bounded report: errors innermost first, queries with
  structural **N+1 detection**, policies, notifications, async branches,
  and the `ash.symbol_id`s in the trace — with an honest `truncated?` flag
  and an optional `backend_url` deep-link. Pure and dependency-free: bring
  spans from any source.
- **BEAM runtime introspection** — `AshAgentTools.Runtime` answers
  `snapshot/1`, `top/2` (busiest processes — the hidden-queue hunt), and
  `tree/2` (supervision trees). When the host ships observer_cli 2.0 it
  delegates to its heap-capped, JSON-safe snapshot worker (the versioned
  `observer_cli.cli/v1` envelope, passed through verbatim); otherwise
  built-in `Process`/`:ets`/`:supervisor` walks answer. `trace_id`/
  `correlation_id` opts are echoed back, joining the state plane to a
  trace.
- **Kaizen loop** — tool misses (unknown input, search miss, context miss)
  emit `[:ash_agent, :tool_gap]` telemetry with `did_you_mean` candidates
  folded into the tools' output. `AshAgentTools.Kaizen.attach/0` is a
  dev-only ETS sink; `digest/0` (or `mix ash_agent.gaps`) turns the
  aggregate into the alias/doc-fix worklist. Emitting never raises and a
  broken handler never breaks a tool.
- **Name paths & semantic edits** — `resolve/1` pins any DSL entity by
  name path (`MyApp.Post/actions/by_tag`, `.../policies/policy[0]`,
  suffix-matched modules) with spans, provenance, and a shape digest;
  `AshAgentTools.Edit` performs anchor edits (`replace_entity_block`,
  `insert_before_entity`, `insert_after_entity`, `safe_delete_entity`)
  with a mechanical read-before-edit digest handshake, a provenance guard
  against transformer-injected declarations, atomic writes that preserve
  EOLs/indentation, and a post-edit compile+validate gate that reverts on
  failure. `mix ash_agent.edit` is dry-run by default. Search and context
  outputs use Serena-style truncation ladders (over-limit refinement
  errors, capped lists with shown/total markers).

- **Iron-law judge** — `judge_laws/2` (and `mix ash_agent.laws`) checks a
  snippet, file, or unified diff against the codified *26 Iron Laws*
  (adapted from [phxagents.dev/iron-laws](https://phxagents.dev/iron-laws),
  MIT) with deterministic grep-tier detectors — no LLM, no keys, no boot.
  Violations-only output at three certainty tiers (`definite`, `likely`,
  `review`) with counts for every tier; the law text ships as the
  `usage-rules/iron-laws.md` sub-rule for `mix usage_rules.sync`.

- **MCP daemon** — `mix ash_agent.serve` starts a supervised, loopback-only
  MCP server (POST-only JSON-RPC over HTTP on `127.0.0.1:4100`, stateless,
  no sessions, no SSE) that exposes the facade as tools: `ash_describe`,
  `ash_validate`, `ash_search`, `ash_context`, `ash_forbidden`,
  `ash_daemon_status`, and `ash_reload`. Same compile-only boot contract as
  the tasks — the mix boot is paid once at daemon start, every tool call is
  an in-memory read — plus a debounced `lib/`/`config/` file watcher that
  recompiles and invalidates caches behind a serialized reload mutex. Add a
  `"type": "http"` entry pointing at `http://127.0.0.1:4100` to your MCP
  client config. `plug`/`bandit`/`file_system` are optional deps (Phoenix
  apps already have all three).

## Compile-only boot

The introspection tasks (`describe`, `validate`, `search`, `context`,
`edit`) boot `app.config` + compile only — **your application is never
started**: no Oban queues consuming jobs mid-task, no projectors draining,
no side effects. Introspection needs compiled DSL state, not a running
app. Only `runtime` boots the application (the running tree is the point),
and `diff`/`laws`/`gaps` need nothing at all — `laws` never even compiles.

`serve` follows the same contract: the daemon compiles your project and
loads the configured domains, then serves reads from memory. The
application is never started inside the daemon; your running app (if any)
is a separate node.

## Installation

```elixir
def deps do
  [
    {:ash_agent_tools, "~> 0.1"}
  ]
end
```

Ash (`~> 3.0`) is the only runtime dependency besides `jason`,
`telemetry`, and `sourceror` (precise AST ranges for the edit tools; small,
pure Elixir, and already in most Ash projects' graphs via igniter). The
BEAM runtime tools use observer_cli 2.0 (+ recon) when the **host
application** ships them — both are optional, dev-only, and never pulled in
by this package; without them the built-in backends answer.

## Usage rules for agents

This package ships a `usage-rules.md` at the package root, following the
[usage_rules](https://hexdocs.pm/usage_rules) convention. If your project
uses `mix usage_rules.sync`, add `:ash_agent_tools` to the sync list and the
rules land in your `AGENTS.md` automatically.

## Limitations

- Discovery sees **loaded** modules; the Mix tasks handle loading for you.
- Validation reports input-level problems only — authorization, uniqueness,
  and actor-dependent validations surface when an action actually runs.
- `explain_forbidden/2` is a guidance stub, not an evaluator; use `Ash.can?/3`
  for real verdicts.
- `context/3` positions symbols via Spark annotations; modules compiled
  without debug info carry none, so their files cannot be matched (the
  report comes back `module: null`, `match: null`).
- `diff_manifest/2` operates on manifest documents, not live modules — pair
  it with an exporter once one exists (the RFC's `mix ash.manifest.dump
  --semantic` proposal), or hand-authored fixtures.
- `explain_trace/2` reports durations in the input's own time units, and its
  N+1 detection is structural (identical sources under one parent); it does
  not fetch spans from a backend.
- `AshAgentTools.Runtime` observes the VM it runs in; a library application
  without a running top supervisor reports `root: null`.
- The kaizen ETS aggregate lives in the VM that attached it; a fresh mix
  boot digests to `gaps: []` (run `mix ash_agent.gaps --out` from the
  attached session, or call `digest/0` in-VM).

## Contributing

Conventional Commits; MIT licensed with REUSE/SPDX headers on every source
file (`reuse lint` clean; `eval/` fixtures are annotated via `REUSE.toml`).

## License

MIT — see [LICENSES/MIT.txt](LICENSES/MIT.txt).
