# Rules for working with AshAgentTools

AshAgentTools is a read-only introspection layer over Ash. It answers an
agent's questions about a project's domains, resources, and actions as plain
JSON-encodable maps, validates action inputs without running anything, and
lists the policies that can forbid an action. It ships as **regular library
code plus this file** — deliberately *not* as registered MCP tools or any
other tool-surface integration, which keeps it usable from `project_eval`,
Livebook, Mix tasks, or any future hosted tool-definition API. Read these
rules before using it; do not assume prior knowledge of the API.

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

Compose these freely: the typical loop is describe → validate → execute →
on `Forbidden`, explain_forbidden → adjust inputs or actor.

## Mix tasks

For agents without code execution:

- `mix ash_agent.describe` — JSON summary of loaded domains/resources
- `mix ash_agent.describe MyApp.Post` — resource description
- `mix ash_agent.describe MyApp.Post create` — action description
- `mix ash_agent.validate MyApp.Post create '{"title": "Hi"}'` — validation
  report

Both tasks run `app.start`, print compact JSON by default (`--pretty` for
humans), load the domains your app registers under
`config :my_app, ash_domains: [...]`, and guarantee **pure-JSON stdout**:
Logger output from application start (repo wiring, banners, debug logs) is
suppressed for the duration of the task. Flags: `--out FILE` writes the
JSON to a file instead of stdout; `--verbose` restores the logs (breaking
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
- Types are normalized to readable strings: `:string`, `array<string>`,
  `ci_string` (builtins report their short name; extensions keep their
  module name).

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
