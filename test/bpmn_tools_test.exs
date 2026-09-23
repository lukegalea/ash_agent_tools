# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.BpmnToolsTest do
  use AshAgentTools.BpmnCase, async: true

  # These tests run the REAL ash_bpmn engine (macros, compiler, interpreter,
  # StateExport) against the sandboxed TestRepo — see AshAgentTools.Test.Bpmn
  # for why the fixtures are the engine's own resources. The facade's
  # processes/2 doctest runs here too: it reads the database, so it needs the
  # sandbox connection this case owns.

  doctest AshAgentTools, only: [processes: 2], tags: [db: true]

  @definition_resource AshAgentTools.Test.Bpmn.Definition
  @domain AshAgentTools.Test.BpmnDomain

  @review_xml File.read!("test/fixtures/review.bpmn")
  @broken_xml "<not-bpmn/>"

  describe "processes/2" do
    @describetag :db

    test "aggregates definitions per key, never returning raw xml" do
      publish_definition!(@definition_resource, "review", "Review", @review_xml)
      create_broken_draft!(@definition_resource, "wip", "WIP", @broken_xml)

      report = AshAgentTools.processes()

      assert report.count == 2
      entries = Map.new(report.processes, &{&1.key, &1})

      review = Map.fetch!(entries, "review")
      assert review.domain == "AshAgentTools.Test.BpmnDomain"
      assert {review.status, review.version} == {:published, 1}
      assert review.errors_count == 0
      assert review.has_draft == false
      assert review.latest_published_version == 1
      assert String.length(review.content_hash) == 64

      wip = Map.fetch!(entries, "wip")
      assert {wip.status, wip.has_draft, wip.errors_count} == {:draft, true, 1}
      assert wip.latest_published_version == nil

      # the sensitive? xml never leaks into the listing
      refute Map.has_key?(review, :xml)
      refute Jason.encode!(report) =~ ~s/"xml"/
    end

    test "a draft shadows the published version as the representative" do
      published = publish_definition!(@definition_resource, "review", "Review", @review_xml)

      # a v2 draft over the published v1
      @definition_resource
      |> Ash.Changeset.for_create(:create, %{key: "review", name: "Review 2", xml: @review_xml})
      |> Ash.create!(authorize?: false)

      entry =
        AshAgentTools.processes(nil, key: "review") |> Map.fetch!(:processes) |> hd()

      assert entry.version == published.version + 1
      assert entry.status == :draft
      assert entry.has_draft == true
      assert entry.latest_published_version == published.version
    end

    test "a key miss answers with an empty list and emits the kaizen gap" do
      AshAgentTools.Kaizen.attach()
      AshAgentTools.Kaizen.reset()

      publish_definition!(@definition_resource, "review", "Review", @review_xml)

      assert %{count: 0, processes: []} = AshAgentTools.processes(nil, key: "nope")

      gap =
        Enum.find(AshAgentTools.Kaizen.digest().gaps, &(&1.tool == "processes"))

      assert gap != nil
    end
  end

  describe "process_graph/2" do
    @describetag :db

    test "returns the compiled graph with element digests" do
      publish_definition!(@definition_resource, "review", "Review", @review_xml)

      report = AshAgentTools.process_graph("review")

      assert report.status == :published
      assert report.version == 1
      assert is_map(report.graph)
      assert map_size(report.graph["nodes"]) == 3
      assert report.graph["start"] == "Start_1"
      # per-element occupancy digests (the migration-classification surface)
      element = Map.fetch!(report.elements, "Review")
      assert element["type"] == "userTask"
      assert String.starts_with?(element["digest"], "sha256:")
      assert element["wait"]["kind"] == "human_task"
    end

    test "an uncompiled draft renders its stored errors instead of a graph" do
      create_broken_draft!(@definition_resource, "wip", "WIP", @broken_xml)

      report = AshAgentTools.process_graph("wip", draft: true)

      assert report.graph == nil
      assert report.elements == nil
      assert report.errors != []
      assert report.note =~ "did not compile"
    end

    test "an unknown key raises with did_you_mean candidates" do
      publish_definition!(@definition_resource, "review", "Review", @review_xml)

      assert_raise ArgumentError, ~r/did_you_mean: \["review"\]/, fn ->
        AshAgentTools.process_graph("revie")
      end
    end

    test "an unknown version raises with the structured message" do
      publish_definition!(@definition_resource, "review", "Review", @review_xml)

      assert_raise ArgumentError, ~r/no v9 definition for key "review"/, fn ->
        AshAgentTools.process_graph("review", version: 9)
      end
    end

    test "include_elements: false skips the digest work" do
      publish_definition!(@definition_resource, "review", "Review", @review_xml)

      report = AshAgentTools.process_graph("review", include_elements: false)

      assert is_map(report.graph)
      assert report.elements == nil
    end
  end

  describe "process_instance/1" do
    @describetag :db

    test "exports the in-flight instance with its pinned definition and open task" do
      publish_definition!(@definition_resource, "review", "Review", @review_xml)

      {:ok, _} =
        AshBpmn.start_instance(@domain,
          subject_type: "Account",
          subject_id: Ash.UUID.generate(),
          process: "review"
        )

      report = AshAgentTools.process_instance(definition_key: "review")

      assert report.count == 1
      [instance] = report.instances
      assert instance["status"] == "running"
      assert instance["definition_key"] == "review"
      assert instance["definition_version"] == 1
      # drift is decidable: the content hash of the pinned definition
      assert is_binary(instance["definition_content_hash"])
      assert String.length(instance["definition_content_hash"]) == 64

      [token] = instance["tokens"]
      assert token["node_id"] == "Review"
      assert token["node_type"] == "userTask"
      assert token["status"] == "waiting"
      assert token["element_digest"] != nil

      [task] = instance["open_tasks"]
      assert {task.node_id, task.status} == {"Review", :open}
      assert [%{principal_type: :user}] = task.candidates
      # the export's waiting block is the engine's own view of the park
      waiting = hd(instance["tokens"])["waiting"]
      assert waiting["waits_for"] == "human_task"
    end

    test "selects by instance_id, with a structured miss" do
      publish_definition!(@definition_resource, "review", "Review", @review_xml)

      {:ok, instance} =
        AshBpmn.start_instance(@domain,
          subject_type: "Account",
          subject_id: Ash.UUID.generate(),
          process: "review"
        )

      assert %{count: 1} = AshAgentTools.process_instance(instance_id: instance.id)

      assert %{count: 0} = AshAgentTools.process_instance(instance_id: Ash.UUID.generate())
    end

    test "selects by subject, and a subject miss is an empty answer" do
      publish_definition!(@definition_resource, "review", "Review", @review_xml)
      subject_id = Ash.UUID.generate()

      {:ok, _} =
        AshBpmn.start_instance(@domain,
          subject_type: "Account",
          subject_id: subject_id,
          process: "review"
        )

      assert %{count: 1} =
               AshAgentTools.process_instance(subject_type: "Account", subject_id: subject_id)

      assert %{count: 0} = AshAgentTools.process_instance(subject_type: "Nothing")
    end
  end

  describe "the mutation line" do
    @describetag :db

    test "reading an instance's open task does not claim or complete it" do
      publish_definition!(@definition_resource, "review", "Review", @review_xml)

      {:ok, _} =
        AshBpmn.start_instance(@domain,
          subject_type: "Account",
          subject_id: Ash.UUID.generate(),
          process: "review"
        )

      AshAgentTools.process_instance(definition_key: "review")

      tasks =
        AshAgentTools.Test.Bpmn.HumanTask
        |> Ash.Query.for_read(:read)
        |> Ash.read!(authorize?: false)

      assert Enum.all?(tasks, &(&1.status == :open and is_nil(&1.assignee_id)))
    end
  end

  describe "the MCP surface" do
    @describetag :db

    test "ash_processes lists definitions; ash_process_instance reads one" do
      publish_definition!(@definition_resource, "review", "Review", @review_xml)

      {:ok, report} = AshAgentTools.Mcp.Tools.call("ash_processes", %{})

      assert report.count == 1

      {:ok, instance} =
        AshBpmn.start_instance(@domain,
          subject_type: "Account",
          subject_id: Ash.UUID.generate(),
          process: "review"
        )

      {:ok, in_flight} =
        AshAgentTools.Mcp.Tools.call("ash_process_instance", %{"instance_id" => instance.id})

      assert in_flight.count == 1
    end
  end
end
