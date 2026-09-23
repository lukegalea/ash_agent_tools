# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.AvailabilityOffTest do
  # Runs after every async test (ExUnit ordering): mutating the node-global
  # code server here cannot race another test's use of the modules.
  use ExUnit.Case, async: false

  # The optional-dep contract's off-path: with the integration's beam off the
  # code path, every tool of that integration raises the structured "add the
  # dep" error instead of crashing. The dep IS loaded in this repo, so the
  # test removes its code-path entry (in memory only) and restores it.

  describe "the structured not-available error" do
    test "the bpmn tools name the dep to add instead of crashing" do
      dir = ebin_dir!(AshBpmn)
      off!(AshBpmn, dir)

      assert_raise ArgumentError,
                   ~r/ash_bpmn tooling is not available: add \{:ash_bpmn, github: "lukegalea\/ash_bpmn"\}/,
                   fn -> AshAgentTools.processes() end

      assert_raise ArgumentError, ~r/add \{:ash_bpmn/, fn ->
        AshAgentTools.process_graph("review")
      end

      assert_raise ArgumentError, ~r/add \{:ash_bpmn/, fn ->
        AshAgentTools.process_instance([])
      end

      on!(AshBpmn, dir)
    end

    test "the decisions tools name the dep to add instead of crashing" do
      dir = ebin_dir!(AshDecisions)
      off!(AshDecisions, dir)

      assert_raise ArgumentError,
                   ~r/ash_decisions tooling is not available: add \{:ash_decisions, github: "lukegalea\/ash_decisions"\}/,
                   fn -> AshAgentTools.decisions() end

      assert_raise ArgumentError, ~r/add \{:ash_decisions/, fn ->
        AshAgentTools.decision_evaluate("surcharge", %{})
      end

      on!(AshDecisions, dir)
    end

    test "availability reports the integration as inactive while its beam is off the path" do
      dir = ebin_dir!(AshDecisions)
      off!(AshDecisions, dir)

      report = AshAgentTools.Availability.report()
      assert Enum.find(report.integrations, &(&1.integration == :ash_decisions)).active? == false

      on!(AshDecisions, dir)
    end

    # Removes the module's ebin directory from the in-memory code path and
    # purges the loaded copy, so `Code.ensure_loaded?/1` — the activation
    # check — honestly fails. Restored by `on!/2`.
    defp off!(module, dir) do
      :code.purge(module)
      :code.delete(module)
      :code.del_path(dir)
    end

    defp on!(module, dir) do
      :code.add_path(dir)
      {:module, ^module} = Code.ensure_loaded(module)
    end

    defp ebin_dir!(module) do
      beam = Atom.to_charlist(module) ++ ~c".beam"

      case :code.where_is_file(beam) do
        :non_existing -> flunk("#{inspect(module)} beam not on the code path")
        full -> full |> List.to_string() |> Path.dirname() |> to_charlist()
      end
    end
  end
end
