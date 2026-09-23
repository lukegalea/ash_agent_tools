# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

import Config

# The BPMN/decision tooling tests talk to a real PostgreSQL through the
# sandboxed TestRepo — the ash_bpmn/ash_decisions resource macros are
# AshPostgres by construction. `SKIP_DB=1` excludes those tests (`:db` tag)
# for runs without a database; every other test in the suite is unaffected.
if System.get_env("SKIP_DB") do
  config :ash_agent_tools, :db_tests_enabled?, false
else
  config :ash_agent_tools, :db_tests_enabled?, true
end

config :ash_agent_tools,
  ecto_repos: [AshAgentTools.TestRepo]

config :ash_agent_tools, AshAgentTools.TestRepo,
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: "ash_agent_tools_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  queue_target: 1000

# Ash loads relationships (the export reads the pinned definition) in spawned
# Tasks by default; those processes do not own the sandbox connection and hit
# DBConnection.OwnershipError intermittently. The standard fix, and what
# `mix igniter.install ash_postgres` writes.
config :ash, disable_async?: true

# With ash_postgres on the dependency graph, Ash requires an explicit string
# length count (it is what SQL data layers count). Codepoints is the
# recommended setting.
config :ash, default_string_length_count: :codepoints

# This package's test domains are fixtures for introspection, not application
# domains: none of them is meant to land in `config :ash_agent_tools,
# :ash_domains`, which is the host's declaration. Ash's inclusion validation
# (active with ash_postgres on the graph) would otherwise warn on every one.
config :ash, :validate_domain_config_inclusion?, false
config :ash, :validate_domain_resource_inclusion?, false

# Deterministic engine tests: the ash_bpmn runtime's Oban shim executes
# workers inline instead of enqueueing (no Oban instance is started here), and
# the fixture resolver maps every candidate spec to a deterministic principal.
config :ash_bpmn, oban_testing: :inline
config :ash_bpmn, assignment_resolver: AshAgentTools.Test.AssignmentResolver

config :logger, level: :warning
