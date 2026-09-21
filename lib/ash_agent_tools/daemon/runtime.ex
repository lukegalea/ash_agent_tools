# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Daemon.Runtime do
  @moduledoc """
  The `mix ash_agent.serve` daemon's compiled-context owner.

  A single GenServer that boots the project **compile-only** (the same
  `app.config` + compile + `load_configured_domains/0` contract the
  introspection mix tasks enforce — the application is never started), then
  owns everything derived from compiled state:

    * the discovery summary (loaded domains + resources)
    * a per-module describe cache, keyed by `{module, action, beam checksum}`,
      so repeated tool calls are in-memory reads and a recompile invalidates
      stale entries automatically
    * the reload mutex: recompiles are serialized behind this process, so a
      file change can never race a tool call's module access

  `AshAgentTools.Daemon.Watcher` (file events) and the `ash_reload` tool both
  funnel into `request_reload/2` / `request_reload_async/1`; every successful
  reload emits the `[:ash_agent, :daemon, :reloaded]` telemetry event with the
  resource count and trigger, and logs the resource-count delta.

  This is deliberately a *different* module from `AshAgentTools.Runtime`
  (the read-only BEAM snapshot API) — the daemon namespace keeps the two
  "runtime" meanings apart.
  """

  use GenServer

  require Logger

  alias AshAgentTools.Describe
  alias AshAgentTools.Registry
  alias AshAgentTools.TaskOutput

  @telemetry_event [:ash_agent, :daemon, :reloaded]

  # A reload runs `Mix.Task.run("compile")`, which on a cold project can take
  # a while; the default call timeout gives it room without hanging forever.
  @default_reload_timeout 120_000

  # -- client API ----------------------------------------------------------

  @doc """
  Starts the runtime. Options:

    * `:name` — the GenServer name (default `#{inspect(__MODULE__)}`)
    * `:boot?` — run the compile-only boot in `init/1` (default `true`;
      tests can pass `false` to start against already-loaded modules)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The daemon status report: boot time, last reload, discovery counts, cache
  size, reload count, and total BEAM memory (staleness made visible).
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc """
  The discovery summary: counts plus sorted loaded domains and resources
  (as strings). Served from the boot-time snapshot; a reload refreshes it.
  """
  @spec discovery(GenServer.server()) :: map()
  def discovery(server \\ __MODULE__) do
    GenServer.call(server, :discovery)
  end

  @doc """
  Describes `module` — optionally just `action` — through the checksum-keyed
  cache.

  Returns `{:ok, report}` on a hit or fresh compute, or
  `{:error, %{error: message, did_you_mean: candidates}}` for the structured
  unknown-resource/unknown-action failures the mix tasks already emit. All
  module access happens inside this process, so a concurrent reload cannot
  race the read.
  """
  @spec describe(GenServer.server(), module(), atom() | String.t() | nil) ::
          {:ok, map()} | {:error, %{error: String.t(), did_you_mean: [String.t()]}}
  def describe(server \\ __MODULE__, module, action \\ nil) do
    GenServer.call(server, {:describe, module, action})
  end

  @doc """
  Reloads synchronously: re-runs the compile-only boot, refreshes the
  discovery snapshot, and invalidates the describe cache. This is the
  `ash_reload` tool's backstop for watcher misses (git stash edge cases and
  friends). Returns the fresh status report.
  """
  @spec request_reload(GenServer.server(), keyword()) :: map()
  def request_reload(server \\ __MODULE__, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_reload_timeout)
    GenServer.call(server, {:reload, :manual}, timeout)
  end

  @doc """
  Fire-and-forget reload — the file watcher's entry point. The work still
  runs serialized inside the runtime process; concurrent tool calls simply
  queue behind it.
  """
  @spec request_reload_async(GenServer.server()) :: :ok
  def request_reload_async(server \\ __MODULE__) do
    GenServer.cast(server, {:reload, :watcher})
  end

  @doc """
  The telemetry event emitted after every successful reload:
  `[:ash_agent, :daemon, :reloaded]`.
  """
  @spec reloaded_event() :: [atom()]
  def reloaded_event, do: @telemetry_event

  # -- server callbacks ----------------------------------------------------

  @impl GenServer
  def init(opts) do
    state =
      if Keyword.get(opts, :boot?, true) do
        boot()
      else
        fresh_state()
      end

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, status_report(state), state}
  end

  def handle_call(:discovery, _from, state) do
    {:reply, state.discovery, state}
  end

  def handle_call({:describe, module, action}, _from, state) do
    checksum = beam_checksum(module)

    case Map.get(state.cache, {module, action}) do
      %{checksum: ^checksum} = entry ->
        {:reply, {:ok, entry.report}, state}

      _ ->
        case run_describe(module, action) do
          {:ok, report} ->
            entry = %{checksum: checksum, report: report}
            cache = Map.put(state.cache, {module, action}, entry)
            {:reply, {:ok, report}, %{state | cache: cache}}

          {:error, _} = error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:reload, trigger}, _from, state) do
    {:reply, status_report(reload(state, trigger)), state}
  end

  @impl GenServer
  def handle_cast({:reload, trigger}, state) do
    {:noreply, reload(state, trigger)}
  end

  # -- internals -----------------------------------------------------------

  # The compile-only boot, exactly as the mix tasks enforce it: configure,
  # compile, load the configured domains — never start the application.
  defp boot do
    TaskOutput.ensure_compiled()
    TaskOutput.load_configured_domains()
    fresh_state()
  end

  defp fresh_state do
    %{
      booted_at: DateTime.utc_now(),
      compiled_at: DateTime.utc_now(),
      discovery: discovery_summary(),
      cache: %{},
      reloads: 0
    }
  end

  defp reload(state, trigger) do
    started = System.monotonic_time(:millisecond)
    before_count = state.discovery[:resource_count]

    TaskOutput.ensure_compiled()
    TaskOutput.load_configured_domains()

    new_state = %{
      state
      | compiled_at: DateTime.utc_now(),
        discovery: discovery_summary(),
        cache: %{},
        reloads: state.reloads + 1
    }

    duration_ms = System.monotonic_time(:millisecond) - started
    after_count = new_state.discovery[:resource_count]

    Logger.info(
      "ash_agent daemon reloaded (trigger: #{trigger}) in #{duration_ms}ms: " <>
        "#{after_count} resources (delta: #{after_count - before_count}); " <>
        "#{map_size(state.cache)} cached entries invalidated"
    )

    # Best-effort, like Kaizen.emit: telemetry being down (or a broken
    # handler) must never fail a reload.
    try do
      :telemetry.execute(
        @telemetry_event,
        %{duration_ms: duration_ms, resource_count: after_count},
        %{
          trigger: trigger
        }
      )
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    new_state
  end

  defp status_report(state) do
    %{
      status: :ready,
      booted_at: state.booted_at,
      compiled_at: state.compiled_at,
      reloads: state.reloads,
      domain_count: state.discovery[:domain_count],
      resource_count: state.discovery[:resource_count],
      cache_entries: map_size(state.cache),
      beam_memory_bytes: :erlang.memory(:total)
    }
  end

  defp discovery_summary do
    domains = Registry.list_domains()
    resources = Registry.list_resources()

    %{
      domain_count: length(domains),
      resource_count: length(resources),
      domains: Enum.map(domains, &Registry.module_name/1),
      resources: Enum.map(resources, &Registry.module_name/1)
    }
  end

  defp run_describe(module, action) do
    # The lazy-load / purge window: a reload may have replaced the module
    # between the caller's checkout and this read. ensure_loaded/1 is cheap
    # when already loaded and bounds the race (retry-once semantics fall out
    # of the next tool call re-computing the entry).
    Code.ensure_loaded(module)

    case action do
      nil -> {:ok, AshAgentTools.describe_resource(module)}
      action -> {:ok, AshAgentTools.describe_action(module, action)}
    end
  rescue
    error in ArgumentError ->
      {:error, structured_error(error, module, action)}

    error ->
      # Never let an unexpected failure (a purge race, a malformed DSL edge)
      # take the daemon down: report it as a structured error instead.
      Logger.error("ash_agent daemon describe failed: #{Exception.format(:error, error)}")

      {:error, %{error: "describe failed: #{Exception.format(:error, error)}", did_you_mean: []}}
  end

  # The mix tasks' structured-error shape: the ArgumentError message plus
  # did_you_mean candidates from the real action list.
  defp structured_error(error, module, action) do
    did_you_mean =
      if is_binary(action) or is_atom(action),
        do: Describe.action_did_you_mean(module, action),
        else: []

    %{error: Exception.message(error), did_you_mean: did_you_mean}
  end

  # The cache key includes the compiled beam's checksum, so a recompile
  # invalidates the affected entry even if a reload was somehow skipped.
  defp beam_checksum(module) do
    case :code.which(module) do
      path when is_list(path) ->
        case path |> List.to_string() |> File.read() do
          {:ok, beam} -> Base.encode16(:erlang.md5(beam))
          _ -> fallback_checksum(module)
        end

      _ ->
        fallback_checksum(module)
    end
  end

  defp fallback_checksum(module), do: Base.encode16(:erlang.md5(:erlang.term_to_binary(module)))
end
