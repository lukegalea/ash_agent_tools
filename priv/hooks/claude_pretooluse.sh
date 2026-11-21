#!/bin/sh
# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

# Claude Code PreToolUse adapter for the pre-flight gate (AshAgentTools.Gate).
#
# Posts the hook input, unchanged and never evaluated by the shell, to the
# ash_agent daemon's POST /gate?format=claude_code and prints the reply,
# which is already Claude Code's hook output: a permissionDecision of
# "deny" or "ask" with the rule's reason, or {} to leave the call to
# Claude Code's own permissions.
#
# When the daemon cannot answer (not running, an error, too slow), the call
# is put to a person ("ask"): an unanswered gate is not an allow. Read-only
# tools pass, so the session can still look around. Telling a read-only
# tool apart needs jq; without it every call is asked.
#
#   ASH_AGENT_GATE_URL         default http://127.0.0.1:4100/gate
#   ASH_AGENT_GATE_TIMEOUT     seconds, default 1

set -u

url="${ASH_AGENT_GATE_URL:-http://127.0.0.1:4100/gate}"
timeout="${ASH_AGENT_GATE_TIMEOUT:-1}"

input=$(cat)

if reply=$(printf '%s' "$input" |
  curl --silent --fail --max-time "$timeout" \
    --header 'content-type: application/json' \
    --data-binary @- "${url}?format=claude_code"); then
  printf '%s\n' "$reply"
  exit 0
else
  status=$?
fi

tool=""
if command -v jq >/dev/null 2>&1; then
  tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
fi

case "$tool" in
  Read | Glob | Grep | LS | NotebookRead) exit 0 ;;
esac

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"The pre-flight gate is unavailable (curl exit %d): a person decides."}}\n' \
  "$status"
exit 0
