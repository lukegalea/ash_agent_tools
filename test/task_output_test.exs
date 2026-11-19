# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.TaskOutputTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshAgentTools.TaskOutput

  # AST-154. `ensure_compiled/0` used to silence compile chatter by swapping
  # the *global* `Mix.shell/0` to `Mix.Shell.Quiet` and restoring what it had
  # read first. Two overlapping calls (async tests, the daemon's reloads, a
  # Mix task running beside either) could each read the other's `Quiet` as
  # the "previous" shell and leave it installed for good — after which every
  # `Mix.shell().info/1` in the VM printed nothing, whichever test came next.

  describe "quiet compile boot" do
    @tag ac: "AST-154/AC-1"
    test "overlapping callers leave the global Mix shell exactly as they found it" do
      shell = Mix.shell()

      for _round <- 1..25 do
        1..16
        |> Enum.map(fn _ -> Task.async(&TaskOutput.ensure_compiled/0) end)
        |> Task.await_many(60_000)

        assert Mix.shell() == shell
      end
    end

    @tag ac: "AST-154/AC-2"
    test "a bystander's shell output is never swallowed while another process boots" do
      booter =
        Task.async(fn ->
          for _ <- 1..200, do: TaskOutput.ensure_compiled()
        end)

      outputs =
        for _ <- 1..200 do
          capture_io(fn -> Mix.shell().info("still here") end)
        end

      Task.await(booter, 60_000)

      assert Enum.all?(outputs, &(&1 == "still here\n"))
    end

    test "quietly/1 swallows the shell chatter of its own process" do
      shell = Mix.shell()

      leaked =
        capture_io(fn ->
          assert :done == TaskOutput.quietly(fn -> Mix.shell().info("compiling...") && :done end)
        end)

      assert leaked == ""
      assert Mix.shell() == shell
    end

    test "quietly/1 puts the caller's group leader back, even when the function raises" do
      leader = Process.group_leader()

      assert_raise RuntimeError, "boom", fn -> TaskOutput.quietly(fn -> raise "boom" end) end

      assert Process.group_leader() == leader
    end
  end
end
