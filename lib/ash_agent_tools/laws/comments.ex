# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Laws.Comments do
  @moduledoc """
  Blanks comments and doc attributes out of Elixir/HEEx source before the
  judge reads it, so a law about code does not fire on prose that mentions
  the pattern. Every line stays in place: the result has the same number
  of lines as the input, with the commented parts emptied, so the judge's
  line numbers still point at the right place.

  What is blanked:

    * `#` to the end of the line, outside a double-quoted string
    * `@doc`, `@moduledoc`, `@typedoc` and `@shortdoc` values: a one-line
      string, or a `\"\"\"` / `'''` heredoc (with or without `~S`/`~s`), the
      whole block
    * HEEx comments `<%!-- --%>` and HTML comments `<!-- -->`, across lines

  Grep-tier, like the judge: strings are tracked per line, so a `#` inside
  a multi-line string or a `?"` character literal can fool it, and the
  tiers say so. In `diff?` mode only the one-line forms are applied, to
  each added (`+`) line, because a diff does not carry enough context to
  pair a heredoc's or a comment's opening with its close.

  `AshAgentTools.Laws.judge/2` applies this when given `ignore_comments:
  true`; it is off by default.
  """

  @doc_heredoc ~r/^\s*@(?:module|type|short)?doc\s+(?:~[sS])?("""|''')\s*$/
  @doc_one_line ~r/^(\s*@(?:module|type|short)?doc\s+)(?:~[sS])?"(?:[^"\\]|\\.)*"\s*$/
  @inline_comments ~r/<%!--.*?--%>|<!--.*?-->/

  @doc """
  The source with its comments and doc attributes blanked, line for line.

  Options: `diff?: true` treats the text as a unified diff and blanks only
  the one-line forms, on added lines.
  """
  @spec blank(String.t(), keyword()) :: String.t()
  def blank(source, opts \\ []) when is_binary(source) do
    lines = String.split(source, ["\r\n", "\n"])

    blanked =
      if Keyword.get(opts, :diff?, false) do
        Enum.map(lines, &blank_diff_line/1)
      else
        lines |> Enum.map_reduce(:code, &blank_line/2) |> elem(0)
      end

    Enum.join(blanked, "\n")
  end

  defp blank_diff_line("+" <> rest), do: "+" <> inline(rest)
  defp blank_diff_line(line), do: line

  # One line in file mode, carrying the state across lines: inside a doc
  # heredoc or a multi-line HEEx/HTML comment, lines are emptied until the
  # closer; in code, a line may open either and is blanked from there.
  defp blank_line(line, :code) do
    case Regex.run(@doc_heredoc, line) do
      [_, closer] ->
        {"", {:heredoc, closer}}

      nil ->
        without_inline = Regex.replace(@inline_comments, line, "")

        case opener(without_inline) do
          nil -> {inline(line), :code}
          {before, closer} -> {inline(before), {:comment, closer}}
        end
    end
  end

  defp blank_line(line, {:heredoc, closer}) do
    if String.trim(line) == closer, do: {"", :code}, else: {"", {:heredoc, closer}}
  end

  defp blank_line(line, {:comment, closer}) do
    case String.split(line, closer, parts: 2) do
      [_inside, after_close] -> blank_line(after_close, :code)
      [_] -> {"", {:comment, closer}}
    end
  end

  # The earliest comment opener left on a line once complete comments are
  # gone, with the code before it and the closer to wait for.
  defp opener(line) do
    [{"<%!--", "--%>"}, {"<!--", "-->"}]
    |> Enum.flat_map(fn {open, close} ->
      case :binary.match(line, open) do
        {pos, _} -> [{pos, binary_part(line, 0, pos), close}]
        :nomatch -> []
      end
    end)
    |> Enum.min_by(&elem(&1, 0), fn -> nil end)
    |> case do
      nil -> nil
      {_pos, before, close} -> {before, close}
    end
  end

  # The one-line forms: a one-line doc string, complete HEEx/HTML comments,
  # then `#` to the end of the line outside a string.
  defp inline(line) do
    line
    |> then(&Regex.replace(@doc_one_line, &1, "\\1\"\""))
    |> then(&Regex.replace(@inline_comments, &1, ""))
    |> strip_hash(false, [])
  end

  defp strip_hash(<<>>, _in_string?, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp strip_hash(<<"\\", c::utf8, rest::binary>>, true, acc),
    do: strip_hash(rest, true, [<<"\\", c::utf8>> | acc])

  defp strip_hash(<<?", rest::binary>>, in_string?, acc),
    do: strip_hash(rest, not in_string?, [?" | acc])

  defp strip_hash(<<?#, _::binary>>, false, acc), do: strip_hash(<<>>, false, acc)

  defp strip_hash(<<c::utf8, rest::binary>>, in_string?, acc),
    do: strip_hash(rest, in_string?, [<<c::utf8>> | acc])
end
