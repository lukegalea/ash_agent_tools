# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.SymbolsTest do
  use ExUnit.Case, async: true

  doctest AshAgentTools.Symbols

  alias AshAgentTools.Symbols
  alias AshAgentTools.Test.Probed

  describe "extension_symbols/1 — projection" do
    test "projects custom extension sections under namespaced kinds" do
      symbols = Symbols.resource_symbols(Probed)

      custom =
        Enum.filter(
          symbols,
          &(is_binary(&1.dsl_path) and String.starts_with?(&1.dsl_path, "probe_"))
        )

      assert Enum.map(custom, &{&1.kind, &1.dsl_path, &1.name}) |> Enum.sort() == [
               {:probe_badges, "probe_badges", :badges_1},
               {:probe_badges, "probe_badges", :badges_2},
               {:probe_badges, "probe_badges", :critical},
               {:probe_widgets, "probe_widgets", :stethoscope},
               {:probe_widgets, "probe_widgets", :syringe},
               {:probe_widgets_gears, "probe_widgets_gears", :main}
             ]
    end

    test "positions follow declaration order within a kind" do
      symbols = Symbols.extension_symbols(Probed)

      assert Enum.map(Enum.filter(symbols, &(&1.kind == :probe_widgets)), & &1.position) ==
               [0, 1]

      assert Enum.map(Enum.filter(symbols, &(&1.kind == :probe_badges)), & &1.position) ==
               [0, 1, 2]
    end

    test "the identifier ladder — :name, :id, :tag, then positional fallback" do
      names = Symbols.extension_symbols(Probed) |> MapSet.new(& &1.name)

      assert MapSet.member?(names, :stethoscope)
      assert MapSet.member?(names, :main)
      assert MapSet.member?(names, :critical)
      # the two seal entities expose no identifier-shaped field at all
      assert MapSet.member?(names, :badges_1)
      assert MapSet.member?(names, :badges_2)
    end

    test "foreign entities are not fabricating a type; core sections are not re-projected" do
      for symbol <- Symbols.extension_symbols(Probed) do
        assert symbol.type == nil

        assert symbol.dsl_path not in ~w(attributes actions calculations relationships policies code_interfaces)
      end
    end

    test "custom entities carry their Spark annotation when present" do
      symbol =
        Symbols.extension_symbols(Probed)
        |> Enum.find(&(&1.name == :stethoscope))

      assert symbol.provenance == :source
      assert symbol.source.file =~ ~r{test/support/probed\.ex$}
      assert is_integer(symbol.source.line)
    end

    test "extension-free resources project nothing generic" do
      assert Symbols.extension_symbols(AshAgentTools.Test.Post) == []
    end

    test "resource_symbols carries the custom symbols alongside the core ones" do
      symbols = Symbols.resource_symbols(Probed)

      assert Enum.any?(symbols, &(&1.kind == :attribute and &1.name == :id))
      assert Enum.any?(symbols, &(&1.kind == :probe_widgets and &1.name == :stethoscope))
    end
  end

  describe "search visibility" do
    test "custom extension symbols are searchable without a kind filter" do
      results = AshAgentTools.semantic_search("stethoscope")

      assert [%{kind: :probe_widgets, name: :stethoscope} = hit] = results
      assert hit.resource == Probed
      assert hit.source[:line] > 0
    end

    test "custom extension kinds are filterable (atom and string forms)" do
      assert Enum.any?(
               AshAgentTools.semantic_search("stethoscope", kinds: :probe_widgets),
               &(&1.name == :stethoscope)
             )

      assert Enum.any?(
               AshAgentTools.semantic_search("main", kinds: "probe_widgets_gears"),
               &(&1.name == :main)
             )
    end

    test "unknown kinds still raise, listing the dynamic kinds" do
      assert_raise ArgumentError, ~r/probe_widgets/, fn ->
        AshAgentTools.semantic_search("stethoscope", kinds: :nonsense)
      end
    end
  end

  describe "name-path addressing" do
    test "resolves an entity inside a custom section" do
      {:ok, report} = AshAgentTools.resolve("Probed/probe_widgets/stethoscope")

      assert report.name_path == "AshAgentTools.Test.Probed/probe_widgets/stethoscope"
      assert report.symbol.kind == :probe_widgets
      assert report.symbol.provenance == :source
    end

    test "resolves into a nested section through its namespaced dsl_path" do
      {:ok, report} = AshAgentTools.resolve("Probed/probe_widgets_gears/main")

      assert report.symbol.kind == :probe_widgets_gears
      assert report.symbol.name == :main
    end

    test "resolves a positional fallback name by occurrence" do
      {:ok, report} = AshAgentTools.resolve("Probed/probe_badges/badges_1[1]")

      assert report.name_path == "AshAgentTools.Test.Probed/probe_badges/badges_1[1]"
      assert report.symbol.kind == :probe_badges
      assert report.symbol.name == :badges_1
      assert report.symbol.position == 1
    end

    test "an entity-less section name is not an addressable dsl_path" do
      assert_raise ArgumentError, ~r/unknown dsl_path "probe_options"/, fn ->
        AshAgentTools.resolve("Probed/probe_options/mode")
      end
    end
  end

  describe "semantic edit dry-run" do
    test "replace_entity_block reaches an entity inside a custom section" do
      {:ok, report} =
        AshAgentTools.Edit.replace_entity_block(
          "Probed/probe_widgets/stethoscope",
          "widget :stethoscope do\n    size :small\n  end"
        )

      assert report.dry_run?
      assert report.write? == false
      assert report.diff =~ "widget :stethoscope"
      assert report.diff =~ "size :small"
      assert is_binary(report.current_digest)
    end

    test "insert_after_entity anchors inside a custom section" do
      {:ok, report} =
        AshAgentTools.Edit.insert_after_entity(
          "Probed/probe_badges/badges_1[1]",
          "seal(level: 9)"
        )

      assert report.dry_run?
      assert report.diff =~ "seal(level: 9)"
    end
  end
end
