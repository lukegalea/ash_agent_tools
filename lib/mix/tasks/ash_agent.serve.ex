# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Serve do
  @shortdoc "Serve the Ash introspection MCP daemon (read-only)"

  @moduledoc """
  Starts the supervised MCP daemon: a loopback HTTP endpoint exposing the
  `AshAgentTools` facade as MCP tools (`ash_describe`, `ash_validate`,
  `ash_search`, `ash_context`, `ash_forbidden`, `ash_daemon_status`,
  `ash_reload`), then blocks until interrupted.

  **Boot contract: compile, don't start** — the same contract as the other
  `ash_agent` tasks. The daemon configures and compiles the project and
  loads the configured domains (`config :my_app, ash_domains: [...]`) but
  *never starts the application*: no Oban queues, no projectors, no
  endpoints. The mix boot is paid once here; every tool call afterwards is
  an in-memory read.

  **Loopback only.** The default bind address is `127.0.0.1` (configurable,
  but the daemon is a dev tool with no auth — do not expose it). An
  optional `config :ash_agent_tools, :daemon, port: ...` overrides the
  port; CLI flags win.

  Requires the optional `plug` and `bandit` deps for the HTTP surface
  (Phoenix apps have both) and `file_system` for hot reload; without them
  you get a pointed error (or a daemon without hot reload, respectively).

  ## Usage

      mix ash_agent.serve
      mix ash_agent.serve --port 4200

  ## Command line options

    * `--port N` - listen port (default `4100`, or the configured `:port`)
    * `--no-watch` - start without the file watcher (manual `ash_reload` only)

  Once it is up, point an MCP client at `http://127.0.0.1:4100`:

      $ curl -s -X POST http://127.0.0.1:4100 \\
          -H 'content-type: application/json' \\
          -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
  """

  use Mix.Task

  # Compile-only boot: introspection needs compiled DSL state, not a
  # running application (see the moduledoc and usage-rules.md).
  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args, strict: [port: :integer, no_watch: :boolean])

    AshAgentTools.TaskOutput.ensure_compiled()
    AshAgentTools.TaskOutput.load_configured_domains()

    # The kaizen dev sink: tool gaps become the daemon's fire-rate metric.
    AshAgentTools.Kaizen.attach()

    overrides =
      opts
      |> Keyword.take([:port])
      |> Keyword.merge(watch?: not Keyword.get(opts, :no_watch, false))

    case AshAgentTools.Daemon.Supervisor.start_link(overrides) do
      {:ok, _supervisor} ->
        cfg = AshAgentTools.Daemon.Supervisor.config(overrides)
        banner(cfg)
        Process.sleep(:infinity)

      {:error, {:already_started, _pid}} ->
        Mix.raise("The ash_agent daemon is already running in this VM")

      {:error, reason} ->
        Mix.raise("Failed to start the ash_agent daemon: #{inspect(reason)}")
    end
  end

  defp banner(cfg) do
    resources = AshAgentTools.list_resources()
    domains = AshAgentTools.list_domains()

    Mix.shell().info("""
    ash_agent daemon listening on http://#{ip_string(cfg.ip)}:#{cfg.port} (POST-only MCP, read-only)

      boot:   compile-only (application not started)
      watch:  #{if cfg.watch?, do: "hot reload on lib/ + config/ changes", else: "disabled (--no-watch)"}
      loaded: #{length(domains)} domain(s), #{length(resources)} resource(s)

      tools:  ash_describe, ash_validate, ash_search, ash_context, ash_forbidden, ash_daemon_status, ash_reload

    Point your MCP client at http://#{ip_string(cfg.ip)}:#{cfg.port} (e.g. a "type": "http" .mcp.json entry).
    Press Ctrl-C to stop.
    """)
  end

  defp ip_string(ip) when is_tuple(ip) do
    ip |> :inet.ntoa() |> to_string()
  end
end
