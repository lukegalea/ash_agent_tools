# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.CodeSubjectsStandardsTest do
  @moduledoc """
  AST-138's tooling over code subjects: seed labels, the chunk roll-up, the
  standing re-scan, the advisory review and the two Mix tasks.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias AshAgentTools.CodeSubjects
  alias AshAgentTools.CodeSubjects.Advisory
  alias AshAgentTools.CodeSubjects.Seeds
  alias AshAgentTools.CodeSubjects.Standing
  alias AshAgentTools.Laws
  alias AshAgentTools.Test.CodeFact
  alias AshJudgments.Facts.Materialiser

  doctest AshAgentTools.CodeSubjects, only: [roll_up: 2]

  @package_root Path.expand("..", __DIR__)

  # -- roll-up ---------------------------------------------------------------------

  describe "roll_up/2" do
    test "an unknown chunk never folds into either side" do
      assert CodeSubjects.roll_up([:out, :out], :any) == :out
      assert CodeSubjects.roll_up([:out, {:unknown, :stale}], :any) == {:unknown, [:stale]}
      assert CodeSubjects.roll_up([{:in, :fact}, {:unknown, :no_fact}], :any) == :in

      assert CodeSubjects.roll_up([:in, {:unknown, :expired}], :all) == {:unknown, [:expired]}
      assert CodeSubjects.roll_up([:in, {:out, :fact}, {:unknown, :stale}], :all) == :out
      assert CodeSubjects.roll_up([], :any) == {:unknown, [:no_fact]}
    end
  end

  # -- seeds from the laws judge ---------------------------------------------------------

  describe "Seeds.from_laws/3" do
    test "a whole-file detector labels every unit that matches its anchor" do
      root = tmp_dir!()

      write!(root, "lib/demo_live.ex", """
      defmodule DemoLive do
        def mount(_params, _session, socket), do: {:ok, socket}

        def handle_event("save", params, socket) do
          {:noreply, assign(socket, :params, params)}
        end

        def handle_event("drop", _params, socket), do: {:noreply, socket}

        def render(assigns), do: ~H"<p>hi</p>"
      end
      """)

      write!(root, "lib/guarded_live.ex", """
      defmodule GuardedLive do
        def handle_event("save", _params, socket) do
          if Ash.can?({Post, :create}, socket.assigns.actor), do: {:noreply, socket}, else: {:noreply, socket}
        end
      end
      """)

      subjects = CodeSubjects.scan(root, repository: "demo").subjects
      labels = Seeds.from_laws(root, subjects, standards: %{"11" => "std-handle-event"})

      assert [label] = labels
      assert label.standard == "std-handle-event"
      assert label.label == true
      assert label.source == "laws_judge"
      assert label.strength == "likely"
      assert label.subject.name_path == "DemoLive.handle_event/3"
      assert label.evidence.law == "11"
    end

    test "a hit a person reviewed and excused in the baseline is a negative" do
      root = tmp_dir!()

      write!(root, "lib/demo_live.ex", """
      defmodule DemoLive do
        def handle_event("save", params, socket) do
          {:noreply, assign(socket, :params, params)}
        end
      end
      """)

      subjects = CodeSubjects.scan(root, repository: "demo").subjects

      baseline = [
        %{
          "law" => "11",
          "file" => "lib/demo_live.ex",
          "text" => ~s{def handle_event("save", params, socket) do},
          "reason" => "Authorized through policies."
        }
      ]

      [label] =
        Seeds.from_laws(root, subjects,
          standards: %{"11" => "std-handle-event"},
          baseline: baseline
        )

      assert label.label == false
      assert label.source == "laws_baseline"
      assert label.strength == "reviewed"
      assert label.evidence.reason == "Authorized through policies."
    end

    test "a line detector labels the unit that holds the line" do
      root = tmp_dir!()

      write!(root, "lib/atoms.ex", """
      defmodule Atoms do
        def safe(name), do: name

        def unsafe(name) do
          String.to_atom(name)
        end
      end
      """)

      subjects = CodeSubjects.scan(root, repository: "demo").subjects
      [label] = Seeds.from_laws(root, subjects, standards: %{"10" => "std-atoms"})

      assert label.subject.name_path == "Atoms.unsafe/1"
      assert label.strength == "definite"
    end
  end

  # -- seeds from fix commits -------------------------------------------------------------

  describe "Seeds.from_fix_commits/2" do
    test "the version before a fix is a positive and the version after it a negative" do
      root = git_repo!()

      write!(root, "lib/check.ex", """
      defmodule Check do
        def match?(actor), do: Repo.exists?(Team, actor.team_id)

        def describe(_), do: "member"
      end
      """)

      write!(root, "test/check_test.exs", "defmodule CheckTest do\n  def t, do: 1\nend\n")
      commit!(root, "feat: add the check")

      write!(root, "lib/check.ex", """
      defmodule Check do
        def match?(actor), do: actor.context.team_id != nil

        def describe(_), do: "member"
      end
      """)

      write!(root, "test/check_test.exs", "defmodule CheckTest do\n  def t, do: 2\nend\n")
      commit!(root, "fix: policy checks never query")

      write!(root, "lib/check.ex", """
      defmodule Check do
        def match?(actor), do: actor.context.team_id != nil

        def describe(_), do: "a member"
      end
      """)

      commit!(root, "docs: say the check never queries")

      labels =
        Seeds.from_fix_commits(root,
          standards: [%{id: "std-checks", pattern: "never quer"}],
          repository: "demo"
        )

      assert [positive, negative] = labels
      assert positive.subject.name_path == "Check.match?/1"
      assert positive.label == true and negative.label == false
      assert positive.subject.text =~ "Repo.exists?"
      refute negative.subject.text =~ "Repo"
      assert positive.strength == "weak"
      assert negative.revision == git!(root, ["rev-parse", "HEAD~1"]) |> String.trim()
      assert positive.revision == git!(root, ["rev-parse", "HEAD~2"]) |> String.trim()
      assert positive.evidence.subject_line == "fix: policy checks never query"
    end

    test "a commit that changes too many units seeds nothing" do
      root = git_repo!()
      write!(root, "lib/many.ex", many_functions(1))
      commit!(root, "feat: many")
      write!(root, "lib/many.ex", many_functions(2))
      commit!(root, "fix: never query anywhere")

      assert Seeds.from_fix_commits(root,
               standards: [%{id: "s", pattern: "never query"}],
               max_units: 3
             ) ==
               []

      assert length(
               Seeds.from_fix_commits(root,
                 standards: [%{id: "s", pattern: "never query"}],
                 max_units: 4
               )
             ) ==
               8
    end

    test "doc paragraphs seed for documentation standards" do
      root = git_repo!()
      write!(root, "README.md", "# Tool\n\nThis groundbreaking tool is the first of its kind.\n")
      commit!(root, "docs: readme")
      write!(root, "README.md", "# Tool\n\nThis tool lists the units of a repository.\n")
      commit!(root, "fix(docs): drop the novelty claim")

      [positive, negative] =
        Seeds.from_fix_commits(root,
          standards: [%{id: "std-novelty", pattern: "novelty", kinds: [:doc_paragraph]}]
        )

      assert positive.subject.name_path == "Tool[0]"
      assert positive.subject.text =~ "first of its kind"
      refute negative.subject.text =~ "first"
    end
  end

  defp many_functions(value) do
    defs = Enum.map_join(1..4, "\n", &"  def f#{&1}, do: #{value}")
    "defmodule Many do\n#{defs}\nend\n"
  end

  # -- the standing re-scan ------------------------------------------------------------------

  describe "Standing" do
    setup do
      [question] = AshJudgments.Registry.Info.questions(AshAgentTools.Test.CodeUnit)
      %{predicate: "#{question.question_id}:standing:#{System.unique_integer([:positive])}"}
    end

    test "assess/4 returns the edited and the new units, and nothing else", %{
      predicate: predicate
    } do
      root = tmp_dir!()
      repository = "standing-#{System.unique_integer([:positive])}"

      write!(root, "lib/a.ex", "defmodule A do\n  def one, do: 1\n\n  def two, do: 2\nend\n")
      opts = [repository: repository, kinds: [:function]]

      for subject <- CodeSubjects.scan(root, opts).subjects, do: admit!(subject, predicate, true)
      assert Standing.assess(root, CodeFact, predicate, opts) == []

      write!(
        root,
        "lib/a.ex",
        "defmodule A do\n  def one, do: 1\n\n  def two, do: 3\n\n  def three, do: 3\nend\n"
      )

      assert root
             |> Standing.assess(CodeFact, predicate, opts)
             |> Enum.map(fn {subject, reason} -> {subject.name_path, reason} end)
             |> Enum.sort() == [{"A.three/0", :no_fact}, {"A.two/0", :stale}]
    end

    test "statuses/4 rolls a chunked unit's facts back up to the unit", %{predicate: predicate} do
      root = tmp_dir!()
      repository = "standing-#{System.unique_integer([:positive])}"

      statements =
        Enum.map_join(1..40, "\n", &"    value_#{&1} = compute(#{&1}, :some_option, \"text\")")

      write!(
        root,
        "lib/long.ex",
        "defmodule Long do\n  def run do\n#{statements}\n    :ok\n  end\nend\n"
      )

      opts = [repository: repository, kinds: [:function], max_tokens: 200, reserve_tokens: 40]
      [unit] = CodeSubjects.scan(root, opts).subjects
      [first | rest] = chunks = CodeSubjects.chunk(unit, [], max_tokens: 200, reserve_tokens: 40)
      assert length(chunks) > 1

      admit!(first, predicate, true)
      for chunk <- rest, do: admit!(chunk, predicate, false)

      assert [{rolled, :in}] = Standing.statuses(root, CodeFact, predicate, opts)
      assert rolled.id == unit.id
      assert rolled.text == unit.text

      assert [{_unit, :out}] =
               Standing.statuses(root, CodeFact, predicate, Keyword.put(opts, :mode, :all))
    end

    test "a unit whose context alone exceeds the budget is reported, and the scan goes on", %{
      predicate: predicate
    } do
      root = tmp_dir!()
      repository = "standing-#{System.unique_integer([:positive])}"
      doc = Enum.map_join(1..60, "\n", &"  # line #{&1} of a long module body")

      write!(root, "lib/big.ex", "defmodule Big do\n#{doc}\n  def one, do: 1\nend\n")
      write!(root, "lib/small.ex", "defmodule Small do\n  def two, do: 2\nend\n")

      opts = [
        repository: repository,
        kinds: [:function],
        projection: [:module],
        max_tokens: 400,
        reserve_tokens: 40
      ]

      assert root
             |> Standing.assess(CodeFact, predicate, opts)
             |> Enum.map(fn {subject, reason} -> {subject.name_path, reason} end) == [
               {"Small.two/0", :no_fact},
               {"Big.one/0", :context_too_large}
             ]

      assert root
             |> Standing.statuses(CodeFact, predicate, opts)
             |> Enum.map(fn {unit, status} -> {unit.name_path, status} end) == [
               {"Big.one/0", {:unknown, [:context_too_large]}},
               {"Small.two/0", {:unknown, [:no_fact]}}
             ]
    end
  end

  defp admit!(subject, predicate, holds) do
    {:ok, :materialised} =
      Materialiser.materialise(
        %{
          result: :admitted,
          subject: CodeSubjects.subject_term(subject),
          predicate: predicate,
          value: holds,
          holds: holds,
          grade: :grant,
          subject_state_digest: CodeSubjects.digest(subject),
          admission_id: Ash.UUID.generate()
        },
        resource: CodeFact
      )
  end

  # -- AC-2: the deterministic report is untouched by the model signal --------------------------

  describe "AST-138/AC-2: the laws judge's output is byte-identical with and without the model signal" do
    @tag ac: "AST-138/AC-2"
    test "over every source file of this package, as files and as diffs" do
      files = Path.wildcard(Path.join(@package_root, "{lib,test}/**/*.{ex,exs}"))
      assert length(files) > 100

      for file <- files do
        source = File.read!(file)
        diff = as_added_diff(Path.relative_to(file, @package_root), source)
        {:ok, subjects} = CodeSubjects.from_source(source, Path.relative_to(file, @package_root))

        findings =
          subjects
          |> Enum.take(5)
          |> Enum.with_index()
          |> Enum.map(fn {subject, index} ->
            %{
              subject: subject,
              standard: "std-#{index}",
              probability: 0.99,
              status: {:in, :fact},
              admitted?: rem(index, 2) == 0
            }
          end)

        for {input, laws_opts} <- [{diff, []}, {source, [diff?: false]}] do
          without = Advisory.review(input, [], laws_opts: laws_opts)
          with_signal = Advisory.review(input, findings, laws_opts: laws_opts)
          judge = Laws.judge(input, Keyword.merge([diff?: true], laws_opts))

          assert Jason.encode!(without.laws) == Jason.encode!(judge)
          assert Jason.encode!(with_signal.laws) == Jason.encode!(judge)

          assert deterministic_section(with_signal.markdown) ==
                   deterministic_section(without.markdown)
        end
      end
    end

    test "the advisory section says it is advisory and names the rung" do
      {:ok, [subject | _]} =
        CodeSubjects.from_source("defmodule M do\nend\n", "m.ex", repository: "r")

      review =
        Advisory.review("", [%{subject: subject, standard: "std-x", probability: 0.912}])

      assert review.markdown =~ "### Standards (System One, advisory: not a gate)"
      assert review.markdown =~ "- `m.ex:1` std-x: observation, p = 0.91, not admitted"
      assert [%{rung: :system_one, admitted?: false}] = review.advisory
    end
  end

  defp as_added_diff(path, source) do
    lines = String.split(source, "\n")

    "--- /dev/null\n+++ b/#{path}\n@@ -0,0 +1,#{length(lines)} @@\n" <>
      Enum.map_join(lines, "\n", &("+" <> &1))
  end

  defp deterministic_section(markdown) do
    markdown |> String.split("### Standards") |> hd()
  end

  # -- the Mix tasks ---------------------------------------------------------------------------

  describe "mix ash_agent.subjects" do
    @fixture_root Path.expand("fixtures/code_subjects", __DIR__)

    test "prints the subjects of a checkout as JSON" do
      output =
        capture_io(fn ->
          Mix.Tasks.AshAgent.Subjects.run([@fixture_root, "--kind", "function"])
        end)

      report = Jason.decode!(output)

      assert report["count"] == 3

      assert Enum.map(report["subjects"], & &1["location"]) ==
               ["lib/demo/ticket.ex:40", "lib/demo/ticket.ex:43", "lib/demo/ticket.ex:51"]
    end

    test "--locate prints the innermost unit; --summary counts by kind" do
      located =
        capture_io(fn ->
          Mix.Tasks.AshAgent.Subjects.run([@fixture_root, "--locate", "lib/demo/ticket.ex:44"])
        end)

      assert [%{"name_path" => "Demo.Ticket.normalise/1"}] = Jason.decode!(located)["subjects"]

      summary =
        capture_io(fn -> Mix.Tasks.AshAgent.Subjects.run([@fixture_root, "--summary"]) end)

      assert %{"function" => 3, "module" => 2} = Jason.decode!(summary)["by_kind"]
    end

    test "an unknown kind is a JSON error and a non-zero exit" do
      output =
        capture_io(fn ->
          assert catch_exit(
                   Mix.Tasks.AshAgent.Subjects.run([@fixture_root, "--kind", "everything"])
                 ) ==
                   {:shutdown, 1}
        end)

      assert Jason.decode!(output)["error"] =~ "unknown --kind"
    end
  end

  describe "mix ash_agent.seeds" do
    test "prints labels and counts per standard and source" do
      root = git_repo!()

      write!(
        root,
        "lib/live.ex",
        "defmodule Live do\n  def handle_event(_, _, s), do: {:noreply, s}\nend\n"
      )

      commit!(root, "feat: live")

      write!(
        root,
        "lib/live.ex",
        "defmodule Live do\n  def handle_event(_, _, s), do: {:noreply, s.x}\nend\n"
      )

      commit!(root, "fix: authorize every event")

      standards = Path.join(root, "standards.json")

      File.write!(
        standards,
        Jason.encode!([
          %{id: "std-11", laws: ["11"], pattern: "authorize every event", kinds: ["function"]}
        ])
      )

      output =
        capture_io(fn ->
          Mix.Tasks.AshAgent.Seeds.run([root, "--standards", standards, "--no-text"])
        end)

      report = Jason.decode!(output)

      assert report["counts"] == %{
               "std-11" => %{
                 "laws_judge" => %{"positive" => 1, "negative" => 0},
                 "fix_commit" => %{"positive" => 1, "negative" => 1}
               }
             }

      assert Enum.all?(report["labels"], &(not Map.has_key?(&1["subject"], "text")))
      assert report["revision"] == String.trim(git!(root, ["rev-parse", "HEAD"]))
    end
  end

  # -- helpers ------------------------------------------------------------------------------------

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "code_subjects_std_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write!(root, path, content) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp git_repo! do
    root = tmp_dir!()
    git!(root, ["init", "--quiet"])
    root
  end

  defp commit!(root, message) do
    git!(root, ["add", "-A"])

    git!(root, [
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@example.test",
      "commit",
      "--quiet",
      "-m",
      message
    ])
  end

  defp git!(root, args) do
    {output, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    output
  end
end
