# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Seeds do
  @shortdoc "Seed labels for standards over code, from the laws judge and fix commits, as JSON"

  @moduledoc """
  Seed labels for questions judged over code: positives from the iron-laws
  judge where a detector exists, and before/after pairs from fix commits.
  Wraps `AshAgentTools.CodeSubjects.Seeds`.

  **Pure text processing and `git log`.** Nothing is booted or compiled.
  **stdout is pure JSON, always.**

  ## Usage

      mix ash_agent.seeds ROOT --standards standards.json

  `standards.json` is a list of standards:

      [
        {"id": "std-handle-event-authorized", "laws": ["11"],
         "pattern": "authori[sz]|handle_event", "kinds": ["function"]},
        {"id": "std-no-novelty-claims", "pattern": "novelty", "kinds": ["doc_paragraph"]}
      ]

  `laws` maps law ids onto the standard (the laws-judge source); `pattern`
  is a case-insensitive regex over commit messages (the fix-commit source).
  Either may be absent.

  ## Command line options

    * `--standards FILE` (required) - the standards file
    * `--repository NAME` - the repository name in subject ids (default: ROOT's basename)
    * `--revisions RANGE` - the `git log` range for fix commits (default `HEAD`)
    * `--max-units N` - skip fix commits that change more units than this (default 6)
    * `--path PATH` - scan only these paths for the laws source; repeatable
    * `--min-tier TIER` - the laws judge's floor (default `likely`)
    * `--baseline FILE` - a reviewed iron-laws baseline (`[{law, file, text, reason}]`);
      excused hits become negative labels. Default: `scripts/iron-laws.baseline.json`
      under ROOT when it exists
    * `--no-text` - drop subject text and context from the output
    * `--out FILE` - write the JSON to FILE instead of stdout
    * `--pretty` - pretty-print the JSON

  The output holds `labels` and `counts`: per standard, per source, the
  number of positive and negative labels.
  """

  use Mix.Task

  alias AshAgentTools.CodeSubjects
  alias AshAgentTools.CodeSubjects.Seeds
  alias AshAgentTools.TaskOutput

  @switches [
    standards: :string,
    repository: :string,
    revisions: :string,
    max_units: :integer,
    path: :keep,
    min_tier: :string,
    baseline: :string,
    text: :boolean,
    out: :string,
    pretty: :boolean,
    verbose: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: @switches)
    root = Path.expand(List.first(positional) || ".")

    try do
      TaskOutput.with_quiet_logger(opts, fn ->
        root
        |> report(opts)
        |> Jason.encode!(pretty: !!opts[:pretty])
        |> TaskOutput.write_json(opts)
      end)
    rescue
      error in ArgumentError ->
        TaskOutput.emit_json_error(%{error: Exception.message(error)}, opts)
        exit({:shutdown, 1})
    end
  end

  defp report(root, opts) do
    standards = read_standards!(opts[:standards])
    repository = opts[:repository] || Path.basename(root)

    law_map =
      for standard <- standards, law <- standard.laws, into: %{}, do: {law, standard.id}

    law_labels =
      if law_map == %{} do
        []
      else
        scan_opts = [repository: repository] ++ paths(opts)
        subjects = CodeSubjects.scan(root, scan_opts).subjects

        Seeds.from_laws(root, subjects,
          standards: law_map,
          min_tier: min_tier(opts[:min_tier]),
          baseline: baseline(root, opts[:baseline])
        )
      end

    fix_standards = for standard <- standards, standard.pattern, do: Map.delete(standard, :laws)

    fix_labels =
      if fix_standards == [] do
        []
      else
        Seeds.from_fix_commits(root,
          standards: fix_standards,
          revisions: opts[:revisions] || "HEAD",
          max_units: opts[:max_units] || 6,
          repository: repository
        )
      end

    labels = law_labels ++ fix_labels

    %{
      repository: repository,
      revision: head(root),
      counts: counts(labels),
      labels: Enum.map(labels, &(&1 |> Map.update!(:subject, fn s -> trim_subject(s, opts) end)))
    }
  end

  defp read_standards!(nil), do: raise(ArgumentError, "--standards FILE is required")

  defp read_standards!(path) do
    with {:ok, body} <- File.read(path),
         {:ok, list} when is_list(list) <- Jason.decode(body) do
      Enum.map(list, &standard!/1)
    else
      _ -> raise ArgumentError, "#{path} is not a JSON list of standards"
    end
  end

  defp standard!(%{"id" => id} = raw) when is_binary(id) do
    %{
      id: id,
      laws: Map.get(raw, "laws", []),
      pattern: Map.get(raw, "pattern"),
      kinds: raw |> Map.get("kinds", ["function", "dsl_entity"]) |> Enum.map(&kind!/1)
    }
  end

  defp standard!(other), do: raise(ArgumentError, "a standard needs an id: #{inspect(other)}")

  defp kind!(name) do
    Enum.find(CodeSubjects.kinds(), &(Atom.to_string(&1) == name)) ||
      raise ArgumentError, "unknown kind #{inspect(name)}"
  end

  defp paths(opts) do
    case Keyword.get_values(opts, :path) do
      [] -> []
      paths -> [paths: paths]
    end
  end

  defp baseline(root, nil) do
    default = Path.join(root, "scripts/iron-laws.baseline.json")
    if File.regular?(default), do: baseline(root, default), else: []
  end

  defp baseline(_root, path) do
    with {:ok, body} <- File.read(path),
         {:ok, entries} when is_list(entries) <- Jason.decode(body) do
      entries
    else
      _ -> raise ArgumentError, "#{path} is not a JSON list of baseline entries"
    end
  end

  defp min_tier(nil), do: :likely

  defp min_tier(name) do
    Enum.find(AshAgentTools.Laws.tiers(), &(Atom.to_string(&1) == name)) ||
      raise ArgumentError, "unknown --min-tier #{inspect(name)}"
  end

  defp counts(labels) do
    labels
    |> Enum.group_by(& &1.standard)
    |> Map.new(fn {standard, group} ->
      {standard,
       group
       |> Enum.group_by(& &1.source)
       |> Map.new(fn {source, rows} ->
         {source,
          %{
            positive: Enum.count(rows, & &1.label),
            negative: Enum.count(rows, &(not &1.label))
          }}
       end)}
    end)
  end

  defp trim_subject(subject, opts) do
    if opts[:text] == false, do: Map.drop(subject, [:text, :context]), else: subject
  end

  defp head(root) do
    case System.cmd("git", ["-C", root, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end
end
