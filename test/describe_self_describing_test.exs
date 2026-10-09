# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.DescribeSelfDescribingTest do
  @moduledoc """
  Pins the self-describing describe output (audit finding #2): a fresh agent
  reading `.accepts` got `null` (the key is `accept`), concluded the tool was
  broken, and fell back to reading source. The output now answers its own
  readers — alias keys for guessed spellings, a legend for non-obvious keys,
  full detail for every input, and provenance for extension-injected fields.
  """

  use ExUnit.Case, async: true

  alias AshAgentTools.Test.Injected
  alias AshAgentTools.Test.Post

  describe "accepts — the additive alias of accept" do
    test "describe_resource action entries carry accepts alongside accept" do
      actions =
        Post
        |> AshAgentTools.describe_resource()
        |> Map.fetch!(:actions)
        |> Map.new(&{&1.name, &1})

      create = Map.fetch!(actions, :create)

      assert create.accept == [:title, :body, :status, :tags, :score]
      assert create.accepts == create.accept

      # The audit trigger: `publish` accepts *nothing* — an agent reading
      # `.accepts` must see that truth, not a jq `// []`-masked null.
      publish = Map.fetch!(actions, :publish)
      assert publish.accept == []
      assert publish.accepts == []
    end

    test "describe_action carries accepts alongside accept" do
      create = AshAgentTools.describe_action(Post, :create)

      assert create.accept == [:title, :body, :status, :tags, :score]
      assert create.accepts == create.accept

      publish = AshAgentTools.describe_action(Post, :publish)
      assert publish.accepts == []
    end
  end

  describe "input detail — no required input is a bare name" do
    test "action arguments carry constraints, allow_nil?, and defaults" do
      report = AshAgentTools.describe_action(Post, :rate)

      arguments = Map.new(report.arguments, &{&1.name, &1})

      verdict = Map.fetch!(arguments, :verdict)
      assert verdict.constraints.one_of == ["hot", "not"]
      assert verdict.allow_nil? == false
      assert verdict.default == nil
      assert verdict.required? == true

      stars = Map.fetch!(arguments, :stars)
      assert stars.constraints == %{max: 5, min: 1}
      assert stars.default == 3
      assert stars.required? == false

      # The same full entries live in the input contract, not just the
      # top-level argument list.
      input_arguments = Map.new(report.input.arguments, &{&1.name, &1})
      assert Map.fetch!(input_arguments, :verdict).constraints.one_of == ["hot", "not"]
    end

    test "accepted attributes appear in input.attributes with full detail" do
      input = AshAgentTools.describe_action(Post, :create) |> Map.fetch!(:input)

      attributes = Map.new(input.attributes, &{&1.name, &1})

      # Every accepted attribute is detailed — including `title`, which the
      # required list only names.
      assert MapSet.new(Map.keys(attributes)) ==
               MapSet.new([:title, :body, :status, :tags, :score])

      title = Map.fetch!(attributes, :title)
      assert title.type == "string"
      assert title.allow_nil? == false
      assert title.default == nil

      status = Map.fetch!(attributes, :status)
      assert status.type == "atom"
      assert status.constraints.one_of == ["draft", "published", "archived"]
      assert status.default == "draft"

      tags = Map.fetch!(attributes, :tags)
      assert tags.type == "array<string>"
      assert tags.default == []
    end

    test "every required name resolves to a detailed entry" do
      input = AshAgentTools.describe_action(Post, :create) |> Map.fetch!(:input)

      detailed_names =
        MapSet.new(Enum.map(input.arguments ++ input.attributes, & &1.name))

      for name <- input.required do
        assert name in detailed_names,
               "required input #{inspect(name)} has no detailed entry in input.arguments/input.attributes"
      end
    end
  end

  describe "~legend — the output explains its own keys" do
    test "describe_resource carries a legend for the non-obvious keys" do
      legend = AshAgentTools.describe_resource(Post) |> Map.fetch!(:"~legend")

      for key <- ["accept", "accepts", "constraints", "source", "~extension"] do
        assert Map.has_key?(legend, key), "legend missing key #{inspect(key)}"
      end

      # One line each: a legend that wraps is a legend nobody reads.
      for {key, value} <- legend do
        assert is_binary(value) and value != "" and not String.contains?(value, "\n"),
               "legend entry #{inspect(key)} is not a single line"
      end
    end

    test "describe_action carries the same legend plus the input contract keys" do
      legend = AshAgentTools.describe_action(Post, :create) |> Map.fetch!(:"~legend")

      assert legend["accepts"] =~ "alias"
      assert Map.has_key?(legend, "input.required")

      assert AshAgentTools.describe_resource(Post)
             |> Map.fetch!(:"~legend")
             |> Map.has_key?("extensions")
    end

    test "the whole report stays JSON-encodable" do
      for report <- [
            AshAgentTools.describe_resource(Post),
            AshAgentTools.describe_action(Post, :rate),
            AshAgentTools.describe_resource(Injected)
          ] do
        assert report |> Jason.encode!() |> Jason.decode!()
      end
    end
  end

  describe "~extension — injected fields carry provenance" do
    test "describe_resource lists the extensions in use" do
      extensions = AshAgentTools.describe_resource(Injected) |> Map.fetch!(:extensions)

      assert "AshAgentTools.Test.Injected.Extension" in extensions
    end

    test "transformer-injected fields are marked and have no source" do
      fields =
        Injected
        |> AshAgentTools.describe_resource()
        |> Map.fetch!(:fields)
        |> Map.new(&{&1.name, &1})

      injected = Map.fetch!(fields, :injected_flag)
      assert injected.source == nil
      assert injected[:"~extension"] == true

      declared = Map.fetch!(fields, :declared_title)
      assert declared.source
      assert declared.source.file =~ "injected.ex"
      refute declared[:"~extension"]
    end

    test "in-file fields are unmarked (no false positives)" do
      fields =
        Post
        |> AshAgentTools.describe_resource()
        |> Map.fetch!(:fields)
        |> Map.new(&{&1.name, &1})

      # `author_id` is generated by the `belongs_to :author` line — no
      # source annotation, but the provenance is the resource's own DSL,
      # not an extension. Marking it would erode trust in the marker.
      refute fields[:author_id][:"~extension"]

      for {name, field} <- fields do
        refute field[:"~extension"],
               "#{inspect(name)} is declared in post.ex but marked ~extension"
      end
    end

    test "input.attributes carries the same provenance marker" do
      attributes =
        Injected
        |> AshAgentTools.describe_action(:create)
        |> Map.fetch!(:input)
        |> Map.fetch!(:attributes)
        |> Map.new(&{&1.name, &1})

      refute Map.fetch!(attributes, :declared_title)[:"~extension"]
    end
  end

  describe "daemon parity — the serve path serves the same output builder" do
    test "Daemon.Runtime.describe returns the same self-describing shape" do
      name = Module.concat([__MODULE__, "Runtime", "n#{System.unique_integer([:positive])}"])
      server = start_supervised!({AshAgentTools.Daemon.Runtime, name: name, boot?: false})

      assert {:ok, resource_report} = AshAgentTools.Daemon.Runtime.describe(server, Injected)
      assert Map.has_key?(resource_report, :"~legend")
      assert "AshAgentTools.Test.Injected.Extension" in resource_report.extensions

      fields = Map.new(resource_report.fields, &{&1.name, &1})
      assert Map.fetch!(fields, :injected_flag)[:"~extension"] == true

      assert {:ok, action_report} =
               AshAgentTools.Daemon.Runtime.describe(server, Injected, :create)

      assert action_report.accepts == action_report.accept
      assert Map.has_key?(action_report, :"~legend")
      assert Map.has_key?(action_report.input, :attributes)
    end
  end
end
