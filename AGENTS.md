<!-- SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools> -->
<!-- SPDX-License-Identifier: MIT -->

# AGENTS.md

This is `ash_agent_tools`, read-only Ash introspection for AI agents.

## Agent constitution

This repository follows `AGENT_PRINCIPLES.md` v1.5, the agent constitution of
the ai-sdlc platform:
<https://github.com/lukegalea/ai-sdlc/blob/master/AGENT_PRINCIPLES.md>.
That file is the root policy for every agent session here. This file adds the
rules of this repository only. It does not replace or weaken the root policy.
If a rule here contradicts a security rule there, stop and ask a human. The
link opens only for people with access to the ai-sdlc repository. If you cannot
open it, these rules from it still apply:

- Do not approve your own work. A human approves every merge and every release.
- Do not put a secret in a file, a commit, a log, or a prompt.
- Do not publish anything outside this repository without human approval.
- Do not say that work is verified unless a CI result shows it.

## Project guidelines

- The tools are read-only. They return plain, JSON-encodable maps and execute
  nothing.
- The package does not register MCP tools or any other editor-side tool
  surface. The API is plain functions and Mix tasks.
- The introspection tasks boot `app.config` and compile only. They never start
  the host application. Only `runtime` boots it.
- The Mix tasks write pure JSON to stdout. Logger noise stays off stdout unless
  you pass `--verbose`.
- The concept tooling (`ash_rules`, `ash_bpmn`, `ash_decisions`,
  `ash_state_machine`) is optional. Without a dependency, its tools return an
  install hint, and the package still compiles with zero forced dependencies.
- Commits use Conventional Commits. Every source file has an SPDX header, and
  `reuse lint` must be clean.

## Before you finish

CI runs `mix compile --force --warnings-as-errors`, `mix test`,
`mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`, `mix docs`,
`mix deps.unlock --check-unused`, `mix deps.audit`, and a REUSE check. Run them
before you finish.

## Generated sections

This repository does not run `mix usage_rules.sync` today. If it starts to, the
task adds its own section at the end of this file, between its
`usage-rules-start` and `usage-rules-end` markers. Do not edit text inside
those markers. Keep the rules of this repository above them.
