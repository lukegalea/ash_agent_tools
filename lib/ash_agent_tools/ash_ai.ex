# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

# Compiled only when the optional ash_ai dependency is present (the same
# conditional-compilation pattern as AshAgentTools.Mcp.Plug).
if Code.ensure_loaded?(AshAi) do
  defmodule AshAgentTools.AshAi do
    @moduledoc """
    The read-only ash_agent_tools tools as an ash_ai tool domain, for
    serving them from ash_ai's MCP router inside your app in dev.

    Seven tools, named and described exactly as on the `mix ash_agent.serve`
    daemon (the descriptions come from `AshAgentTools.Mcp.Cards`):
    `ash_describe`, `ash_validate`, `ash_can`, `ash_forbidden`,
    `ash_context`, `ash_search` and `ash_laws`. Each is a generic action on
    `AshAgentTools.AshAi.Tools` that calls the same dispatch the daemon uses
    and returns the daemon's JSON shape.

    Mount it in your router's dev-only block:

        if Application.compile_env(:my_app, :dev_routes) do
          scope "/" do
            forward "/ash_agent/mcp", AshAi.Mcp.Router,
              otp_app: :my_app,
              protocol_version_statement: "2024-11-05",
              actions: [{AshAgentTools.AshAi.Tools, :*}],
              tools: [:ash_describe, :ash_validate, :ash_can, :ash_forbidden, :ash_context, :ash_search, :ash_laws]
          end
        end

    Inside the app the tools run in the app's VM. `ash_describe`,
    `ash_validate`, `ash_forbidden`, `ash_context` and `ash_search` read
    compiled DSL only. `ash_can` reads the actor record (and, for
    update/destroy, the target record) with an unauthorized `Ash.get`, so
    it touches your dev data. It never runs the action.

    Every action refuses when `Mix` is not loaded, as in a release: these
    are dev tools. The daemon-only tools (`ash_daemon_status`,
    `ash_reload`) and the optional concept tools (rules, BPMN, decisions)
    are not part of this domain.
    """

    use Ash.Domain,
      extensions: [AshAi],
      validate_config_inclusion?: false

    alias AshAgentTools.Mcp.Cards

    tools do
      tool :ash_describe, AshAgentTools.AshAi.Tools, :ash_describe do
        description Cards.description("ash_describe")
      end

      tool :ash_validate, AshAgentTools.AshAi.Tools, :ash_validate do
        description Cards.description("ash_validate")
      end

      tool :ash_can, AshAgentTools.AshAi.Tools, :ash_can do
        description Cards.description("ash_can")
      end

      tool :ash_forbidden, AshAgentTools.AshAi.Tools, :ash_forbidden do
        description Cards.description("ash_forbidden")
      end

      tool :ash_context, AshAgentTools.AshAi.Tools, :ash_context do
        description Cards.description("ash_context")
      end

      tool :ash_search, AshAgentTools.AshAi.Tools, :ash_search do
        description Cards.description("ash_search")
      end

      tool :ash_laws, AshAgentTools.AshAi.Tools, :ash_laws do
        description Cards.description("ash_laws")
      end
    end

    resources do
      resource AshAgentTools.AshAi.Tools
    end
  end
end
