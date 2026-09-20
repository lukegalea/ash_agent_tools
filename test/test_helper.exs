# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

# The introspection API is a pure function over *loaded* modules; make sure
# the test support modules are loaded before any doctest or test runs.
[
  AshAgentTools.Test.Domain,
  AshAgentTools.Test.Post,
  AshAgentTools.Test.Author,
  AshAgentTools.Test.Comment,
  AshAgentTools.Test.Guarded
]
|> Enum.each(&Code.ensure_loaded!/1)

ExUnit.start()
