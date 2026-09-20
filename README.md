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
```

Or from the shell, no code execution required:

```sh
mix ash_agent.describe                       # discovery summary
mix ash_agent.describe MyApp.Post create     # action contract
mix ash_agent.validate MyApp.Post create '{"title": "Hi"}'
mix ash_agent.validate MyApp.Post create '{"title": "Hi"}' --out report.json
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

## Installation

```elixir
def deps do
  [
    {:ash_agent_tools, "~> 0.1"}
  ]
end
```

Ash (`~> 3.0`) is the only runtime dependency besides `jason`.

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

## Contributing

Conventional Commits; MIT licensed with REUSE/SPDX headers on every source
file (`reuse lint` clean).

## License

MIT — see [LICENSES/MIT.txt](LICENSES/MIT.txt).
