# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.DomainMapRenderTest do
  use ExUnit.Case, async: true

  alias AshAgentTools.DomainMap

  # The golden fixture renders against the package's own test support registry
  # (AshAgentTools.Test.Domain: Post, Author, Comment, User, Machine, ...), so
  # the assertions below cover every renderer without a host application.
  defp fixture do
    %{
      "planes" => [%{"id" => "content", "name" => "Content", "purpose" => "The corpus plane."}],
      "contexts" => [
        %{
          "id" => "posts",
          "name" => "Posts",
          "domain" => "AshAgentTools.Test.Domain",
          "plane" => "content",
          "mission" => "Owns the test corpus.",
          "packages" => ["ash_agent_tools"],
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
      # "Probe" hides the ContextProbe/Probed resources behind the omission note.
      "vendor_tokens" => ["Probe"]
    }
  end

  defp regions do
    fixture()
    |> DomainMap.build_model([AshAgentTools.Test.Domain])
    |> DomainMap.regions()
  end

  test "the graph region renders a fenced mermaid diagram" do
    graph = regions()["graph"]

    assert graph =~ "```mermaid"
    assert graph =~ "flowchart LR"
    assert graph =~ "ctx_posts["
    assert graph =~ "subgraph content["
  end

  test "the contexts catalogue links every context to its heading" do
    assert regions()["contexts"] =~
             "| [Posts](#posts) | Content | `AshAgentTools.Test.Domain` | Owns the test corpus. |"
  end

  test "vendor-named resource rows are omitted with the count note" do
    section = regions()["context:posts"]

    refute section =~ "ContextProbe"
    refute section =~ "Probed"
    assert section =~ "*2 provider-named resources omitted from this table.*"
    assert section =~ "`AshAgentTools.Test.Post`"
  end

  test "the substrate row renders the locked kind and context links" do
    assert regions()["substrates"] =~ "| `ash` | first-party | hex"
  end

  test "the adopted table renders package and role" do
    assert regions()["adopted"] == "| Package | Role |\n|---|---|\n| `jason` | JSON encoding. |"
  end

  test "a registry without declared signals renders the quiet note" do
    assert regions()["signals"] =~ "No declared signals cross the registered domains"
  end

  test "a registry with a real signal graph renders rows and counterparts" do
    fixture =
      put_in(fixture()["contexts"], [
        %{
          "id" => "sources",
          "name" => "Sources",
          "domain" => "AshAgentTools.Test.SignalDomain",
          "plane" => "content",
          "mission" => "Emits the test signal.",
          "packages" => [],
          "adrs" => [],
          "terms" => [
            %{"term" => "Source", "definition" => "The emitter."},
            %{"term" => "Sink", "definition" => "The listener."},
            %{"term" => "Signal", "definition" => "The declared fact."}
          ],
          "edges" => []
        }
      ])

    regions =
      fixture
      |> DomainMap.build_model([AshAgentTools.Test.SignalDomain])
      |> DomainMap.regions()

    # Without the record-shape fix this raised: the counterpart extraction
    # handed whole listener/emit records to `Ash.Resource.Info.domain/1`.
    assert regions["context:sources"] =~
             "| emits | `AshAgentTools.Test.Signals.thing_happened` | sources |"

    assert regions["context:sources"] =~
             "| listens | `AshAgentTools.Test.Signals.thing_happened` | sources |"
  end

  test "rewrite pads every generated region with blank lines" do
    regions = regions()

    path = Path.join(System.tmp_dir!(), "domain_map_rewrite_#{System.unique_integer()}.md")

    File.write!(path, """
    # Domain map

    <!-- domain-map:graph:start -->
    <!-- domain-map:graph:end -->
    """)

    on_exit(fn -> File.rm(path) end)

    {:changed, rendered} = DomainMap.rewrite(path, regions)

    assert rendered =~ "<!-- domain-map:graph:start -->\n\n```mermaid"
    assert rendered =~ "\n\n<!-- domain-map:graph:end -->"

    # Idempotent: a second rewrite of the padded file is unchanged.
    File.write!(path, rendered)
    assert {:unchanged, _} = DomainMap.rewrite(path, regions)
  end
end
