# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

# Dialyzer suppressions for ash_agent_tools.
#
# Entries follow dialyxir's `.exs` ignore format ({file, warning_type});
# keep each entry next to the comment explaining why it is deliberate.

[
  # The `_ -> %{kind: :unknown, type: nil}` fallback in return_shape/2 is
  # deliberate: it keeps describe_resource/1 from crashing should a future
  # Ash release add a new action type, which Dialyzer's success typing
  # cannot see.
  {"lib/ash_agent_tools/describe.ex", :pattern_match_cov}
]
