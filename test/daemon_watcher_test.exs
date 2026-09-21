# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Daemon.WatcherTest do
  use ExUnit.Case, async: true

  # The watcher is a thin debounce in front of the runtime's reload. This
  # test drives a real file event through a real `file_system` backend
  # pointed at a temp dir, with a near-zero debounce, and listens for the
  # reload telemetry on a private runtime instance. Unique names everywhere
  # keep the test `async: true`.

  alias AshAgentTools.Daemon.{Runtime, Watcher}

  defp unique, do: System.unique_integer([:positive])

  defp start_watched_runtime do
    suffix = unique()
    runtime_name = Module.concat([__MODULE__, "Runtime", "n#{suffix}"])
    watcher_name = Module.concat([__MODULE__, "Watcher", "n#{suffix}"])
    dir = Path.join(System.tmp_dir!(), "ash_agent_watcher_test_#{suffix}")
    File.mkdir_p!(dir)

    start_supervised!({Runtime, name: runtime_name, boot?: false})

    start_supervised!(
      {Watcher, name: watcher_name, runtime: runtime_name, dirs: [dir], debounce_ms: 5}
    )

    %{runtime: runtime_name, watcher: watcher_name, dir: dir}
  end

  @tag :watcher
  test "a file event in a watched dir triggers a debounced runtime reload" do
    %{dir: dir} = start_watched_runtime()

    test_pid = self()
    ref = make_ref()
    handler_id = "watcher-test-#{unique()}"

    :ok =
      :telemetry.attach(
        handler_id,
        Runtime.reloaded_event(),
        fn event, measurements, metadata, ^ref ->
          send(test_pid, {:reloaded, event, measurements, metadata})
        end,
        ref
      )

    File.write!(Path.join(dir, "change.ex"), ":changed\n")

    assert_receive {:reloaded, [:ash_agent, :daemon, :reloaded], _measurements,
                    %{trigger: :watcher}},
                   5_000

    :telemetry.detach(handler_id)
  end

  @tag :watcher
  test "a burst of writes collapses into a small number of reloads" do
    %{runtime: runtime_name, dir: dir} = start_watched_runtime()

    test_pid = self()
    ref = make_ref()
    handler_id = "watcher-test-#{unique()}"

    :ok =
      :telemetry.attach(
        handler_id,
        Runtime.reloaded_event(),
        fn event, measurements, metadata, ^ref ->
          send(test_pid, {:reloaded, event, measurements, metadata})
        end,
        ref
      )

    for i <- 1..10, do: File.write!(Path.join(dir, "burst.ex"), "n = #{i}\n")

    assert_receive {:reloaded, _, _, %{trigger: :watcher}}, 5_000

    # The debounce should have eaten most of the burst; allow a couple of
    # stragglers for backend event-delivery jitter, but not ten.
    assert Runtime.status(runtime_name).reloads in 1..4

    :telemetry.detach(handler_id)
  end
end
