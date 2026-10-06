# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.MixTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshAgentTools.MixTask

  test "run parses common and task-specific options after compile-only boot" do
    test_pid = self()

    MixTask.run(
      ["resource", "--action", "create", "--pretty"],
      fn positional, opts ->
        send(test_pid, {:parsed, positional, opts})
      end,
      action: :string
    )

    assert_receive {:parsed, ["resource"], opts}
    assert opts[:action] == "create"
    assert opts[:pretty]
  end

  test "write_json emits compact JSON by default" do
    output = capture_io(fn -> MixTask.write_json(%{valid?: true}, []) end)

    assert Jason.decode!(output) == %{"valid?" => true}
  end

  test "emit_json_error preserves the structured error contract" do
    output = capture_io(fn -> MixTask.emit_json_error(%{error: "bad input"}, []) end)

    assert Jason.decode!(output) == %{"error" => "bad input", "is_error?" => true}
  end
end
