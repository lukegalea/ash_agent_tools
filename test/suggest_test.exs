# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.SuggestTest do
  use ExUnit.Case, async: true

  alias AshAgentTools.Suggest

  describe "closest/4" do
    test "returns the closest candidates first, within the distance budget" do
      assert Suggest.closest("wat", ["title", "body", "status", "tags", "score"]) == ["tags"]
    end

    test "ties break alphabetically" do
      # "abb" is distance 1 from both "aba" and "abc"
      assert Suggest.closest("abb", ["abc", "aba"]) == ["aba", "abc"]
    end

    test "matching is case-insensitive; candidates may be atoms" do
      assert Suggest.closest("WAT", [:tags]) == ["tags"]
      assert Suggest.closest("wat", ["TAGS"]) == ["TAGS"]
    end

    test "respects max_results and max_distance" do
      candidates = ["aa", "ab", "ac", "zzzzz"]

      assert Suggest.closest("aa", candidates, 2) == ["aa", "ab"]
      assert Suggest.closest("aa", candidates, 3, 0) == ["aa"]
      assert Suggest.closest("aa", candidates, 3, 1) == ["aa", "ab", "ac"]
    end

    test "empty or disjoint candidate sets suggest nothing" do
      assert Suggest.closest("x", []) == []
      assert Suggest.closest("completely-different", ["tags"]) == []
    end
  end

  describe "levenshtein/2" do
    test "computes the classic edit distance" do
      assert Suggest.levenshtein("kitten", "sitting") == 3
      assert Suggest.levenshtein("flaw", "lawn") == 2
      assert Suggest.levenshtein("", "abc") == 3
      assert Suggest.levenshtein("abc", "") == 3
      assert Suggest.levenshtein("same", "same") == 0
    end
  end
end
