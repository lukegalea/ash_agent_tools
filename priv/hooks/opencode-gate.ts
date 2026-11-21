// SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
//
// SPDX-License-Identifier: MIT

// opencode adapter for the pre-flight gate (AshAgentTools.Gate): a plugin
// whose tool.execute.before posts each tool call to the ash_agent daemon's
// POST /gate and throws, which blocks the call, on "deny" and on "ask"
// (tool.execute.before cannot open a permission prompt, so "ask" blocks with
// the reason and the agent brings it to a person).
//
// When the daemon cannot answer (not running, an error, too slow), the call
// is blocked as an "ask": an unanswered gate is not an allow. Read-only tools
// pass, so the session can still look around.
//
//   ASH_AGENT_GATE_URL          default http://127.0.0.1:4100/gate
//   ASH_AGENT_GATE_TIMEOUT_MS   default 1000

import type { Plugin } from "@opencode-ai/plugin"

const READ_ONLY = new Set(["read", "glob", "grep", "list"])
const GATE_URL = process.env.ASH_AGENT_GATE_URL ?? "http://127.0.0.1:4100/gate"
const TIMEOUT_MS = Number(process.env.ASH_AGENT_GATE_TIMEOUT_MS ?? 1000)

type Verdict = { decision: string; rule_id: string; reason: string }

export const AshAgentGate: Plugin = async ({ directory }) => ({
  "tool.execute.before": async (input, output) => {
    let verdict: Verdict
    try {
      const response = await fetch(GATE_URL, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          harness: "opencode",
          tool: input.tool,
          sessionID: input.sessionID,
          args: output.args,
          directory,
        }),
        signal: AbortSignal.timeout(TIMEOUT_MS),
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      verdict = (await response.json()) as Verdict
    } catch (error) {
      if (READ_ONLY.has(input.tool)) return
      const why = error instanceof Error ? error.message : String(error)
      throw new Error(`The pre-flight gate is unavailable (${why}): a person decides on this ${input.tool} call.`)
    }

    if (verdict.decision === "allow" || verdict.decision === "defer") return
    if (verdict.decision === "deny") {
      throw new Error(`Denied by gate rule ${verdict.rule_id}: ${verdict.reason}`)
    }
    throw new Error(`Gate rule ${verdict.rule_id} asks a person first: ${verdict.reason}`)
  },
})
