# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.DomainMapTest do
  use ExUnit.Case, async: true

  alias AshAgentTools.DomainMap

  # A minimal, valid document over the package's own test support registry.
  # Substrates and adopted entries use real lock entries ("ash" is hex,
  # "jason" is hex) so validation exercises the lock lookups.
  defp base_data do
    %{
      "planes" => [%{"id" => "content", "name" => "Content", "purpose" => "The corpus plane."}],
      "contexts" => [
        %{
          "id" => "posts",
          "name" => "Posts",
          "domain" => "AshAgentTools.Test.Domain",
          "plane" => "content",
          "mission" => "Owns the test corpus.",
          "packages" => [],
          "adrs" => [],
          "terms" => [
            %{"term" => "Post", "definition" => "A written entry."},
            %{"term" => "Author", "definition" => "Who writes posts."},
            %{"term" => "Comment", "definition" => "Reader notes on a post."}
          ],
          "edges" => []
        }
      ],
      "substrates" => [
        %{
          "package" => "ash",
          "repo" => "hex",
          "kind" => "first-party",
          "context" => "posts",
          "role" => "The framework."
        }
      ],
      "adopted" => [%{"package" => "jason", "role" => "JSON encoding."}],
      "first_party_orgs" => [],
      "vendor_tokens" => ["Probe"]
    }
  end

  test "a valid document passes" do
    assert DomainMap.validate!(base_data()) == :ok
  end

  test "an unknown top-level key is rejected" do
    data = Map.put(base_data(), "bogus", true)

    assert_raise Mix.Error, ~r/Unknown key\(s\) "bogus" at top level/, fn ->
      DomainMap.validate!(data)
    end
  end

  test "an unknown context key is rejected" do
    data = put_in(base_data(), ["contexts", Access.at(0), "owner"], "someone")

    assert_raise Mix.Error, ~r/Unknown key\(s\) "owner" at context/, fn ->
      DomainMap.validate!(data)
    end
  end

  test "an edge to an undefined context is rejected" do
    edge = %{"to" => "nowhere", "pattern" => "publishes", "note" => "drafts flow out"}
    data = put_in(base_data(), ["contexts", Access.at(0), "edges"], [edge])

    assert_raise Mix.Error, ~r/points at context "nowhere", which is not defined/, fn ->
      DomainMap.validate!(data)
    end
  end

  test "a substrate that is not in the lock is rejected" do
    substrate = %{
      "package" => "definitely_not_a_real_package",
      "repo" => "hex",
      "kind" => "transitive",
      "context" => "posts",
      "role" => "Imaginary."
    }

    data = Map.put(base_data(), "substrates", [substrate])

    assert_raise Mix.Error, ~r/is not in mix\.lock/, fn ->
      DomainMap.validate!(data)
    end
  end

  test "an in-repo substrate without a path is rejected" do
    substrate = %{
      "package" => "battery",
      "repo" => "in-repo",
      "kind" => "in-repo",
      "context" => "posts",
      "role" => "The battery."
    }

    data = Map.put(base_data(), "substrates", [substrate])

    assert_raise Mix.Error, ~r/needs a non-empty "path"/, fn ->
      DomainMap.validate!(data)
    end
  end

  test "an in-repo substrate whose path does not exist is rejected" do
    substrate = %{
      "package" => "battery",
      "repo" => "in-repo",
      "kind" => "in-repo",
      "path" => "no/such/dir/here",
      "context" => "posts",
      "role" => "The battery."
    }

    data = Map.put(base_data(), "substrates", [substrate])

    assert_raise Mix.Error, ~r/but that directory does not exist/, fn ->
      DomainMap.validate!(data)
    end
  end

  test "fewer than three terms is rejected outside draft mode" do
    data =
      put_in(base_data(), ["contexts", Access.at(0), "terms"], [
        %{"term" => "Post", "definition" => "A written entry."}
      ])

    assert_raise Mix.Error, ~r/has 1 terms/, fn ->
      DomainMap.validate!(data)
    end
  end

  test "a missing mission is rejected outside draft mode" do
    data = put_in(base_data(), ["contexts", Access.at(0), "mission"], "")

    assert_raise Mix.Error, ~r/needs a mission/, fn ->
      DomainMap.validate!(data)
    end
  end

  test "draft mode holds validation to referential integrity" do
    data =
      base_data()
      |> put_in(["contexts", Access.at(0), "mission"], "")
      |> put_in(["contexts", Access.at(0), "terms"], [])
      |> Map.put("draft", true)

    assert DomainMap.validate!(data) == :ok
  end

  test "duplicate context ids are rejected" do
    data =
      update_in(base_data(), ["contexts"], fn contexts -> contexts ++ contexts end)

    assert_raise Mix.Error, ~r/Duplicate context id: "posts"/, fn ->
      DomainMap.validate!(data)
    end
  end

  test "a non-list first_party_orgs is rejected" do
    data = Map.put(base_data(), "first_party_orgs", "lukegalea")

    assert_raise Mix.Error, ~r/"first_party_orgs" must be a list of non-empty strings/, fn ->
      DomainMap.validate!(data)
    end
  end

  test "a non-boolean draft is rejected" do
    data = Map.put(base_data(), "draft", "yes")

    assert_raise Mix.Error, ~r/"draft" must be true or false/, fn ->
      DomainMap.validate!(data)
    end
  end

  # Completeness is the build step's rule, not validation's: it needs the
  # registry and the lock. This repo's lock carries git entries under
  # github.com/lukegalea, so claiming that org with nothing claiming the
  # packages must fail.
  test "an unclaimed first-party org fails the lock-completeness check" do
    data = Map.put(base_data(), "first_party_orgs", ["lukegalea"])

    assert_raise Mix.Error, ~r/claimed by no substrate or context package/, fn ->
      DomainMap.build_model(data, [AshAgentTools.Test.Domain])
    end
  end

  test "every registered domain must have a context" do
    data =
      update_in(base_data(), ["contexts"], fn [ctx | rest] ->
        [Map.put(ctx, "domain", nil) | rest]
      end)

    assert_raise Mix.Error, ~r/have no context in the domain map/, fn ->
      DomainMap.build_model(data, [AshAgentTools.Test.Domain])
    end
  end

  # -- target integrity ------------------------------------------------------

  defp with_target(contents) do
    path = Path.join(System.tmp_dir!(), "domain_map_target_#{System.unique_integer()}.md")
    File.write!(path, contents)

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp model do
    DomainMap.build_model(base_data(), [AshAgentTools.Test.Domain])
  end

  test "a region naming no renderer is an error" do
    target =
      with_target("""
      # Domain map

      <!-- domain-map:widgets:start -->

      <!-- domain-map:widgets:end -->
      """)

    assert_raise Mix.Error, ~r/there is no renderer by that name/, fn ->
      DomainMap.ensure_target_regions!(target, DomainMap.regions(model()))
    end
  end

  test "a context without its region is an error" do
    target =
      with_target("""
      # Domain map

      <!-- domain-map:graph:start -->

      <!-- domain-map:graph:end -->
      """)

    assert_raise Mix.Error, ~r/is missing the region for these contexts: posts/, fn ->
      DomainMap.ensure_target_regions!(target, DomainMap.regions(model()))
    end
  end
end
