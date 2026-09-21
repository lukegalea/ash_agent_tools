# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

# Compiled conditionally (Ecto's optional-Jason pattern): `plug` is an
# *optional* dependency, so a host that does not ship it still compiles this
# package cleanly. The daemon (`mix ash_agent.serve`) refuses to boot without
# it, with a pointed install hint.
if Code.ensure_loaded?(Plug.Conn) do
  defmodule AshAgentTools.Mcp.Plug do
    @moduledoc """
    The stateless MCP-over-HTTP endpoint behind `mix ash_agent.serve`.

    A POST-only JSON-RPC 2.0 endpoint (MCP "Streamable HTTP" transport,
    stateless profile — no `Mcp-Session-Id`, no SSE, no server-initiated
    messages; the spec permits both omissions). Protocol behavior is
    written against the MCP specification and cross-checked against
    existing MCP server implementations:

      * `initialize` — negotiates the protocol version down to the client's
        request (`2024-11-05` accepted, per the repo's own
        `AshAi.Mcp.Dev` precedent) and returns serverInfo + `tools` capability
      * notifications (`notifications/*`, or any request without an `id`) and
        client responses → `202` with no body
      * `tools/list` / `tools/call` / `ping` → JSON-RPC responses
      * `tools/call` results are `content: [%{type: "text", text: json}]`;
        structured tool failures set `isError: true` with the mix tasks'
        `{error, did_you_mean}` shape as the text payload
      * `GET`/`DELETE` → `405` (POST-only server)
      * `Origin` header validated on every request (DNS-rebinding defense):
        absent → allowed; local hosts → allowed; anything else → `403`
      * `MCP-Protocol-Version` header after initialize: absent → assumed
        `2025-03-26`; a non-negotiable value → `400`
      * always replies `content-type: application/json`; the
        `Accept: application/json, text/event-stream` dance is tolerated

    The body is read directly (`Plug.Conn.read_body/1`) — no `Plug.Parsers`
    — so malformed JSON becomes a JSON-RPC `-32700` response rather than a
    parser exception. Stateless by design: every request is answered from
    in-memory compiled state.
    """

    @behaviour Plug

    import Plug.Conn

    require Logger

    alias AshAgentTools.Mcp.Tools

    # One revision family, initialize-negotiated. `2024-11-05` is pinned for
    # older client stacks (same rationale as the repo's AshAi.Mcp.Dev);
    # `2025-03-26` is the assumed default for post-initialize requests.
    @protocol_versions ["2024-11-05", "2025-03-26", "2025-06-18"]
    @default_protocol_version "2025-03-26"

    @local_hosts ["localhost", "127.0.0.1", "::1", "0.0.0.0"]

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts) do
      case conn.method do
        "POST" -> validate_origin(conn)
        method -> method_not_allowed(conn, method)
      end
    end

    # -- guards ---------------------------------------------------------------

    # DNS-rebinding defense: a browser page can only reach this endpoint by
    # making a cross-origin request, which always carries Origin. Local
    # origins (the .mcp.json entries point at 127.0.0.1) pass; anything else
    # is refused. No Origin header at all means a non-browser client (curl,
    # MCP SDKs) — allowed.
    defp validate_origin(conn) do
      case get_req_header(conn, "origin") do
        [] ->
          validate_protocol_version(conn)

        [origin] ->
          if local_origin?(origin) do
            validate_protocol_version(conn)
          else
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(403, Jason.encode!(%{error: "untrusted origin #{inspect(origin)}"}))
            |> halt()
          end

        _multiple ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(400, Jason.encode!(%{error: "multiple Origin headers"}))
          |> halt()
      end
    end

    defp local_origin?(origin) when is_binary(origin) do
      case URI.new(origin) do
        {:ok, %URI{host: host}} when is_binary(host) ->
          String.downcase(host) in @local_hosts

        _ ->
          false
      end
    end

    # Post-initialize requests SHOULD carry MCP-Protocol-Version. Absent →
    # assume the default; a value we cannot negotiate → 400 (per the spec's
    # version-negotiation rules, echoing the client's impossible request).
    defp validate_protocol_version(conn) do
      case get_req_header(conn, "mcp-protocol-version") do
        [] ->
          handle(conn)

        [version] ->
          if version in @protocol_versions do
            handle(conn)
          else
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              400,
              Jason.encode!(%{
                error: "unsupported MCP-Protocol-Version #{inspect(version)}",
                supported: @protocol_versions
              })
            )
            |> halt()
          end

        _multiple ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(400, Jason.encode!(%{error: "multiple MCP-Protocol-Version headers"}))
          |> halt()
      end
    end

    defp method_not_allowed(conn, method) do
      conn
      |> put_resp_header("allow", "POST")
      |> put_resp_content_type("application/json")
      |> send_resp(
        405,
        Jason.encode!(%{error: "#{method} not allowed; this MCP server accepts POST only"})
      )
      |> halt()
    end

    # -- dispatch -------------------------------------------------------------

    defp handle(conn) do
      case read_body(conn) do
        {:ok, body, conn} ->
          dispatch(conn, body)

        {:error, reason} ->
          json_rpc_error(
            conn,
            400,
            nil,
            -32_700,
            "failed to read request body: #{inspect(reason)}"
          )
      end
    end

    defp dispatch(conn, body) do
      case Jason.decode(body) do
        {:ok, %{"jsonrpc" => "2.0", "method" => method} = request} when is_binary(method) ->
          route(conn, method, request)

        {:ok, %{"jsonrpc" => "2.0", "result" => _, "id" => _}} ->
          # A client replying to one of our (never-sent) server requests.
          accepted(conn)

        {:ok, %{"jsonrpc" => "2.0", "error" => _, "id" => _}} ->
          accepted(conn)

        {:ok, _other} ->
          json_rpc_error(conn, 400, nil, -32_600, "not a valid JSON-RPC 2.0 request")

        {:error, %Jason.DecodeError{} = error} ->
          json_rpc_error(conn, 400, nil, -32_700, Exception.message(error))
      end
    end

    # Notifications and id-less requests are fire-and-forget: 202, no body.
    # Per JSON-RPC, a request without an "id" is a notification by definition.
    defp route(conn, "notifications/" <> _rest, _request), do: accepted(conn)

    defp route(conn, _method, %{"id" => nil}), do: accepted(conn)

    defp route(conn, "initialize", %{"id" => id} = request) do
      params = Map.get(request, "params", %{})

      result = %{
        protocolVersion: negotiate_version(params["protocolVersion"]),
        capabilities: %{tools: %{listChanged: false}},
        serverInfo: server_info()
      }

      json_rpc_result(conn, id, result)
    end

    defp route(conn, "ping", %{"id" => id}), do: json_rpc_result(conn, id, %{})

    defp route(conn, "tools/list", %{"id" => id}),
      do: json_rpc_result(conn, id, %{tools: Tools.tool_cards()})

    defp route(conn, "tools/call", %{"id" => id} = request) do
      params = Map.get(request, "params", %{})
      name = Map.get(params, "name")
      arguments = Map.get(params, "arguments", %{})

      cond do
        not is_binary(name) ->
          json_rpc_error(
            conn,
            400,
            id,
            -32_602,
            "tools/call requires a string \"name\" parameter"
          )

        name not in Tools.tool_names() ->
          candidates = Tools.tool_names()

          json_rpc_error(
            conn,
            400,
            id,
            -32_602,
            "unknown tool #{inspect(name)}. Valid tools: #{inspect(candidates)}"
          )

        true ->
          result =
            try do
              case Tools.call(name, arguments) do
                {:ok, report} ->
                  %{content: [%{type: "text", text: Jason.encode!(report)}], isError: false}

                {:error, error} ->
                  %{content: [%{type: "text", text: Jason.encode!(error)}], isError: true}
              end
            rescue
              error ->
                Logger.error(
                  "ash_agent daemon tool #{name} crashed: #{Exception.format(:error, error)}"
                )

                text =
                  Jason.encode!(%{error: "internal error running #{name}", did_you_mean: []})

                %{content: [%{type: "text", text: text}], isError: true}
            end

          json_rpc_result(conn, id, result)
      end
    end

    defp route(conn, method, %{"id" => id}) do
      json_rpc_error(conn, 400, id, -32_601, "method not found: #{inspect(method)}")
    end

    # A request with no "id" at all is a JSON-RPC notification by
    # definition — accepted with 202, never answered.
    defp route(conn, _method, _request), do: accepted(conn)

    # -- responses ------------------------------------------------------------

    defp negotiate_version(requested) do
      if requested in @protocol_versions do
        # Negotiate down to the client's revision — older client stacks stay
        # first-class (the tidewave-0.8.2-era pin lesson).
        requested
      else
        @default_protocol_version
      end
    end

    defp server_info do
      %{
        name: "ash_agent_tools",
        version: Application.spec(:ash_agent_tools, :vsn) |> to_string()
      }
    end

    defp json_rpc_result(conn, id, result) do
      send_json(conn, 200, %{jsonrpc: "2.0", id: id, result: result})
    end

    defp json_rpc_error(conn, status, id, code, message) do
      send_json(conn, status, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})
    end

    defp send_json(conn, status, payload) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(payload))
    end

    # 202 Accepted, deliberately no body and no content-type: notifications
    # and client responses get nothing back per the transport rules.
    defp accepted(conn) do
      send_resp(conn, 202, "")
    end
  end
end
