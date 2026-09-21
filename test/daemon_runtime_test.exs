# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Daemon.RuntimeTest do
  use ExUnit.Case, async: true

  # The runtime boots `boot?: false` in tests: the modules under test are
  # already loaded (test_helper.exs ensures the support domain/resources),
  # and a compile-only mix boot inside a test adds nothing but seconds.
  # Each test gets its own named GenServer, so tests stay `async: true`.

  alias AshAgentTools.Daemon.Runtime

  defp start_runtime(opts \\ []) do
    name = Module.concat([__MODULE__, "Runtime", "n#{System.unique_integer([:positive])}"])

    opts =
      opts
      |> Keyword.put(:name, name)
      |> Keyword.put(:boot?, false)

    start_supervised!({Runtime, opts})
    name
  end

  describe "boot state" do
    test "starts with a fresh discovery snapshot and empty cache" do
      server = start_runtime()
      status = Runtime.status(server)

      assert status.status == :ready
      assert %DateTime{} = status.booted_at
      assert %DateTime{} = status.compiled_at
      assert status.reloads == 0
      assert status.cache_entries == 0
      assert is_integer(status.beam_memory_bytes) and status.beam_memory_bytes > 0

      discovery = Runtime.discovery(server)
      assert discovery.resource_count >= 1
      assert "AshAgentTools.Test.Post" in discovery.resources
      assert "AshAgentTools.Test.Domain" in discovery.domains
    end
  end

  describe "describe/3 — the checksum-keyed cache" do
    test "serves the resource report and caches it" do
      server = start_runtime()

      {:ok, report} = Runtime.describe(server, AshAgentTools.Test.Post)
      assert report.module == AshAgentTools.Test.Post
      assert Runtime.status(server).cache_entries == 1

      # A repeat call is served from the cache (same report, no new entry).
      {:ok, ^report} = Runtime.describe(server, AshAgentTools.Test.Post)
      assert Runtime.status(server).cache_entries == 1
    end

    test "caches per {module, action}" do
      server = start_runtime()

      {:ok, _resource} = Runtime.describe(server, AshAgentTools.Test.Post)
      {:ok, _action} = Runtime.describe(server, AshAgentTools.Test.Post, :create)

      assert Runtime.status(server).cache_entries == 2
    end

    test "unknown actions come back as structured errors and are not cached" do
      server = start_runtime()

      {:error, error} = Runtime.describe(server, AshAgentTools.Test.Post, "creat")

      assert error.error =~ "no action named"
      assert "create" in error.did_you_mean
      assert Runtime.status(server).cache_entries == 0
    end

    test "unknown resources come back as structured errors" do
      server = start_runtime()

      {:error, error} = Runtime.describe(server, AshAgentTools.Test.Nope)
      assert error.error =~ "is not a loaded Ash resource"

      {:error, error} = Runtime.describe(server, String)
      assert error.error =~ "is not a loaded Ash resource"
    end
  end

  describe "reload — the serialized mutex + cache invalidation" do
    test "reload invalidates the cache, bumps counters, and emits telemetry" do
      server = start_runtime()
      {:ok, _} = Runtime.describe(server, AshAgentTools.Test.Post)
      assert Runtime.status(server).cache_entries == 1

      test_pid = self()
      handler_id = "runtime-test-#{System.unique_integer()}"
      ref = make_ref()

      :ok =
        :telemetry.attach(
          handler_id,
          Runtime.reloaded_event(),
          fn event, measurements, metadata, ^ref ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          ref
        )

      status = Runtime.request_reload(server)

      assert status.reloads == 1
      assert status.cache_entries == 0
      assert status.resource_count >= 1
      assert DateTime.compare(status.compiled_at, status.booted_at) in [:gt, :eq]

      assert_receive {:telemetry, [:ash_agent, :daemon, :reloaded], measurements, metadata}
      assert measurements.resource_count == status.resource_count
      assert is_integer(measurements.duration_ms)
      assert metadata.trigger == :manual

      # The cache repopulates on the next describe after invalidation.
      {:ok, _} = Runtime.describe(server, AshAgentTools.Test.Post)
      assert Runtime.status(server).cache_entries == 1

      :telemetry.detach(handler_id)
    end

    test "async reload (the watcher's entry point) runs serialized in the server" do
      server = start_runtime()
      {:ok, _} = Runtime.describe(server, AshAgentTools.Test.Post)

      :ok = Runtime.request_reload_async(server)

      # The cast is processed before our next call on the same server.
      status = Runtime.status(server)
      assert status.reloads == 1
      assert status.cache_entries == 0
    end

    test "reload refreshes the discovery snapshot" do
      server = start_runtime()

      before = Runtime.discovery(server)
      Runtime.request_reload(server)
      after_reload = Runtime.discovery(server)

      assert after_reload.resource_count == before.resource_count
      assert "AshAgentTools.Test.Comment" in after_reload.resources
    end
  end
end
