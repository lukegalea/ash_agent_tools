# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Evaluate do
  @shortdoc "Dry-evaluates a DMN decision against JSON inputs"

  @moduledoc """
  Evaluates a DMN decision against a JSON inputs map and prints the result —
  a **designer preview**: `AshDecisions.Evaluator.evaluate/3` with
  `record: false` hard-coded, so no `Evaluation` row is ever written.
  **Requires the optional `ash_decisions` dependency.**

  Resolves the latest **published** version by default; `--version N` pins
  one and `--draft` evaluates the key's draft (draft evaluation churns the
  engine's model cache, so it sits behind the explicit flag). Documents
  declaring several decisions need `--decision NAME`; an ambiguous call is
  a structured error naming the declared decisions.

  **Boot contract: compile, don't start.** **stdout is pure JSON, always.**

  ## Usage

      mix ash_agent.evaluate KEY JSON_INPUTS [--decision NAME] [--version N] [--draft]
          [--domain D] [--out FILE] [--pretty] [--verbose]

  ## Examples

      $ mix ash_agent.evaluate surcharge '{"region": "international"}'
      {"key":"surcharge","version":1,"decision":"Surcharge","outputs":{"surcharge":"25"},
       "duration_us":812,"recorded":false}

      $ mix ash_agent.evaluate surcharge '{"region": "domestic"}' --decision Surcharge
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          decision: :string,
          version: :integer,
          draft: :boolean,
          domain: :string,
          pretty: :boolean,
          out: :string,
          verbose: :boolean
        ]
      )

    AshAgentTools.TaskOutput.with_quiet_logger(opts, fn ->
      AshAgentTools.TaskOutput.ensure_compiled()
      AshAgentTools.TaskOutput.load_configured_domains()

      case positional do
        [key, inputs_json] ->
          inputs = decode_inputs!(inputs_json)

          tool_opts = [
            decision: opts[:decision],
            version: opts[:version],
            draft: opts[:draft],
            domain: opts[:domain]
          ]

          try do
            AshAgentTools.decision_evaluate(key, inputs, tool_opts)
            |> Jason.encode!(pretty: !!opts[:pretty])
            |> AshAgentTools.TaskOutput.write_json(opts)
          rescue
            error in ArgumentError ->
              AshAgentTools.TaskOutput.emit_json_error(
                %{error: Exception.message(error), did_you_mean: []},
                opts
              )

              exit({:shutdown, 1})
          end

        _ ->
          Mix.raise(
            "Usage: mix ash_agent.evaluate KEY JSON_INPUTS [--decision NAME] [--version N]"
          )
      end
    end)
  end

  defp decode_inputs!(json) do
    case Jason.decode(json) do
      {:ok, inputs} when is_map(inputs) -> inputs
      {:ok, _} -> Mix.raise("JSON_INPUTS must be a JSON object")
      {:error, reason} -> Mix.raise("Invalid JSON_INPUTS: #{Exception.message(reason)}")
    end
  end
end
