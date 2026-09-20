# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

import Config

# Ash 3.33+ requires an explicit string-length counting mode. `:codepoints`
# matches how SQL data layers count, so constraints are consistent between
# Elixir-side validation and the database.
config :ash, default_string_length_count: :codepoints

if config_env() == :test do
  # The test support domain must be registered so Ash's
  # domain-config-inclusion verifier accepts it.
  config :ash_agent_tools, ash_domains: [AshAgentTools.Test.Domain]
end
