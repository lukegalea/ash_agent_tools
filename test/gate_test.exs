# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.GateTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshAgentTools.Gate
  alias AshAgentTools.Gate.Request

  @host_table Path.expand("fixtures/gate_host.dmn", __DIR__)

  # A git repository per kind, with the remotes that classify it.
  setup_all do
    base = Path.join(System.tmp_dir!(), "gate_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    repo = fn name, remotes ->
      dir = Path.join(base, name)
      File.mkdir_p!(dir)
      {_, 0} = System.cmd("git", ["init", "-q", dir])

      for {remote, url} <- remotes do
        {_, 0} = System.cmd("git", ["-C", dir, "remote", "add", remote, url])
      end

      dir
    end

    root = repo.("project", [{"origin", "https://example.test/first/project.git"}])

    File.mkdir_p!(Path.join(root, ".agents"))

    File.write!(
      Path.join(root, ".agents/gate.json"),
      Jason.encode!(%{
        version: 1,
        first_party: ["example\\.test/first/"],
        private: ["example\\.test/private/"]
      })
    )

    worktree = Path.join(base, "project-worktree")
    git = fn args -> {_, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true) end

    git.([
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@example.test",
      "commit",
      "-q",
      "--allow-empty",
      "-m",
      "init"
    ])

    git.(["worktree", "add", "-q", "--detach", worktree])

    # A worktree nested inside the repository, where a session whose cwd is the
    # outer checkout edits files.
    nested = Path.join(root, "nested/wt")
    git.(["worktree", "add", "-q", "--detach", nested])

    %{
      root: root,
      worktree: worktree,
      nested: nested,
      fork:
        repo.("fork", [
          {"origin", "https://example.test/first/fork.git"},
          {"upstream", "https://example.test/community/fork.git"}
        ]),
      private: repo.("private", [{"origin", "https://example.test/private/x.git"}]),
      stray: repo.("stray", [{"origin", "https://elsewhere.test/someone/x.git"}])
    }
  end

  defp bash(ctx, command, cwd \\ nil, opts \\ []) do
    Gate.explain(
      %{"tool" => "Bash", "command" => command, "cwd" => cwd || ctx.root},
      Keyword.merge([root: ctx.root], opts)
    )
  end

  defp decision(result), do: {result.decision, result.rule_id}

  describe "the seed table" do
    test "passes the ash_decisions verifier: complete, nothing undecided" do
      report = Gate.verify(tables: [Gate.seed_table()])

      assert [%{ok?: true, obligations: [], findings: findings}] = report.tables
      assert report.ok?
      # Under FIRST an overlap is legal; nothing else may be found.
      assert Enum.all?(findings, &(&1["severity"] == "info" and &1["kind"] == "overlap"))
    end

    test "each rule's rule_id output is the id of the rule the engine matched", ctx do
      for command <- ["git push -f origin main", "pkill -f beam", "ls"] do
        result = bash(ctx, command)
        assert result.rule_id == hd(result.matched_rule_ids)
      end
    end

    test "gate_fork_push: a push from a community fork is denied, local work is not", ctx do
      assert decision(bash(ctx, "git push origin main", ctx.fork)) == {"deny", "gate_fork_push"}

      assert decision(bash(ctx, "git -C #{ctx.fork} push origin HEAD:refs/heads/x")) ==
               {"deny", "gate_fork_push"}

      assert decision(bash(ctx, "cd #{ctx.fork} && git push")) == {"deny", "gate_fork_push"}
      assert decision(bash(ctx, "git commit -m wip", ctx.fork)) == {"defer", "gate_no_rule"}
      assert decision(bash(ctx, "git status", ctx.fork)) == {"defer", "gate_no_rule"}
    end

    test "gate_force_push: every force spelling is denied, a plain push is not", ctx do
      for command <- [
            "git push -f origin main",
            "git push --force origin main",
            "git push --force-with-lease origin feature",
            "git push -uf origin main",
            "git push origin +main",
            "git -C . push --force origin main"
          ] do
        assert decision(bash(ctx, command)) == {"deny", "gate_force_push"}, command
      end

      for command <- [
            "git push origin main",
            "git push --follow-tags origin main",
            "git push -u origin feature",
            "git push origin --delete scratch/x"
          ] do
        assert decision(bash(ctx, command)) == {"defer", "gate_no_rule"}, command
      end
    end

    test "gate_no_verify: skipping hooks is denied, a normal commit is not", ctx do
      assert decision(bash(ctx, "git commit --no-verify -m x")) == {"deny", "gate_no_verify"}
      assert decision(bash(ctx, "git push --no-verify origin main")) == {"deny", "gate_no_verify"}
      assert decision(bash(ctx, ~S(git commit -m "a message"))) == {"defer", "gate_no_rule"}
    end

    test "gate_kill_by_pattern: pkill and killall are denied, kill by PID and grep are not",
         ctx do
      for command <- ["pkill -f phx.server", "pkill beam", "killall postgres", "ls; pkill -f x"] do
        assert decision(bash(ctx, command)) == {"deny", "gate_kill_by_pattern"}, command
      end

      for command <- ["kill 12345", "grep -rn pkill lib", "echo killall"] do
        assert decision(bash(ctx, command)) == {"defer", "gate_no_rule"}, command
      end
    end

    test "gate_push_unclassified: a push from an unclassified repository asks", ctx do
      assert decision(bash(ctx, "git push origin main", ctx.stray)) ==
               {"ask", "gate_push_unclassified"}

      assert decision(bash(ctx, "git push origin main", ctx.private)) == {"defer", "gate_no_rule"}
      assert decision(bash(ctx, "git push origin main")) == {"defer", "gate_no_rule"}
    end

    test "gate_no_rule: anything else defers", ctx do
      assert decision(bash(ctx, "ls -la")) == {"defer", "gate_no_rule"}

      read = Gate.explain(%{"tool" => "Read", "paths" => ["lib/x.ex"], "cwd" => ctx.root})
      assert decision(read) == {"defer", "gate_no_rule"}
    end
  end

  describe "a host table ahead of the seed" do
    setup ctx, do: %{tables: [@host_table, Gate.seed_table()], ctx: ctx}

    test "the first answer that is not defer wins", %{ctx: ctx, tables: tables} do
      allowed = bash(ctx, "git push -f origin HEAD:refs/heads/scratch/mine", nil, tables: tables)
      assert decision(allowed) == {"allow", "host_own_branch"}
      assert [%{rule_id: "host_own_branch"}] = allowed.evaluations

      denied = bash(ctx, "git push -f origin HEAD:refs/heads/main", nil, tables: tables)
      assert decision(denied) == {"deny", "gate_force_push"}

      assert Enum.map(denied.evaluations, & &1.rule_id) == ["host_no_rule", "gate_force_push"]
    end

    test "the narrow allow does not cover a compound command", %{ctx: ctx, tables: tables} do
      command = "git push -f origin HEAD:refs/heads/scratch/mine && git push -f origin main"
      assert decision(bash(ctx, command, nil, tables: tables)) == {"deny", "gate_force_push"}
    end

    test "the narrow allow does not reach a community fork", %{ctx: ctx, tables: tables} do
      result =
        bash(ctx, "git push -f origin HEAD:refs/heads/scratch/mine", ctx.fork, tables: tables)

      assert decision(result) == {"deny", "gate_fork_push"}
    end

    test "paths are matched relative to their repository, and the strictest wins",
         %{ctx: ctx, tables: tables} do
      payload = %{
        "tool" => "Edit",
        "paths" => ["lib/ok.ex", Path.join(ctx.root, "vendored/x.json")],
        "cwd" => ctx.root
      }

      result = Gate.explain(payload, root: ctx.root, tables: tables)
      assert decision(result) == {"deny", "host_vendored"}
      assert result.path == "vendored/x.json"
    end
  end

  describe "the shell's other spellings of a refused act" do
    test "a force push behind git's global options, a quote or an assignment is denied", ctx do
      for command <- [
            "git -c x=y push --force origin main",
            "git --no-pager push -f origin main",
            ~S(git push "--force" origin main),
            "git push origin main --force",
            "FOO=1 git push -f origin main",
            "git${IFS}push${IFS}-f${IFS}origin${IFS}main",
            "git -C $(echo${IFS}/tmp) push -f origin HEAD:refs/heads/x",
            "ls\ngit push -f origin main"
          ] do
        assert decision(bash(ctx, command)) == {"deny", "gate_force_push"}, command
      end
    end

    test "skipping hooks with -n or after a quoted separator is denied", ctx do
      for command <- [
            "git commit -n -m wip",
            "git commit -anm wip",
            ~S(git commit -m "a; b" --no-verify),
            "git -c core.x=y commit --no-verify -m x"
          ] do
        assert decision(bash(ctx, command)) == {"deny", "gate_no_verify"}, command
      end

      for command <- [
            "git commit --no-edit",
            "git push -n origin main",
            "git commit --amend -m x"
          ] do
        assert decision(bash(ctx, command)) == {"defer", "gate_no_rule"}, command
      end
    end

    test "killing by pattern behind a prefix, a newline or a substitution is denied", ctx do
      for command <- [
            "FOO=1 pkill -f beam",
            "timeout 5 pkill -f beam",
            "env -i pkill -f beam",
            "printf x; pkill${IFS}-f${IFS}beam",
            "kill $(pgrep -f phx.server)",
            "kill -9 `pgrep beam`",
            "pgrep -f beam | xargs kill",
            "ls\npkill -f beam",
            "echo $(pkill -f beam)"
          ] do
        assert decision(bash(ctx, command)) == {"deny", "gate_kill_by_pattern"}, command
      end

      for command <- [
            "kill $(lsof -ti :4000)",
            "pgrep -f beam",
            "cat > stop.sh <<'EOF'\npkill -f beam\nEOF\nls",
            "cat <<-EOF\n\tkillall x\n\tEOF"
          ] do
        assert decision(bash(ctx, command)) == {"defer", "gate_no_rule"}, command
      end
    end

    test "a push from a fork is denied however the command gets there", ctx do
      for {command, cwd} <- [
            {"(cd #{ctx.fork} && git push origin main)", ctx.root},
            {"ls && cd #{ctx.fork} && git push origin main", ctx.root},
            {"FOO=1 git push origin main", ctx.fork},
            {"git --no-pager push origin main", ctx.fork}
          ] do
        assert decision(bash(ctx, command, cwd)) == {"deny", "gate_fork_push"}, command
      end
    end

    test "a directory the shell would compute is not known, so a push from it asks", ctx do
      for command <- [
            "git -C $(echo${IFS}#{ctx.fork}) push origin main",
            "git -C `echo #{ctx.fork}` push origin main",
            "cd $(dirname #{ctx.fork}/x) && git push origin main"
          ] do
        assert decision(bash(ctx, command)) == {"ask", "gate_push_unclassified"}, command
      end
    end

    test "the command the tables read" do
      assert Request.command_input("git${IFS}push$IFS-f") == "git push -f"
      assert Request.command_input(~S(g"i"t push '--force' \-f)) == "git push --force -f"
      assert Request.command_input(~S(git commit -m "a; b")) == ~S(git commit -m "a; b")
      assert Request.command_input("ls\npwd") == "ls;pwd"
      assert Request.command_input("echo \"a\nb\"") == "echo \"a\nb\""
      assert Request.command_input("cat <<'EOF' > x\npkill\nEOF\nls") == "cat <<EOF > x;ls"
      assert Request.command_input("ls \\\n -la") == "ls   -la"
      assert Request.command_input(nil) == ""
    end

    test "the directory a command acts in, through subshells and substitutions" do
      assert Request.subject_dir("(cd /b && git push)", "/a") == "/b"
      assert Request.subject_dir("ls && cd /b && cd c; git push", "/a") == "/b/c"
      assert Request.subject_dir("git -c x=y -C /c push", "/a") == "/c"
      assert Request.subject_dir("git -C $(echo /c) push", "/a") == nil
      assert Request.subject_dir("cd `pwd` && git push", "/a") == nil
      assert Request.subject_dir("cd $HOME/x && ls", "/a") == Path.join(System.user_home(), "x")
    end
  end

  describe "paths in a nested worktree" do
    test "are relative to the worktree, not to the checkout around it", ctx do
      tables = [@host_table, Gate.seed_table()]

      payload = %{
        "hook_event_name" => "PreToolUse",
        "tool_name" => "Write",
        "cwd" => ctx.root,
        "tool_input" => %{"file_path" => Path.join(ctx.nested, "vendored/x.json")}
      }

      result = Gate.explain(payload, root: ctx.root, tables: tables)
      assert decision(result) == {"deny", "host_vendored"}
      assert result.path == "vendored/x.json"
      assert [%{path: "vendored/x.json", kind: "first_party"}] = result.request.targets
    end
  end

  describe "MCP tools that do what a built-in does" do
    test "fold into bash, edit or eval by the tool's own name" do
      assert Request.tool_name("mcp__serena__execute_shell_command") == "bash"
      assert Request.tool_name("serena_execute_shell_command") == "bash"
      assert Request.tool_name("mcp__tidewave__project_eval") == "eval"
      assert Request.tool_name("mcp__serena__create_text_file") == "edit"
      assert Request.tool_name("mcp__serena__replace_content") == "edit"
      assert Request.tool_name("mcp__serena__find_symbol") == "mcp__serena__find_symbol"
    end

    test "a shell tool's command and a file tool's path meet the same rules", ctx do
      tables = [@host_table, Gate.seed_table()]

      shell = %{
        "hook_event_name" => "PreToolUse",
        "tool_name" => "mcp__serena__execute_shell_command",
        "cwd" => ctx.root,
        "tool_input" => %{"command" => "git push --force origin main"}
      }

      assert decision(Gate.explain(shell, root: ctx.root, tables: tables)) ==
               {"deny", "gate_force_push"}

      in_fork =
        put_in(shell, ["tool_input"], %{"command" => "git push origin main", "cwd" => ctx.fork})

      assert decision(Gate.explain(in_fork, root: ctx.root, tables: tables)) ==
               {"deny", "gate_fork_push"}

      write = %{
        "hook_event_name" => "PreToolUse",
        "tool_name" => "mcp__serena__create_text_file",
        "cwd" => ctx.root,
        "tool_input" => %{"relative_path" => "vendored/x.json", "content" => "{}"}
      }

      assert decision(Gate.explain(write, root: ctx.root, tables: tables)) ==
               {"deny", "host_vendored"}
    end

    test "an eval tool asks: no command pattern can read the code", ctx do
      eval = %{
        "hook_event_name" => "PreToolUse",
        "tool_name" => "mcp__tidewave__project_eval",
        "cwd" => ctx.root,
        "tool_input" => %{"code" => ~S|System.cmd("git", ["push", "-f", "origin", "main"])|}
      }

      assert decision(Gate.explain(eval, root: ctx.root)) == {"ask", "gate_eval"}
    end
  end

  describe "errors are asks, never allows" do
    test "a table that does not exist", ctx do
      result = bash(ctx, "ls", nil, tables: [Path.join(ctx.root, "missing.dmn")])
      assert decision(result) == {"ask", "gate_error"}
    end

    test "a payload with no tool still answers", ctx do
      assert %{decision: "defer"} = Gate.explain(%{"nonsense" => true}, root: ctx.root)
    end
  end

  describe "the audit log" do
    test "check/2 appends the decision, the table's hash and the matched rules", ctx do
      log = Path.join(ctx.root, ".agents/logs/gate-#{System.unique_integer([:positive])}.jsonl")

      Gate.check(%{"tool" => "Bash", "command" => "ls", "cwd" => ctx.root},
        root: ctx.root,
        log: log
      )

      Gate.check(%{"tool" => "Bash", "command" => "git push -f origin main", "cwd" => ctx.root},
        root: ctx.root,
        log: log
      )

      [deferred, denied] =
        log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      seed_hash =
        :crypto.hash(:sha256, File.read!(Gate.seed_table())) |> Base.encode16(case: :lower)

      assert %{
               "decision" => "defer",
               "rule_id" => "gate_no_rule",
               "definition_hash" => ^seed_hash,
               "matched_rule_ids" => ["gate_no_rule"]
             } = deferred

      assert %{"decision" => "deny", "rule_id" => "gate_force_push", "command" => cmd} = denied
      assert cmd == "git push -f origin main"
      assert "gate_force_push" in denied["matched_rule_ids"]
    end

    test "explain/2 writes nothing", ctx do
      bash(ctx, "ls")
      refute File.exists?(Path.join(ctx.root, ".agents/logs/gate.jsonl"))
    end
  end

  describe "normalising harness payloads" do
    test "Claude Code PreToolUse input", ctx do
      request =
        Request.normalize(%{
          "hook_event_name" => "PreToolUse",
          "session_id" => "s1",
          "cwd" => ctx.root,
          "tool_name" => "MultiEdit",
          "tool_input" => %{"file_path" => Path.join(ctx.root, "lib/a.ex")}
        })

      assert %{harness: "claude_code", tool: "edit", session_id: "s1"} = request
      assert request.targets == [%{path: "lib/a.ex", kind: nil}]
    end

    test "opencode tool.execute.before arguments, including a patch", ctx do
      request =
        Request.normalize(
          %{
            "harness" => "opencode",
            "tool" => "patch",
            "sessionID" => "s2",
            "directory" => ctx.root,
            "args" => %{
              "patchText" => "*** Begin Patch\n*** Update File: lib/b.ex\n@@\n*** End Patch"
            }
          },
          %{"first_party" => ["example\\.test/first/"]}
        )

      assert %{harness: "opencode", tool: "edit", session_id: "s2"} = request
      assert request.targets == [%{path: "lib/b.ex", kind: "first_party"}]
    end

    test "a worktree is classified by its repository's shared config", ctx do
      config = %{"first_party" => ["example\\.test/first/"]}
      assert Request.repo_for(ctx.worktree, config) == %{root: ctx.worktree, kind: "first_party"}

      assert Request.repo_for(Path.join(ctx.root, "lib/not/yet"), config) ==
               %{root: ctx.root, kind: "first_party"}

      assert Request.repo_for(System.tmp_dir!(), config) == %{root: nil, kind: nil}
    end

    test "the directory a command acts in" do
      assert Request.subject_dir("ls", "/a") == "/a"
      assert Request.subject_dir("cd /b && ls", "/a") == "/b"
      assert Request.subject_dir("cd sub; git push", "/a") == "/a/sub"
      assert Request.subject_dir("git -C '/c d' push", "/a") == "/c d"
      assert Request.subject_dir("cd /b && git -C sub push", "/a") == "/b/sub"
    end
  end

  test "the Claude Code hook output" do
    deny = %{decision: "deny", reason: "No.", rule_id: "r"}

    assert %{
             "hookSpecificOutput" => %{
               "hookEventName" => "PreToolUse",
               "permissionDecision" => "deny",
               "permissionDecisionReason" => "No. (gate rule r)"
             }
           } = Gate.claude_code_output(deny)

    assert Gate.claude_code_output(%{deny | decision: "ask"})["hookSpecificOutput"][
             "permissionDecision"
           ] == "ask"

    assert Gate.claude_code_output(%{deny | decision: "allow"}) == %{}
    assert Gate.claude_code_output(%{deny | decision: "defer"}) == %{}
  end

  property "benign reads are never denied", ctx do
    benign =
      StreamData.member_of([
        "ls",
        "ls -la lib",
        "git status",
        "git log --oneline -5",
        "git diff",
        "cat mix.exs",
        "grep -rn pkill lib",
        "devenv shell -- mix test",
        "devenv shell -- mix test test/a_test.exs --max-cases 4",
        "rg 'git push -f' docs"
      ])

    check all(command <- benign, max_runs: 50) do
      refute bash(ctx, command).decision == "deny"
    end
  end
end
