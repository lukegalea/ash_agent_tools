# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

# Compiled conditionally (Ecto's optional-Jason pattern): `ash_rules` is an
# *optional* dependency, so a host that does not ship it still compiles this
# package cleanly. Without it every function here answers with the structured
# "not available" error that names the dep to add (see
# `AshAgentTools.Availability`).
if Code.ensure_loaded?(AshRules) do
  defmodule AshAgentTools.Rules do
    @moduledoc """
    Introspection and dry evaluation for host `AshRules` rule sets — active
    only when the host ships the optional `ash_rules` dependency (see
    `AshAgentTools.Availability`; without it every function here raises the
    structured "add the dep" error).

    Two read-only moves over the host's rule bundles:

      * `list_rule_sets/0` and `describe/1` — the *static* view: which rule
        sets are loaded, with their fact schemas, rules, combining
        algorithm, revisions, and content hash. Read from the compiled
        `AshRules.Ir.Bundle` (`AshRules.Info.bundle/1`) — the same
        content-hashed data an evaluator consumes and an auditor signs.
      * `evaluate/3` — the *dynamic* view: dry-evaluate a rule set module
        (or a bundle JSON document) against fact triples you provide. Pure
        evaluation, zero host state: nothing is read from the host's data
        layer, nothing is persisted — the result is the same
        `AshRules.Result` an in-band run would produce, projected
        JSON-safe.

    ## Search and name paths

    The generic symbols probe already indexes the rules DSL: a rule set's
    `fact_schema` entities are searchable as kind `rules_fact_schema`
    (`AshAgentTools.semantic_search("kyc", kinds: [:rules_fact_schema])`) and
    name-addressable as `Module/rules_fact_schema/<fact>` via
    `AshAgentTools.resolve/1` — the DSL-level view of the same facts this
    module reports from the compiled bundle.

    Nothing here mutates anything: bundles are immutable snapshots, and
    evaluation runs against the triples you hand it.

    ## Examples

        iex> report = AshAgentTools.Rules.describe(AshAgentTools.Test.RuleSets.KYC)
        iex> {report.combining, length(report.rules), is_binary(report.content_hash)}
        {:deny_overrides, 2, true}

        iex> report = AshAgentTools.Rules.evaluate(AshAgentTools.Test.RuleSets.KYC, [{"customer", "status", "active"}, {"customer", "jurisdiction", "regulated"}])
        iex> report.overall
        :unknown
    """

    alias AshAgentTools.Availability
    alias AshAgentTools.Registry
    alias AshAgentTools.Types

    @doc """
    Lists every loaded `AshRules` rule set with its full bundle report
    (see `describe/1`). Discovery never raises; an empty list usually means
    the modules are not loaded (the standing loaded-modules caveat) or the
    `ash_rules` dep is absent (`AshAgentTools.Availability.active?(:ash_rules)`).
    """
    @spec list_rule_sets() :: [map()]
    def list_rule_sets do
      Availability.ensure_active!(:ash_rules)

      Registry.loaded_modules_matching(&function_exported?(&1, :__bundle__, 0))
      |> Enum.map(&describe/1)
    end

    @doc """
    The bundle report for one rule set module: revisions, combining
    algorithm, content hash, compiler version, fact schema, and rules.

    Raises `ArgumentError` when the module is not a loaded AshRules rule set.
    """
    @spec describe(module()) :: map()
    def describe(module) when is_atom(module) do
      Availability.ensure_active!(:ash_rules)
      bundle = bundle!(module)

      %{
        module: module,
        revision: bundle.revision,
        fact_schema_revision: bundle.fact_schema_revision,
        combining: bundle.combining,
        content_hash: bundle.content_hash,
        compiler_version: bundle.compiler_version,
        fact_schema: Enum.map(bundle.fact_schema.facts, &fact_entry/1),
        rules: Enum.map(bundle.rules, &rule_entry/1)
      }
    end

    @doc """
    Dry-evaluates a rule set against fact triples and returns the full
    result: `overall`, per-rule `requirements` (outcomes with provenance),
    `derived_facts`, and `missing_facts`.

    The rule set is either a loaded rule set module or a path to a bundle
    JSON document (decoded and verified through
    `AshRules.Ir.Bundle.from_json/1` — the same admission path tenant
    bundles take). The facts are a list of `{subject, predicate, value}`
    triples; JSON spellings (three-element arrays, or maps with
    `"subject"`/`"predicate"`/`"value"` keys) are accepted. String
    predicates and subjects are matched to the bundle's existing atoms (an
    existing-atom conversion, so nothing is added to the atom table), and
    values are converted to the fact schema's declared types through
    `AshRules.Ir.Fact.decode_value/2` — the library's own admission
    conversion — before evaluation.

    Pure: the evaluation touches only the triples you provide, never the
    host's data. Raises `ArgumentError` for unknown modules, unreadable or
    invalid bundle documents, and evaluation errors (unknown predicates,
    type mismatches) with the library's own messages.
    """
    @spec evaluate(module() | String.t(), list(), keyword()) :: map()
    def evaluate(module_or_path, facts, opts \\ [])

    def evaluate(module, facts, opts) when is_atom(module) and is_list(facts) do
      Availability.ensure_active!(:ash_rules)
      run(bundle!(module), facts, opts)
    end

    def evaluate(path, facts, opts) when is_binary(path) and is_list(facts) do
      Availability.ensure_active!(:ash_rules)

      case load_bundle_document(path) do
        {:ok, bundle} -> run(bundle, facts, opts)
        {:error, message} -> raise ArgumentError, message
      end
    end

    def evaluate(other, _facts, _opts) do
      Availability.ensure_active!(:ash_rules)

      raise ArgumentError,
            "evaluate/3 takes a rule set module or a bundle JSON path, got: #{inspect(other)}"
    end

    # -- evaluation -----------------------------------------------------------

    defp run(bundle, facts, opts) do
      subjects = bundle_ground_subjects(bundle)
      triples = Enum.map(facts, &normalize_triple(bundle, subjects, &1))

      case AshRules.evaluate(bundle, triples, Keyword.take(opts, [:evaluator, :seed])) do
        {:ok, result} -> project_result(result)
        {:error, error} -> raise ArgumentError, Types.error_message(error)
      end
    end

    # The bundle's ground subjects: a DSL-compiled bundle's are atoms, a
    # JSON-admitted bundle's are strings (subjects are opaque terms matched
    # by equality). JSON facts carry string subjects; a fact string is
    # converted to its atom only when the bundle itself uses that atom, so
    # both bundle worlds match without ever adding an atom to the table.
    defp bundle_ground_subjects(bundle) do
      for rule <- bundle.rules,
          predicate <- AshRules.Ir.Rule.predicates(rule),
          not AshRules.Ir.Predicate.var?(predicate.subject),
          into: MapSet.new() do
        predicate.subject
      end
    end

    # {subject, predicate, value} | [subject, predicate, value] |
    # %{"subject" => s, "predicate" => p, "value" => v}
    defp normalize_triple(bundle, subjects, {subject, predicate, value}) do
      {
        normalize_subject(subjects, subject),
        predicate_atom!(bundle, predicate),
        decode_value!(bundle, predicate, value)
      }
    end

    defp normalize_triple(bundle, subjects, [subject, predicate, value]),
      do: normalize_triple(bundle, subjects, {subject, predicate, value})

    defp normalize_triple(bundle, subjects, %{} = fact) do
      subject = fetch_key!(fact, ["subject", :subject])
      predicate = fetch_key!(fact, ["predicate", "name", :predicate, :name])
      value = fetch_key!(fact, ["value", :value])

      normalize_triple(bundle, subjects, {subject, predicate, value})
    end

    defp normalize_triple(_bundle, _subjects, other) do
      raise ArgumentError,
            "facts must be {subject, predicate, value} triples, got: #{inspect(other)}"
    end

    defp fetch_key!(fact, [key | rest]) do
      case fact do
        %{^key => value} -> value
        _ -> fetch_key!(fact, rest)
      end
    end

    defp fetch_key!(fact, []) do
      raise ArgumentError,
            "fact entries need \"subject\", \"predicate\" and \"value\" keys, got: #{inspect(fact)}"
    end

    # A fact string subject becomes its atom only when the bundle itself
    # declares that atom subject (existing-atom conversion, never a new atom).
    defp normalize_subject(subjects, subject) when is_binary(subject) do
      cond do
        MapSet.member?(subjects, subject) ->
          subject

        String.to_existing_atom(subject) in subjects ->
          String.to_existing_atom(subject)

        true ->
          subject
      end
    rescue
      ArgumentError -> subject
    end

    defp normalize_subject(_subjects, subject), do: subject

    # Predicate names are schema-declared atoms: the atom always exists when
    # the triple is valid, so to_existing_atom is safe; anything else stays
    # as-is and becomes the evaluator's structured unknown-predicate error.
    defp predicate_atom!(_bundle, predicate) when is_atom(predicate), do: predicate

    defp predicate_atom!(_bundle, predicate) when is_binary(predicate) do
      String.to_existing_atom(predicate)
    rescue
      ArgumentError -> predicate
    end

    defp predicate_atom!(_bundle, predicate), do: predicate

    # Values arrive as decoded JSON; the schema's declared type says what
    # they must become (atom facts from strings, ISO dates, ...). The
    # conversion is the library's own admission codec.
    defp decode_value!(bundle, predicate, value) do
      atom_predicate = predicate_atom!(bundle, predicate)

      case AshRules.Ir.FactSchema.fetch(bundle.fact_schema, atom_predicate) do
        {:ok, fact} ->
          case AshRules.Ir.Fact.decode_value(fact.type, value) do
            {:ok, decoded} -> decoded
            {:error, message} -> raise ArgumentError, "#{fact.name}: #{message}"
          end

        :error ->
          value
      end
    end

    defp load_bundle_document(path) do
      with {:ok, body} <- read_document(path),
           {:ok, json} <- decode_document(path, body),
           {:ok, bundle} <- AshRules.Ir.Bundle.from_json(json) do
        {:ok, bundle}
      else
        # AshRules.Ir.Bundle.from_json/1's @spec says {:error, String.t()},
        # but the bundle verifiers it runs return a list of Spark errors —
        # both shapes are real and both become one structured message.
        {:error, errors} when is_list(errors) ->
          {:error,
           "invalid bundle document at #{path}: #{Enum.map_join(errors, "; ", &Types.error_message/1)}"}

        {:error, reason} ->
          {:error, "invalid bundle document at #{path}: #{Types.error_message(reason)}"}
      end
    end

    defp read_document(path) do
      case File.read(path) do
        {:ok, body} -> {:ok, body}
        {:error, reason} -> {:error, "cannot read bundle document: #{:file.format_error(reason)}"}
      end
    end

    defp decode_document(path, body) do
      case Jason.decode(body) do
        {:ok, json} -> {:ok, json}
        {:error, reason} -> {:error, "bundle document at #{path} is not valid JSON: #{reason}"}
      end
    end

    # -- projection -----------------------------------------------------------

    defp project_result(result) do
      %{
        overall: result.overall,
        combining: result.combining,
        bundle_hash: result.bundle_hash,
        bundle_revision: result.bundle_revision,
        fact_schema_revision: result.fact_schema_revision,
        evaluator: Registry.module_name(result.evaluator),
        seed: Types.to_json_safe(result.seed),
        requirements: Enum.map(result.requirements, &requirement/1),
        derived_facts: Enum.map(result.derived_facts, &triple/1),
        missing_facts: Enum.map(result.missing_facts, &triple/1)
      }
    end

    defp requirement(requirement) do
      %{
        rule_id: requirement.rule_id,
        rule_revision: requirement.rule_revision,
        severity: requirement.severity,
        gap: requirement.gap,
        outcome: requirement.outcome,
        message: requirement.message,
        bindings: Enum.map(requirement.bindings, &Types.to_json_safe/1),
        consumed_facts: Enum.map(requirement.consumed_facts, &triple/1),
        probed_facts: Enum.map(requirement.probed_facts, &triple/1),
        missing_facts: Enum.map(requirement.missing_facts, &triple/1)
      }
    end

    defp triple({subject, name, value}),
      do: %{
        subject: Types.to_json_safe(subject),
        predicate: name,
        value: Types.to_json_safe(value)
      }

    defp fact_entry(fact) do
      %{
        name: fact.name,
        type: fact.type,
        one_of: fact.one_of && Enum.map(fact.one_of, &to_string/1),
        cardinality: fact.cardinality,
        missing: fact.missing,
        description: fact.description,
        source: fact.source,
        dependencies: Enum.map(fact.dependencies, &to_string/1),
        sensitive?: fact.sensitive?,
        tenant_scoped?: fact.tenant_scoped?
      }
    end

    defp rule_entry(rule) do
      %{
        id: rule.id,
        name: rule.name,
        revision: rule.revision,
        severity: rule.severity,
        message: rule.message,
        remediation_ref: rule.remediation_ref,
        controls: rule.controls,
        evidence: rule.evidence,
        source: rule.source,
        outcome: outcome_entry(rule.outcome),
        applicability: Enum.map(rule.applicability, &predicate_entry/1),
        failure_conditions: Enum.map(rule.failure_conditions, &predicate_entry/1)
      }
    end

    defp outcome_entry(nil), do: nil

    defp outcome_entry(outcome) do
      %{outcome: outcome.outcome, gap: outcome.gap}
    end

    # Var-shaped subjects/values report as %{"var" => name}; ground terms as
    # themselves — the predicate's own JSON spelling, atom-keyed.
    defp predicate_entry(predicate) do
      %{
        op: predicate.op,
        subject: term_entry(predicate.subject),
        name: predicate.name,
        value: term_entry(predicate.value)
      }
    end

    defp term_entry(%AshRules.Ir.Var{name: name}), do: %{var: to_string(name)}
    defp term_entry(term), do: Types.to_json_safe(term)

    # -- discovery helpers ------------------------------------------------------

    defp bundle!(module) do
      case AshRules.Info.bundle(module) do
        {:ok, bundle} ->
          bundle

        {:error, :no_bundle} ->
          candidates =
            Registry.loaded_modules_matching(&function_exported?(&1, :__bundle__, 0))
            |> Enum.map(&Registry.module_name/1)

          raise ArgumentError,
                "#{Registry.module_name(module)} is not a loaded AshRules rule set." <>
                  " Loaded rule sets: #{inspect(candidates)}"
      end
    end
  end
else
  defmodule AshAgentTools.Rules do
    @moduledoc """
    The `ash_rules` tooling stub, compiled when the optional `ash_rules`
    dependency is absent. Every function raises the structured
    "not available" error that names the dep to add — see
    `AshAgentTools.Availability`.
    """

    alias AshAgentTools.Availability

    @spec list_rule_sets() :: [map()]
    def list_rule_sets do
      Availability.ensure_active!(:ash_rules)
      []
    end

    @spec describe(module()) :: map()
    def describe(_module) do
      Availability.ensure_active!(:ash_rules)
    end

    @spec evaluate(module() | String.t(), list(), keyword()) :: map()
    def evaluate(_module_or_path, _facts, _opts \\ []) do
      Availability.ensure_active!(:ash_rules)
    end
  end
end
