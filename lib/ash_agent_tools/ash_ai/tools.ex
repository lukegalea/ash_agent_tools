# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(AshAi) do
  defmodule AshAgentTools.AshAi.Tools do
    @moduledoc """
    Generic actions backing the `AshAgentTools.AshAi` tool domain: one per
    tool, each a thin call into `AshAgentTools.Mcp.Tools.call/2` (the
    daemon's dispatch), so argument parsing, errors and output match the
    daemon. Argument names, types and descriptions follow
    `AshAgentTools.Mcp.Cards`.
    """

    use Ash.Resource, domain: AshAgentTools.AshAi

    alias AshAgentTools.AshAi.Run
    alias AshAgentTools.Mcp.Cards

    actions do
      action :ash_describe, :map do
        description Cards.description("ash_describe")

        argument :resource, :string,
          description: Cards.argument_description("ash_describe", "resource")

        argument :action, :string,
          description: Cards.argument_description("ash_describe", "action")

        run {Run, tool: "ash_describe"}
      end

      action :ash_validate, :map do
        description Cards.description("ash_validate")

        argument :resource, :string,
          allow_nil?: false,
          description: Cards.argument_description("ash_validate", "resource")

        argument :action, :string,
          allow_nil?: false,
          description: Cards.argument_description("ash_validate", "action")

        argument :params, :map, description: Cards.argument_description("ash_validate", "params")

        run {Run, tool: "ash_validate"}
      end

      action :ash_can, :map do
        description Cards.description("ash_can")

        argument :resource, :string,
          allow_nil?: false,
          description: Cards.argument_description("ash_can", "resource")

        argument :action, :string,
          allow_nil?: false,
          description: Cards.argument_description("ash_can", "action")

        # A string or an object, as on the daemon card: the dispatch parses it.
        argument :actor, :term, description: Cards.argument_description("ash_can", "actor")
        argument :params, :map, description: Cards.argument_description("ash_can", "params")
        argument :record, :string, description: Cards.argument_description("ash_can", "record")

        run {Run, tool: "ash_can"}
      end

      action :ash_forbidden, :map do
        description Cards.description("ash_forbidden")

        argument :resource, :string,
          allow_nil?: false,
          description: Cards.argument_description("ash_forbidden", "resource")

        argument :action, :string,
          description: Cards.argument_description("ash_forbidden", "action")

        run {Run, tool: "ash_forbidden"}
      end

      action :ash_context, :map do
        description Cards.description("ash_context")

        argument :file, :string,
          allow_nil?: false,
          description: Cards.argument_description("ash_context", "file")

        argument :line, :integer,
          allow_nil?: false,
          description: Cards.argument_description("ash_context", "line")

        run {Run, tool: "ash_context"}
      end

      action :ash_search, {:array, :map} do
        description Cards.description("ash_search")

        argument :term, :string,
          allow_nil?: false,
          description: Cards.argument_description("ash_search", "term")

        argument :kinds, {:array, AshAgentTools.AshAi.SearchKind},
          description: Cards.argument_description("ash_search", "kinds")

        run {Run, tool: "ash_search"}
      end

      action :ash_laws, :map do
        description Cards.description("ash_laws")

        argument :source, :string, description: Cards.argument_description("ash_laws", "source")
        argument :file, :string, description: Cards.argument_description("ash_laws", "file")
        argument :diff, :string, description: Cards.argument_description("ash_laws", "diff")

        argument :min_tier, :string,
          description: Cards.argument_description("ash_laws", "min_tier")

        argument :laws, {:array, :string},
          description: Cards.argument_description("ash_laws", "laws")

        argument :ignore_comments, :boolean,
          description: Cards.argument_description("ash_laws", "ignore_comments")

        run {Run, tool: "ash_laws"}
      end
    end
  end
end
