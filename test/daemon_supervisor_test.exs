# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Daemon.SupervisorTest do
  use ExUnit.Case, async: true

  # Full-tree smoke tests plus the end-to-end HTTP round trip against a real
  # Bandit listener (on an OS-assigned port). The watcher is left out of the
  # tree here (`watch?: false`) — it has its own dedicated test, and the
  # children get unique names so tests stay `async: true`.

  alias AshAgentTools.Daemon.Supervisor

  @moduletag :daemon_http

  defp unique_suffix, do: System.unique_integer([:positive])

  defp start_daemon(opts) do
    suffix = unique_suffix()

    opts =
      Keyword.merge(opts,
        name: Module.concat([__MODULE__, "Supervisor", "n#{suffix}"]),
        runtime_name: Module.concat([__MODULE__, "Runtime", "n#{suffix}"]),
        watch?: false,
        port: free_port()
      )

    start_supervised!({Supervisor, opts})
    {opts[:name], opts[:port]}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp http_post(port, body, headers \\ []) do
    Application.ensure_all_started(:inets)

    request = {
      ~c"http://127.0.0.1:#{port}/",
      Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end),
      ~c"application/json",
      body
    }

    case :httpc.request(:post, request, [], []) do
      {:ok, {{_http, status, _reason}, _resp_headers, resp_body}} ->
        {status, :erlang.list_to_binary(resp_body)}

      {:error, reason} ->
        flunk("HTTP request failed: #{inspect(reason)}")
    end
  end

  describe "config/1" do
    test "defaults to loopback:4100 with the watcher on" do
      cfg = Supervisor.config()

      assert cfg.port == 4100
      assert cfg.ip == {127, 0, 0, 1}
      assert cfg.watch? == true
      assert cfg.watch_dirs == nil
    end

    test "options win over defaults" do
      cfg = Supervisor.config(port: 4200, watch?: false, watch_dirs: ["lib"])

      assert cfg.port == 4200
      assert cfg.watch? == false
      assert cfg.watch_dirs == ["lib"]
    end
  end

  test "starts the whole tree and serves MCP over HTTP end-to-end" do
    {supervisor, port} = start_daemon([])

    assert Process.whereis(supervisor) |> is_pid()
    assert children(supervisor) == [AshAgentTools.Daemon.Runtime, Bandit]

    # initialize over the wire
    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{protocolVersion: "2024-11-05"}
      })

    {200, resp} = http_post(port, body)

    assert %{"result" => %{"protocolVersion" => "2024-11-05", "serverInfo" => info}} =
             Jason.decode!(resp)

    assert info["name"] == "ash_agent_tools"

    # tools/call over the wire (through the runtime cache)
    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: %{
          name: "ash_validate",
          arguments: %{
            resource: "AshAgentTools.Test.Post",
            action: "create",
            params: %{title: "Hi"}
          }
        }
      })

    {200, resp} = http_post(port, body)

    assert %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} =
             Jason.decode!(resp)

    assert Jason.decode!(text)["valid?"] == true
  end

  test "a daemon without HTTP (http?: false) starts exactly the runtime" do
    {supervisor, _port} = start_daemon(http?: false)

    assert children(supervisor) == [AshAgentTools.Daemon.Runtime]
  end

  defp children(supervisor) do
    supervisor
    |> :supervisor.which_children()
    |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
    |> Enum.sort()
  end
end
