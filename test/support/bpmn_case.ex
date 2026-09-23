# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.BpmnCase do
  @moduledoc """
  Case template for the BPMN/decision tooling tests: each test runs inside
  the Ecto SQL sandbox with automatic checkout/return.

  These tests are tagged `:db` and excluded under `SKIP_DB=1` — the rest of
  the suite needs no database.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import AshAgentTools.BpmnCase

      # every test in a module using this case needs the database
      @module_tag :db
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(AshAgentTools.TestRepo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  Publishes a compiled definition and returns the record. `xml` must compile;
  `publish!/1` refuses a draft with errors.
  """
  def publish_definition!(resource, key, name, xml) do
    resource
    |> Ash.Changeset.for_create(:create, %{key: key, name: name, xml: xml})
    |> Ash.create!(authorize?: false)
    |> then(fn draft ->
      resource.publish!(draft, authorize?: false)
    end)
  end

  @doc """
  Creates a draft whose XML does not compile — the graph-less draft
  (`graph: nil`, `errors` populated) the uncompiled-draft tests need. The
  create action stores compile errors on the draft rather than refusing it;
  it is `publish` that refuses them.
  """
  def create_broken_draft!(resource, key, name, xml) do
    resource
    |> Ash.Changeset.for_create(:create, %{key: key, name: name, xml: xml})
    |> Ash.create!(authorize?: false)
  end
end
