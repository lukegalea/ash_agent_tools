# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Decisions do
  @moduledoc """
  Read-only DMN introspection and dry evaluation for hosts running the
  `ash_decisions` decision engine — active only when the host ships the
  optional `ash_decisions` dependency (see `AshAgentTools.Availability`;
  without it every function here raises the structured "add the dep"
  error).

  Two read-only moves over the host's decision catalogue:

    * `decisions/2` — the catalogue, per host domain: which decision keys
      exist, which have a draft, which version is live, and what decisions
      the document declares — the `AshDecisions.Catalogue.entries/2`
      projection, with the stored publish-time `verification` and the
      graph available per request. The stored attribute is reported as-is;
      the Verifier is **not** re-run (a catalogue read has no business
      re-deciding whether the document was sound at publish time).
    * `decision_evaluate/3` — evaluate a **published** decision against
      inputs you provide, with `record: false` hard-coded: the result is
      computed and nothing is written — no `Evaluation` row, ever. This is
      the designer-preview path the engine itself draws a line around, and
      this toolset refuses to cross it. Drafts evaluate only via the
      explicit `draft: true` flag, because draft evaluation churns the
      engine's `persistent_term` model cache for a document that can still
      change.

  Reads run as the engine (`AshDecisions.Scope` engine opts — the
  catalogue's own default). Nothing mutates, nothing is decided about real
  cases: an evaluation here answers a question about the model, not about
  a case.
  """

  require Ash.Query

  alias AshAgentTools.Availability
  alias AshAgentTools.Kaizen
  alias AshAgentTools.Registry
  alias AshAgentTools.Types

  # ── decisions ─────────────────────────────────────────────────────────────

  @doc """
  Lists the host's DMN decision definitions, per key.

  Scans every loaded Ash domain the engine recognizes
  (`AshDecisions.Resources.for_domain/1`), or only `domain` when given
  (string module names accepted). Each entry carries the catalogue's own
  projection — `key`, `name`, `status` (`:draft` when the key has a draft),
  `has_draft`, `latest_published_version`, and `decisions` (what the
  document declares, in document order, with inputs and outputs).

  Options:

    * `:key` — restrict to one decision key (a miss emits the kaizen
      tool-gap)
    * `:graph` — include the stored graph snapshot of the representative
      document (the draft's when one exists, else the latest published)
    * `:verification` — include the stored publish-time verification
      attribute as-is. The Verifier is not re-run.

  Raises the structured availability error when `ash_decisions` is absent
  or too old.
  """
  @spec decisions(module() | String.t() | nil, keyword()) :: map()
  def decisions(domain, opts \\ []) do
    ensure_active!()
    key = Keyword.get(opts, :key)
    extra? = opts[:graph] == true or opts[:verification] == true

    entries =
      decision_domains(domain)
      |> Enum.flat_map(fn domain ->
        AshDecisions.Catalogue.entries(domain, [])
        |> Enum.map(&Map.put(&1, :domain, Registry.module_name(domain)))
      end)
      |> Enum.filter(&(is_nil(key) or &1.key == key))
      |> Enum.sort_by(&{&1.domain, &1.key})

    entries =
      if extra? do
        Enum.map(entries, &with_stored/1)
      else
        entries
      end

    if not is_nil(key) and entries == [] do
      emit_key_gap!(key)
    end

    %{count: length(entries), decisions: entries}
  end

  # The catalogue entry's representative document is the draft when one
  # exists, else the latest published — the same record the catalogue read
  # its decisions from. Attach the stored graph/verification verbatim.
  defp with_stored(entry) do
    domain = Module.concat([entry.domain])

    case AshDecisions.Resources.for_domain(domain) do
      {:ok, resources} ->
        record = representative(resources, entry)

        entry
        |> Map.put(:graph, record && Map.get(record, :graph))
        |> Map.put(:verification, record && Map.get(record, :verification))

      _ ->
        Map.merge(entry, %{graph: nil, verification: nil})
    end
  end

  defp representative(resources, %{key: key, has_draft: true}) do
    resources.definition
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(key == ^key and status == :draft)
    |> Ash.read_one(engine_opts())
    |> case do
      {:ok, record} -> record
      _ -> latest_published(resources, key)
    end
  end

  defp representative(resources, %{key: key}) do
    latest_published(resources, key)
  end

  # ── decision_evaluate ─────────────────────────────────────────────────────

  @doc """
  Evaluates a decision against inputs you provide — a designer preview,
  not a case decision.

  Resolves the definition: `version:` when given, the draft with
  `draft: true`, else the latest published version. The evaluation runs
  `AshDecisions.Evaluator.evaluate/3` with `record: false` **hard-coded** —
  no `Evaluation` row is written, and `:evaluation_resource` is never
  passed. Draft evaluation churns the engine's `persistent_term` model
  cache, which is why it sits behind the explicit flag: the default path
  is the published document, which cannot change.

  The engine normalizes inputs through `AshDecisions.Feel.to_feel_value/1`
  itself; numbers, strings, booleans and dates arrive as decoded JSON.
  Engine refusals surface as structured errors — notably
  `{:ambiguous_decision, key, names}` when the document declares several
  decisions and none was named via `decision:`.

  Options: `:decision` (the decision name, when the document declares more
  than one), `:version`, `:draft` (default `false`), `:domain`.
  """
  @spec decision_evaluate(String.t() | atom(), map(), keyword()) :: map()
  def decision_evaluate(key, inputs, opts \\ []) do
    ensure_active!()

    unless is_map(inputs) do
      raise ArgumentError, "inputs must be a map, got: #{inspect(inputs)}"
    end

    definition = resolve_definition!(key, opts)

    result =
      AshDecisions.Evaluator.evaluate(definition, inputs,
        record: false,
        decision: opts[:decision]
      )

    case result do
      {:ok, evaluated} ->
        %{
          key: evaluated.definition_key,
          version: evaluated.definition_version,
          decision: evaluated.decision,
          outputs: Types.to_json_safe(evaluated.outputs),
          duration_us: evaluated.duration_us,
          recorded?: false
        }

      {:error, {:ambiguous_decision, key, names}} ->
        raise ArgumentError,
              "the document for key #{inspect(key)} declares several decisions:" <>
                " #{inspect(names)} — pass decision: to choose one"

      {:error, reason} ->
        raise ArgumentError, "decision #{inspect(key)} failed: #{Types.error_message(reason)}"
    end
  end

  # ── shared resolution ------------------------------------------------------

  defp resolve_definition!(key, opts) do
    domains = decision_domains(opts[:domain])

    found =
      Enum.flat_map(domains, fn domain ->
        {:ok, resources} = AshDecisions.Resources.for_domain(domain)

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

    case found do
      [{_domain, record}] ->
        record

      [] ->
        emit_key_gap!(key)
        raise ArgumentError, "no such decision key #{inspect(key)}"
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

  defp engine_opts, do: AshDecisions.Scope.engine(AshDecisions.Scope.system())

  defp decision_domains(nil) do
    Enum.filter(Registry.list_domains(), fn domain ->
      match?({:ok, _}, AshDecisions.Resources.for_domain(domain))
    end)
  end

  defp decision_domains(name) when is_binary(name), do: [Module.concat([name])]
  defp decision_domains(domain) when is_atom(domain), do: [domain]

  # ── availability + kaizen ---------------------------------------------------

  defp ensure_active! do
    Availability.ensure_active!(:ash_decisions)

    # Drift guard: the catalogue/evaluator seams this module reads are the
    # packages' public surface; an older ash_decisions would fail deep in
    # the evaluation. Say so at the door instead.
    unless exported?(AshDecisions.Catalogue, :entries, 2) and
             exported?(AshDecisions.Evaluator, :evaluate, 3) do
      raise ArgumentError,
            "ash_decisions tooling requires a newer ash_decisions:" <>
              " AshDecisions.Catalogue.entries/2 is missing." <>
              " Update {:ash_decisions, github: \"lukegalea/ash_decisions\"} to use this"
    end

    :ok
  end

  defp exported?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end

  defp emit_key_gap!(key) do
    Kaizen.emit(:decisions, :key_miss, to_string(key), %{key: to_string(key)})
  end
end
