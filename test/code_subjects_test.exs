# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.CodeSubjectsTest do
  use ExUnit.Case, async: true

  require Ash.Query

  alias AshAgentTools.CodeSubjects
  alias AshAgentTools.CodeSubjects.Projection
  alias AshAgentTools.Test.CodeUnit
  alias AshAgentTools.Test.PolicyView
  alias AshJudgments.Registry.Canonical

  doctest AshAgentTools.CodeSubjects

  @fixture_root Path.expand("fixtures/code_subjects", __DIR__)
  @package_root Path.expand("..", __DIR__)
  @ticket "lib/demo/ticket.ex"

  defp fixture(opts \\ []) do
    CodeSubjects.scan(@fixture_root, Keyword.merge([repository: "demo"], opts)).subjects
  end

  defp by_path(subjects), do: Map.new(subjects, &{&1.name_path, &1})

  # -- extraction -------------------------------------------------------------------

  describe "addresses" do
    test "every kind in a source file gets a name path keyed by repository and path" do
      subjects = fixture() |> Enum.filter(&(&1.path == @ticket))

      assert Enum.map(subjects, &{&1.kind, &1.name_path}) == [
               {:module, "Demo.Ticket"},
               {:doc_paragraph, "Demo.Ticket@moduledoc[0]"},
               {:doc_paragraph, "Demo.Ticket@moduledoc[1]"},
               {:dsl_entity, "Demo.Ticket/attributes/id"},
               {:dsl_entity, "Demo.Ticket/attributes/title"},
               {:dsl_entity, "Demo.Ticket/actions/open"},
               {:dsl_entity, "Demo.Ticket/policies/policy[0]"},
               {:dsl_entity, "Demo.Ticket/policies/policy[1]"},
               {:doc_paragraph, "Demo.Ticket.display/1@doc[0]"},
               {:function, "Demo.Ticket.display/1"},
               {:function, "Demo.Ticket.normalise/1"},
               {:module, "Demo.Ticket.Reply"},
               {:function, "Demo.Ticket.Reply.body/1"}
             ]

      ticket = subjects |> by_path() |> Map.fetch!("Demo.Ticket.normalise/1")
      assert ticket.id == "demo:lib/demo/ticket.ex#Demo.Ticket.normalise/1"
      assert ticket.visibility == :private
      assert ticket.clauses == 2
      assert ticket.module == "Demo.Ticket"
      assert ticket.text =~ ~r/\A# Normalises a title.\ndefp normalise\(title\)/
      assert ticket.text =~ ~s{defp normalise(nil), do: ""}
    end

    test "Markdown paragraphs are addressed by heading path and position" do
      paragraphs = fixture() |> Enum.filter(&(&1.path == "README.md")) |> by_path()

      assert Map.keys(paragraphs) |> Enum.sort() == [
               "Demo > Standards > Copy[0]",
               "Demo > Standards[0]",
               "Demo > Standards[1]",
               "Demo > Standards[2]",
               "Demo > Standards[3]",
               "Demo[0]"
             ]

      # A fenced block is one paragraph, and a `#` inside it opens no section.
      assert paragraphs["Demo > Standards[3]"].text =~ "# a comment, not a heading"
      assert paragraphs["Demo > Standards[3]"].text =~ ~s{IO.puts("hi")}
    end

    test "DSL entity paths are the name paths NamePath resolves, at the same line" do
      for file <- ["test/support/post.ex", "test/support/guarded.ex"] do
        {:ok, subjects} =
          CodeSubjects.from_source(File.read!(Path.join(@package_root, file)), file)

        core =
          Enum.filter(subjects, fn subject ->
            subject.kind == :dsl_entity and
              subject.dsl_path in ~w(attributes actions calculations relationships policies)
          end)

        assert core != []

        for subject <- core do
          {:ok, report} = AshAgentTools.NamePath.resolve("/" <> subject.name_path)
          assert report.name_path == subject.name_path
          assert report.symbol.source.line == subject.line, subject.name_path
        end
      end
    end

    test "unparsable files are reported, not raised" do
      dir = tmp_dir!()
      File.write!(Path.join(dir, "broken.ex"), "defmodule Broken do\n  def oops(\nend\n")
      File.write!(Path.join(dir, "fine.ex"), "defmodule Fine do\nend\n")

      report = CodeSubjects.scan(dir, repository: "tmp")
      assert [%{path: "broken.ex", reason: reason}] = report.skipped
      assert is_binary(reason)
      assert Enum.map(report.subjects, & &1.name_path) == ["Fine"]
    end
  end

  # -- AC-2 ------------------------------------------------------------------------

  describe "AST-137/AC-2: every subject resolves back to a clickable path:line" do
    @tag ac: "AST-137/AC-2"
    test "every subject of this package's own source and docs" do
      report =
        CodeSubjects.scan(@package_root,
          repository: "ash_agent_tools",
          paths: ["lib", "test", "README.md", "usage-rules.md", "usage-rules"]
        )

      assert report.skipped == []
      assert length(report.subjects) > 1_000

      for kind <- [:module, :function, :dsl_entity, :doc_paragraph] do
        assert Enum.any?(report.subjects, &(&1.kind == kind)), "no #{kind} subjects"
      end

      Enum.each(report.subjects, &assert_resolves!(@package_root, &1))
    end

    @tag ac: "AST-137/AC-2"
    test "every hunk of a diff, at its first added line in the post-image" do
      {root, diff} = edited_repo!()

      hunks = CodeSubjects.from_diff(diff, root: root, repository: "demo")
      assert length(hunks) >= 3

      for hunk <- hunks do
        assert_location_shape!(root, hunk)

        file_line =
          root
          |> Path.join(hunk.path)
          |> File.read!()
          |> String.split("\n")
          |> Enum.at(hunk.line - 1)

        first_added = hunk.text |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "+"))
        assert first_added == "+" <> file_line, hunk.id
      end
    end

    @tag ac: "AST-137/AC-2"
    test "a pending commit message resolves to its file; a committed one to its commit" do
      {root, _diff} = edited_repo!()

      File.write!(
        Path.join(root, ".git/COMMIT_EDITMSG"),
        "fix: trim titles\n\nWhy it matters.\n# Please enter the commit message\n"
      )

      pending =
        CodeSubjects.from_commit_message(File.read!(Path.join(root, ".git/COMMIT_EDITMSG")),
          repository: "demo",
          path: ".git/COMMIT_EDITMSG"
        )

      assert_resolves!(root, pending)
      assert pending.text == "fix: trim titles\n\nWhy it matters."

      {:ok, [commit]} =
        CodeSubjects.from_commits(root, "-1",
          repository: "demo",
          web_base: "https://example.test/demo"
        )

      assert commit.location == commit.sha
      assert commit.url == "https://example.test/demo/commit/#{commit.sha}"
      assert {"commit\n", 0} = System.cmd("git", ["-C", root, "cat-file", "-t", commit.location])
      assert commit.text == "feat: demo"
    end

    @tag ac: "AST-137/AC-2"
    test "chunks resolve to the lines they cover" do
      subject = long_function_subject()
      chunks = CodeSubjects.chunk(subject, [], max_tokens: 200, reserve_tokens: 40)

      assert length(chunks) > 1
      dir = tmp_dir!()
      File.write!(Path.join(dir, subject.path), subject.source)

      for chunk <- chunks, do: assert_resolves!(dir, chunk)
    end

    test "resolve/3 finds a subject again after edits elsewhere moved its lines" do
      dir = tmp_dir!()
      source = File.read!(Path.join(@fixture_root, @ticket))
      File.mkdir_p!(Path.join(dir, "lib/demo"))
      File.write!(Path.join(dir, @ticket), source)

      {:ok, subjects} = CodeSubjects.from_source(source, @ticket, repository: "demo")
      body = subjects |> by_path() |> Map.fetch!("Demo.Ticket.Reply.body/1")

      File.write!(
        Path.join(dir, @ticket),
        String.replace(
          source,
          "  @doc \"The ticket's",
          "  # one\n  # two\n\n  @doc \"The ticket's"
        )
      )

      assert {:ok, moved} = CodeSubjects.resolve(dir, body)
      assert moved.line == body.line + 3
      assert moved.id == body.id
      assert_resolves!(dir, moved)

      File.write!(
        Path.join(dir, @ticket),
        String.replace(source, "def body(reply)", "def text(reply)")
      )

      assert CodeSubjects.resolve(dir, body) == {:error, :not_found}
    end
  end

  # A file-backed subject's location is `path:line`, the file exists, and
  # the line there is the subject's own line: the text maps line for line
  # onto its span.
  defp assert_resolves!(root, subject) do
    assert_location_shape!(root, subject)

    file_lines = root |> Path.join(subject.path) |> File.read!() |> String.split(~r/\r?\n/)
    text_lines = String.split(subject.text, "\n")

    assert subject.span.start_line <= subject.line and subject.line <= subject.span.end_line,
           subject.id

    assert length(text_lines) == subject.span.end_line - subject.span.start_line + 1, subject.id

    expected = Enum.at(text_lines, subject.line - subject.span.start_line)
    actual = Enum.at(file_lines, subject.line - 1)

    # A one-line `@doc "..."` paragraph is the string itself, on its line.
    assert String.trim(expected) == String.trim(actual) or
             String.contains?(actual, String.trim(expected)),
           "#{subject.location} (#{subject.id}) reads #{inspect(actual)}, expected #{inspect(expected)}"
  end

  defp assert_location_shape!(root, subject) do
    assert subject.location == "#{subject.path}:#{subject.line}", subject.id
    assert subject.location =~ ~r/\A[^\s:]+:[1-9]\d*\z/, subject.id
    assert File.regular?(Path.join(root, subject.path)), subject.id
  end

  # -- projections and digests -----------------------------------------------------

  describe "projections and digests" do
    test "the digest is the one a judgment records for the same projected state" do
      subject =
        fixture(context: [:module_header, {:section, :policies}])
        |> by_path()
        |> Map.fetch!("Demo.Ticket.display/1")

      state = PolicyView.project(%{arguments: %{input: subject}}, %{})
      assert CodeSubjects.digest(subject, PolicyView) == Canonical.digest(Canonical.encode(state))

      assert state["context"]["module_header"] ==
               "defmodule Demo.Ticket do\nuse Ash.Resource, domain: Demo"

      assert state["context"]["section:policies"] =~
               ~r/\Apolicies do\n  policy action_type\(:read\) do/

      refute Map.has_key?(state, "line")
    end

    test "a subject that round-tripped through JSON digests the same" do
      subject =
        fixture(context: [:module_header, {:section, :policies}])
        |> by_path()
        |> Map.fetch!("Demo.Ticket/actions/open")

      decoded = subject |> Jason.encode!() |> Jason.decode!()

      assert CodeSubjects.digest(decoded, PolicyView) == CodeSubjects.digest(subject, PolicyView)
      assert CodeSubjects.subject_term(decoded) == CodeSubjects.subject_term(subject)
    end

    test "the declared context is part of the question's identity" do
      [question] = AshJudgments.Registry.Info.questions(CodeUnit)

      assert question.state_contract == Canonical.state_contract(PolicyView.shape())
      refute question.state_contract == Canonical.state_contract(Projection.Text.shape())

      assert PolicyView.shape()["context"] == %{
               "module_header" => "string | null",
               "section:policies" => "string | null"
             }
    end

    test "a projection over context the subject was extracted without raises" do
      subject = fixture() |> by_path() |> Map.fetch!("Demo.Ticket.display/1")

      assert_raise ArgumentError, ~r/extracted without the "module_header" context/, fn ->
        CodeSubjects.digest(subject, PolicyView)
      end
    end

    test "context specs accept their string spellings and refuse unknown ones" do
      assert CodeSubjects.normalize_context([
               "section:policies",
               :moduledoc,
               {:section, "actions"}
             ]) ==
               ["moduledoc", "section:actions", "section:policies"]

      assert_raise ArgumentError, ~r/unknown code-subject context/, fn ->
        CodeSubjects.normalize_context([:everything])
      end
    end

    test "a missing section is captured as nil, distinct from not captured" do
      subject =
        fixture(context: [{:section, :postgres}])
        |> by_path()
        |> Map.fetch!("Demo.Ticket.display/1")

      assert subject.context == %{"section:postgres" => nil}

      assert CodeSubjects.state(subject, [{:section, :postgres}])["context"] == %{
               "section:postgres" => nil
             }
    end
  end

  # -- chunking ---------------------------------------------------------------------

  describe "chunking" do
    test "a subject within the budget is its own single chunk" do
      subject = fixture() |> by_path() |> Map.fetch!("Demo.Ticket.display/1")
      assert CodeSubjects.chunk(subject) == [subject]
    end

    test "every chunk's projected state fits the budget, and the chunks cover the text" do
      subject = long_function_subject()
      budget = 200 - 40

      chunks = CodeSubjects.chunk(subject, [], max_tokens: 200, reserve_tokens: 40)

      for chunk <- chunks do
        tokens =
          chunk |> CodeSubjects.state() |> Jason.encode!() |> CodeSubjects.estimate_tokens()

        assert tokens <= budget
        assert chunk.chunk.parent_id == subject.id
        assert chunk.id == "#{subject.id}~chunk[#{chunk.chunk.index}]"
        assert chunk.chunk.of == length(chunks)
      end

      assert Enum.map_join(chunks, "\n", & &1.text) == subject.text

      assert chunks |> Enum.map(&CodeSubjects.digest/1) |> Enum.uniq() |> length() ==
               length(chunks)
    end

    test "the default budget is the decision model's 1,024 tokens" do
      subject = long_function_subject(400)
      chunks = CodeSubjects.chunk(subject)

      assert length(chunks) > 1

      for chunk <- chunks do
        assert chunk |> CodeSubjects.state() |> Jason.encode!() |> CodeSubjects.estimate_tokens() <=
                 1024 - 256
      end
    end

    test "context that alone exceeds the budget raises" do
      subject = fixture(context: [:module]) |> by_path() |> Map.fetch!("Demo.Ticket.display/1")

      assert_raise ArgumentError, ~r/declared context .* alone exceeds/, fn ->
        CodeSubjects.chunk(subject, [:module], max_tokens: 120, reserve_tokens: 20)
      end
    end

    test "fit/3 returns that case as an error, and otherwise what chunk/3 returns" do
      subject = fixture(context: [:module]) |> by_path() |> Map.fetch!("Demo.Ticket.display/1")

      assert CodeSubjects.fit(subject, [:module], max_tokens: 120, reserve_tokens: 20) ==
               {:error, {:context_too_large, 100}}

      long = long_function_subject(400)
      assert CodeSubjects.fit(long) == {:ok, CodeSubjects.chunk(long)}
      assert CodeSubjects.fit(subject, [:module]) == {:ok, [subject]}
    end
  end

  defp long_function_subject(lines \\ 40) do
    statements =
      Enum.map_join(1..lines, "\n", &"    value_#{&1} = compute(#{&1}, :some_option, \"text\")")

    source = "defmodule Long do\n  def run do\n#{statements}\n    :ok\n  end\nend\n"
    {:ok, subjects} = CodeSubjects.from_source(source, "long.ex", repository: "tmp")

    subjects |> by_path() |> Map.fetch!("Long.run/0") |> Map.put(:source, source)
  end

  # -- diffs, commits, locate ---------------------------------------------------------

  describe "diff hunks" do
    test "hunks are addressed under the unit that encloses them, with its context" do
      {root, diff} = edited_repo!()

      hunks =
        CodeSubjects.from_diff(diff, root: root, repository: "demo", context: [:module_header])

      paths = Enum.map(hunks, & &1.name_path)

      assert "Demo.Ticket.display/1~hunk[0]" in paths
      assert "Demo.Ticket.Reply.body/1~hunk[0]" in paths
      assert Enum.any?(hunks, &(&1.path == "README.md" and &1.name_path == "~hunk[0]"))

      display = Enum.find(hunks, &(&1.name_path == "Demo.Ticket.display/1~hunk[0]"))
      assert display.parent == "Demo.Ticket.display/1"
      assert display.context["module_header"] =~ "defmodule Demo.Ticket do"
      assert display.text =~ ~r/^-  def display.*\n\+  def display/m
      refute display.text =~ "@@"
    end

    test "without a post-image, hunks are numbered per file" do
      {_root, diff} = edited_repo!()
      hunks = CodeSubjects.from_diff(diff, repository: "demo")

      assert hunks |> Enum.filter(&(&1.path == @ticket)) |> Enum.map(& &1.name_path) ==
               ["~hunk[0]", "~hunk[1]"]
    end
  end

  describe "locate/3" do
    test "maps a line-addressed finding onto the innermost unit" do
      subjects = fixture()
      ticket = by_path(subjects)
      normalise = ticket["Demo.Ticket.normalise/1"]
      body = ticket["Demo.Ticket.Reply.body/1"]

      assert CodeSubjects.locate(subjects, @ticket, normalise.line + 1).name_path ==
               "Demo.Ticket.normalise/1"

      assert CodeSubjects.locate(subjects, @ticket, body.line).name_path ==
               "Demo.Ticket.Reply.body/1"

      assert CodeSubjects.locate(subjects, @ticket, 14).name_path == "Demo.Ticket"
      assert CodeSubjects.locate(subjects, @ticket, 1) == nil
    end
  end

  # -- the subject resource ------------------------------------------------------------

  describe "the code-unit resource" do
    test ":scan returns the subjects as records, filtered in memory" do
      records =
        CodeUnit
        |> Ash.Query.for_read(:scan, %{root: @fixture_root, repository: "demo", paths: ["lib"]})
        |> Ash.Query.filter(kind == :function)
        |> Ash.read!()

      assert Enum.map(records, & &1.name_path) == [
               "Demo.Ticket.display/1",
               "Demo.Ticket.normalise/1",
               "Demo.Ticket.Reply.body/1"
             ]

      [display | _] = records
      assert display.location == "lib/demo/ticket.ex:40"

      assert CodeSubjects.digest(display) ==
               CodeSubjects.digest(by_path(fixture())["Demo.Ticket.display/1"])
    end
  end

  # -- helpers -------------------------------------------------------------------------

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "code_subjects_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # A git repository holding the fixture, one commit, then edits to two
  # functions and the README in the working tree. Returns the root and
  # `git diff` of the edits.
  defp edited_repo! do
    root = tmp_dir!()
    File.cp_r!(@fixture_root, root)
    git!(root, ["init", "--quiet"])
    git!(root, ["add", "."])

    git!(root, [
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@example.test",
      "commit",
      "--quiet",
      "-m",
      "feat: demo"
    ])

    ticket = Path.join(root, @ticket)

    ticket
    |> File.read!()
    |> String.replace(
      "def display(%{title: title}), do: title",
      "def display(%{title: title}), do: String.upcase(title)"
    )
    |> String.replace(
      "def body(reply), do: reply.body",
      "def body(reply), do: String.trim(reply.body)"
    )
    |> then(&File.write!(ticket, &1))

    readme = Path.join(root, "README.md")

    File.write!(
      readme,
      String.replace(
        File.read!(readme),
        "Say the thing first.",
        "Say the thing first, then stop."
      )
    )

    {root, git!(root, ["diff"])}
  end

  defp git!(root, args) do
    {output, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    output
  end
end
