# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.ProjectLawsTest.UI do
  @behaviour AshAgentTools.Laws.Source

  @impl true
  def laws do
    [
      %{
        id: "ui-01",
        name: "design-system-buttons",
        category: :ui,
        title: "Buttons come from the design system",
        summary: "A raw <button> drifts from the design system; use <ds-button>.",
        detectors: [
          %{
            kind: :line,
            tier: :likely,
            pattern: ~r/<button[\s>]/,
            hint: "use <ds-button> instead of a raw <button>"
          }
        ]
      },
      %{
        id: "ui-02",
        name: "spacing-tokens",
        category: :ui,
        title: "Spacing comes from tokens",
        summary: "Prefer spacing tokens over the raw Tailwind scale.",
        detectors: [
          %{kind: :line, tier: :review, pattern: ~r/\bgap-\d+\b/, hint: "use a spacing token"}
        ]
      },
      %{
        id: "ui-03",
        name: "copy-is-reviewed",
        category: :ui,
        title: "UI copy is reviewed",
        summary: "A behavioral rule with no detector.",
        detectors: []
      }
    ]
  end
end

defmodule AshAgentTools.ProjectLawsTest do
  # Not async: one test sets the :extra_laws application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshAgentTools.Laws
  alias AshAgentTools.ProjectLawsTest.UI

  @law %{
    id: "ui-09",
    name: "a-law",
    category: :ui,
    title: "A law",
    summary: "A summary.",
    detectors: [%{kind: :line, tier: :definite, pattern: ~r/forbidden/, hint: "don't"}]
  }

  describe "without project laws" do
    test "the registry is the 26 core laws" do
      assert Laws.laws() == Laws.core_laws()
      assert length(Laws.laws()) == 26
      assert Laws.project_laws() == []
    end
  end

  describe "judge/2 with :extra_laws" do
    test "a project law catches its pattern, reported like a core law" do
      report = Laws.judge(~s|<button phx-click="go">Go</button>|, extra_laws: [UI])

      assert report.laws_checked == 29
      assert [violation] = report.violations

      assert %{law: "ui-01", name: "design-system-buttons", category: :ui, tier: :likely} =
               violation

      assert violation.hint =~ "<ds-button>"
      refute report.clean?
    end

    test "core laws still apply alongside project laws" do
      report = Laws.judge("x = String.to_atom(input)\n<button>", extra_laws: [UI])
      assert report.violations |> Enum.map(& &1.law) |> Enum.sort() == ["10", "ui-01"]
    end

    test "--law selection takes project ids; unknown ids still raise" do
      report =
        Laws.judge("x = String.to_atom(input)\n<button>", extra_laws: [UI], laws: ["ui-01"])

      assert [%{law: "ui-01"}] = report.violations

      assert_raise ArgumentError, ~r/ui-99/, fn ->
        Laws.judge("x", extra_laws: [UI], laws: ["ui-99"])
      end
    end

    test "the tier floor filters project laws and counts them" do
      default = Laws.judge(~s|<div class="flex gap-3">|, extra_laws: [UI])
      assert default.violations == []
      assert default.counts.review == 1

      review = Laws.judge(~s|<div class="flex gap-3">|, extra_laws: [UI], min_tier: :review)
      assert [%{law: "ui-02", tier: :review}] = review.violations
    end

    test "diff mode judges only added lines for project laws too" do
      diff = """
      +++ b/lib/page.ex
      @@ -1,2 +1,2 @@
      -<button>old</button>
      +<button>new</button>
       <button>context</button>
      """

      report = Laws.judge(diff, extra_laws: [UI], diff?: true)
      assert [%{law: "ui-01", line: 4}] = report.violations
    end

    test "a project law without detectors is in laws_without_detectors" do
      report = Laws.judge("x", extra_laws: [UI])
      assert %{id: "ui-03", name: "copy-is-reviewed"} in report.laws_without_detectors
    end

    test "law maps work as well as modules" do
      assert [%{law: "ui-09"}] = Laws.judge("forbidden", extra_laws: [@law]).violations
    end
  end

  describe "config :ash_agent_tools, :extra_laws" do
    setup do
      Application.put_env(:ash_agent_tools, :extra_laws, [UI])
      on_exit(fn -> Application.delete_env(:ash_agent_tools, :extra_laws) end)
    end

    test "laws/0 and judge/2 pick them up; the option overrides the config" do
      assert length(Laws.laws()) == 29
      assert Enum.map(Laws.project_laws(), & &1.id) == ["ui-01", "ui-02", "ui-03"]
      assert [%{law: "ui-01"}] = Laws.judge("<button>").violations
      assert Laws.judge("<button>", extra_laws: []).violations == []
    end

    test "mix ash_agent.laws judges and lists them" do
      judged =
        capture_io(fn -> Mix.Tasks.AshAgent.Laws.run(["--code", "<button>Go</button>"]) end)

      assert %{"violations" => [%{"law" => "ui-01"}]} = Jason.decode!(judged)

      registry = Jason.decode!(capture_io(fn -> Mix.Tasks.AshAgent.Laws.run([]) end))
      assert registry["count"] == 29
      assert %{"id" => "ui-01", "project?" => true} = Enum.at(registry["laws"], 26)
      assert Enum.all?(Enum.take(registry["laws"], 26), &(&1["project?"] == false))
    end
  end

  describe "validation" do
    test "a core id is rejected" do
      assert_raise ArgumentError, ~r/"10" is a core iron law/, fn ->
        Laws.project_laws(extra_laws: [%{@law | id: "10"}])
      end
    end

    test "an empty id is rejected" do
      assert_raise ArgumentError, ~r/must not be empty/, fn ->
        Laws.project_laws(extra_laws: [%{@law | id: ""}])
      end
    end

    test "numeric ids are reserved for the core numbering" do
      assert_raise ArgumentError, ~r/"27" is reserved/, fn ->
        Laws.project_laws(extra_laws: [%{@law | id: "27"}])
      end
    end

    test "duplicate ids are rejected" do
      assert_raise ArgumentError, ~r/duplicate project law id\(s\) \["ui-09"\]/, fn ->
        Laws.project_laws(extra_laws: [@law, @law])
      end
    end

    test "a detector missing its pattern is rejected" do
      law = %{@law | detectors: [%{kind: :line, tier: :likely, hint: "h"}]}

      assert_raise ArgumentError, ~r/:line detector of law "ui-09" needs :pattern/, fn ->
        Laws.project_laws(extra_laws: [law])
      end
    end

    test "an unknown detector kind or tier is rejected" do
      for det <- [
            %{kind: :bogus, tier: :likely, pattern: ~r/x/, hint: "h"},
            %{kind: :line, tier: :maybe, pattern: ~r/x/, hint: "h"}
          ] do
        assert_raise ArgumentError, ~r/invalid detector/, fn ->
          Laws.project_laws(extra_laws: [%{@law | detectors: [det]}])
        end
      end
    end

    test "a law missing its title is rejected" do
      assert_raise ArgumentError, ~r/needs a non-empty string :title/, fn ->
        Laws.project_laws(extra_laws: [Map.delete(@law, :title)])
      end
    end

    test "a module without laws/0 is rejected" do
      assert_raise ArgumentError, ~r/exporting laws\/0/, fn ->
        Laws.project_laws(extra_laws: [String])
      end
    end
  end

  describe "paths and exclude" do
    @web_law %{
      id: "ui-10",
      name: "web-buttons",
      category: :ui,
      title: "Buttons come from the design system",
      summary: "Only the web layer draws buttons.",
      paths: ["lib/my_app_web/**/*.{ex,heex}"],
      exclude: ["lib/my_app_web/emails/**"],
      detectors: [
        %{kind: :line, tier: :likely, pattern: ~r/<button[\s>]/, hint: "use <ds-button>"}
      ]
    }

    @everywhere %{
      id: "ui-11",
      name: "no-todo",
      category: :style,
      title: "No TODO",
      summary: "A TODO is a ticket, not a comment.",
      detectors: [%{kind: :line, tier: :review, pattern: ~r/TODO/, hint: "open a ticket"}]
    }

    @source "<button>Go</button>\n"

    defp hits(source, opts) do
      Laws.judge(
        source,
        Keyword.merge([extra_laws: [@web_law, @everywhere], min_tier: :review], opts)
      )
      |> Map.fetch!(:violations)
      |> Enum.map(&{&1.law, &1.file})
    end

    test "a scoped law applies to a matching path and to nothing else" do
      assert hits(@source, file: "lib/my_app_web/live/post_live.ex") == [
               {"ui-10", "lib/my_app_web/live/post_live.ex"}
             ]

      assert hits(@source, file: "lib/my_app_web/components/card.heex") == [
               {"ui-10", "lib/my_app_web/components/card.heex"}
             ]

      assert hits(@source, file: "lib/my_app/accounts/user.ex") == []
      assert hits(@source, file: "test/my_app_web/live/post_live_test.exs") == []
    end

    test "exclude keeps a law off matching paths" do
      assert hits(@source, file: "lib/my_app_web/emails/welcome.heex") == []
    end

    test "a leading ./ does not defeat the match" do
      assert hits(@source, file: "./lib/my_app_web/live/post_live.ex") != []
    end

    test "a snippet has no path: scoped laws are skipped, unscoped laws still judge it" do
      assert hits("<button>TODO</button>", []) == [{"ui-11", nil}]
      assert hits("<button>TODO</button>", file: "inline") == [{"ui-11", nil}]
    end

    test "laws_checked counts the laws that apply to the file" do
      core = length(Laws.core_laws())

      report =
        Laws.judge(@source, extra_laws: [@web_law, @everywhere], file: "lib/my_app/user.ex")

      assert report.laws_checked == core + 1

      report =
        Laws.judge(@source, extra_laws: [@web_law, @everywhere], file: "lib/my_app_web/x.ex")

      assert report.laws_checked == core + 2
    end

    test "glob forms: * stays within a directory, ** crosses, ? is one character, {a,b} alternates" do
      law = fn paths -> Map.merge(@everywhere, %{id: "ui-12", paths: paths}) end

      judge = fn paths, file ->
        Laws.judge("TODO", extra_laws: [law.(paths)], min_tier: :review, file: file).clean?
      end

      refute judge.(["lib/*.ex"], "lib/a.ex")
      assert judge.(["lib/*.ex"], "lib/sub/a.ex")
      refute judge.(["lib/**/*.ex"], "lib/sub/deeper/a.ex")
      refute judge.(["lib/**/*.ex"], "lib/a.ex")
      refute judge.(["lib/?.ex"], "lib/a.ex")
      assert judge.(["lib/?.ex"], "lib/ab.ex")
      refute judge.(["lib/a.{ex,heex}"], "lib/a.heex")
      assert judge.(["lib/a.{ex,heex}"], "lib/a.exs")
    end

    test "in diff mode each hunk is judged under its own file" do
      diff = """
      diff --git a/lib/my_app_web/live/post_live.ex b/lib/my_app_web/live/post_live.ex
      --- a/lib/my_app_web/live/post_live.ex
      +++ b/lib/my_app_web/live/post_live.ex
      @@ -1,2 +1,3 @@
      +<button>Go</button>
       x = 1
      diff --git a/test/post_live_test.exs b/test/post_live_test.exs
      --- a/test/post_live_test.exs
      +++ b/test/post_live_test.exs
      @@ -1,2 +1,3 @@
      +<button>Go</button>
      +# TODO
      """

      report =
        Laws.judge(diff,
          extra_laws: [@web_law, @everywhere],
          min_tier: :review,
          diff?: true,
          file: "-"
        )

      assert Enum.map(report.violations, &{&1.law, &1.file, &1.line}) == [
               {"ui-10", "lib/my_app_web/live/post_live.ex", 5},
               {"ui-11", "test/post_live_test.exs", 12}
             ]
    end

    test "core laws keep applying everywhere, with the file on the violation" do
      report = Laws.judge("x = String.to_atom(input)", file: "lib/anything/at_all.ex")
      assert [%{law: "10", file: "lib/anything/at_all.ex"}] = report.violations
    end

    test "paths and exclude must be lists of glob strings" do
      for {key, bad} <- [paths: "lib/**", exclude: [""], paths: [:lib]] do
        law = Map.put(@everywhere, key, bad)

        assert_raise ArgumentError, ~r/needs #{inspect(key)} to be a list of glob strings/, fn ->
          Laws.judge("x", extra_laws: [law])
        end
      end
    end
  end

  describe ":custom detectors" do
    defp custom_law(check, extra \\ %{}) do
      Map.merge(
        %{
          id: "ui-20",
          name: "click-targets",
          category: :ui,
          title: "Click targets are controls",
          summary: "phx-click belongs on a button or a link, not a div.",
          detectors: [
            %{kind: :custom, tier: :likely, hint: "put phx-click on the control", check: check}
          ]
        },
        extra
      )
    end

    # Lines whose text contains the needle, as the detector's line numbers.
    defp lines_with(needle) do
      fn _source, meta ->
        for {line, no} <- Enum.with_index(meta.lines, 1), String.contains?(line, needle), do: no
      end
    end

    @source """
    <div phx-click="open">a</div>
    <button phx-click="open">b</button>
    """

    test "a hit by line number takes the line's text and the detector's hint" do
      report = Laws.judge(@source, extra_laws: [custom_law(lines_with("<div phx-click"))])

      assert [violation] = report.violations
      assert %{law: "ui-20", tier: :likely, line: 1} = violation
      assert violation.text == ~s(<div phx-click="open">a</div>)
      assert violation.hint == "put phx-click on the control"
    end

    test "a hit map may carry its own text and hint" do
      check = fn _source, _meta ->
        [%{line: 2, text: "the button", hint: "this one is fine, but"}]
      end

      report = Laws.judge(@source, extra_laws: [custom_law(check)])

      assert [%{line: 2, text: "the button", hint: "this one is fine, but"}] = report.violations
    end

    test "check receives the source and meta with file, lines and diff?" do
      me = self()
      check = fn source, meta -> send(me, {:checked, source, meta}) && [] end

      Laws.judge(@source, extra_laws: [custom_law(check)], file: "lib/x.heex")
      assert_receive {:checked, @source, %{file: "lib/x.heex", lines: lines, diff?: false}}
      assert length(lines) == 3

      Laws.judge(@source, extra_laws: [custom_law(check)])
      assert_receive {:checked, @source, %{file: nil, diff?: false}}
    end

    test "runs in diff mode, receiving the diff" do
      diff = "+++ b/lib/x.heex\n+<div phx-click=\"open\">a</div>\n x\n"

      report =
        Laws.judge(diff, extra_laws: [custom_law(lines_with("<div phx-click"))], diff?: true)

      assert [%{line: 2, text: ~s(+<div phx-click="open">a</div>)}] = report.violations
      me = self()

      Laws.judge(diff,
        extra_laws: [custom_law(fn _s, meta -> send(me, meta.diff?) && [] end)],
        diff?: true
      )

      assert_receive true
    end

    test "tiers, --law selection and counts apply like any detector" do
      law =
        custom_law(lines_with("phx-click"), %{
          detectors: [%{kind: :custom, tier: :review, hint: "h", check: lines_with("phx-click")}]
        })

      report = Laws.judge(@source, extra_laws: [law])
      assert report.violations == []
      assert report.counts.review == 2

      assert Laws.judge(@source, extra_laws: [law], min_tier: :review, laws: ["ui-20"]).violations
             |> length() == 2

      assert Laws.judge(@source, extra_laws: [law], min_tier: :review, laws: ["10"]).violations ==
               []

      assert is_binary(Jason.encode!(Laws.judge(@source, extra_laws: [law], min_tier: :review)))
    end

    test "a bad return is the project's bug, named" do
      assert_raise ArgumentError, ~r/law "ui-20" returned "nope"; expected a list/, fn ->
        Laws.judge(@source, extra_laws: [custom_law(fn _, _ -> "nope" end)])
      end

      assert_raise ArgumentError, ~r/law "ui-20" returned the hit %{line: 0}/, fn ->
        Laws.judge(@source, extra_laws: [custom_law(fn _, _ -> [%{line: 0}] end)])
      end

      assert_raise ArgumentError, ~r/returned the hit %{line: 1, text: 7}/, fn ->
        Laws.judge(@source, extra_laws: [custom_law(fn _, _ -> [%{line: 1, text: 7}] end)])
      end
    end

    test "check must be a function of (source, meta)" do
      for check <- [nil, fn _ -> [] end, "f"] do
        law = custom_law(check)

        assert_raise ArgumentError,
                     ~r/a :custom detector of law "ui-20" needs :check \(a function of \(source, meta\)\)/,
                     fn ->
                       Laws.judge(@source, extra_laws: [law])
                     end
      end
    end
  end
end
