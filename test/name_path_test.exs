# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.NamePathTest do
  use ExUnit.Case, async: true

  doctest AshAgentTools.NamePath

  alias AshAgentTools.Test.{Domain, Guarded, Post}

  describe "resolve/2 — modules" do
    test "resolves a resource by full name" do
      {:ok, report} = AshAgentTools.resolve("AshAgentTools.Test.Post")

      assert report.name_path == "AshAgentTools.Test.Post"
      assert report.module.module == Post
      assert report.module.kind == :resource
      assert report.module.domain == AshAgentTools.Test.Domain
      assert report.symbol.kind == :resource
      assert report.symbol.provenance == :source
    end

    test "resolves a domain" do
      {:ok, report} = AshAgentTools.resolve("AshAgentTools.Test.Domain")

      assert report.module.kind == :domain
      assert report.symbol.kind == :domain
    end

    test "suffix matching on dot boundaries" do
      {:ok, report} = AshAgentTools.resolve("Post")
      assert report.module.module == Post

      {:ok, report} = AshAgentTools.resolve("Test.Post")
      assert report.module.module == Post
    end

    test "a leading / requires the exact module name" do
      assert_raise ArgumentError, ~r/no Ash module named "Post"/, fn ->
        AshAgentTools.resolve("/Post")
      end

      {:ok, report} = AshAgentTools.resolve("/AshAgentTools.Test.Post")
      assert report.module.module == Post
    end

    test "unknown modules raise with did_you_mean" do
      # User joined the loaded set, so it joined the candidates — Post stays
      # the closest match and comes first.
      assert_raise ArgumentError, ~r/did you mean: \["Post", "User"\]/, fn ->
        AshAgentTools.resolve("Pst/actions/read")
      end
    end
  end

  describe "resolve/2 — segments" do
    test "resolves an action with its span and file shape" do
      {:ok, report} = AshAgentTools.resolve("Post/actions/by_tag")

      assert report.name_path == "AshAgentTools.Test.Post/actions/by_tag"
      assert report.symbol.kind == :action
      assert report.symbol.provenance == :source
      assert report.symbol.span.start_line > 0
      assert report.symbol.source.file =~ "post.ex"
      assert %{digest: digest, symbols: symbols} = report.file_shape
      assert is_binary(digest)
      assert Enum.any?(symbols, &(&1.name_path == "AshAgentTools.Test.Post/actions/by_tag"))
    end

    test "resolves attributes, calculations, and relationships" do
      assert {:ok, %{symbol: %{kind: :attribute}}} =
               AshAgentTools.resolve("Post/attributes/title")

      assert {:ok, %{symbol: %{kind: :calculation}}} =
               AshAgentTools.resolve("Post/calculations/title_length")

      assert {:ok, %{symbol: %{kind: :relationship}}} =
               AshAgentTools.resolve("Post/relationships/comments")
    end

    test "resolves domain segments" do
      {:ok, report} =
        AshAgentTools.resolve("AshAgentTools.Test.InterfaceDomain/code_interfaces/domain_feature")

      assert report.symbol.kind == :code_interface
      assert report.module.kind == :domain
    end

    test "resolves policies by occurrence" do
      {:ok, first} = AshAgentTools.resolve("Guarded/policies/policy[0]")
      {:ok, second} = AshAgentTools.resolve("Guarded/policies/policy[1]")

      assert first.name_path == "AshAgentTools.Test.Guarded/policies/policy[0]"
      assert second.name_path == "AshAgentTools.Test.Guarded/policies/policy[1]"
      assert first.symbol.position == 0
      assert second.symbol.position == 1
      assert first.symbol.provenance == :source
    end

    test "unnamed entities without an index are ambiguous, with the remedy" do
      assert_raise ArgumentError, ~r/unnamed entities are addressed by occurrence/, fn ->
        AshAgentTools.resolve("Guarded/policies/policy")
      end
    end

    test "an out-of-range index raises" do
      assert_raise ArgumentError, ~r/has no policies\/policy\[9\]/, fn ->
        AshAgentTools.resolve("Guarded/policies/policy[9]")
      end
    end

    test "named symbols reject a non-zero index" do
      assert_raise ArgumentError, ~r/has no actions\/by_tag\[1\]/, fn ->
        AshAgentTools.resolve("Post/actions/by_tag[1]")
      end
    end

    test "unknown segments raise with did_you_mean" do
      assert_raise ArgumentError, ~r/did you mean: \["actions\/by_tag\[0\]"\]/, fn ->
        AshAgentTools.resolve("Post/actions/by_tg")
      end
    end

    test "unknown dsl_paths list the valid ones" do
      assert_raise ArgumentError, ~r/Valid dsl_paths:/, fn ->
        AshAgentTools.resolve("Post/functions/read")
      end
    end

    test "transformer-injected actions resolve as :synthetic" do
      # Post declares `defaults [:read, :destroy]` — the generated actions
      # carry no Spark annotation.
      {:ok, report} = AshAgentTools.resolve("Post/actions/read")

      assert report.symbol.provenance == :synthetic
      assert report.symbol.source == nil
      assert report.symbol.span == nil
      assert report.file_shape == nil
    end

    test "more than one segment level is a grammar error" do
      assert_raise ArgumentError, ~r/malformed name_path/, fn ->
        AshAgentTools.resolve("Post/actions/read/arguments/tag")
      end
    end
  end

  describe "resolve/2 — input validation" do
    test "blank and non-string paths raise" do
      assert_raise ArgumentError, ~r/non-blank string/, fn ->
        AshAgentTools.resolve("   ")
      end

      assert_raise ArgumentError, ~r/must be a string/, fn ->
        AshAgentTools.resolve(:post)
      end
    end
  end

  describe "search/2 max_results ladder" do
    test "an over-limit search refuses with per-resource counts" do
      error =
        assert_raise ArgumentError, ~r/too many results for "t"/, fn ->
          AshAgentTools.semantic_search("t", max_results: 1)
        end

      assert Exception.message(error) =~ "Counts:"
      assert Exception.message(error) =~ "Refine the term or raise :max_results"
    end

    test "max_results accepts a generous limit" do
      results = AshAgentTools.semantic_search("t", max_results: 1000)
      assert length(results) > 1
    end

    test "invalid max_results raises" do
      assert_raise ArgumentError, ~r/:max_results must be a positive integer/, fn ->
        AshAgentTools.semantic_search("t", max_results: 0)
      end
    end
  end

  describe "context/3 max_list ladder" do
    @probe "test/support/context_probe.ex"

    test "lists above :max_list are capped with shown/total markers" do
      manifest = manifest_fixture(5)

      try do
        {:ok, report} = AshAgentTools.context(@probe, 1, manifests: [manifest], max_list: 2)

        assert Map.has_key?(report.manifests, :truncated?)
        assert length(report.manifests.symbols) == 2
        assert report.manifests[:symbols_truncated?] == %{shown: 2, total: 5}

        # under the cap, no markers at all
        {:ok, report} = AshAgentTools.context(@probe, 1, manifests: [manifest], max_list: 25)
        refute Map.has_key?(report.manifests, :truncated?)
        refute Map.has_key?(report.manifests, :symbols_truncated?)
      after
        File.rm(manifest)
      end
    end

    test "invalid :max_list raises" do
      assert_raise ArgumentError, ~r/:max_list must be a positive integer/, fn ->
        AshAgentTools.context(@probe, 1, max_list: 0)
      end
    end

    defp manifest_fixture(symbol_count) do
      path =
        Path.join(
          System.tmp_dir!(),
          "ash_agent_tools_ladder_#{System.unique_integer([:positive])}.json"
        )

      symbols =
        for i <- 1..symbol_count do
          %{
            "id" => "ash:v0:AshAgentTools.Test.ContextProbe#attributes/sym#{i}",
            "kind" => "attribute",
            "name" => "sym#{i}"
          }
        end

      contents =
        Jason.encode!(%{
          "manifest_version" => "0",
          "module" => "AshAgentTools.Test.ContextProbe",
          "module_kind" => "resource",
          "symbols" => symbols,
          "relations" => []
        })

      File.write!(path, contents)
      path
    end
  end
end
