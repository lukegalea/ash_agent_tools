# Rules for working with AshAgentTools

AshAgentTools is a read-only introspection layer over Ash. It answers an
agent's questions about a project's domains, resources, and actions as plain
JSON-encodable maps, validates action inputs without running anything, lists
the policies that can forbid an action, searches symbol names across
resources, describes the Ash context at any source file position, diffs
semantic-manifest documents, and tells you how to use all of that in-VM
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

All tasks run `app.start` (except `ash_agent.diff`, which needs no
application), print compact JSON by default (`--pretty` for humans), and
guarantee **pure-JSON stdout**: Logger output from application start (repo
wiring, banners, debug logs) is suppressed for the duration of the task.
The describe/search tasks load the domains your app registers under
`config :my_app, ash_domains: [...]`. Flags: `--out FILE` writes the JSON
to a file instead of stdout; `--verbose` restores the logs (breaking
pure-JSON stdout).

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
