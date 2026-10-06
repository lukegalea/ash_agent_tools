# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.MixTask do
  @moduledoc """
  Shared plumbing for `mix ash_agent.*` tasks.

  Tasks provide only their task-specific options and callback. The helper keeps
  compile-only boot, quiet logging, and JSON output consistent across tasks.
  """

  alias AshAgentTools.TaskOutput

  @common_options [pretty: :boolean, out: :string, verbose: :boolean]

  @doc """
  Parses task arguments, performs compile-only boot, and invokes `fun`.

  The callback receives positional arguments and parsed options. Configured Ash
  domains are loaded only when `load_domains?` is true, preserving the tasks'
  existing lazy-loading behavior.
  """
  def run(args, fun, extra_options \\ [], load_domains? \\ false)
      when is_list(args) and is_list(extra_options) and is_boolean(load_domains?) and
             is_function(fun, 2) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, strict: extra_options ++ @common_options)

    TaskOutput.with_quiet_logger(opts, fn ->
      TaskOutput.ensure_compiled()

      if load_domains? do
        TaskOutput.load_configured_domains()
      end

      fun.(positional, opts)
    end)
  end

  @doc "Encodes a result and writes it using the task's output options."
  def write_json(result, opts) do
    result
    |> Jason.encode!(pretty: !!opts[:pretty])
    |> TaskOutput.write_json(opts)
  end

  @doc "Writes a structured JSON error using the task's output options."
  def emit_json_error(payload, opts), do: TaskOutput.emit_json_error(payload, opts)
end
