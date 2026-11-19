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
  The boot contract of the introspection tasks: **compile, don't start.**

  Introspection needs compiled DSL state, not a running application —
  and a full `app.start` would boot Oban, projectors, and every other
  supervision child just to answer a schema question. Tasks run under
  `@requirements ["app.config"]` and call this afterwards to make sure the
  project is compiled.

  Compilation output ("Compiling N files", "Generated ... app") goes
  through `Mix.shell/0`, not Logger, so it is silenced with `quietly/1`
  (compiler diagnostics still reach stderr; stdout stays pure JSON).
  `Mix.Task.run/2` caches, so this is a no-op when the project is already
  fresh.
  """
  def ensure_compiled do
    quietly(fn -> Mix.Task.run("compile") end)

    :ok
  end

  @doc """
  Runs `fun`, discarding what it prints to standard output (`:stdio`, which
  is where `Mix.Shell.IO` writes), and returns its result. Standard error is
  a separate device and still reaches the terminal.

  The silence is scoped to the calling process, by pointing its group leader
  at a throwaway `StringIO`. It deliberately does **not** switch
  `Mix.shell/0` to `Mix.Shell.Quiet`: that setting lives in global Mix state,
  and "read the current shell, install Quiet, put back what I read" is not
  safe when two callers overlap. The second reads the first's `Quiet` as the
  shell to restore, so the VM is left on `Quiet` for good, and every later
  `Mix.shell().info/1` — a Mix task's JSON on stdout, a `capture_io` in a
  test — prints nothing (AST-154). A group leader is per process, so
  overlapping callers, and processes that are not booting at all, never see
  each other's setting.

  Processes the function spawns inherit the throwaway group leader, so their
  standard output is discarded as well, which is the intent here.
  """
  def quietly(fun) when is_function(fun, 0) do
    caller = self()
    previous_leader = Process.group_leader()
    {:ok, sink} = StringIO.open("")

    Process.group_leader(caller, sink)

    try do
      fun.()
    after
      Process.group_leader(caller, previous_leader)
      StringIO.close(sink)
    end
  end

  @doc """
  Runs `fun` with Logger output suppressed (unless `--verbose` was given),
  restoring the previous state when `fun` returns or raises.

  The suppression originally had to survive `Mix.Task.run("app.start")`,
  which *stops* `Logger.App` and lets the application restart it — the
  restarted Logger re-applies its level from the `:logger` **application
  env** (defaulting to `:debug`), wiping any runtime `Logger.configure/2`.
  So the env is set (picked up by the restarted Logger) *and* the runtime
  level is lowered (covers the window before the restart). Both are
  restored afterwards. The runtime task still boots the application, so
  the mechanism stays.
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
  Writes a structured error report through `write_json/2`.

  Errors are answers too: a task that cannot answer (unknown action, ...)
  still keeps the pure-JSON stdout contract, and the caller exits non-zero
  via `exit({:shutdown, 1})` — Mix exits quietly on `{:shutdown, _}`, so
  no stacktrace noise pollutes the stream.
  """
  def emit_json_error(payload, opts) do
    payload
    |> Map.put(:is_error?, true)
    |> Jason.encode!()
    |> write_json(opts)
  end

  @doc """
  Loads the resource modules behind the domains the host application
  registers the way ash projects declare them
  (`config :my_app, ash_domains: [...]`).

  Resource modules load lazily, and under the compile-only boot contract
  (`ensure_compiled/0`) nothing loads them for you. Discovery is a pure
  function over *loaded* modules, so introspection tasks call this after
  compiling: the whole declared surface of the configured domains becomes
  visible without starting the application.
  """
  def load_configured_domains do
    AshAgentTools.Registry.load_app_domains(Mix.Project.config()[:app])
  end
end
