# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentToolsTest do
  use ExUnit.Case, async: true

  doctest AshAgentTools
  doctest AshAgentTools.Search
  doctest AshAgentTools.Types

  alias AshAgentTools.Test.{Author, Comment, Domain, Guarded, Post}

  describe "discovery" do
    test "list_domains/0 finds the test domain" do
      assert Domain in AshAgentTools.list_domains()
    end

    test "list_resources/0 finds the test resources" do
      resources = AshAgentTools.list_resources()

      for resource <- [Post, Author, Comment, Guarded] do
        assert resource in resources
      end
    end

    test "discovery never raises and returns sorted modules" do
      assert AshAgentTools.list_domains() == Enum.sort(AshAgentTools.list_domains())
      assert AshAgentTools.list_resources() == Enum.sort(AshAgentTools.list_resources())
    end
  end

  describe "describe_resource/1" do
    test "describes fields with types, constraints, and nullability" do
      fields =
        Post
        |> AshAgentTools.describe_resource()
        |> Map.fetch!(:fields)
        |> Map.new(&{&1.name, &1})

      title = Map.fetch!(fields, :title)
      assert title.type == "string"
      assert title.allow_nil? == false
      assert title.public? == true

      status = Map.fetch!(fields, :status)
      assert status.type == "atom"
      assert status.constraints.one_of == ["draft", "published", "archived"]
      assert status.default == "draft"

      tags = Map.fetch!(fields, :tags)
      assert tags.type == "array<string>"

      id = Map.fetch!(fields, :id)
      assert id.primary_key? == true
    end

    test "describes relationships" do
      relationships =
        Post
        |> AshAgentTools.describe_resource()
        |> Map.fetch!(:relationships)
        |> Map.new(&{&1.name, &1})

      author = Map.fetch!(relationships, :author)
      assert author.type == :belongs_to
      assert author.destination == Author

      comments = Map.fetch!(relationships, :comments)
      assert comments.type == :has_many
      assert comments.destination == Comment
      assert comments.destination_attribute == :post_id
    end

    test "describes actions with names, types, accept lists, and argument types" do
      actions =
        Post
        |> AshAgentTools.describe_resource()
        |> Map.fetch!(:actions)
        |> Map.new(&{&1.name, &1})

      create = Map.fetch!(actions, :create)
      assert create.type == :create
      assert create.accept == [:title, :body, :status, :tags, :score]

      by_tag = Map.fetch!(actions, :by_tag)
      assert [%{name: :tag, type: "string", required?: true}] = by_tag.arguments
    end

    test "includes source locations from Spark annotations" do
      fields =
        Post
        |> AshAgentTools.describe_resource()
        |> Map.fetch!(:fields)

      title = Enum.find(fields, &(&1.name == :title))
      assert title.source
      assert title.source.file =~ "post.ex"
      assert is_integer(title.source.line)
      assert title.source.line > 0
    end

    test "reports domain, primary key, and data layer" do
      description = AshAgentTools.describe_resource(Post)

      assert description.domain == Domain
      assert description.primary_key == [:id]
      assert description.data_layer =~ "Simple"
    end

    test "raises on non-resources" do
      assert_raise ArgumentError, ~r/not a loaded Ash resource/, fn ->
        AshAgentTools.describe_resource(String)
      end
    end
  end

  describe "describe_action/2" do
    test "splits the create input contract into required and optional" do
      input = AshAgentTools.describe_action(Post, :create) |> Map.fetch!(:input)

      assert input.required == [:title]

      optional_names = Enum.map(input.optional, & &1.name)

      for name <- [:body, :status, :tags, :score] do
        assert name in optional_names
      end

      score = Enum.find(input.optional, &(&1.name == :score))
      assert score.type == "integer"
    end

    test "treats accepted attributes as optional on update actions" do
      # :publish accepts nothing; :create is the attribute-heavy case above.
      publish = AshAgentTools.describe_action(Post, :publish)
      assert publish.type == :update
      assert publish.input.required == []
      assert publish.accept == []
    end

    test "reports required action arguments" do
      by_tag = AshAgentTools.describe_action(Post, :by_tag)

      assert by_tag.input.required == [:tag]
      assert [%{name: :tag, required?: true}] = by_tag.arguments
    end

    test "reports return shapes" do
      assert %{kind: :record, type: Post} = AshAgentTools.describe_action(Post, :create).returns
      assert %{kind: :list, type: Post} = AshAgentTools.describe_action(Post, :read).returns

      assert %{kind: :value, type: "string"} =
               AshAgentTools.describe_action(Post, :feature).returns
    end

    test "reports code interfaces, resource-level and domain-level" do
      interfaces = AshAgentTools.describe_action(Post, :feature) |> Map.fetch!(:code_interfaces)

      assert interfaces != []

      assert Enum.any?(interfaces, fn interface ->
               interface.name == :feature and interface.domain == Domain and
                 interface.args == [:level]
             end)
    end

    test "includes a source location for the action" do
      source = AshAgentTools.describe_action(Post, :create) |> Map.fetch!(:source)
      assert source
      assert source.file =~ "post.ex"
    end

    test "raises on unknown actions" do
      assert_raise ArgumentError, ~r/no action named/, fn ->
        AshAgentTools.describe_action(Post, :nonexistent)
      end
    end

    test "accepts binary action names" do
      assert %{name: :publish} = AshAgentTools.describe_action(Post, "publish")
    end
  end

  describe "validate_input/3" do
    test "casts and normalizes valid input without running anything" do
      report =
        AshAgentTools.validate_input(Post, :create, %{
          "title" => "Hello",
          "score" => "7",
          "status" => "published",
          "tags" => ["a", "b"]
        })

      assert report.valid? == true
      assert report.errors == []
      assert report.normalized_inputs["title"] == "Hello"
      assert report.normalized_inputs["score"] == 7
      assert report.normalized_inputs["status"] == "published"
      assert report.normalized_inputs["tags"] == ["a", "b"]
    end

    test "reports invalid values with a path and the DSL source" do
      report =
        AshAgentTools.validate_input(Post, :create, %{"title" => "ok", "score" => "not a number"})

      assert report.valid? == false
      assert Enum.any?(report.errors, &(&1.path == "score"))

      score_error = Enum.find(report.errors, &(&1.path == "score"))
      assert score_error.message =~ "invalid"
    end

    test "reports missing required inputs" do
      report = AshAgentTools.validate_input(Post, :create, %{})

      assert report.valid? == false
      assert Enum.any?(report.errors, &(&1.path == "title" and &1.message == "is required"))
    end

    test "reports unknown inputs exactly once, with Ash's hint folded in" do
      report = AshAgentTools.validate_input(Post, :create, %{"title" => "ok", "wat" => 1})

      assert report.valid? == false
      assert Enum.count(report.errors) == 1

      [error] = report.errors
      assert error.path == "wat"
      assert error.message =~ "unknown input"
      # Ash's build-stage NoSuchInput hint (valid inputs list / suggestions)
      # is appended to our structured entry instead of duplicating it.
      assert error.message =~ "Valid Inputs"
    end

    test "unknown input on an argument-taking action surfaces Ash's suggestion" do
      report = AshAgentTools.validate_input(Post, :by_tag, %{"tag" => "elixir", "wat" => 1})

      assert report.valid? == false
      wat_errors = Enum.filter(report.errors, &(&1.path == "wat"))
      assert length(wat_errors) == 1
      assert Enum.any?(report.errors, &(&1.message =~ "Perhaps you meant to add an argument"))
      # the raw NoSuchInput duplicate is gone
      refute Enum.any?(report.errors, &(&1.message =~ ~r/^no such input/i))
    end

    test "enforces atom constraints" do
      report =
        AshAgentTools.validate_input(Post, :create, %{"title" => "ok", "status" => "bogus"})

      assert report.valid? == false
      assert Enum.any?(report.errors, &(&1.path == "status"))
    end

    test "validates action arguments too" do
      report = AshAgentTools.validate_input(Post, :by_tag, %{"tag" => "elixir"})
      assert report.valid? == true
      assert report.normalized_inputs["tag"] == "elixir"

      missing = AshAgentTools.validate_input(Post, :by_tag, %{})
      assert missing.valid? == false
      assert Enum.any?(missing.errors, &(&1.path == "tag"))

      wrong = AshAgentTools.validate_input(Post, :feature, %{"level" => "high"})
      assert wrong.valid? == false
    end

    test "generic actions use action inputs, and defaults fill in" do
      report = AshAgentTools.validate_input(Post, :feature, %{})

      assert report.valid? == true
      assert report.normalized_inputs == %{}
    end

    test "mirrors the input contract as `expected`" do
      report = AshAgentTools.validate_input(Post, :create, %{"title" => "ok"})

      assert report.expected.required == [:title]
    end

    test "raises on unknown actions" do
      assert_raise ArgumentError, ~r/no action named/, fn ->
        AshAgentTools.validate_input(Post, :nonexistent, %{})
      end
    end

    test "the whole report is JSON-encodable" do
      report =
        AshAgentTools.validate_input(Post, :create, %{
          "score" => "bad",
          "wat" => 1,
          "tags" => ["x"]
        })

      encoded = Jason.encode!(report)
      assert is_binary(encoded)
    end
  end

  describe "explain_forbidden/2" do
    test "lists policies with bypass flags, conditions, and checks" do
      report = AshAgentTools.explain_forbidden(Guarded, :read)

      assert length(report.policies) == 2

      bypass = Enum.find(report.policies, & &1.bypass?)
      assert bypass
      assert bypass.condition == ["actor.admin == true"]
      assert bypass.checks == ["always true"]

      read_policy = Enum.find(report.policies, &(!&1.bypass?))
      assert "action.type == :read" in read_policy.condition
      assert "actor is present" in read_policy.checks
      assert Enum.any?(read_policy.checks, &(&1 =~ "public"))
    end

    test "lists field policies" do
      report = AshAgentTools.explain_forbidden(Guarded)

      # The explicit :name field policy, plus the catch-all the verifier
      # expands to cover every public field.
      assert Enum.any?(report.field_policies, &(&1.fields == [:name]))
      assert Enum.all?(report.field_policies, &(&1.checks != []))
    end

    test "attaches guidance for policy-protected resources" do
      report = AshAgentTools.explain_forbidden(Guarded, :read)

      assert report.guidance != []
      assert Enum.any?(report.guidance, &(&1 =~ "deny-by-default"))
    end

    test "explains when the authorizer is absent" do
      report = AshAgentTools.explain_forbidden(Post, :create)

      assert report.policies == []
      assert report.field_policies == []
      assert Enum.any?(report.guidance, &(&1 =~ "does not use Ash.Policy.Authorizer"))
    end

    test "is JSON-encodable" do
      assert is_binary(Jason.encode!(AshAgentTools.explain_forbidden(Guarded, :read)))
    end
  end

  describe "semantic_search/2" do
    test "finds attributes, actions, calculations, and relationships by substring" do
      results = AshAgentTools.semantic_search("tag")

      kinds =
        results
        |> Enum.map(&{&1.resource, &1.kind, &1.name})
        |> MapSet.new()

      assert MapSet.member?(kinds, {Post, :attribute, :tags})
      assert MapSet.member?(kinds, {Post, :action, :by_tag})

      refute Enum.any?(results, &(&1.resource != Post))
    end

    test "matches are case-insensitive" do
      assert [%{name: :tags}] = AshAgentTools.semantic_search("TAG", kinds: [:attribute])
    end

    test "hits carry resource, kind, name, type, and source" do
      hit = Enum.find(AshAgentTools.semantic_search("tag"), &(&1.kind == :attribute))

      assert hit.resource == Post
      assert hit.name == :tags
      assert hit.type == "array<string>"
      assert hit.source
      assert hit.source.file =~ "post.ex"
      assert is_integer(hit.source.line)
    end

    test "action hits carry the action type" do
      hit = Enum.find(AshAgentTools.semantic_search("by_tag"), &(&1.kind == :action))
      assert hit.type == :read
    end

    test "finds calculations" do
      hits = Enum.filter(AshAgentTools.semantic_search("length"), &(&1.kind == :calculation))

      assert [%{resource: resource, name: :title_length, type: "integer"}] = hits
      assert resource == Post
    end

    test "finds relationships" do
      hits = AshAgentTools.semantic_search("author", kinds: :relationship)

      assert [%{resource: resource, name: :author, type: :belongs_to}] = hits
      assert resource == Post
    end

    test "kind filter accepts a single kind or a list" do
      single = AshAgentTools.semantic_search("tag", kinds: :attribute)
      assert Enum.all?(single, &(&1.kind == :attribute))

      multiple = AshAgentTools.semantic_search("tag", kinds: [:attribute, :action])
      assert Enum.map(multiple, & &1.kind) |> Enum.uniq() |> Enum.sort() == [:action, :attribute]
    end

    test "raises on unknown kinds" do
      assert_raise ArgumentError, ~r/unknown symbol kind/, fn ->
        AshAgentTools.semantic_search("tag", kinds: [:atribute])
      end
    end

    test "raises on blank or non-binary terms" do
      assert_raise ArgumentError, ~r/non-blank string/, fn ->
        AshAgentTools.semantic_search("   ")
      end

      assert_raise ArgumentError, ~r/must be a string/, fn ->
        AshAgentTools.semantic_search(:tag)
      end
    end

    test "results are sorted by resource, kind, name" do
      results = AshAgentTools.semantic_search("t")

      sorted =
        Enum.sort_by(
          results,
          &{AshAgentTools.Registry.module_name(&1.resource), &1.kind, &1.name}
        )

      assert results == sorted
    end

    test "no match is an empty list; results are JSON-encodable" do
      assert [] = AshAgentTools.semantic_search("no-such-symbol-xyz")
      assert is_binary(Jason.encode!(AshAgentTools.semantic_search("t")))
    end
  end

  describe "diff_manifest/2" do
    @v1 "test/fixtures/manifest_v1.json"
    @v2 "test/fixtures/manifest_v2.json"

    test "summarizes add/remove/change by stable symbol id" do
      report = AshAgentTools.diff_manifest(@v1, @v2)

      assert report.summary == %{added: 1, removed: 1, changed: 1, unchanged: 2}
      assert report.old_file == @v1
      assert report.new_file == @v2
    end

    test "reports added and removed symbols" do
      report = AshAgentTools.diff_manifest(@v1, @v2)

      assert Enum.map(report.added, & &1.id) == ["ash:v0:Example.Post#actions/publish"]
      assert Enum.map(report.removed, & &1.id) == ["ash:v0:Example.Post#attributes/score"]

      publish = hd(report.added)
      assert publish.kind == "action"
      assert publish.name == "publish"

      score = hd(report.removed)
      assert score.kind == "attribute"
      assert score.name == "score"
    end

    test "reports content changes, ignoring hashes and spans" do
      report = AshAgentTools.diff_manifest(@v1, @v2)

      assert [%{} = title] = report.changed
      assert title.id == "ash:v0:Example.Post#attributes/title"
      assert title.kind == "attribute"

      assert Enum.map(title.changed_fields, & &1.field) == ["constraints"]

      constraints_change = hd(title.changed_fields)
      assert constraints_change.old == nil
      assert constraints_change.new == %{"max_length" => 160}
    end

    test "a span-only move (and fresh hashes) do not count as changes" do
      # Both fixtures' `resource` symbols have different spans between v1 and
      # v2 (the declaration moved down the file); per RFC §4.4 the span is
      # excluded from content, so the symbol is unchanged.
      report = AshAgentTools.diff_manifest(@v2, @v1)

      refute Enum.any?(report.changed, &(&1.id == "ash:v0:Example.Post#resource"))
      assert report.summary.changed == 1
    end

    test "the diff is its own inverse for add/remove" do
      forward = AshAgentTools.diff_manifest(@v1, @v2)
      reverse = AshAgentTools.diff_manifest(@v2, @v1)

      assert Enum.map(forward.added, & &1.id) == Enum.map(reverse.removed, & &1.id)
      assert Enum.map(forward.removed, & &1.id) == Enum.map(reverse.added, & &1.id)
      assert Enum.map(forward.changed, & &1.id) == Enum.map(reverse.changed, & &1.id)
    end

    test "the report is JSON-encodable" do
      assert is_binary(Jason.encode!(AshAgentTools.diff_manifest(@v1, @v2)))
    end

    test "raises on unreadable files" do
      assert_raise ArgumentError, ~r/cannot read semantic manifest/, fn ->
        AshAgentTools.diff_manifest(@v1, "test/fixtures/does-not-exist.json")
      end
    end

    test "raises on invalid JSON" do
      path = tmp_file!("{not json")

      try do
        assert_raise ArgumentError, ~r/not valid JSON/, fn ->
          AshAgentTools.diff_manifest(@v1, path)
        end
      after
        File.rm(path)
      end
    end

    test "raises on documents without a symbols array" do
      path = tmp_file!(Jason.encode!(%{"manifest_version" => "0"}))

      try do
        assert_raise ArgumentError, ~r/no "symbols" array/, fn ->
          AshAgentTools.diff_manifest(@v1, path)
        end
      after
        File.rm(path)
      end
    end

    test "raises on symbols without a string id" do
      path = tmp_file!(Jason.encode!(%{"symbols" => [%{"kind" => "resource"}]}))

      try do
        assert_raise ArgumentError, ~r/without a string "id"/, fn ->
          AshAgentTools.diff_manifest(@v1, path)
        end
      after
        File.rm(path)
      end
    end

    test "raises on duplicate symbol ids" do
      symbol = %{"id" => "ash:v0:Example.Post#resource", "kind" => "resource", "name" => "Post"}
      path = tmp_file!(Jason.encode!(%{"symbols" => [symbol, symbol]}))

      try do
        assert_raise ArgumentError, ~r/duplicate symbol id/, fn ->
          AshAgentTools.diff_manifest(@v1, path)
        end
      after
        File.rm(path)
      end
    end

    defp tmp_file!(contents) do
      path =
        Path.join(
          System.tmp_dir!(),
          "ash_agent_tools_test_#{System.unique_integer([:positive])}.json"
        )

      File.write!(path, contents)
      path
    end
  end

  describe "JSON-encodability of the whole API" do
    test "describe_resource round-trips through Jason" do
      for resource <- [Post, Author, Comment, Guarded] do
        assert is_binary(Jason.encode!(AshAgentTools.describe_resource(resource)))
      end
    end

    test "describe_action round-trips through Jason" do
      for {resource, action} <- [{Post, :create}, {Post, :by_tag}, {Post, :feature}] do
        assert is_binary(Jason.encode!(AshAgentTools.describe_action(resource, action)))
      end
    end
  end
end
