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
  AshAgentTools.Test.ContextProbe,
  AshAgentTools.Test.ProbeDsl,
  AshAgentTools.Test.Probed,
  AshAgentTools.Test.User,
  AshAgentTools.Test.Machine,
  AshAgentTools.Test.RuleSets.KYC,
  # the BPMN/decision fixtures join the symbol index (search suggestions,
  # discovery counts) whether or not the database tests run
  AshAgentTools.Test.BpmnDomain,
  AshAgentTools.Test.Bpmn.Definition,
  AshAgentTools.Test.Bpmn.Instance,
  AshAgentTools.Test.Bpmn.Token,
  AshAgentTools.Test.Bpmn.HumanTask,
  AshAgentTools.Test.Bpmn.TaskCandidate,
  AshAgentTools.Test.Bpmn.ProcessEvent,
  AshAgentTools.Test.DecisionsDomain,
  AshAgentTools.Test.Decisions.Definition,
  AshAgentTools.Test.Decisions.Evaluation
]
|> Enum.each(&Code.ensure_loaded!/1)

# The ETS-backed fixture resources create their tables lazily on first
# write, and two parallel tests racing on that first write can hit
# `:table_not_found`. Create them eagerly, once, before the fan-out.
AshAgentTools.Test.User
|> Ash.Changeset.for_create(:create, %{email: "seed@example.com"})
|> Ash.create!(authorize?: false)

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

# The BPMN/decision tooling tests talk to a real PostgreSQL (the ash_bpmn/
# ash_decisions resource macros are AshPostgres by construction). The database
# is created and migrated here, once per test run, so a fresh clone needs no
# setup task; `SKIP_DB=1` excludes those tests (`:db` tag) for runs without a
# database. Migrations run outside the sandbox (:auto), and the pool is
# switched to manual ownership afterwards.
db_tests? =
  if Application.get_env(:ash_agent_tools, :db_tests_enabled?, true) do
    {:ok, _} = AshAgentTools.TestRepo.start_link()

    Ecto.Adapters.SQL.Sandbox.mode(AshAgentTools.TestRepo, :auto)

    case AshAgentTools.TestRepo.__adapter__().storage_up(AshAgentTools.TestRepo.config()) do
      :ok -> :ok
      {:error, :already_up} -> :ok
    end

    Ecto.Migrator.run(AshAgentTools.TestRepo, "priv/test_repo/migrations", :up, all: true)

    Ecto.Adapters.SQL.Sandbox.mode(AshAgentTools.TestRepo, :manual)
    true
  else
    false
  end

ExUnit.start()

# Same watcher semantics as before; `:db` excludes the BPMN/decision tests
# under SKIP_DB.
ExUnit.configure(exclude: [watcher: not watcher_works?] ++ if(db_tests?, do: [], else: [:db]))

unless db_tests? do
  IO.puts("note: SKIP_DB — excluding the BPMN/decision tooling tests (:db tag)")
end

unless watcher_works? do
  IO.puts("note: file_system backend unavailable — excluding @tag :watcher tests")
end
