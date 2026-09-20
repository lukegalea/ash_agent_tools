# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Suggest do
  @moduledoc false

  # "Did you mean" support shared by the tool-gap reporting (validate,
  # search, context): ranks candidate names by Levenshtein distance from the
  # misspelled input and returns the closest ones. Deliberately tiny and
  # dependency-free — the candidate set is always small (one action's input
  # contract, the loaded symbol names, the loaded module files).

  @doc """
  Returns up to `max_results` candidates within `max_distance` edits of
  `name`, closest first (ties broken alphabetically). Comparison is
  case-insensitive; candidates may be atoms or binaries and are returned as
  binaries.
  """
  @spec closest(String.t(), [atom() | String.t()], pos_integer(), non_neg_integer()) :: [
          String.t()
        ]
  def closest(name, candidates, max_results \\ 3, max_distance \\ 3)
      when is_binary(name) and is_list(candidates) and is_integer(max_results) and
             is_integer(max_distance) do
    needle = String.downcase(name)

    candidates
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.map(&{levenshtein(String.downcase(&1), needle), &1})
    |> Enum.filter(fn {distance, _candidate} -> distance <= max_distance end)
    |> Enum.sort()
    |> Enum.take(max_results)
    |> Enum.map(&elem(&1, 1))
  end

  # Classic two-row dynamic-programming Levenshtein distance.
  @spec levenshtein(String.t(), String.t()) :: non_neg_integer()
  def levenshtein(left, right) do
    left = String.to_charlist(left)
    right = String.to_charlist(right)

    initial = Enum.map(0..length(right), & &1)

    {final_row, _} =
      Enum.reduce(Enum.with_index(left, 1), {initial, 0}, fn {char, i}, {prev_row, _} ->
        {row, _} =
          Enum.reduce(Enum.with_index(right, 1), {[i], i}, fn {rchar, j}, {row_acc, above} ->
            cost = if char == rchar, do: 0, else: 1
            diagonal = Enum.at(prev_row, j - 1)
            value = Enum.min([Enum.at(prev_row, j) + 1, above + 1, diagonal + cost])
            {row_acc ++ [value], value}
          end)

        {row, i}
      end)

    Enum.at(final_row, length(right))
  end
end
