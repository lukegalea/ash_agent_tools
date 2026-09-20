# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Runtime do
  @shortdoc "BEAM runtime snapshot, top processes, or supervision tree as JSON"

  @moduledoc """
  Read-only BEAM runtime introspection as JSON: a VM `snapshot`, the `top`
  busiest processes, or an application's supervision `tree`.

  Wraps `AshAgentTools.Runtime` (which delegates to observer_cli 2.0's
  JSON-safe snapshot worker when the host ships it, and falls back to
  built-in `Process`/`:ets`/`:supervisor` walks otherwise — the report says
  which backend answered). Nothing is executed against your data and the
  VM is not mutated: no tracing, no signals.

  The point of observing through the mix task is that `app.start` boots your
  application first, so the tree and top processes are *your project's* —
  not Mix's.

  **stdout is pure JSON, always.** Logger output from application start is
  suppressed while the task runs; use `--verbose` if you want the logs back.

  ## Usage

      mix ash_agent.runtime snapshot [--n N] [--trace-id ID] [--correlation-id ID] [--out FILE] [--pretty]
      mix ash_agent.runtime top [N] [--sort KEY] [--trace-id ID] [--correlation-id ID] [--out FILE] [--pretty]
      mix ash_agent.runtime tree [APP] [--depth N] [--trace-id ID] [--correlation-id ID] [--out FILE] [--pretty]

  `--trace-id`/`--correlation-id` are echoed into the report, joining this
  point-in-time view to a trace under investigation (OTel = time plane,
  observer = state plane).

  ## Command line options

    * `top`: `N` (default 10) — how many processes; `--sort` one of
      `message_queue_len` (default), `memory`, `reductions`
    * `tree`: `APP` (default: all started applications); `--depth` levels
      walked (default 5)
    * `--trace-id ID` / `--correlation-id ID` - echoed into the report
    * `--out FILE` - write the JSON to FILE instead of stdout
    * `--pretty` - pretty-print the JSON (default: compact, which is cheaper for agents)
    * `--verbose` - do not suppress Logger output (breaks pure-JSON stdout)

  ## Examples

      $ mix ash_agent.runtime snapshot
      {"backend":"observer_cli","trace_id":null,"correlation_id":null,
       "command":"snapshot","response":{"schema":"observer_cli.cli/v1",...}}

      $ mix ash_agent.runtime top 20
      {"backend":"builtin","sort":"message_queue_len","count":20,"processes":[
        {"pid":"#PID<0.1234.0>","name":"MyApp.Projector","message_queue_len":412,...}]}

      $ mix ash_agent.runtime tree MyApp
      {"backend":"builtin","filter":"MyApp","applications":[{"name":"my_app","root":{...}}]}
  """

  use Mix.Task

  # app.start runs inside run/1 (not via @requirements) so the logger is
  # silenced before the application boots — and so the supervision tree and
  # process population being observed is the host application's.
  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          pretty: :boolean,
          out: :string,
          verbose: :boolean,
          n: :integer,
          sort: :string,
          depth: :integer,
          trace_id: :string,
          correlation_id: :string
        ]
      )

    AshAgentTools.TaskOutput.with_quiet_logger(opts, fn ->
      Mix.Task.run("app.start")

      case positional do
        ["snapshot"] ->
          AshAgentTools.Runtime.snapshot(
            n: Keyword.get(opts, :n, 10),
            trace_id: opts[:trace_id],
            correlation_id: opts[:correlation_id]
          )

        ["top"] ->
          AshAgentTools.Runtime.top(Keyword.get(opts, :n, 10),
            sort: opts[:sort] || "message_queue_len",
            trace_id: opts[:trace_id],
            correlation_id: opts[:correlation_id]
          )

        ["top", n] ->
          AshAgentTools.Runtime.top(positive_int!(n, "top N"),
            sort: opts[:sort] || "message_queue_len",
            trace_id: opts[:trace_id],
            correlation_id: opts[:correlation_id]
          )

        ["tree"] ->
          AshAgentTools.Runtime.tree(nil,
            depth: Keyword.get(opts, :depth, 5),
            trace_id: opts[:trace_id],
            correlation_id: opts[:correlation_id]
          )

        ["tree", app] ->
          AshAgentTools.Runtime.tree(app,
            depth: Keyword.get(opts, :depth, 5),
            trace_id: opts[:trace_id],
            correlation_id: opts[:correlation_id]
          )

        _ ->
          Mix.raise(
            "Usage: mix ash_agent.runtime snapshot|top|tree [ARGS] [--out FILE] [--pretty]"
          )
      end
      |> Jason.encode!(pretty: !!opts[:pretty])
      |> AshAgentTools.TaskOutput.write_json(opts)
    end)
  end

  defp positive_int!(value, what) do
    case Integer.parse(value) do
      {n, ""} when n > 0 ->
        n

      _ ->
        Mix.raise("#{what} must be a positive integer, got: #{inspect(value)}")
    end
  end
end
