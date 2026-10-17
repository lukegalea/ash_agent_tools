# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Subjects do
  @shortdoc "Extracts code units as judgment subjects, as JSON"

  @moduledoc """
  Extracts the code units of a checkout as judgment subjects and prints
  them as JSON: modules, functions, DSL entities and doc paragraphs, or the
  hunks of a diff, or the messages of a commit range. Each subject has a
  stable id, a clickable `path:line` and its text. Wraps
  `AshAgentTools.CodeSubjects`.

  **Pure text processing.** Nothing is booted or compiled: extraction reads
  source files. **stdout is pure JSON, always.**

  ## Usage

      mix ash_agent.subjects [ROOT]                     # every unit under ROOT (default ".")
      mix ash_agent.subjects ROOT --path lib --kind function
      git diff main | mix ash_agent.subjects ROOT --diff -
      mix ash_agent.subjects ROOT --commits main..HEAD
      mix ash_agent.subjects ROOT --locate lib/my_app/post.ex:42

  ## Command line options

    * `--repository NAME` - the repository name in subject ids (default: ROOT's basename)
    * `--path PATH` - scan only these files or directories under ROOT; repeatable
    * `--kind KIND` - keep only these kinds (`module`, `function`, `dsl_entity`,
      `doc_paragraph`, `diff_hunk`, `commit_message`); repeatable, commas accepted
    * `--context SPEC` - capture context: `module_header`, `moduledoc`, `module`,
      `section:<name>`; repeatable
    * `--diff FILE` - subjects for the hunks of a unified diff (`-` reads stdin),
      addressed under their enclosing units in ROOT
    * `--commits RANGE` - subjects for the messages of a commit range (runs `git log`)
    * `--chunk` - split units that would not fit the decision model's context
    * `--max-tokens N` - the context `--chunk` fits (default 1024)
    * `--locate PATH:LINE` - print only the innermost unit containing that line
    * `--summary` - print counts by kind instead of the subjects
    * `--out FILE` - write the JSON to FILE instead of stdout
    * `--pretty` - pretty-print the JSON
  """

  use Mix.Task

  alias AshAgentTools.CodeSubjects
  alias AshAgentTools.TaskOutput

  @switches [
    repository: :string,
    path: :keep,
    kind: :keep,
    context: :keep,
    diff: :string,
    commits: :string,
    chunk: :boolean,
    max_tokens: :integer,
    locate: :string,
    summary: :boolean,
    out: :string,
    pretty: :boolean,
    verbose: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: @switches)
    root = List.first(positional) || "."

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
    extract_opts =
      [context: Keyword.get_values(opts, :context), kinds: kinds(opts)]
      |> put_opt(:repository, opts[:repository])

    {subjects, skipped} = extract(root, opts, extract_opts)

    subjects
    |> maybe_chunk(opts)
    |> maybe_locate(opts[:locate])
    |> shape(skipped, opts)
  end

  defp extract(root, opts, extract_opts) do
    cond do
      opts[:diff] ->
        diff = read_input!(opts[:diff])
        {CodeSubjects.from_diff(diff, Keyword.put(extract_opts, :root, root)), []}

      opts[:commits] ->
        case CodeSubjects.from_commits(root, opts[:commits], extract_opts) do
          {:ok, subjects} -> {subjects, []}
          {:error, output} -> raise ArgumentError, "git log failed: #{output}"
        end

      true ->
        scan_opts =
          case Keyword.get_values(opts, :path) do
            [] -> extract_opts
            paths -> Keyword.put(extract_opts, :paths, paths)
          end

        report = CodeSubjects.scan(root, scan_opts)
        {report.subjects, report.skipped}
    end
  end

  defp kinds(opts) do
    case Keyword.get_values(opts, :kind) |> Enum.flat_map(&String.split(&1, ",", trim: true)) do
      [] ->
        nil

      names ->
        Enum.map(names, fn name ->
          Enum.find(CodeSubjects.kinds(), &(Atom.to_string(&1) == String.trim(name))) ||
            raise ArgumentError,
                  "unknown --kind #{inspect(name)}; kinds: #{Enum.map_join(CodeSubjects.kinds(), ", ", &Atom.to_string/1)}"
        end)
    end
  end

  defp maybe_chunk(subjects, opts) do
    if opts[:chunk] do
      chunk_opts = put_opt([], :max_tokens, opts[:max_tokens])
      context = Keyword.get_values(opts, :context)
      Enum.flat_map(subjects, &CodeSubjects.chunk(&1, context, chunk_opts))
    else
      subjects
    end
  end

  defp maybe_locate(subjects, nil), do: subjects

  defp maybe_locate(subjects, location) do
    case Regex.run(~r/\A(.+):(\d+)\z/, location) do
      [_, path, line] -> List.wrap(CodeSubjects.locate(subjects, path, String.to_integer(line)))
      nil -> raise ArgumentError, "--locate takes PATH:LINE, got #{inspect(location)}"
    end
  end

  defp shape(subjects, skipped, opts) do
    if opts[:summary] do
      %{
        count: length(subjects),
        by_kind: Enum.frequencies_by(subjects, & &1.kind),
        skipped: skipped
      }
    else
      %{count: length(subjects), subjects: subjects, skipped: skipped}
    end
  end

  defp read_input!("-"), do: IO.read(:stdio, :eof)

  defp read_input!(path) do
    case File.read(path) do
      {:ok, content} ->
        content

      {:error, reason} ->
        raise ArgumentError, "cannot read #{path}: #{:file.format_error(reason)}"
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
