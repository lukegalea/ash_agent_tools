# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.TaskOutput do
  @moduledoc false

  # Shared plumbing for the `mix ash_agent.*` tasks. The contract these
  # enforce: **stdout is pure JSON, always.** Application start (repo
  # wiring, telemetry, migration banners...) logs through Logger, which
  # would otherwise interleave with the task's output regardless of shell
  # redirection, because Logger writes to the group leader (stdout) too.
  # So the logger is silenced around app start; `--verbose` opts out.

  @doc """
  Runs `fun` with Logger output suppressed (unless `--verbose` was given),
  restoring the previous state when `fun` returns or raises.

  The suppression has to survive `Mix.Task.run("app.start")`, which *stops*
  `Logger.App` and lets the application restart it — the restarted Logger
  re-applies its level from the `:logger` **application env** (defaulting
  to `:debug`), wiping any runtime `Logger.configure/2`. So the env is set
  (picked up by the restarted Logger) *and* the runtime level is lowered
  (covers the window before the restart). Both are restored afterwards.
  """
  def with_quiet_logger(opts, fun) do
    if opts[:verbose] do
      fun.()
    else
      previous_level = Logger.level()
      previous_env = Application.get_env(:logger, :level)

      Application.put_env(:logger, :level, :emergency)
      Logger.configure(level: :emergency)

      try do
        fun.()
      after
        Logger.configure(level: previous_level)

        case previous_env do
          nil -> Application.delete_env(:logger, :level)
          env -> Application.put_env(:logger, :level, env)
        end
      end
    end
  end

  @doc """
  Writes the JSON payload to stdout, or — when `--out FILE` was given — to
  the file instead, leaving stdout empty.
  """
  def write_json(json, opts) do
    case opts[:out] do
      nil ->
        Mix.shell().info(json)

      file ->
        File.write!(file, json <> "\n")
    end
  end

  @doc """
  Loads the resource modules behind the domains the host application
  registers the way ash projects declare them
  (`config :my_app, ash_domains: [...]`).

  Resource modules load lazily, so a freshly booted application does not
  necessarily have them in memory; the introspection API is a pure function
  over *loaded* modules. Tasks that report on resources call this after
  `app.start`.
  """
  def load_configured_domains do
    app = Mix.Project.config()[:app]

    for domain <- Application.get_env(app, :ash_domains, []) do
      with {:module, domain} <- Code.ensure_loaded(domain),
           true <- function_exported?(domain, :spark_is, 0) do
        for resource <- Ash.Domain.Info.resources(domain) do
          Code.ensure_loaded(resource)
        end
      else
        _ -> :ok
      end
    end

    :ok
  end
end
