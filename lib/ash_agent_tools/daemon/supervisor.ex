# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Daemon.Supervisor do
  @moduledoc """
  The `mix ash_agent.serve` daemon's supervision tree — one_for_one:

  ```
  AshAgentTools.Daemon.Supervisor            (one_for_one; started by the task)
  ├── AshAgentTools.Daemon.Runtime           (compile-only boot; caches; reload mutex)
  ├── AshAgentTools.Daemon.Watcher           (lib/ + config/ → debounced reload)
  │                                           (only when :file_system is available)
  └── Bandit                                 (AshAgentTools.Mcp.Plug on 127.0.0.1:4100)
  ```

  Options (also configurable via `config :ash_agent_tools, :daemon, []`,
  CLI flags win):

    * `:port` — listen port (default `4100`)
    * `:ip` — bind address (default `{127, 0, 0, 1}`; loopback only — the
      daemon is a dev tool with no auth)
    * `:watch_dirs` — watcher directories (default `["lib", "config"]`)
    * `:watch?` — start the watcher at all (default `true`)
    * `:http?` — start Bandit (default `true`; tests may pass `false`)

  Every optional piece is gated: without `plug`/`bandit` (both optional
  deps) `start_link/1` raises a pointed `ArgumentError` before anything
  starts; without `file_system` the watcher simply does not join the tree.
  """

  use Supervisor

  require Logger

  @default_port 4100
  @default_ip {127, 0, 0, 1}

  @doc """
  Starts the daemon supervision tree. Raises `ArgumentError` with install
  hints when the optional HTTP dependencies are missing.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    ensure_http_deps!(opts)
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The effective daemon configuration (defaults ← app env `:daemon` key ←
  options), useful for tests and the startup banner. `:watch_dirs` is nil
  when unset (the watcher falls back to its own defaults).
  """
  @spec config(keyword()) :: %{
          port: :inet.port_number(),
          ip: :inet.ip_address(),
          watch?: boolean(),
          watch_dirs: [String.t()] | nil
        }
  def config(opts \\ []) do
    env = Application.get_env(:ash_agent_tools, :daemon, [])

    %{
      port: Keyword.get(opts, :port, Keyword.get(env, :port, @default_port)),
      ip: Keyword.get(opts, :ip, Keyword.get(env, :ip, @default_ip)),
      watch?: Keyword.get(opts, :watch?, Keyword.get(env, :watch?, true)),
      watch_dirs: Keyword.get(opts, :watch_dirs, Keyword.get(env, :watch_dirs))
    }
  end

  @impl Supervisor
  def init(opts) do
    cfg = config(opts)

    # The supervisor's :name opt must not leak into the child (it would
    # collide with the supervisor's own registration); the Runtime keeps its
    # default name unless explicitly overridden (useful for tests).
    runtime_opts =
      opts
      |> Keyword.take([:boot?])
      |> Keyword.put(:name, Keyword.get(opts, :runtime_name, AshAgentTools.Daemon.Runtime))

    watcher_opts =
      case cfg.watch_dirs do
        nil -> []
        dirs -> [dirs: dirs]
      end

    children =
      [
        {AshAgentTools.Daemon.Runtime, runtime_opts}
      ] ++
        watcher_child(watcher_opts, cfg.watch?) ++
        http_child(cfg, opts)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp watcher_child(_opts, false), do: []

  defp watcher_child(opts, true) do
    if Code.ensure_loaded?(AshAgentTools.Daemon.Watcher) do
      [{AshAgentTools.Daemon.Watcher, opts}]
    else
      Logger.info(
        "ash_agent daemon: :file_system not available — starting without hot reload; " <>
          "the ash_reload tool is the manual backstop"
      )

      []
    end
  end

  defp http_child(cfg, opts) do
    if Keyword.get(opts, :http?, true) do
      [
        %{
          id: Bandit,
          start:
            {Bandit, :start_link, [[plug: AshAgentTools.Mcp.Plug, ip: cfg.ip, port: cfg.port]]},
          type: :worker
        }
      ]
    else
      []
    end
  end

  defp ensure_http_deps!(opts) do
    if Keyword.get(opts, :http?, true) do
      missing =
        for {module, package} <- [{Plug, :plug}, {Bandit, :bandit}],
            not Code.ensure_loaded?(module) do
          {module, package}
        end

      case missing do
        [] ->
          :ok

        missing ->
          modules = Enum.map(missing, fn {module, _package} -> inspect(module) end)

          packages =
            Enum.map_join(missing, ", ", fn {_module, package} ->
              "{:#{package}, optional: true}"
            end)

          raise ArgumentError,
                "the ash_agent daemon needs its optional HTTP deps, not installed here: " <>
                  Enum.join(modules, ", ") <>
                  ". Add #{packages} to your deps (or run the daemon from a project " <>
                  "that has them — Phoenix apps do)."
      end
    end
  end
end
