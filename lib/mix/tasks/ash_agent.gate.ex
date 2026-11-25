# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Gate do
  @shortdoc "Explains a pre-flight gate decision, or verifies the gate's tables, as JSON"

  @moduledoc """
  Debugs the pre-flight tool-call gate (`AshAgentTools.Gate`) from the shell.

  Hooks do not use this task (they post to the `mix ash_agent.serve`
  daemon's `POST /gate`, which answers without a mix boot); it is for
  writing and checking rules.

  ## Usage

      mix ash_agent.gate --explain '{"tool":"bash","command":"git push -f origin main","cwd":"."}'
      mix ash_agent.gate --explain - < pretooluse.json
      mix ash_agent.gate --verify

  `--explain` takes a harness payload or a request (see
  `AshAgentTools.Gate.Request`) and prints the decision, the normalised
  request and every table evaluated, without writing the audit log.
  `--verify` runs the `ash_decisions` verifier over every table (the System
  One rung's banding table too, when the rung is configured) and exits
  non-zero when one does not pass. **stdout is pure JSON.**

  When a System One rung is configured (`config :ash_agent_tools, :gate,
  system_one: ...`), `--explain` starts its runtime first
  (`AshAgentTools.Gate.system_one_children/1`) and a deferred call is put
  to it, as the daemon does.

  Requires the optional `ash_decisions` dependency.

  ## Command line options

    * `--explain JSON` - the payload to decide (`-` reads stdin)
    * `--verify` - verify the tables instead
    * `--pretty` - pretty-print the JSON
    * `--out FILE` - write the JSON to FILE instead of stdout
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [explain: :string, verify: :boolean, pretty: :boolean, out: :string]
      )

    cond do
      opts[:verify] ->
        report = AshAgentTools.Gate.verify()
        emit(report, opts)
        unless report.ok?, do: exit({:shutdown, 1})

      explain = opts[:explain] ->
        case Jason.decode(read(explain)) do
          {:ok, %{} = payload} ->
            start_system_one()
            payload |> AshAgentTools.Gate.explain() |> emit(opts)

          _ ->
            AshAgentTools.TaskOutput.emit_json_error(
              %{error: "--explain takes a JSON object"},
              opts
            )

            exit({:shutdown, 1})
        end

      true ->
        Mix.raise("Usage: mix ash_agent.gate --explain JSON | --verify")
    end
  end

  defp start_system_one do
    case AshAgentTools.Gate.system_one_children() do
      [] -> :ok
      children -> {:ok, _supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
    end
  end

  defp read("-"), do: IO.read(:stdio, :eof)
  defp read(json), do: json

  defp emit(report, opts) do
    report
    |> Jason.encode!(pretty: !!opts[:pretty])
    |> AshAgentTools.TaskOutput.write_json(opts)
  end
end
