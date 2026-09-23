# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.TestRepo do
  @moduledoc """
  The sandboxed PostgreSQL repo behind the BPMN/decision tooling tests.

  Test-only, like the fixtures it serves: the `ash_bpmn`/`ash_decisions`
  resource macros are AshPostgres by construction (`repo:` is a required
  option), so exercising the tools against the real macros means a real
  database. This library's own code never touches it — `lib/` is data-layer
  agnostic as ever.
  """

  use AshPostgres.Repo, otp_app: :ash_agent_tools, warn_on_missing_ash_functions?: false

  def installed_extensions, do: ["uuid-ossp", "citext", "ash-functions"]

  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}
end
