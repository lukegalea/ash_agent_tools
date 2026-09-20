# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Gaps do
  @shortdoc "Digests the kaizen tool-gap telemetry aggregate as JSON"

  @moduledoc """
  Prints the kaizen tool-gap digest as JSON: which `mix ash_agent.*` tools
  failed to answer, how often, with what questions, and which `did_you_mean`
  candidates kept coming back — the weekly "propose an alias / a doc fix /
  a new default" list, read from aggregates rather than prose.

  Wraps `AshAgentTools.Kaizen.digest/0`. The aggregate lives in the VM where
  `AshAgentTools.Kaizen.attach/0` was called (an `iex` session, `.iex.exs`,
  or dev application start); a fresh mix boot has no gaps recorded yet and
  reports `gaps: []`. Run this task with `--out` from the attached session,
  or call `AshAgentTools.Kaizen.digest/0` directly in-VM — the digest of a
  long-lived dev node is the one that matters.

  Tools report their own misses: `validate` (unknown inputs, with the
  closest real input names), `search` (no hits, with the closest known
  symbols), `context` (no Ash module at the position, with the closest
  declared files). Any `:telemetry` consumer can attach to the same
  `[:ash_agent, :tool_gap]` event instead.

  **stdout is pure JSON, always.**

  ## Usage

      mix ash_agent.gaps [--out FILE] [--pretty] [--verbose]

  ## Examples

      $ mix ash_agent.gaps
      {"event":"ash_agent.tool_gap","attached?":true,"table_present?":true,
       "generated_at":"2026-09-20T12:00:00.000000Z","total":3,"gaps":[
         {"tool":"validate","gap_kind":"unknown_input","count":3,
          "last_question":"MyApp.Post.create",
          "samples":[{"question":"MyApp.Post.create","detail":{"unknown":["approver_id"],
                      "candidates":{"approver_id":["approver","owner_id"]}}}]}]}

  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args, strict: [pretty: :boolean, out: :string, verbose: :boolean])

    AshAgentTools.TaskOutput.with_quiet_logger(opts, fn ->
      # The digest reads the ETS aggregate of this VM; no app boot is
      # needed, but silence the logger all the same so stdout stays pure
      # JSON for the window the task runs in.
      AshAgentTools.Kaizen.digest()
      |> Jason.encode!(pretty: !!opts[:pretty])
      |> AshAgentTools.TaskOutput.write_json(opts)
    end)
  end
end
