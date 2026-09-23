# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Mcp.PlugTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias AshAgentTools.Mcp.Plug

  @jsonrpc %{"jsonrpc" => "2.0", "id" => 1}
  @default_headers [{"content-type", "application/json"}]

  defp post(body, headers \\ []) do
    conn(:post, "/", body)
    |> put_req_headers(@default_headers ++ headers)
    |> Plug.call([])
  end

  defp put_req_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, conn -> put_req_header(conn, k, v) end)
  end

  defp rpc(method, params \\ %{}) do
    Jason.encode!(Map.merge(@jsonrpc, %{"method" => method, "params" => params}))
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  describe "initialize" do
    test "echoes a supported client protocol version and exposes serverInfo" do
      conn = post(rpc("initialize", %{"protocolVersion" => "2024-11-05"}))

      assert conn.status == 200
      assert %{"result" => result} = decode(conn)
      assert result["protocolVersion"] == "2024-11-05"
      assert result["capabilities"]["tools"] == %{"listChanged" => false}
      assert result["serverInfo"]["name"] == "ash_agent_tools"
      assert result["serverInfo"]["version"] =~ ~r/^\d+\.\d+/
    end

    test "negotiates down to the default for an unknown/absent version" do
      for params <- [%{"protocolVersion" => "9999-99-99"}, %{}] do
        conn = post(rpc("initialize", params))
        assert %{"result" => %{"protocolVersion" => "2025-03-26"}} = decode(conn)
      end
    end
  end

  describe "notifications and client responses" do
    test "notifications/initialized gets 202 with no body" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

      conn = post(body)

      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "an id-less request is a notification: 202" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "ping"})
      conn = post(body)

      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "a client response envelope gets 202" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "result" => %{"ok" => true}})
      conn = post(body)

      assert conn.status == 202
    end
  end

  describe "ping" do
    test "answers with an empty result" do
      conn = post(rpc("ping"))

      assert conn.status == 200
      assert %{"result" => %{}} = decode(conn)
    end
  end

  describe "tools/list" do
    test "returns tool cards with input schemas" do
      conn = post(rpc("tools/list"))

      assert conn.status == 200
      assert %{"result" => %{"tools" => tools}} = decode(conn)
      names = Enum.map(tools, & &1["name"])

      assert names == [
               "ash_describe",
               "ash_validate",
               "ash_can",
               "ash_search",
               "ash_context",
               "ash_forbidden",
               "ash_rules",
               "ash_transitions",
               "ash_processes",
               "ash_process_graph",
               "ash_process_instance",
               "ash_decisions",
               "ash_decision_evaluate",
               "ash_daemon_status",
               "ash_reload"
             ]

      assert Enum.all?(tools, &is_binary(&1["description"]))
      assert Enum.all?(tools, &(&1["inputSchema"]["type"] == "object"))
    end
  end

  describe "tools/call" do
    test "returns the report as text content" do
      conn =
        post(
          rpc("tools/call", %{
            "name" => "ash_validate",
            "arguments" => %{
              "resource" => "AshAgentTools.Test.Post",
              "action" => "create",
              "params" => %{"title" => "Hi"}
            }
          })
        )

      assert conn.status == 200

      assert %{
               "result" => %{
                 "isError" => false,
                 "content" => [%{"type" => "text", "text" => text}]
               }
             } = decode(conn)

      report = Jason.decode!(text)
      assert report["valid?"] == true
      assert report["normalized_inputs"]["title"] == "Hi"
    end

    test "structured tool failures carry isError with did_you_mean" do
      conn =
        post(
          rpc("tools/call", %{
            "name" => "ash_describe",
            "arguments" => %{"resource" => "AshAgentTools.Test.Post", "action" => "creat"}
          })
        )

      assert conn.status == 200
      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} = decode(conn)

      error = Jason.decode!(text)
      assert error["error"] =~ "no action named"
      assert "create" in error["did_you_mean"]
    end

    test "an unknown tool is JSON-RPC invalid params (-32602)" do
      conn = post(rpc("tools/call", %{"name" => "ash_nope"}))

      assert conn.status == 400

      assert %{"error" => %{"code" => -32_602, "message" => message}} = decode(conn)
      assert message =~ "unknown tool"
    end

    test "a missing tool name is JSON-RPC invalid params (-32602)" do
      conn = post(rpc("tools/call", %{}))

      assert %{"error" => %{"code" => -32_602}} = decode(conn)
    end
  end

  describe "discovery via ash_describe with no arguments" do
    test "returns the discovery summary" do
      conn = post(rpc("tools/call", %{"name" => "ash_describe", "arguments" => %{}}))

      assert conn.status == 200
      assert %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} = decode(conn)

      summary = Jason.decode!(text)
      assert summary["resource_count"] >= 1
      assert "AshAgentTools.Test.Post" in summary["resources"]
    end
  end

  describe "protocol-level errors" do
    test "unparseable JSON is -32700" do
      conn = post("{not json")

      assert conn.status == 400
      assert %{"error" => %{"code" => -32_700}} = decode(conn)
    end

    test "a non-JSON-RPC envelope is -32600" do
      conn = post(Jason.encode!(%{"hello" => "world"}))

      assert %{"error" => %{"code" => -32_600}} = decode(conn)
    end

    test "an unknown method with an id is -32601" do
      conn = post(rpc("resources/list"))

      assert %{"error" => %{"code" => -32_601, "message" => message}} = decode(conn)
      assert message =~ "resources/list"
    end
  end

  describe "transport guards" do
    test "GET is 405 with Allow: POST" do
      conn =
        conn(:get, "/", nil)
        |> Plug.call([])

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
    end

    test "DELETE is 405" do
      conn =
        conn(:delete, "/", nil)
        |> Plug.call([])

      assert conn.status == 405
    end

    test "a local Origin is accepted" do
      conn = post(rpc("ping"), [{"origin", "http://127.0.0.1:3927"}])
      assert conn.status == 200

      conn = post(rpc("ping"), [{"origin", "http://localhost:3927"}])
      assert conn.status == 200
    end

    test "a non-local Origin is rejected with 403 (DNS-rebinding defense)" do
      conn = post(rpc("ping"), [{"origin", "https://evil.example.com"}])

      assert conn.status == 403
      assert decode(conn)["error"] =~ "untrusted origin"
    end

    test "an absent Origin is allowed (non-browser clients)" do
      conn = post(rpc("ping"))
      assert conn.status == 200
    end

    test "an unsupported MCP-Protocol-Version header is 400" do
      conn = post(rpc("ping"), [{"mcp-protocol-version", "1999-01-01"}])

      assert conn.status == 400
      assert decode(conn)["error"] =~ "unsupported MCP-Protocol-Version"
    end

    test "a supported MCP-Protocol-Version header is accepted, absent assumed 2025-03-26" do
      conn = post(rpc("ping"), [{"mcp-protocol-version", "2024-11-05"}])
      assert conn.status == 200

      conn = post(rpc("ping"))
      assert conn.status == 200
    end
  end
end
