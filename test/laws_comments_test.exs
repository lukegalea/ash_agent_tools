# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Laws.CommentsTest do
  use ExUnit.Case, async: true

  alias AshAgentTools.Laws
  alias AshAgentTools.Laws.Comments

  defp lines(text), do: String.split(text, "\n")

  describe "blank/2" do
    test "keeps every line in place" do
      source = """
      # a comment
      @doc \"\"\"
      two
      lines
      \"\"\"
      def f, do: 1 # trailing
      <%!-- heex
      comment --%>x
      """

      out = Comments.blank(source)
      assert length(lines(out)) == length(lines(source))
    end

    test "blanks # comments outside strings, keeps them inside" do
      assert Comments.blank("x = 1 # String.to_atom(y)") == "x = 1 "
      assert Comments.blank(~s|s = "a # b"|) == ~s|s = "a # b"|
      assert Comments.blank(~S|s = "#{x}" # note|) == ~S|s = "#{x}" |
      assert Comments.blank(~S|s = "say \"#\"" # note|) == ~S|s = "say \"#\"" |
      assert Comments.blank("    # only a comment") == "    "
    end

    test "blanks doc heredocs, with or without ~S, and one-line doc strings" do
      source = """
      @moduledoc ~S\"\"\"
      Never call String.to_atom(input) here.
      \"\"\"
      @doc \"\"\"
      Repo.insert in a comment
      \"\"\"
      @typedoc "String.to_atom is bad"
      @doc false
      def f(x), do: String.to_atom(x)
      """

      # six blanked lines, then the one-line typedoc emptied, then code as it was
      assert Comments.blank(source) ==
               "





@typedoc \"\"
@doc false
def f(x), do: String.to_atom(x)
"
    end

    test "blanks HEEx and HTML comments on one line and across lines" do
      assert Comments.blank(~s|<p>a</p><%!-- <button> --%><p>b</p>|) == "<p>a</p><p>b</p>"
      assert Comments.blank(~s|<p>a</p><!-- <button> --><p>b</p>|) == "<p>a</p><p>b</p>"

      source = """
      <div>
      <%!-- a <button> here
      and <table> there --%><span>kept</span>
      <!-- another
      one -->
      </div>
      """

      assert Comments.blank(source) == "<div>\n\n<span>kept</span>\n\n\n</div>\n"
    end

    test "code before a comment opener stays" do
      assert Comments.blank("<p>x</p><%!-- open\nstill --%>") == "<p>x</p>\n"
    end

    test "in diff mode only one-line forms are blanked, on added lines" do
      diff = """
      +++ b/lib/x.ex
      +x = 1 # String.to_atom(y)
      +@doc "String.to_atom"
      +@doc \"\"\"
      +String.to_atom in a heredoc the diff cannot pair
      -y = 2 # removed, untouched
       z = 3 # context, untouched
      """

      assert Comments.blank(diff, diff?: true) == """
             +++ b/lib/x.ex
             +x = 1 
             +@doc ""
             +@doc \"\"\"
             +String.to_atom in a heredoc the diff cannot pair
             -y = 2 # removed, untouched
              z = 3 # context, untouched
             """
    end
  end

  describe "judge/2 with ignore_comments" do
    @source """
    # String.to_atom(x) in a comment
    @doc \"\"\"
    Calls String.to_atom(y).
    \"\"\"
    def f(z), do: String.to_atom(z)
    """

    test "comments and docs trip laws by default" do
      assert Enum.map(Laws.judge(@source).violations, & &1.line) == [1, 3, 5]
    end

    test "with ignore_comments only the code is judged, at its own line" do
      report = Laws.judge(@source, ignore_comments: true)
      assert [%{law: "10", line: 5}] = report.violations
    end

    test "applies in diff mode too" do
      diff = "+++ b/lib/x.ex\n+# String.to_atom(a)\n+b = String.to_atom(c)\n"
      assert Enum.map(Laws.judge(diff, diff?: true).violations, & &1.line) == [2, 3]

      assert Enum.map(Laws.judge(diff, diff?: true, ignore_comments: true).violations, & &1.line) ==
               [3]
    end
  end
end
