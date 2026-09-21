# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

# The introspection API is a pure function over *loaded* modules; make sure
# the test support modules are loaded before any doctest or test runs.
[
  AshAgentTools.Test.Domain,
  AshAgentTools.Test.InterfaceDomain,
  AshAgentTools.Test.Post,
  AshAgentTools.Test.Author,
  AshAgentTools.Test.Comment,
  AshAgentTools.Test.Guarded,
  AshAgentTools.Test.ContextProbe
]
|> Enum.each(&Code.ensure_loaded!/1)

# The daemon watcher tests drive a real `file_system` backend; environments
# where the port program cannot bootstrap or deliver events (bare containers
# without inotify) get them excluded instead of red.
watcher_works? =
  try do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ash_agent_watcher_probe_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    {:ok, backend} = FileSystem.start_link(dirs: [dir])
    :ok = FileSystem.subscribe(backend)

    File.write!(Path.join(dir, "probe"), "x")

    received? =
      receive do
        {:file_event, _backend, {_path, _events}} -> true
      after
        2_000 -> false
      end

    Process.exit(backend, :kill)
    File.rm_rf!(dir)
    received?
  rescue
    _ -> false
  end

unless watcher_works? do
  IO.puts("note: file_system backend unavailable — excluding @tag :watcher tests")
end

ExUnit.start(exclude: [watcher: not watcher_works?])
