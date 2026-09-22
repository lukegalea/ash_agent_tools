# Rules for working with AshAgentTools

AshAgentTools is a read-only introspection layer over Ash. It answers an
agent's questions about a project's domains, resources, and actions as plain
JSON-encodable maps, validates action inputs without running anything, lists
the policies that can forbid an action, searches symbol names across
resources, describes the Ash context at any source file position, diffs
semantic-manifest documents, judges code against the codified 26 iron laws,
and tells you how to use all of that in-VM
without a mix boot. It ships as **regular library code plus this file** —
deliberately *not* as registered MCP tools or any other tool-surface
integration, which keeps it usable from `project_eval`, Livebook, Mix tasks,
or any future hosted tool-definition API. Read these rules before using it;
do not assume prior knowledge of the API.

## The read-only contract

- **Nothing executes.** `validate_input/3` builds a changeset/query/action
  input with `error?: false` and inspects it; the subject is never run, no
  action fires, no data layer is touched. You still execute actions yourself
  through the project's own code interfaces or `Ash.*` calls.
- **Nothing is loaded for you.** Discovery (`list_domains/0`,
  `list_resources/0`) sees *loaded* modules only. Compiled-but-unloaded
  modules are invisible. Prefer the Mix tasks (they run `app.start` first)
  or ensure the modules are loaded before introspecting.
- **Functions raise `ArgumentError`** when pointed at a non-resource or an
  unknown action; discovery functions never raise.

## Core workflow

1. **Discover**: `AshAgentTools.list_domains/0`, `list_resources/0`.
2. **Describe**: `describe_resource/1` for fields, relationships, actions
   (with argument types and source locations); `describe_action/2` for the
   exact input contract (`required` / `optional` / `private` keys with
   normalized types), return shape, and code interfaces.
3. **Validate before you act**: `validate_input/3` casts each param with
   `Ash.Type.cast_input/3` — the same machinery Ash uses at runtime — and
   returns `%{valid?, errors, normalized_inputs, expected}`. Check
   `report.valid?` (the report itself is always returned, never raised).
4. **If forbidden**: `explain_forbidden/2` lists the resource's policies in
   human-readable form plus general guidance. It is a guidance stub, not an
   evaluator — get real verdicts from `Ash.can?/3` or the generated
   `can_<action>?` interfaces.
5. **Lost the full name?** `semantic_search/2` finds attributes, actions,
   calculations, and relationships across loaded resources by name substring
   (case-insensitive; optional `kinds:` filter), each hit with its declaring
   resource, normalized type, and source location. Useful between steps 1
   and 2, when you know a fragment like `"tag"` but not where it lives.
6. **Standing at a file position?** `context/3` takes a file path and a
   1-based line and returns which loaded Ash resource/domain declares there,
   which symbol's declaration covers the line, the nearest symbols, what
   references the matched symbol (actions that accept an attribute, code
   interfaces that call an action, relationships wired through it), and —
   when `priv/semantic/**/*.json` manifests exist — manifest-derived
   relations. Point it at a compiler error, a diff hunk, or wherever your
   cursor landed: one call replaces the grep → read → re-grep loop, and a
   miss is graceful (`{:ok, %{match: nil, nearest: [...]}}`), never an
   error.
7. **Track DSL changes across revisions**: `diff_manifest/2` diffs two
   semantic-manifest JSON documents (see the Semantic Manifest v0 RFC for
   the id grammar, `ash:v0:<Module>#<dsl_path>/<name>`) by stable symbol id
   into `added`/`removed`/`changed` sets. "Changed" compares content only —
   `hashes`, `span`, and `property_spans` are ignored — so a moved
   declaration is unchanged. Works on hand-authored manifest documents
   today; exported manifests (the RFC's `--semantic` emitter) diff the same
   way once the exporter exists.
8. **Debugging a trace?** `explain_trace/2` reduces a list of OpenTelemetry
   spans into a budget-bounded report: errors innermost first, queries with
   N+1 detection (identical sources under one parent collapse into one
   flagged entry), policies, notifications, async branches, and the
   `ash.symbol_id`s seen in the trace. Pure function — bring spans from any
   source. See `AshAgentTools.Trace` for the accepted span shapes.
9. **Debugging the VM itself?** `AshAgentTools.Runtime` is the *state* plane
   that pairs with the trace's *time* plane (join on `trace_id`):
   `Runtime.snapshot()`, `Runtime.top(20)`, `Runtime.tree("MyApp")` —
   read-only, JSON-safe, and capped in size. Pass `trace_id:`/
   `correlation_id:` to have them echoed into the report.
10. **Missed? Tell the loop.** When a tool fails to answer — unknown input,
    search with no hits, context on a non-Ash file — it emits a
    `[:ash_agent, :tool_gap]` telemetry event and folds `did_you_mean`
    candidates into its output so you can self-correct in one round-trip.
    Hosts aggregate the events with `AshAgentTools.Kaizen` (see the kaizen
    section below).

Compose these freely: the typical loop is describe → validate → execute →
on `Forbidden`, explain_forbidden → adjust inputs or actor.

## Prefer in-VM calls over mix boots

A per-query `mix` boot costs seconds to minutes (cold compile, dependency
resolution) — measured between ~10s warm and ~2min cold — which is exactly
why agents fall back to grepping. If your session is attached to a node
that already runs the application (`iex --server`, `iex -S mix phx.server`,
a Tidewave-style `project_eval` tool, Livebook), **prefer evaluating the
API directly; do not shell out to `mix ash_agent.*` at all**. Every
function is a pure, instant call over already-loaded modules.

`AshAgentTools.eval_docs/0` returns the exact snippet to evaluate: the
facade module, every public function with an example, and a worked
describe → validate loop. When in doubt, evaluate `AshAgentTools.eval_docs()`
first and follow it.

```elixir
# the whole contract in one string — evaluate and follow it
AshAgentTools.eval_docs()

# then call directly, no mix boot:
AshAgentTools.describe_action(MyApp.Post, :create)
AshAgentTools.validate_input(MyApp.Post, :create, %{"title" => "Hi"})
AshAgentTools.context("lib/my_app/accounts/post.ex", 42)
```

The Mix tasks remain for shell-only agents; they wrap the same functions.

## Mix tasks

For agents without code execution:

- `mix ash_agent.describe` — JSON summary of loaded domains/resources
- `mix ash_agent.describe MyApp.Post` — resource description
- `mix ash_agent.describe MyApp.Post create` — action description
- `mix ash_agent.validate MyApp.Post create '{"title": "Hi"}'` — validation
  report
- `mix ash_agent.search TERM [--kind KIND]...` — symbol search across loaded
  resources; prints `{"query","kinds","count","results"}`
- `mix ash_agent.context lib/my_app/accounts/post.ex:42` — the resource,
  symbol, nearest symbols, and references at a file position (also accepts
  the two-argument `PATH LINE` form)
- `mix ash_agent.diff OLD NEW` — semantic-manifest diff report (does not
  boot your application; pure file processing)
- `mix ash_agent.runtime snapshot|top|tree [N|APP]` — BEAM runtime views
  (`--trace-id`/`--correlation-id` echoed; `top` takes `--sort`; `tree`
  takes `--depth`); runs `app.start` first so you observe *your* tree
- `mix ash_agent.gaps` — the kaizen tool-gap digest (reads the ETS
  aggregate of the VM where `AshAgentTools.Kaizen.attach/0` was called; a
  fresh mix boot has none)
- `mix ash_agent.edit OP NAME_PATH [--body ...] [--write --expected-digest D]`
  — semantic DSL edits: `replace`, `insert-before`, `insert-after`,
  `delete`; dry-run by default
- `mix ash_agent.laws [FILE...] [--code SNIPPET] [-] [--diff] [--min-tier TIER]`
  — the iron-law judge: violations of the 26 laws as JSON (`--law ID`
  restricts; `-` reads stdin). No boot at all — pure text processing. With
  no arguments it prints the law registry.
- `mix ash_agent.serve [--port N] [--no-watch]` — the supervised MCP
  daemon (see the next section). Same compile-only boot contract as the
  other introspection tasks; the application is never started.

All tasks run under the **compile-only boot contract** (except
`ash_agent.runtime`, which is *justified* in a full boot — the running tree
is the point; `ash_agent.diff`/`ash_agent.laws`/`ash_agent.gaps`, which need
no application at all — `laws` never even compiles; and `ash_agent.serve`,
which keeps the contract but holds the compiled context long-lived instead
of exiting). The contract is
`app.config` + compile + the domains configured under
`config :my_app, ash_domains: [...]`. **The application is not started** —
no Oban queues consuming jobs, no projectors draining, no endpoints. If a
tool needs the running tree, that is a different tool.

Tasks print compact JSON by default (`--pretty` for humans) and guarantee
**pure-JSON stdout**: Logger output is suppressed and compilation output is
routed away from stdout for the duration of the task. Errors are answers
too — `describe`/`validate`/`search`/`edit` emit
`{"is_error?": true, ...}` JSON on stdout and exit non-zero (unknown
actions carry `did_you_mean`). Cold starts may still print dependency
compilation before the task body runs, so compile before parsing if that
matters. Flags: `--out FILE` writes the JSON to a file instead of stdout;
`--verbose` restores the logs (breaking pure-JSON stdout).

## The MCP daemon (`mix ash_agent.serve`)

`mix ash_agent.serve` starts a supervised daemon in this VM: a loopback
HTTP MCP server (`127.0.0.1:4100` by default, POST-only JSON-RPC,
stateless — no sessions, no SSE) plus a file watcher on `lib/` and
`config/`. Point an MCP client at it with a `"type": "http"` entry:

```json
{ "ash-agent": { "type": "http", "url": "http://127.0.0.1:4100" } }
```

- **Tools:** `ash_describe` (no args → discovery summary), `ash_validate`,
  `ash_search`, `ash_context`, `ash_forbidden`, `ash_daemon_status`,
  `ash_reload`. All read-only — same contract as the facade. There is no
  edit tool on the daemon: write paths stay in `mix ash_agent.edit` and
  your edit tools.
- **Boot contract holds:** the daemon compiles the project and loads the
  configured domains but never starts the application. The mix boot is
  paid once at daemon start; every tool call is an in-memory read served
  through a checksum-keyed describe cache.
- **Hot reload:** file events trigger a recompile + cache invalidation,
  serialized behind the runtime process so a reload can never race a tool
  call. `ash_reload` is the manual backstop (git stash edge cases, watcher
  misses). Every reload emits `[:ash_agent, :daemon, :reloaded]` telemetry.
- **Loopback only:** the daemon is a dev tool with no auth — do not expose
  the port. Origin headers are validated (DNS-rebinding defense) and
  `MCP-Protocol-Version` is negotiated down to the client (`2024-11-05`
  accepted).
- **Optional deps:** `plug` and `bandit` (HTTP surface) and `file_system`
  (watcher) are optional — Phoenix apps ship all three. Without them the
  daemon refuses to boot (with an install hint) or starts without hot
  reload, respectively.
- Prefer the daemon over per-query `mix ash_agent.*` tasks when you are
  making **many** introspection calls in one session: the boot is paid
  once instead of per call. Single-question sessions are fine with the
  tasks. Prefer in-VM calls (above) when you are already attached to a
  running node.

## Output conventions

- **stdout from the Mix tasks is pure JSON, always** — pipe it straight
  into a JSON parser. Application logger noise is suppressed (unless
  `--verbose`); compile output can still appear when the project is stale,
  so compile before parsing if that matters.
- All reports are plain maps of JSON-safe values — `Jason.encode!/1` always
  works. Atom values (module names, relationship types) encode as strings.
- Input paths and `normalized_inputs` keys are strings, matching the JSON
  params you passed in. Cast values are normalized (e.g. `"7"` becomes `7`
  for `:integer`).
- Unknown-input errors appear exactly once per input, with Ash's own hint
  (valid-inputs list, "Perhaps you meant ...") folded into the structured
  entry rather than duplicated.
- Source locations come from Spark annotations (`file`, `line`, `column`);
  they are best-effort and `nil` where unavailable.
- `context/3` derives symbol spans from consecutive annotation starts (they
  are best-effort, not parsed block ends), and its `manifests` report carries
  the manifest document's string values verbatim. With no semantic manifests
  present (`priv/semantic/**/*.json`, or the `:manifests` option) the field
  is `nil`.
- Types are normalized to readable strings: `:string`, `array<string>`,
  `ci_string` (builtins report their short name; extensions keep their
  module name). Search hits on actions/relationships report the action /
  relationship type instead of a value type.
- `diff_manifest/2` reports field-level changes with `old`/`new` values; a
  field missing on one side reports `null` there. Symbol ids follow the RFC
  §4.3 grammar, so policies (which have no name) appear as ordinal ids like
  `ash:v0:Mod#policies/0` — those ids are position-dependent by design.

## Traces, runtime state, and the kaizen loop

**`AshAgentTools.Trace.explain/2`** (facade: `explain_trace/2`) is the
read-side of trace debugging. Feed it spans from any source — a host-side
ring buffer, an OTLP export, a fixture — and read `report.errors`
(innermost first), `report.queries` (`n_plus_one?: true` entries are your
N+1s), `report.policy`, `report.async`, `report.symbols`, and
`report.truncated?` before anything else. The `:budget` (default ~8000
characters of encoded JSON) is enforced by dropping whole entries, never by
silently shortening them; pass `:backend_url` to get a deep-link echoed
back for the human you escalate to.

**`AshAgentTools.Runtime`** is point-in-time VM introspection — the state
plane that answers "which process is stuck?" while the trace answers "when
did it happen?". `snapshot/1` for vitals, `top/2` for the busiest processes
(`message_queue_len` first — the hidden-queue suspect), `tree/2` for
supervision trees. When the host ships observer_cli 2.0 the answers come
from its heap-capped, JSON-safe snapshot worker (the `observer_cli.cli/v1`
envelope, passed through verbatim under `:response`); otherwise built-in
`Process`/`:ets`/`:supervisor` walks answer, and `backend` in the report
says which. Echo `trace_id:`/`correlation_id:` to join the planes.

**The kaizen loop** turns tool failures into signal. Every miss emits
`[:ash_agent, :tool_gap]` telemetry (`tool`, `gap_kind`, `question`,
`detail` with `did_you_mean` candidates). Hosts can attach any `:telemetry`
handler; the built-in dev sink is one call:

```elixir
AshAgentTools.Kaizen.attach()   # once per dev session (iex, .iex.exs, app start)
# ... let agents miss things for a week ...
AshAgentTools.Kaizen.digest()   # or: mix ash_agent.gaps
```

Read the digest as a worklist: recurring `unknown_input` gaps with the same
candidates are an alias or doc fix waiting to happen; recurring
`context_miss`es on the same directory mean the agent is looking for a
resource that is not Ash (or is not loaded). `did_you_mean` in the tool
output itself is the same signal, folded in at the moment of failure so the
agent can self-correct immediately.

## Name paths and semantic edits

Every DSL entity has a stable **name path** — the DSL-native equivalent of
Serena's `Class/method` addressing:

    Module/attributes/name        Module/relationships/name
    Module/actions/name           Module/policies/policy[0]
    Module/calculations/name      Domain/code_interfaces/name

Custom Spark extension sections are addressed the same way, through a
namespaced dsl_path: `<extension_short_name>_<section_path>` — the
underscored last component of the extension module with a trailing
`_extension`/`_dsl` stripped (`MyApp.Rules.Dsl` → `rules`), so a
`fact_schema do … end` block resolves as
`Module/rules_fact_schema/<entity>` (nested sections extend the path).
Entity names come from the entity's own `:name`/`:id`/`:tag` field, with
a positional `<section>_<index>` fallback when an entity exposes none.
The same kinds appear in `semantic_search/2` (`:kinds` filter included)
and `context/3` output — search `AshAgentTools.Search.valid_kinds/0` for
the live list.

The module part may be a dot-boundary **suffix** (`User/actions/read`);
a leading `/` demands the full module name. Policies are unnamed, so they
are addressed by occurrence. `AshAgentTools.resolve/1` returns the symbol
(kind, type, span, `provenance: :source | :synthetic`) plus the file's
shape digest; misses raise with did_you_mean candidates, ambiguous
suffixes raise with the match list — refine and retry.

**`AshAgentTools.Edit`** performs semantic edits at those anchors:
`replace_entity_block/3`, `insert_before_entity/3`,
`insert_after_entity/3`, `safe_delete_entity/2`. The safety model is
mechanical, not prompt-level:

1. **Dry-run default.** Without `write: true` you get the planned diff and
   the file's shape digest; nothing is written.
2. **Digest handshake.** Writes require `expected_digest` from your last
   read — any change to the file in between refuses the edit
   (`stale_file`).
3. **Provenance guard.** Transformer-injected declarations (no Spark
   annotation — `defaults [:read]` actions and friends) are refused
   (`synthetic_symbol`); edit the declaring construct instead.
4. **Atomic write** with the file's EOLs and indentation preserved.
5. **Post-edit gate.** The file is recompiled with diagnostics captured and
   the resource runs a per-action validate canary; a failed gate reverts
   the file and reports the diagnostics. `safe_delete_entity/2` refuses
   while anything references the entity (`has_references`, with the list).

`mix ash_agent.edit OP NAME_PATH [--body ... | --body-file FILE] [--write
--expected-digest D]` wraps all of it with the same JSON contract.

Truncation is a ladder, not a wall: `semantic_search/2` takes
`:max_results` (default 100) and refuses over-limit searches with
per-resource counts; `context/3` takes `:max_list` (default 25) and marks
capped lists with `*_truncated?` shown/total entries.

## The iron-law judge

`judge_laws/2` (facade for `AshAgentTools.Laws.judge/2`) checks a snippet, a
file's content, or a unified diff against the codified **26 Iron Laws**
(adapted from phxagents.dev/iron-laws, MIT — every law is a scar). It is a
deterministic, grep-tier judge: no LLM, no provider keys, and no boot at
all — a pure function over the text you hand it. Output is violations-only,
tiered by pattern certainty (`definite` → `likely` → `review`), with a
default floor of `likely` so review-tier hints stay in `counts` without
flooding `violations`.

```elixir
report = AshAgentTools.judge_laws(source)
report.violations   # [%{law: "10", name: ..., tier: "definite", line: 3, text: ..., hint: ...}]
report.counts       # %{definite: 1, likely: 0, review: 2} — every tier, even when filtered
report.laws_without_detectors  # the behavioral laws (a review checklist, not greps)
```

`diff?: true` judges only the added (`+`) lines of a unified diff — the
pre-apply gate for your own edits. `laws:` restricts by id; `:min_tier`
moves the floor. The full law text ships as the **`usage-rules/iron-laws.md`
sub-rule**, so `mix usage_rules.sync` distributes the laws themselves as
agent rules (`ash_agent_tools:iron-laws` section) alongside this file —
that sub-rule, not this paragraph, is what to consult for what each law
means.

Read hits honestly: a hit means the *pattern* matched, and the tier is the
pattern's certainty — judge context (the compile-time-constant
`String.to_atom` is the documented exception to #10).

## Integration posture

- Do not wrap this package in editor- or server-registered tool surfaces.
  Package-registered MCP tools have been rejected upstream (Tidewave PRs
  #237/#242); the accepted pattern is plain code + usage rules, with agents
  composing calls themselves. If Tidewave's tool-definition API lands
  (PR #215), each function here maps 1:1 onto a tool definition — adapt
  then, don't pre-integrate.
- If you add agent-facing behavior to this package, keep it read-only and
  JSON-encodable, and document it here.

## Known limits

- Domain-level `define` code interfaces are discovered by scanning loaded
  domains that list the resource; very large projects may prefer describing
  the action directly.
- `validate_input/3` reports input-level errors (casting, missing required
  keys, unknown keys, build-time errors). It cannot predict
  context-dependent failures (authorization, uniqueness checks, custom
  validations that need an actor) — those only surface when an action
  actually runs.
- `explain_forbidden/2` requires `Ash.Policy.Authorizer` for policy
  listings; resources with other authorizers get a pointer instead.
- `context/3` positions symbols via Spark annotations; modules compiled
  without debug info carry no annotations, so their symbols cannot be
  positioned (the module still cannot be matched by file) and the report
  comes back with `module: null`, `match: null`.
- `explain_trace/2` reports durations in the input's own time units (it
  cannot know whether an exporter produced nanoseconds or milliseconds),
  and its N+1 detection is purely structural: identical sources under one
  parent. It does not execute anything and does not fetch spans from a
  backend.
- `AshAgentTools.Runtime` observes the VM it runs in — point it at the node
  that actually runs your application (the `runtime` task boots it for
  you). The builtin tree walk reports a library application with no
  running top supervisor as `root: null`; that is data, not a failure.
- The kaizen ETS aggregate lives in the VM that attached it; a fresh mix
  boot digests to `gaps: []`. Emitting never raises and a broken handler
  never breaks a tool.
