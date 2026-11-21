# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.GateHooksTest do
  # The adapters against the daemon's real HTTP endpoint (Bandit on an
  # OS-assigned port), and against a closed port.
  use ExUnit.Case, async: false

  @claude_hook Path.expand("../priv/hooks/claude_pretooluse.sh", __DIR__)
  @opencode_plugin Path.expand("../priv/hooks/opencode-gate.ts", __DIR__)

  setup_all do
    root = Path.join(System.tmp_dir!(), "gate_hooks_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {_, 0} = System.cmd("git", ["init", "-q", root])
    on_exit(fn -> File.rm_rf!(root) end)

    previous = File.cwd!()
    File.cd!(root)
    on_exit(fn -> File.cd!(previous) end)

    port = free_port()

    start_supervised!(
      {Bandit, plug: AshAgentTools.Mcp.Plug, ip: {127, 0, 0, 1}, port: port, startup_log: false}
    )

    %{
      root: root,
      url: "http://127.0.0.1:#{port}/gate",
      closed: "http://127.0.0.1:#{free_port()}/gate"
    }
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp pretooluse(root, tool, input) do
    Jason.encode!(%{
      "session_id" => "hook-test",
      "transcript_path" => "/dev/null",
      "cwd" => root,
      "hook_event_name" => "PreToolUse",
      "tool_name" => tool,
      "tool_input" => input
    })
  end

  # Runs the hook with `stdin` as its standard input; returns stdout, the
  # exit status and the wall time in milliseconds.
  defp run_hook(stdin, url) do
    dir = Path.join(System.tmp_dir!(), "gate_hook_in_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    input = Path.join(dir, "input.json")
    File.write!(input, stdin)

    {us, {out, status}} =
      :timer.tc(fn ->
        System.cmd("sh", ["-c", ~s(exec "$0" < "$1"), @claude_hook, input],
          env: [{"ASH_AGENT_GATE_URL", url}]
        )
      end)

    File.rm_rf!(dir)
    {out, status, div(us, 1000)}
  end

  test "POST /gate answers in under 50 ms at p95, warm", ctx do
    :inets.start()
    body = pretooluse(ctx.root, "Bash", %{"command" => "git push -f origin main"})

    post = fn ->
      {:ok, {{_, 200, _}, _, _}} =
        :httpc.request(
          :post,
          {String.to_charlist(ctx.url <> "?format=claude_code"), [], ~c"application/json", body},
          [],
          []
        )
    end

    post.()

    timings = for _ <- 1..200, do: elem(:timer.tc(post), 0)
    p95 = timings |> Enum.sort() |> Enum.at(189)
    IO.puts("POST /gate p95 over 200 warm requests: #{Float.round(p95 / 1000, 2)} ms")
    assert p95 < 50_000
  end

  test "the ash_gate MCP tool answers the same question", ctx do
    request = %{"tool" => "Bash", "command" => "killall beam.smp", "cwd" => ctx.root}

    assert {:ok, %{decision: "deny", rule_id: "gate_kill_by_pattern"}} =
             AshAgentTools.Mcp.Tools.call("ash_gate", %{"request" => request})

    assert {:error, %{error: "ash_gate requires a \"request\" object"}} =
             AshAgentTools.Mcp.Tools.call("ash_gate", %{})
  end

  describe "the Claude Code PreToolUse adapter" do
    test "a denied call comes back as Claude Code's deny, with the rule's reason", ctx do
      stdin = pretooluse(ctx.root, "Bash", %{"command" => "git push --force origin main"})
      {out, 0, _ms} = run_hook(stdin, ctx.url)

      assert %{
               "hookSpecificOutput" => %{
                 "hookEventName" => "PreToolUse",
                 "permissionDecision" => "deny",
                 "permissionDecisionReason" => reason
               }
             } = Jason.decode!(out)

      assert reason =~ "gate rule gate_force_push"
    end

    test "a deferred call leaves the decision to Claude Code", ctx do
      {out, 0, _ms} = run_hook(pretooluse(ctx.root, "Bash", %{"command" => "ls"}), ctx.url)
      assert Jason.decode!(out) == %{}
    end

    test "daemon down: a mutating call is asked within 300 ms, a read-only one passes", ctx do
      stdin = pretooluse(ctx.root, "Bash", %{"command" => "ls"})
      {out, 0, ms} = run_hook(stdin, ctx.closed)

      assert %{
               "hookSpecificOutput" => %{
                 "permissionDecision" => "ask",
                 "permissionDecisionReason" => reason
               }
             } =
               Jason.decode!(out)

      assert reason =~ "gate is unavailable"
      assert ms < 300, "the unavailable path took #{ms} ms"

      {out, 0, _ms} = run_hook(pretooluse(ctx.root, "Read", %{"file_path" => "x"}), ctx.closed)
      assert out == ""
    end

    test "shell metacharacters and JSON tricks reach the daemon as data", ctx do
      sentinel = Path.join(ctx.root, "pwned")

      command =
        ~s|echo $(touch #{sentinel}) `touch #{sentinel}` "; touch #{sentinel}; \\"} ' && git push -f origin main|

      stdin = pretooluse(ctx.root, "Bash", %{"command" => command})
      {out, 0, _ms} = run_hook(stdin, ctx.url)

      refute File.exists?(sentinel)
      assert Jason.decode!(out)["hookSpecificOutput"]["permissionDecision"] == "deny"

      [line] =
        ctx.root
        |> Path.join(".agents/logs/gate.jsonl")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["command"] == command))

      assert line["rule_id"] == "gate_force_push"
    end

    test "a body that is not JSON is asked, not allowed", ctx do
      {out, 0, _ms} = run_hook("not json {", ctx.url)
      assert Jason.decode!(out)["hookSpecificOutput"]["permissionDecision"] == "ask"
    end

    @tag :shellcheck
    test "shellcheck finds nothing" do
      case System.find_executable("shellcheck") do
        nil -> :ok
        shellcheck -> assert {_, 0} = System.cmd(shellcheck, [@claude_hook])
      end
    end
  end

  describe "the opencode tool.execute.before adapter" do
    # Runs the plugin under bun when it is installed (the plugin is
    # TypeScript; opencode itself runs on bun).
    defp run_plugin(tool, args, url, root) do
      script = Path.join(root, "run_plugin_#{System.unique_integer([:positive])}.ts")

      File.write!(script, """
      import { AshAgentGate } from #{Jason.encode!(@opencode_plugin)}
      const hooks = await AshAgentGate({ directory: #{Jason.encode!(root)} } as any)
      try {
        await hooks["tool.execute.before"]!(
          { tool: #{Jason.encode!(tool)}, sessionID: "s", callID: "c" },
          { args: #{Jason.encode!(args)} },
        )
        console.log("PASSED")
      } catch (error) {
        console.log("BLOCKED " + (error as Error).message)
      }
      """)

      {out, 0} = System.cmd("bun", ["run", script], env: [{"ASH_AGENT_GATE_URL", url}])
      File.rm!(script)
      String.trim(out)
    end

    unless System.find_executable("bun"), do: @describetag(skip: "bun is not installed")

    test "deny blocks with the rule id; defer passes", ctx do
      assert run_plugin("bash", %{"command" => "git push -f origin main"}, ctx.url, ctx.root) =~
               "BLOCKED Denied by gate rule gate_force_push"

      assert run_plugin("bash", %{"command" => "ls"}, ctx.url, ctx.root) == "PASSED"
    end

    test "daemon down: a mutating call is blocked, a read passes", ctx do
      assert run_plugin("bash", %{"command" => "ls"}, ctx.closed, ctx.root) =~
               "BLOCKED The pre-flight gate is unavailable"

      assert run_plugin("read", %{"filePath" => "x"}, ctx.closed, ctx.root) == "PASSED"
    end
  end
end
