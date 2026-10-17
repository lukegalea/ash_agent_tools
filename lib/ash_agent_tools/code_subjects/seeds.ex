# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.CodeSubjects.Seeds do
  @moduledoc """
  Seed labels for questions judged over code, from two deterministic
  sources: the iron-laws judge, where a detector exists, and the history
  of fix commits.

  A seed label says "this version of this unit is (or is not) an example of
  standard S". It is evidence for a person to confirm, not a verdict: each
  carries its `source`, its strength, and the subject version it is about.
  Labels confirmed through the review loop become the labelled set a
  question is calibrated and evaluated on.

  Every label is a plain map:

      %{
        standard: "law-11",                 # the caller's standard id
        label: true,                         # true = an example of the violation
        source: "laws_judge" | "fix_commit",
        strength: "likely" | "review" | "definite" | "weak",
        subject: %{...},                     # the code subject, at the labelled version
        revision: nil | "<sha>",             # the commit the subject version comes from
        evidence: %{...}                     # law hit or commit, enough to audit the label
      }

  ## From the laws judge

  `from_laws/3` runs `AshAgentTools.Laws.judge/2` over every file the
  subjects come from and maps each violation onto the subject it is about
  (`AshAgentTools.CodeSubjects.locate/3`). A whole-file detector (law #11
  reports a file with `handle_event` and no `Ash.can?`) is attributed to
  every unit in the file that matches the detector's anchor pattern, since
  the judge itself reports only the first. Only positives come from here:
  a unit the judge does not flag is not thereby a negative, because the
  detectors are grep-tier.

  ## From fix commits

  `from_fix_commits/2` reads `git log` and keeps the commits whose message
  matches a standard's pattern. For each one it extracts the units of
  every changed file before and after the commit. A unit whose text the
  commit changed is labelled: its version before the commit is a positive,
  its version after is a negative. A fix commit usually touches more than
  the violation it fixes, so these labels are `strength: "weak"` and
  commits that change more than `:max_units` units are skipped.
  """

  alias AshAgentTools.CodeSubjects
  alias AshAgentTools.Laws

  @default_max_units 6

  # A fix commit says so in its subject line.
  @default_fix_pattern "^(fix|revert)\\b|\\bfix(es|ed)?\\b"

  # Tests, configuration and the build file change alongside fixes without
  # being what was fixed.
  @default_exclude ["test/", "config/", "deps/", "mix.exs"]

  @doc """
  Positive seed labels from the laws judge.

  `subjects` are code subjects of the checkout at `root` (from
  `AshAgentTools.CodeSubjects.scan/2`). Options:

    * `:standards` — `%{law_id => standard_id}`; only these laws are
      judged, and labels carry the standard id. Default: every law, with
      `"law-<id>"` as the standard id
    * `:min_tier` — passed to the judge (default `:likely`)
    * `:baseline` — reviewed exceptions, `[%{law, file, text, reason}]`
      (the shape of an iron-laws baseline file such as ash_enterprise's
      `scripts/iron-laws.baseline.json`). A violation a person has already
      reviewed and excused (same law, file and trimmed line) becomes a
      **negative** label, `source: "laws_baseline"`, `strength: "reviewed"`,
      carrying the recorded reason
  """
  @spec from_laws(Path.t(), [CodeSubjects.subject()], keyword()) :: [map()]
  def from_laws(root, subjects, opts \\ []) do
    root = Path.expand(root)
    standards = Keyword.get(opts, :standards)
    law_ids = if standards, do: Map.keys(standards), else: nil
    min_tier = Keyword.get(opts, :min_tier, :likely)
    detectors = file_detectors()
    baseline = opts |> Keyword.get(:baseline, []) |> Map.new(&baseline_key/1)

    subjects
    |> Enum.filter(&(&1.path && Path.extname(&1.path) in [".ex", ".exs"]))
    |> Enum.group_by(& &1.path)
    |> Enum.sort_by(fn {path, _} -> path end)
    |> Enum.flat_map(fn {path, file_subjects} ->
      case File.read(Path.join(root, path)) do
        {:ok, source} ->
          source
          |> Laws.judge(file: path, min_tier: min_tier, laws: law_ids)
          |> Map.fetch!(:violations)
          |> Enum.flat_map(&attribute(&1, file_subjects, path, detectors))
          |> Enum.map(fn {violation, _subject} = hit ->
            reason = Map.get(baseline, {violation.law, path, String.trim(violation.text)})
            law_label(hit, standards, reason)
          end)

        {:error, _} ->
          []
      end
    end)
    |> Enum.uniq_by(&{&1.standard, &1.subject.id})
  end

  # The anchor pattern of each whole-file detector, keyed by law id: the
  # judge reports a file-level hit at the anchor's first match only.
  defp file_detectors do
    for law <- Laws.laws(), detector <- law.detectors, detector.kind == :file, into: %{} do
      {{law.id, detector.hint}, hd(detector.all)}
    end
  end

  defp attribute(violation, subjects, path, detectors) do
    case Map.fetch(detectors, {violation.law, violation.hint}) do
      {:ok, anchor} ->
        subjects
        |> Enum.filter(&(&1.kind in [:function, :dsl_entity] and Regex.match?(anchor, &1.text)))
        |> Enum.map(&{violation, &1})

      :error ->
        case CodeSubjects.locate(subjects, path, violation.line) do
          nil -> []
          subject -> [{violation, subject}]
        end
    end
  end

  defp baseline_key(entry) do
    entry = Map.new(entry, fn {k, v} -> {to_string(k), v} end)
    {{entry["law"], entry["file"], String.trim(entry["text"] || "")}, entry["reason"]}
  end

  defp law_label({violation, subject}, standards, nil) do
    law_label({violation, subject}, standards)
  end

  defp law_label({violation, subject}, standards, reason) do
    {violation, subject}
    |> law_label(standards)
    |> Map.merge(%{label: false, source: "laws_baseline", strength: "reviewed"})
    |> put_in([:evidence, :reason], reason)
  end

  defp law_label({violation, subject}, standards) do
    standard =
      case standards do
        nil -> "law-#{violation.law}"
        map -> Map.fetch!(map, violation.law)
      end

    %{
      standard: standard,
      label: true,
      source: "laws_judge",
      strength: Atom.to_string(violation.tier),
      subject: subject,
      revision: nil,
      evidence: %{
        law: violation.law,
        name: violation.name,
        line: violation.line,
        text: violation.text,
        hint: violation.hint
      }
    }
  end

  @doc """
  Seed labels from the fix commits of the git repository at `root`.

  Options:

    * `:standards` (required) — a list of
      `%{id: "std-id", pattern: "regex", kinds: [:function, ...]}`; a
      commit whose subject line or body matches `pattern`
      (case-insensitive) seeds labels for that standard over units of the
      given kinds (default `[:function, :dsl_entity]`)
    * `:revisions` — the `git log` range (default `"HEAD"`)
    * `:max_units` — skip a commit that changes more labelled-kind units
      than this (default #{@default_max_units})
    * `:fix_pattern` — a regex the commit's subject line must match to
      count as a fix (default `#{@default_fix_pattern}`, case-insensitive)
    * `:exclude` — path prefixes whose units are never labelled (default
      `#{inspect(@default_exclude)}`)
    * `:repository` — the repository name in subject ids (default: the
      basename of `root`)
    * `:context` — context specs to capture on each subject version

  Merge commits are skipped (their diff is not one change).
  """
  @spec from_fix_commits(Path.t(), keyword()) :: [map()]
  def from_fix_commits(root, opts) do
    root = Path.expand(root)
    standards = opts |> Keyword.fetch!(:standards) |> Enum.map(&compile_standard!/1)
    revisions = Keyword.get(opts, :revisions, "HEAD")
    max_units = Keyword.get(opts, :max_units, @default_max_units)
    fix_regex = compile!(Keyword.get(opts, :fix_pattern, @default_fix_pattern), "fix_pattern")
    exclude = Keyword.get(opts, :exclude, @default_exclude)

    subject_opts = [
      repository: Keyword.get(opts, :repository, Path.basename(root)),
      context: Keyword.get(opts, :context, [])
    ]

    root
    |> commits(revisions)
    |> Enum.filter(&Regex.match?(fix_regex, &1.subject))
    |> Enum.flat_map(fn commit ->
      matching = Enum.filter(standards, &Regex.match?(&1.regex, commit.message))

      if matching == [] do
        []
      else
        changes =
          root
          |> changed_units(commit, subject_opts)
          |> Enum.reject(fn {before, _} -> String.starts_with?(before.path, exclude) end)

        Enum.flat_map(matching, fn standard ->
          changes
          |> Enum.filter(fn {before, _after} -> before.kind in standard.kinds end)
          |> labels_for(standard, commit, max_units)
        end)
      end
    end)
  end

  defp compile_standard!(%{id: id, pattern: pattern} = standard) when is_binary(id) do
    %{
      id: id,
      regex: compile!(pattern, "standard #{id}"),
      kinds: Map.get(standard, :kinds, [:function, :dsl_entity])
    }
  end

  defp compile!(pattern, label) do
    case Regex.compile(pattern, "i") do
      {:ok, regex} -> regex
      {:error, reason} -> raise ArgumentError, "#{label}: bad pattern #{inspect(reason)}"
    end
  end

  defp labels_for(changes, _standard, _commit, max_units) when length(changes) > max_units,
    do: []

  defp labels_for(changes, standard, commit, _max_units) do
    Enum.flat_map(changes, fn {before, after_fix} ->
      evidence = %{
        commit: commit.sha,
        subject_line: commit.subject,
        changed_units: length(changes)
      }

      positive = %{
        standard: standard.id,
        label: true,
        source: "fix_commit",
        strength: "weak",
        subject: before,
        revision: commit.parent,
        evidence: evidence
      }

      negative =
        after_fix &&
          %{positive | label: false, subject: after_fix, revision: commit.sha}

      Enum.reject([positive, negative], &is_nil/1)
    end)
  end

  # Every non-merge commit in the range: sha, first parent, subject line,
  # full message.
  defp commits(root, revisions) do
    args =
      ["-C", root, "log", "--no-merges", "--format=%H%x00%P%x00%s%x00%B%x1e"] ++
        OptionParser.split(revisions)

    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\x1e", trim: true)
        |> Enum.map(&String.trim_leading/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.flat_map(fn record ->
          case String.split(record, "\0", parts: 4) do
            [sha, parent, subject, message] when parent != "" ->
              [%{sha: sha, parent: parent, subject: subject, message: message}]

            _root_commit ->
              []
          end
        end)

      {output, _} ->
        raise ArgumentError, "git log failed in #{root}: #{String.trim(output)}"
    end
  end

  # `{before, after_or_nil}` for every unit whose text the commit changed,
  # over the Elixir and Markdown files it modified or deleted.
  defp changed_units(root, commit, subject_opts) do
    root
    |> changed_paths(commit)
    |> Enum.flat_map(fn path ->
      before = units_at(root, commit.parent, path, subject_opts)
      after_fix = units_at(root, commit.sha, path, subject_opts) |> Map.new(&{&1.name_path, &1})

      before
      |> Enum.reject(&(&1.kind == :module))
      |> Enum.flat_map(fn unit ->
        case Map.fetch(after_fix, unit.name_path) do
          {:ok, %{text: text}} when text == unit.text -> []
          {:ok, changed} -> [{unit, changed}]
          :error -> [{unit, nil}]
        end
      end)
    end)
  end

  defp changed_paths(root, commit) do
    case System.cmd(
           "git",
           [
             "-C",
             root,
             "diff-tree",
             "--no-commit-id",
             "-r",
             "--name-only",
             commit.parent,
             commit.sha
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&(Path.extname(&1) in [".ex", ".exs", ".md"]))

      _ ->
        []
    end
  end

  defp units_at(root, revision, path, subject_opts) do
    with {source, 0} <-
           System.cmd("git", ["-C", root, "show", "#{revision}:#{path}"], stderr_to_stdout: true),
         {:ok, subjects} <- CodeSubjects.from_source(source, path, subject_opts) do
      subjects
    else
      _ -> []
    end
  end
end
