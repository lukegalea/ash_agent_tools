# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

# Test-only configuration: the sandboxed TestRepo behind the BPMN/decision
# tooling tests (see test/support/test_repo.ex). This package ships no
# runtime configuration of its own.
import Config

if config_env() == :test do
  import_config "test.exs"
end
