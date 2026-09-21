# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

# Compiled conditionally (the same pattern as `AshAgentTools.Mcp.Plug`):
# `file_system` is an *optional* dependency, so a host that does not ship it
# still compiles this package cleanly. `AshAgentTools.Daemon.Supervisor`
# gates the child on `Code.ensure_loaded?/1` and logs the degradation —
# `ash_reload` remains the manual backstop.
if Code.ensure_loaded?(FileSystem) do
  defmodule AshAgentTools.Daemon.Watcher do
    @moduledoc """
    Watches the project's `lib/` and `config/` trees and funnels file events
    into `AshAgentTools.Daemon.Runtime.request_reload_async/1`, with a short
    debounce so an editor's multi-file save is one reload, not N.

    The `file_system` package is an **optional** dependency (it arrives via
    `phoenix_live_reload` in most Phoenix apps, or can be declared
    directly): when it is not loadable this module simply does not compile
    into the host, the supervisor starts without hot reload, and the
    `ash_reload` tool covers reloads by hand. This keeps the package's
    no-hard-dep story intact.
    """

    use GenServer

    require Logger

    @debounce_ms 300
    @default_watch_dirs ["lib", "config"]

    @doc """
    Starts the watcher. Options:

      * `:name` — GenServer name (default `#{inspect(__MODULE__)}`)
      * `:runtime` — the runtime server to notify (default
        `AshAgentTools.Daemon.Runtime`)
      * `:dirs` — directories to watch (default `["lib", "config"]`
        relative to the cwd the daemon booted in); existing directories only
      * `:debounce_ms` — event debounce (default `300`)

    Returns `{:ok, pid}`, or `:ignore` when there is nothing to watch.
    """
    @spec start_link(keyword()) :: {:ok, pid()} | :ignore | {:error, term()}
    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    end

    @impl GenServer
    def init(opts) do
      runtime = Keyword.get(opts, :runtime, AshAgentTools.Daemon.Runtime)
      backend_name = Module.concat(Keyword.get(opts, :name, __MODULE__), Backend)

      dirs =
        opts
        |> Keyword.get_lazy(:dirs, fn -> @default_watch_dirs end)
        |> Enum.map(&Path.absname/1)
        |> Enum.filter(&File.dir?/1)

      case dirs do
        [] ->
          Logger.info("ash_agent daemon: no watch directories found — hot reload disabled")
          :ignore

        dirs ->
          # A backend that cannot bootstrap (e.g. inotifywait missing or
          # unrunnable) must not crash-loop the daemon: degrade to :ignore
          # and leave `ash_reload` as the manual backstop.
          case FileSystem.start_link(dirs: dirs, name: backend_name) do
            {:ok, backend} ->
              :ok = FileSystem.subscribe(backend)

              Logger.info("ash_agent daemon: watching #{inspect(dirs)} for changes")

              {:ok,
               %{
                 timer: nil,
                 runtime: runtime,
                 debounce_ms: Keyword.get(opts, :debounce_ms, @debounce_ms),
                 dirs: dirs
               }}

            :ignore ->
              Logger.warning(
                "ash_agent daemon: file_system backend unavailable — hot reload disabled; " <>
                  "use the ash_reload tool as the manual backstop"
              )

              :ignore

            {:error, reason} ->
              Logger.warning(
                "ash_agent daemon: file_system worker failed to start (#{inspect(reason)}) — " <>
                  "hot reload disabled; use the ash_reload tool as the manual backstop"
              )

              :ignore
          end
      end
    end

    @impl GenServer
    def handle_info({:file_event, _backend, {_path, _events}}, state) do
      # Debounce: cancel the pending timer and restart the window, so a
      # burst of save events collapses into one reload when it settles.
      if is_reference(state.timer), do: Process.cancel_timer(state.timer)
      timer = Process.send_after(self(), :reload, state.debounce_ms)
      {:noreply, %{state | timer: timer}}
    end

    def handle_info(:reload, state) do
      AshAgentTools.Daemon.Runtime.request_reload_async(state.runtime)
      {:noreply, %{state | timer: nil}}
    end

    def handle_info({:file_event, _backend, :stop}, state) do
      # The backend stopped (shutdown); nothing to do — the supervisor
      # tears us down together.
      {:noreply, state}
    end
  end
end
