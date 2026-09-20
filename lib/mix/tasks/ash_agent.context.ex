# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Context do
  @shortdoc "Describes the Ash context at a file position as JSON"

  @moduledoc """
  Prints, as JSON, which loaded Ash resource/domain declares at or near a
  source position: the containing symbol, its nearest neighbours, what
  references it (actions that accept it, code interfaces that call it,
  relationships wired through it), and — when `priv/semantic/**/*.json`
  manifests exist — manifest-derived relations for the module.

  Wraps `AshAgentTools.context/3`. One call replaces the grep → read →
  re-grep loop: point it wherever a cursor, compiler error, or diff hunk
  landed. A position inside no declaration still reports the surrounding
  module and nearest symbols; a file that belongs to no loaded Ash module
  reports `module: null`, `match: null`. Nothing is executed against your
  data.

  **Boot contract: compile, don't start.** The task boots only
  `app.config` + compile + the domains configured under
  `config :my_app, ash_domains: [...]` — the application is *not started*
  (no Oban queues, no projectors, no endpoints). See usage-rules.md.

  **stdout is pure JSON, always.** Logger output is suppressed while the
  task runs; use `--verbose` if you want the logs back.

  ## Usage

      mix ash_agent.context PATH:LINE [--out FILE] [--pretty] [--verbose]

  The position may also be given as two arguments (`PATH LINE`). `PATH` is
  repo-relative or absolute; matching is done against the compile-time file
  recorded in each symbol's Spark annotation.

  ## Command line options

    * `--out FILE` - write the JSON to FILE instead of stdout
    * `--pretty` - pretty-print the JSON (default: compact, which is cheaper for agents)
    * `--verbose` - do not suppress Logger output (breaks pure-JSON stdout)

  ## Examples

      $ mix ash_agent.context lib/my_app/accounts/post.ex:42
      {"file":"lib/my_app/accounts/post.ex","line":42,
       "module":{"module":"MyApp.Accounts.Post","kind":"resource","domain":"MyApp.Accounts",...},
       "match":{"kind":"attribute","name":"title","span":{"start_line":40,"end_line":44},...},
       "nearest":[...],"references":{...},"manifests":null}

  """

  use Mix.Task

  # Compile-only boot: introspection needs compiled DSL state, not a
  # running application (see the moduledoc and usage-rules.md).
  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, strict: [pretty: :boolean, out: :string, verbose: :boolean])

    AshAgentTools.TaskOutput.with_quiet_logger(opts, fn ->
      AshAgentTools.TaskOutput.ensure_compiled()

      # Resource modules load lazily; load the domains configured the way
      # ash projects declare them so context covers the declared surface.
      AshAgentTools.TaskOutput.load_configured_domains()

      case parse_position(positional) do
        {file, line} ->
          {:ok, report} = AshAgentTools.context(file, line)

          report
          |> Jason.encode!(pretty: !!opts[:pretty])
          |> AshAgentTools.TaskOutput.write_json(opts)

        :error ->
          Mix.raise("Usage: mix ash_agent.context PATH:LINE [--out FILE] [--pretty]")
      end
    end)
  end

  # Accepts `PATH:LINE` (split at the last colon, so paths containing
  # colons keep working) or the two-argument `PATH LINE` form.
  defp parse_position([arg]) do
    case String.split(arg, ":") do
      [_single] ->
        :error

      parts ->
        [line | file_parts] = Enum.reverse(parts)
        position(Enum.join(Enum.reverse(file_parts), ":"), line)
    end
  end

  defp parse_position([file, line]), do: position(file, line)
  defp parse_position(_), do: :error

  defp position(file, line) do
    case Integer.parse(line) do
      {line, ""} when line > 0 -> {file, line}
      _ -> :error
    end
  end
end
