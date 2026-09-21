# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.LawsTest do
  use ExUnit.Case, async: true

  doctest AshAgentTools.Laws

  alias AshAgentTools.Laws

  @categories ~w(live_view ecto oban security otp elixir verification style)a

  describe "laws/0 — the registry" do
    test "codifies all 26 iron laws with unique zero-padded ids" do
      laws = Laws.laws()

      assert length(laws) == 26
      assert Enum.map(laws, & &1.id) == Enum.uniq(Enum.map(laws, & &1.id))
      assert Enum.all?(laws, &(&1.id =~ ~r/^\d{2}$/))
    end

    test "categories mirror the canonical grouping (6/6/3/3/2/4/1/1)" do
      counts = Enum.frequencies_by(Laws.laws(), & &1.category)

      assert counts == %{
               live_view: 6,
               ecto: 6,
               oban: 3,
               security: 3,
               otp: 2,
               elixir: 4,
               verification: 1,
               style: 1
             }
    end

    test "every law is documented and categorized" do
      for law <- Laws.laws() do
        assert law.category in @categories
        assert is_binary(law.title) and law.title != ""
        assert is_binary(law.summary) and law.summary != ""
        assert is_list(law.detectors)
      end
    end

    test "detector shapes are internally consistent" do
      for law <- Laws.laws(),
          det <- law.detectors do
        assert det.tier in Laws.tiers()
        assert is_binary(det.hint) and det.hint != ""

        case det.kind do
          :line -> assert is_struct(det.pattern, Regex)
          :mount -> assert is_struct(det.pattern, Regex)
          :window -> assert is_struct(det.pattern, Regex) and is_integer(det.window)
          :file -> assert is_list(det.all) and is_list(det.none)
        end
      end
    end
  end

  describe "judge/2 — line detectors" do
    test "flags String.to_atom as a definite security violation with line and hint" do
      source = """
      defmodule Bad do
        def build(input) do
          String.to_atom(input)
        end
      end
      """

      report = Laws.judge(source)
      assert [violation] = Enum.filter(report.violations, &(&1.law == "10"))
      assert %{tier: :definite, line: 3, category: :security} = violation
      assert violation.text == "String.to_atom(input)"
      assert violation.hint =~ "to_existing_atom"
    end

    test "flags :erlang.binary_to_atom as definite #10" do
      report = Laws.judge(":erlang.binary_to_atom(input, :utf8)")
      assert Enum.any?(report.violations, &(&1.law == "10" and &1.tier == :definite))
    end

    test "raw(literal) is clean; raw(variable) is a definite #12" do
      literal = Laws.judge(~s|raw("<p>static</p>")|)
      refute Enum.any?(literal.violations, &(&1.law == "12"))

      dynamic = Laws.judge("raw(@comment.body)")
      assert [violation] = Enum.filter(dynamic.violations, &(&1.law == "12"))
      assert violation.tier == :definite
    end

    test "money-named float fields are a definite #04" do
      attribute = Laws.judge("attribute :price, :float")
      assert Enum.any?(attribute.violations, &(&1.law == "04" and &1.tier == :definite))

      migration = Laws.judge("add :total_amount, :float, null: false")
      assert Enum.any?(migration.violations, &(&1.law == "04" and &1.tier == :definite))
    end

    test "non-money floats are clean" do
      report = Laws.judge("attribute :ratio, :float")
      assert report.violations == []
    end

    test "unpinned fragment interpolation is a definite #05" do
      report = Laws.judge(~S|where: fragment("? = ?::text", p.name, ^"#{name}")|)

      assert Enum.any?(report.violations, &(&1.law == "05" and &1.tier == :definite))
    end

    test "a join: continued by on: on the next line is clean (#15)" do
      clean = """
      from u in User,
        join: p in Post,
        on: p.author_id == u.id,
        select: u.name
      """

      assert Laws.judge(clean).violations == []

      cross = """
      from u in User,
        join: p in ^subquery,
        select: u.name
      """

      assert Enum.any?(Laws.judge(cross).violations, &(&1.law == "15" and &1.tier == :likely))
    end

    test "cast_assoc is a review-tier #17 hit" do
      report = Laws.judge("cast_assoc(:comments, with: &Changesets.comment/2)", min_tier: :review)
      assert [violation] = Enum.filter(report.violations, &(&1.law == "17"))
      assert violation.tier == :review
    end

    test "Task.start outside supervision is a likely #14; spawn is review #13" do
      report = Laws.judge("Task.start(fn -> :ok end)")
      assert Enum.any?(report.violations, &(&1.law == "14" and &1.tier == :likely))

      report = Laws.judge("spawn(fn -> :ok end)", min_tier: :review)
      assert Enum.any?(report.violations, &(&1.law == "13" and &1.tier == :review))
    end

    test "assign_new is a likely #21 hit" do
      report = Laws.judge("assign_new(socket, :posts, fn -> [] end)")
      assert Enum.any?(report.violations, &(&1.law == "21" and &1.tier == :likely))
    end
  end

  describe "judge/2 — mount block detectors" do
    @live_view """
    defmodule MyApp.PostLive do
      use MyAppWeb, :live_view

      def mount(_params, _session, socket) do
        posts = Repo.all(Post)
        {:ok, assign(socket, posts: posts)}
      end

      def render(assigns) do
        ~H"-posts"
      end
    end
    """

    test "Repo.all inside mount is a definite #01 at the query's line" do
      report = Laws.judge(@live_view)
      assert [violation] = Enum.filter(report.violations, &(&1.law == "01"))
      assert violation.tier == :definite
      assert violation.text == "posts = Repo.all(Post)"
    end

    test "the same query outside mount is not flagged as #01" do
      source = """
      defmodule MyApp.Posts do
        def list, do: Repo.all(Post)
      end
      """

      assert Laws.judge(source).violations == []
    end

    test "unguarded PubSub.subscribe in mount is a definite #03" do
      source = """
      def mount(_params, _session, socket) do
        Phoenix.PubSub.subscribe(MyApp.PubSub, "posts")
        {:ok, socket}
      end
      """

      assert Enum.any?(Laws.judge(source).violations, &(&1.law == "03" and &1.tier == :definite))
    end

    test "connected?-guarded subscribe in mount is clean (#03)" do
      source = """
      def mount(_params, _session, socket) do
        socket =
          if connected?(socket) do
            Phoenix.PubSub.subscribe(MyApp.PubSub, "posts")
            socket
          end

        {:ok, socket}
      end
      """

      assert Laws.judge(source).violations == []
    end

    test "starting a process in mount is a likely #13" do
      source = """
      def mount(_params, _session, socket) do
        {:ok, _} = GenServer.start_link(MyApp.Watcher, :ok)
        {:ok, socket}
      end
      """

      assert Enum.any?(Laws.judge(source).violations, &(&1.law == "13" and &1.tier == :likely))
    end
  end

  describe "judge/2 — window detectors" do
    test "Oban.Worker without unique is a likely #07" do
      source = """
      defmodule MyApp.Workers.Sync do
        use Oban.Worker,
          queue: :sync,
          max_attempts: 5

        @impl true
        def perform(%Oban.Job{}), do: :ok
      end
      """

      assert [violation] = Enum.filter(Laws.judge(source).violations, &(&1.law == "07"))
      assert violation.tier == :likely
    end

    test "Oban.Worker with unique is clean (#07)" do
      source = """
      defmodule MyApp.Workers.Sync do
        use Oban.Worker,
          queue: :sync,
          unique: [period: 300]

        @impl true
        def perform(%Oban.Job{}), do: :ok
      end
      """

      assert Laws.judge(source).violations == []
    end
  end

  describe "judge/2 — file detectors" do
    test "handle_event with no Ash.can? in the file is a likely #11" do
      source = """
      defmodule MyApp.AdminLive do
        def handle_event("delete", %{"id" => id}, socket) do
          {:noreply, socket}
        end
      end
      """

      assert [violation] = Enum.filter(Laws.judge(source).violations, &(&1.law == "11"))
      assert violation.tier == :likely
    end

    test "an Ash.can? anywhere in the file cleans #11" do
      source = """
      defmodule MyApp.AdminLive do
        def handle_event("delete", %{"id" => id}, socket) do
          if Ash.can?({Post, :destroy}, socket.assigns.current_scope) do
            :ok
          end

          {:noreply, socket}
        end
      end
      """

      assert Laws.judge(source).violations == []
    end

    test "File.read! without @external_resource is a review #16" do
      source = "def terms, do: File.read!(\"priv/terms.md\")"
      report = Laws.judge(source, min_tier: :review)

      assert [violation] = Enum.filter(report.violations, &(&1.law == "16"))
      assert violation.tier == :review
    end

    test "hidden inputs alongside inputs_for keep #19 clean" do
      clean = """
      <.inputs_for :let={f} field={@form[:meta]}>
        <.input type="hidden" field={f[:id]} />
        <.input field={f[:note]} />
      </.inputs_for>
      """

      assert Laws.judge(clean, min_tier: :review).violations == []

      naked = """
      <.inputs_for :let={f} field={@form[:meta]}>
        <.input field={f[:note]} />
      </.inputs_for>
      """

      assert Enum.any?(
               Laws.judge(naked, min_tier: :review).violations,
               &(&1.law == "19" and &1.tier == :review)
             )
    end
  end

  describe "judge/2 — filtering and report shape" do
    @review_only "cast_assoc(:comments)"
    @mixed """
    cast_assoc(:comments)
    x = String.to_atom(input)
    """

    test "default min_tier (:likely) hides review hits but counts them" do
      report = Laws.judge(@review_only)

      assert report.violations == []
      assert report.clean? == true
      assert report.counts == %{definite: 0, likely: 0, review: 1}
    end

    test "min_tier: :review surfaces everything" do
      report = Laws.judge(@review_only, min_tier: :review)
      assert length(report.violations) == 1
      assert report.clean? == false
    end

    test "min_tier: :definite leaves only definite hits" do
      report = Laws.judge(@mixed, min_tier: :definite)
      assert Enum.map(report.violations, & &1.law) == ["10"]

      # counts still cover every tier regardless of the floor
      assert report.counts == %{definite: 1, likely: 0, review: 1}
    end

    test "laws: restricts the judgement; unknown ids raise with the valid ids" do
      report = Laws.judge(@mixed, laws: ["10"])
      assert Enum.map(report.violations, & &1.law) == ["10"]
      assert report.laws_checked == 1

      assert_raise ArgumentError, ~r/unknown law id\(s\)/, fn ->
        Laws.judge("x", laws: ["99"])
      end
    end

    test "clean source reports clean? with zero counts" do
      report = Laws.judge("def ok, do: :ok", min_tier: :review)

      assert %{violations: [], counts: %{definite: 0, likely: 0, review: 0}, clean?: true} =
               report
    end

    test "the report is JSON-encodable" do
      report = Laws.judge(@mixed, file: "lib/bad.ex", min_tier: :review)

      json = Jason.encode!(report)
      decoded = Jason.decode!(json)

      assert decoded["source"] == "lib/bad.ex"
      # sorted by line: cast_assoc (line 1), String.to_atom (line 2)
      assert Enum.map(decoded["violations"], & &1["law"]) == ["17", "10"]
      assert decoded["counts"] == %{"definite" => 1, "likely" => 0, "review" => 1}
    end

    test "violations are sorted by line" do
      source = """
      defmodule M do
        def a, do: String.to_atom(x)
        def b, do: String.to_atom(y)
      end
      """

      lines = Laws.judge(source).violations |> Enum.map(& &1.line)
      assert lines == Enum.sort(lines)
    end

    test "laws_without_detectors lists the selected behavior-only laws" do
      all = Laws.judge("x").laws_without_detectors
      assert %{} = Map.new(all, &{&1.id, &1.name})
      assert {"22", "verify-before-claiming-done"} in Enum.map(all, &{&1.id, &1.name})

      # a restricted selection only lists its own gaps
      restricted = Laws.judge("x", laws: ["10"]).laws_without_detectors
      assert restricted == []
    end
  end

  describe "judge/2 — diff mode" do
    @diff """
    diff --git a/lib/ok.ex b/lib/ok.ex
    --- a/lib/ok.ex
    +++ b/lib/ok.ex
    @@ -1,3 +1,3 @@
    -old = String.to_atom(input)
    +new = String.upcase(input)
    context = Repo.all(Post)
    """
    @bad_diff """
    diff --git a/lib/bad.ex b/lib/bad.ex
    --- a/lib/bad.ex
    +++ b/lib/bad.ex
    @@ -1,2 +1,3 @@
    +x = String.to_atom(input)
     y = Repo.all(Post)
    """

    test "only added lines are judged; removed and context lines are ignored" do
      report = Laws.judge(@diff, diff?: true)
      assert report.violations == []
    end

    test "added violations are reported at their diff line number" do
      report = Laws.judge(@bad_diff, diff?: true)
      assert [violation] = report.violations
      assert violation.law == "10"
      assert violation.line == 5
    end

    test "whole-file detectors are skipped in diff mode" do
      # the +hunk alone would trigger #10 but never the file-level #01;
      # and a diff full of +context lines must not run file detectors
      source = """
      +++ b/lib/x.ex
      +def handle_event("delete", _, socket), do: :ok
      """

      report = Laws.judge(source, diff?: true)
      assert report.violations == []
    end
  end
end
