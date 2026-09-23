# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Bpmn do
  @moduledoc """
  Read-only BPMN introspection for hosts running the `ash_bpmn` process
  engine — active only when the host ships the optional `ash_bpmn`
  dependency (see `AshAgentTools.Availability`; without it every function
  here raises the structured "add the dep" error).

  Three read-only moves over the host's process engine:

    * `processes/2` — which process definitions exist, per host domain,
      aggregated per key: versions, statuses, drafts, content hashes.
    * `process_graph/2` — one definition's compiled graph (`nodes`,
      `flows`, `joins`, `boundaries`, …) plus, optionally, the per-element
      occupancy digests `AshBpmn.StateExport.elements/1` computes. An
      uncompiled draft renders its stored `errors` instead of a graph.
    * `process_instance/1` — what is in flight right now, thin-wrapping
      `AshBpmn.StateExport.export/2` (correlation keys stay digested unless
      explicitly requested) and adding each instance's open human tasks
      with their candidate rows.

  **Scoping.** Definitions and graphs read as the engine
  (`AshBpmn.Scope.system(:engine)` — the export's own default). Instance
  and task reads thread `:actor`/`:tenant` when the caller provides them
  and fall back to the engine otherwise; pass `scope: :engine` to force the
  engine even when an actor is in hand. **Nothing mutates**: no task is
  completed, no token advanced, no instance cancelled — those are host
  actions with downstream effects, and this toolset deliberately does not
  call them.

  A token's position is interpreted against the definition its instance
  **pinned** (the export loads it), and every instance entry carries
  `definition_version` and `definition_content_hash`, so "the process has
  changed since this instance started" is decidable from the report.

  The raw `xml` is never returned — it is `sensitive?` in the engine, and
  the compiled graph is the artifact an agent needs.
  """

  require Ash.Query

  alias AshAgentTools.Availability
  alias AshAgentTools.Kaizen
  alias AshAgentTools.Registry

  @default_statuses [:running]

  # ── processes ─────────────────────────────────────────────────────────────

  @doc """
  Lists the host's BPMN process definitions, aggregated per key.

  Scans every loaded Ash domain the engine recognizes
  (`AshBpmn.Resources.for_domain/1`), or only `domain` when given (string
  module names accepted). One entry per `{domain, key}`:

    * `name` — the draft's name when a draft exists, else the latest
      published version's
    * `version` / `status` / `content_hash` — the representative version
      (the draft when one exists, else the latest published)
    * `errors_count` — the representative version's stored compile errors
    * `has_draft` / `latest_published_version` — the two facts a picker
      shows next to the name

  Retired versions never represent a key; a key whose every version is
  retired still lists, with the numbers that say so. The report is a plain,
  JSON-encodable map; the raw `xml` is never included.

  Options: `:key` — restrict to one process key (a miss emits the kaizen
  tool-gap). Raises the structured availability error when `ash_bpmn` is
  absent or too old.
  """
  @spec processes(module() | String.t() | nil, keyword()) :: map()
  def processes(domain, opts \\ []) do
    ensure_active!()
    key = Keyword.get(opts, :key)

    entries =
      bpmn_domains(domain)
      |> Enum.flat_map(fn domain ->
        domain
        |> domain_entries()
        |> Enum.map(&Map.put(&1, :domain, domain))
      end)
      |> Enum.filter(&(is_nil(key) or &1.key == key))
      |> Enum.sort_by(&{Registry.module_name(&1.domain), &1.key})
      |> Enum.map(fn entry -> Map.update!(entry, :domain, &Registry.module_name/1) end)

    if not is_nil(key) and entries == [] do
      emit_key_gap!(key)
    end

    %{count: length(entries), processes: entries}
  end

  defp domain_entries(domain) do
    {:ok, resources} = AshBpmn.Resources.for_domain(domain)

    read_definitions(resources, nil)
    |> Enum.group_by(& &1.key)
    |> Enum.map(fn {key, versions} -> key_entry(domain, key, versions) end)
    |> Enum.sort_by(& &1.key)
  end

  defp key_entry(domain, key, versions) do
    published = published_versions(versions)
    draft = Enum.find(versions, &(&1.status == :draft))
    retired? = published == [] and is_nil(draft)
    representative = representative_version(versions, published, draft)

    %{
      domain: domain,
      key: key,
      name: representative.name,
      version: representative.version,
      status: if(retired?, do: :retired, else: representative.status),
      content_hash: representative.content_hash,
      errors_count: length(List.wrap(Map.get(representative, :errors) || [])),
      has_draft: draft != nil,
      latest_published_version: (published != [] && List.last(published).version) || nil
    }
  end

  defp published_versions(versions) do
    versions |> Enum.filter(&(&1.status == :published)) |> Enum.sort_by(& &1.version)
  end

  defp representative_version(_versions, _published, draft) when not is_nil(draft), do: draft

  defp representative_version(_versions, [_ | _] = published, _draft), do: List.last(published)

  defp representative_version(versions, _published, _draft) do
    Enum.max_by(versions, &(&1.version || 0), fn -> hd(versions) end)
  end

  # ── process_graph ────────────────────────────────────────────────────────

  @doc """
  One process definition's compiled graph, with identity facts.

  Resolves `key`: `version:` when given (`by_key_version/2`), else the
  key's draft with `draft: true`, else the latest published version
  (`latest_published/1`, which returns a list — the `hd/1` is taken). The
  report carries the engine's public `graph` map (`nodes`, `flows`,
  `joins`, `boundaries`, `feel_engine`, `process_id`, `start`) plus, when
  `include_elements:` (default `true`), `AshBpmn.StateExport.elements/1`'s
  per-element occupancy digests — the same digests a migration
  classification compares.

  An **uncompiled draft** has `graph: nil`; the report renders the stored
  compile `errors` and says so in `note`, rather than inventing an empty
  graph — exactly the distinction the engine itself draws. An unknown key
  or version raises the structured error with `did_you_mean` candidates
  from the keys that do exist (and emits the kaizen tool-gap).

  Options: `:version`, `:domain`, `:include_elements` (default `true`),
  `:draft` (default `false`).
  """
  @spec process_graph(String.t() | atom(), keyword()) :: map()
  def process_graph(key, opts \\ []) do
    ensure_active!()

    case resolve_definition(key, opts) do
      {:ok, {domain, record}} ->
        graph = Map.get(record, :graph)

        base = %{
          domain: Registry.module_name(domain),
          key: record.key,
          name: record.name,
          version: record.version,
          status: record.status,
          content_hash: record.content_hash,
          graph: graph,
          elements: graph_elements(graph, Keyword.get(opts, :include_elements, true)),
          errors: List.wrap(Map.get(record, :errors) || [])
        }

        if is_nil(graph) do
          Map.put(base, :note, "no compiled graph: this draft did not compile — see errors")
        else
          base
        end

      {:error, reason} ->
        raise ArgumentError, reason
    end
  end

  defp graph_elements(nil, _include_elements?), do: nil
  defp graph_elements(_graph, false), do: nil
  defp graph_elements(graph, true), do: AshBpmn.StateExport.elements(graph)

  # ── process_instance ─────────────────────────────────────────────────────

  @doc """
  What is in flight right now: instances, their tokens, and their open
  human tasks.

  Thin-wraps `AshBpmn.StateExport.export/2` — identifiers, statuses and
  shape digests, not business data — and adds, per instance, the open
  `HumanTask` rows with their `TaskCandidate` entries, so "who can act on
  this, and has anyone?" is one call.

  Selects instances by `instance_id:`, by `subject_type:` (+ optional
  `subject_id:`), or by `definition_key:`; with nothing given, every
  instance in `statuses:` (default `[:running]`). `include_children:`
  (default `true`) follows call-activity children.
  `include_correlation_keys:` (default `false`) emits correlation keys in
  the clear instead of digested — the privacy line the export already
  draws, kept opt-in here. `scope: :engine` forces the engine scope even
  when `:actor`/`:tenant` are given.

  Token positions are interpreted against the **pinned** definition, and
  each instance entry carries `definition_version` +
  `definition_content_hash` so version drift is decidable. Raises the
  structured error for an unknown instance id (with the kaizen gap); a
  subject miss is an empty list, not an error.
  """
  @spec process_instance(keyword()) :: map()
  def process_instance(opts \\ []) do
    ensure_active!()

    domains = bpmn_domains(opts[:domain])

    instances =
      Enum.flat_map(domains, fn domain ->
        case AshBpmn.StateExport.export(domain, export_opts(opts)) do
          {:ok, export} ->
            Enum.map(export["instances"], fn entry ->
              Map.put(entry, "domain", Registry.module_name(domain))
            end)

          {:error, :missing_resources, _kinds} ->
            []
        end
      end)
      |> Enum.filter(&subject_matches?(&1, opts))

    instance_ids = Enum.map(instances, & &1["id"])

    tasks_by_instance =
      domains
      |> Enum.flat_map(&open_tasks(&1, opts, instance_ids))
      |> Enum.group_by(& &1.instance_id)

    instances =
      Enum.map(instances, fn instance ->
        Map.put(instance, "open_tasks", Map.get(tasks_by_instance, instance["id"], []))
      end)

    if id = opts[:instance_id] do
      if instances == [], do: emit_instance_gap!(id)
    end

    %{count: length(instances), instances: instances}
  end

  # A subject miss is an empty answer, not an error; a subject_type alone
  # narrows without pinning the id.
  defp subject_matches?(entry, opts) do
    type = Keyword.get(opts, :subject_type)
    id = Keyword.get(opts, :subject_id)

    cond do
      is_nil(type) -> true
      is_nil(id) -> entry["subject_type"] == type
      true -> entry["subject_type"] == type and entry["subject_id"] == id
    end
  end

  defp export_opts(opts) do
    base = [
      statuses: Keyword.get(opts, :statuses, @default_statuses) || @default_statuses,
      definition_key: opts[:definition_key],
      instance_ids: opts[:instance_id] && List.wrap(opts[:instance_id]),
      include_children: Keyword.get(opts, :include_children, true),
      include_correlation_keys: Keyword.get(opts, :include_correlation_keys, false)
    ]

    scope_opts =
      if opts[:scope] == :engine do
        []
      else
        [actor: opts[:actor], tenant: opts[:tenant]]
      end

    Keyword.merge(base, scope_opts)
  end

  # Open human tasks with their candidate rows, read-only, in the same
  # scope the export ran under.
  defp open_tasks(domain, opts, instance_ids) do
    {:ok, resources} = AshBpmn.Resources.for_domain(domain)

    tasks =
      resources.human_task
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(instance_id in ^instance_ids)
      |> Ash.Query.filter(status == :open)
      |> Ash.read!(scope_opts(opts))

    task_ids = Enum.map(tasks, & &1.id)

    candidates =
      if task_ids == [] do
        []
      else
        resources.task_candidate
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(task_id in ^task_ids)
        |> Ash.read!(scope_opts(opts))
      end

    by_task = Enum.group_by(candidates, & &1.task_id)

    Enum.map(tasks, fn task ->
      %{
        id: task.id,
        instance_id: task.instance_id,
        token_id: task.token_id,
        node_id: task.node_id,
        name: task.name,
        status: task.status,
        assignee_type: task.assignee_type,
        assignee_id: task.assignee_id,
        claimed_at: timestamp(task.claimed_at),
        due_at: timestamp(task.due_at),
        candidates: Enum.map(Map.get(by_task, task.id, []), &candidate_entry/1)
      }
    end)
  end

  defp candidate_entry(candidate) do
    %{
      id: candidate.id,
      principal_type: candidate.principal_type,
      principal_id: candidate.principal_id
    }
  end

  defp scope_opts(opts) do
    scope =
      if opts[:scope] == :engine do
        AshBpmn.Scope.system(:engine)
      else
        AshBpmn.Scope.from_opts(actor: opts[:actor], tenant: opts[:tenant])
      end

    AshBpmn.Scope.engine(scope)
  end

  # ── shared resolution ------------------------------------------------------

  defp read_definitions(resources, _key) do
    resources.definition
    |> Ash.Query.for_read(:read)
    |> Ash.read!(engine_opts())
  end

  defp engine_opts, do: AshBpmn.Scope.engine(AshBpmn.Scope.system(:engine))

  # The definition the report is about: an explicit version (by_key_version),
  # the key's draft (:draft), or the latest published (latest_published,
  # which returns a list — the engine's own callers take hd).
  defp resolve_definition(key, opts) do
    domains = bpmn_domains(opts[:domain])

    found =
      Enum.flat_map(domains, fn domain ->
        {:ok, resources} = AshBpmn.Resources.for_domain(domain)

        record =
          cond do
            version = opts[:version] -> by_key_version(resources, key, version)
            opts[:draft] -> draft_for(resources, key)
            true -> latest_published(resources, key)
          end

        case record do
          nil -> []
          record -> [{domain, record}]
        end
      end)

    cond do
      found == [] ->
        keys = known_keys(domains)
        emit_key_gap!(key)

        {:error,
         "no #{describe_selection(opts)} definition for key #{inspect(key)}." <>
           " did_you_mean: #{inspect(keys)}"}

      length(found) == 1 ->
        {:ok, hd(found)}

      true ->
        names = Enum.map(found, fn {domain, _record} -> Registry.module_name(domain) end)

        {:error,
         "key #{inspect(key)} matches definitions in several domains: #{inspect(names)} —" <>
           " pass :domain to choose one"}
    end
  end

  defp describe_selection(opts) do
    cond do
      opts[:version] -> "v#{opts[:version]}"
      opts[:draft] -> "draft"
      true -> "published"
    end
  end

  defp by_key_version(resources, key, version) do
    case resources.definition.by_key_version(key, version, engine_opts()) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  defp draft_for(resources, key) do
    resources.definition
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(key == ^key and status == :draft)
    |> Ash.read_one(engine_opts())
    |> case do
      {:ok, record} -> record
      _ -> nil
    end
  end

  defp latest_published(resources, key) do
    # the code interface wraps the read result: {:ok, list} — and the engine's
    # own callers take hd of the list
    case resources.definition.latest_published(key, engine_opts()) do
      {:ok, [record | _]} -> record
      {:ok, []} -> nil
      [record | _] -> record
      [] -> nil
      {:ok, record} when is_map(record) -> record
      record when is_map(record) -> record
      _ -> nil
    end
  end

  defp known_keys(domains) do
    Enum.flat_map(domains, fn domain ->
      {:ok, resources} = AshBpmn.Resources.for_domain(domain)
      Enum.map(read_definitions(resources, nil), & &1.key)
    end)
    |> Enum.uniq()
  end

  defp bpmn_domains(nil) do
    Enum.filter(Registry.list_domains(), fn domain ->
      match?({:ok, _}, AshBpmn.Resources.for_domain(domain))
    end)
  end

  defp bpmn_domains(name) when is_binary(name), do: [Module.concat([name])]
  defp bpmn_domains(domain) when is_atom(domain), do: [domain]

  # ── availability + kaizen ---------------------------------------------------

  defp ensure_active! do
    Availability.ensure_active!(:ash_bpmn)

    # Drift guard: the tools read the engine's code interfaces and export
    # shape; an older ash_bpmn would fail deep inside the export. Say so at
    # the door instead.
    unless exported?(AshBpmn.StateExport, :export, 2) and
             exported?(AshBpmn.Resources, :for_domain, 1) do
      raise ArgumentError,
            "ash_bpmn tooling requires a newer ash_bpmn:" <>
              " AshBpmn.StateExport.export/2 is missing." <>
              " Update {:ash_bpmn, github: \"lukegalea/ash_bpmn\"} to use this"
    end

    :ok
  end

  defp exported?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end

  defp emit_key_gap!(key) do
    Kaizen.emit(:processes, :key_miss, to_string(key), %{key: to_string(key)})
  end

  defp emit_instance_gap!(id) do
    Kaizen.emit(:process_instance, :instance_miss, to_string(id), %{instance_id: to_string(id)})
  end

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(%NaiveDateTime{} = value), do: DateTime.to_iso8601(value)
end
