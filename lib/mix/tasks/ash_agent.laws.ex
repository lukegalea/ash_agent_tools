# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Laws do
  @shortdoc "Judges code against the codified iron laws as JSON"

  @moduledoc """
  Judges code — a snippet, a unified diff, or files — against the codified
  *26 Iron Laws* and prints violations as JSON.

  Wraps `AshAgentTools.Laws.judge/2` (registry: `AshAgentTools.Laws.laws/0`;
  the full law text ships as the `usage-rules/iron-laws.md` sub-rule). The
  judge is deterministic pattern-matching — no LLM, no provider keys — at
  three certainty tiers (`definite`, `likely`, `review`) with violations-only
  output: `violations` lists hits at `--min-tier` or above, and `counts`
  covers every tier so filtered hits stay visible.

  **Pure text processing.** Your application is not booted at all — not even
  compiled: the judge needs no project modules, so it is as cheap as
  `ash_agent.diff`. **stdout is pure JSON, always.**

  ## Usage

      mix ash_agent.laws                            # the law registry
      mix ash_agent.laws FILE [FILE...] [--diff]    # judge files
      mix ash_agent.laws --code 'SNIPPET'           # judge a snippet
      mix ash_agent.laws - < patch.diff             # judge stdin

  ## Command line options

    * `--code SNIPPET` - judge the given snippet instead of files
    * `--diff` - treat the input as a unified diff: only added (`+`) lines
      are judged, and whole-file detectors are skipped (they need full context)
    * `--min-tier TIER` - report violations at this certainty or above:
      `definite`, `likely` (default), or `review` (= everything)
    * `--law ID` - restrict the judgement to specific law ids; repeatable,
      commas accepted (`--law 10,04`)
    * `--out FILE` - write the JSON to FILE instead of stdout
    * `--pretty` - pretty-print the JSON (default: compact, which is cheaper for agents)
    * `--verbose` - do not suppress Logger output (breaks pure-JSON stdout)

  ## Examples

      $ mix ash_agent.laws --code 'x = String.to_atom(user_input)'
      {"source":"inline","laws_checked":26,"violations":[
        {"law":"10","name":"no-string-to-atom-on-user-input","category":"security",
         "tier":"definite","line":1,"text":"x = String.to_atom(user_input)","hint":"..."}],
       "counts":{"definite":1,"likely":0,"review":0},"clean?":false,
       "laws_without_detectors":[...]}

      $ mix ash_agent.laws lib/my_app/live/post_live.ex --min-tier review --pretty

      $ git diff main | mix ash_agent.laws - --diff   # judge only added lines

  Multiple files produce one report per source under `sources` with aggregate
  `counts` and a top-level `clean?`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          code: :string,
          diff: :boolean,
          min_tier: :string,
          law: :keep,
          pretty: :boolean,
          out: :string,
          verbose: :boolean
        ]
      )

    try do
      AshAgentTools.TaskOutput.with_quiet_logger(opts, fn ->
        dispatch(opts, positional)
      end)
    rescue
      # a judge that cannot answer (unreadable file, unknown law id) is still
      # an answer: structured JSON on stdout, non-zero exit
      error in ArgumentError ->
        AshAgentTools.TaskOutput.emit_json_error(%{error: Exception.message(error)}, opts)
        exit({:shutdown, 1})
    end
  end

  defp dispatch(opts, positional) do
    cond do
      opts[:code] && positional != [] ->
        Mix.raise("Usage: pass either --code SNIPPET or file arguments, not both")

      opts[:code] ->
        judge_sources([{"inline", opts[:code]}], opts)

      positional == [] ->
        registry_summary(opts)

      true ->
        sources = Enum.map(positional, fn path -> {path, read_source!(path)} end)
        judge_sources(sources, opts)
    end
  end

  defp judge_sources(sources, opts) do
    judge_opts = [
      min_tier: parse_min_tier!(opts[:min_tier]),
      laws: law_ids(opts),
      diff?: !!opts[:diff]
    ]

    case sources do
      [{label, content}] ->
        AshAgentTools.Laws.judge(content, Keyword.put(judge_opts, :file, label))
        |> Jason.encode!(pretty: !!opts[:pretty])
        |> AshAgentTools.TaskOutput.write_json(opts)

      multiple ->
        reports =
          Enum.map(multiple, fn {label, content} ->
            AshAgentTools.Laws.judge(content, Keyword.put(judge_opts, :file, label))
          end)

        aggregate(reports)
        |> Jason.encode!(pretty: !!opts[:pretty])
        |> AshAgentTools.TaskOutput.write_json(opts)
    end
  end

  # `-` reads stdin (e.g. `git diff main | mix ash_agent.laws - --diff`).
  defp read_source!("-"), do: IO.read(:stdio, :eof)

  defp read_source!(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, reason} -> raise ArgumentError, "cannot read #{path}: #{:file.format_error(reason)}"
    end
  end

  defp parse_min_tier!(nil), do: :likely

  defp parse_min_tier!(tier) when is_binary(tier) do
    valid = AshAgentTools.Laws.tiers()
    normalized = Enum.find(valid, &(Atom.to_string(&1) == tier))

    normalized ||
      Mix.raise("Unknown --min-tier #{inspect(tier)}. Valid tiers: #{inspect(valid)}")
  end

  defp law_ids(opts) do
    case Keyword.get_values(opts, :law) do
      [] ->
        nil

      values ->
        values
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp aggregate(reports) do
    tiers = AshAgentTools.Laws.tiers()

    counts =
      Map.new(tiers, fn tier ->
        {tier, Enum.sum(Enum.map(reports, &get_in(&1, [:counts, tier]) || 0))}
      end)

    %{sources: reports, counts: counts, clean?: Enum.all?(reports, & &1.clean?)}
  end

  defp registry_summary(opts) do
    laws = AshAgentTools.Laws.laws()

    %{
      count: length(laws),
      tiers: AshAgentTools.Laws.tiers(),
      laws:
        Enum.map(laws, fn law ->
          %{
            id: law.id,
            name: law.name,
            category: law.category,
            title: law.title,
            summary: law.summary,
            mechanical?: law.detectors != [],
            detectors: length(law.detectors)
          }
        end)
    }
    |> Jason.encode!(pretty: !!opts[:pretty])
    |> AshAgentTools.TaskOutput.write_json(opts)
  end
end
