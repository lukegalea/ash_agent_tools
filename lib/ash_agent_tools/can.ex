# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Can do
  @moduledoc """
  Actor-aware authorization verdicts, without executing anything.

  `can/5` is the evaluator sibling of `AshAgentTools.Forbidden.explain_forbidden/2`:
  where `explain_forbidden` lists the policies that *could* deny an action,
  `can` resolves an actor, builds the very changeset/query an action run
  would build, and asks Ash for the actual verdict through `Ash.can/3` —
  policy evaluation only. The subject is never run: no action executes,
  nothing is written, and `run_queries?: false` keeps even the policy
  checks from touching the data layer (undecidable checks surface as an
  honest `:maybe` instead).

  The verdict comes straight from Ash's own machinery; the per-policy
  breakdown is read from the fact set Ash attaches to its forbidden errors
  (`Ash.Error.Forbidden.Policy` carries `facts` and the policy list), with
  per-policy decisions via the public `Ash.Policy.Policy.evaluate/2` and
  `Ash.Policy.Policy.fetch_fact/2`. Nothing about a policy is re-implemented:
  the report says what Ash decided and which checks the facts decided it.
  """

  alias AshAgentTools.Describe
  alias AshAgentTools.Forbidden
  alias AshAgentTools.Kaizen
  alias AshAgentTools.Registry
  alias AshAgentTools.Suggest
  alias AshAgentTools.Types

  @typedoc "How the actor was provided."
  @type actor_spec ::
          nil
          | :none
          | :record
          | %{resource: module(), id: term()}
          | %{String.t() => String.t()}
          | Ash.actor()

  @doc """
  Answers "can this actor perform this action?" as a JSON-encodable report.

  The subject is built exactly as an action run would build it
  (`Ash.Changeset.for_create/for_update/for_destroy`, `Ash.Query.for_read`,
  `Ash.ActionInput.for_action` — `params` optional, `error?: false`) and
  handed to `Ash.can/3` with the actor. **The subject is never run.** The
  evaluation itself runs with `run_queries?: false`: policy checks that
  would need a data-layer round-trip stay undecidable and surface as
  `verdict: :maybe` rather than being silently guessed.

  The `actor` is one of:

    * `nil` or `:none` — no actor (anonymous)
    * `%{resource: MyApp.User, id: id}` (string keys accepted) — the record
      is resolved with `Ash.get!(resource, id, authorize?: false)`; the read
      is the one deliberate data-layer touch, and it is unauthorized by
      construction
    * `:record` — the action's own target record (from `record:`) acts
      ("can this record update itself?" — the `expr(id == actor.id)` case)
    * an already-resolved actor struct (used as-is)

  For `:update`/`:destroy` actions the changeset needs a target record:
  pass `record:` (a record or an id, resolved the same way) or the resolved
  actor record is used — "can this actor update themselves?" — falling back
  to an empty struct when there is no actor.

  Report shape:

    * `allowed` — the boolean an agent gates on
    * `verdict` — `:allowed`, `:forbidden`, or the honest `:maybe`
    * `per_policy` — the fact-backed breakdown (empty unless Ash exposed
      the fact set, which it does on policy denials): each policy with its
      condition applicability, per-check facts, and computed decision, plus
      `responsible` — the non-bypass policy `Ash.Policy.Policy.
      responsible_for_forbidden/2` holds accountable
    * `policies` / `field_policies` / `guidance` — the static listing, the
      same shape `AshAgentTools.Forbidden.explain_forbidden/2` reports
    * `input_valid?` — whether the built subject itself is valid; when
      false, `AshAgentTools.validate_input/3` has the detailed breakdown

  ## Examples

      iex> report = AshAgentTools.Can.can(AshAgentTools.Test.Guarded, :create, :none)
      iex> {report.allowed, report.verdict}
      {false, :forbidden}

  Raises `ArgumentError` for unknown resources/actions, malformed actor
  specs, and unresolvable actor records (with did_you_mean candidates for
  the resource name — and a kaizen tool-gap event, like every other miss).
  """
  @spec can(module(), atom() | String.t(), actor_spec(), map(), keyword()) :: map()
  def can(resource, action_name, actor, params \\ %{}, opts \\ []) do
    Describe.ensure_resource!(resource)
    action = Describe.resolve_action!(resource, action_name)
    params = params || %{}

    {actor_record, actor_report} = resolve_actor!(actor, resource, action, opts)
    {target, target_note} = resolve_target!(resource, action, actor_record, opts)

    subject = build_subject(resource, action, params, target)

    case run_check(subject, actor_record) do
      {:ok, verdict, notes, policy_error} ->
        report =
          report(resource, action, actor_report, verdict, notes, policy_error, subject, %{
            "target_note" => target_note
          })

        report

      {:error, error} ->
        # Ash refused to evaluate (e.g. a runtime check needing initial data).
        # The honest answer is :maybe with the reason, not a raise: the tool
        # answered everything it could.
        notes = ["Ash could not fully evaluate the action: #{Types.error_message(error)}"]

        report(resource, action, actor_report, :maybe, notes, nil, subject, %{
          "target_note" => target_note
        })
    end
  end

  # -- the verdict -----------------------------------------------------------

  defp run_check(subject, actor_record) do
    case Ash.can(subject, actor_record,
           return_forbidden_error?: true,
           run_queries?: false
         ) do
      {:ok, true} ->
        {:ok, :allowed, [], nil}

      {:ok, :maybe} ->
        {:ok, :maybe,
         [
           "The verdict is :maybe: some checks could not be decided without " <>
             "data-layer access (this evaluation runs with run_queries?: false)."
         ], nil}

      {:ok, false, error} ->
        policy_error = find_policy_error(error)

        notes =
          if policy_error do
            []
          else
            ["Ash denied the action without a policy breakdown: #{Types.error_message(error)}"]
          end

        {:ok, :forbidden, notes, policy_error}

      {:error, error} ->
        {:error, error}
    end
  end

  defp report(resource, action, actor_report, verdict, notes, policy_error, subject, extra) do
    listing = Forbidden.explain_forbidden(resource, action.name)

    notes =
      Enum.reject(
        [
          notes_head(listing, verdict),
          extra["target_note"],
          input_note(subject)
          | notes
        ],
        &is_nil/1
      )

    %{
      resource: resource,
      action: action.name,
      action_type: action.type,
      actor: actor_report,
      allowed: verdict == :allowed,
      verdict: verdict,
      per_policy: per_policy(policy_error),
      responsible: responsible(policy_error),
      policies: listing.policies,
      field_policies: listing.field_policies,
      guidance: listing.guidance,
      input_valid?: subject_valid?(subject),
      notes: notes
    }
  end

  defp notes_head(listing, _verdict) do
    if listing.policies == [] and listing.field_policies == [] do
      "No policies are declared for this resource — the verdict comes from " <>
        "Ash's other authorizers, not from Ash.Policy.Authorizer."
    end
  end

  defp input_note(subject) do
    unless subject_valid?(subject) do
      "The built subject itself has errors (invalid input): the verdict is " <>
        "the policy decision for this input as given — run validate_input/3 " <>
        "for the input-level breakdown."
    end
  end

  defp subject_valid?(subject), do: subject.valid? != false

  # -- the fact-backed per-policy breakdown ---------------------------------

  # Ash attaches the evaluated fact set to policy forbidden errors; the
  # breakdown below only reads what Ash already computed.
  defp find_policy_error(%Ash.Error.Forbidden.Policy{} = policy_error), do: policy_error

  defp find_policy_error(%{errors: errors}) when is_list(errors) do
    Enum.find(errors, &is_struct(&1, Ash.Error.Forbidden.Policy))
  end

  defp find_policy_error(_), do: nil

  defp per_policy(nil), do: []

  defp per_policy(%Ash.Error.Forbidden.Policy{} = policy_error) do
    facts = policy_error.facts

    policy_error.policies
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {policy, index} ->
      %{
        index: index,
        bypass?: Map.get(policy, :bypass?, false),
        access_type: Map.get(policy, :access_type),
        description: Map.get(policy, :description),
        condition: Enum.map(List.wrap(policy.condition), &describe_check/1),
        applies?: condition_applies?(policy, facts),
        decision: Ash.Policy.Policy.evaluate(policy, facts),
        checks: Enum.map(List.wrap(policy.policies), &check_entry(&1, facts))
      }
    end)
  end

  defp check_entry(check, facts) do
    %{
      type: Map.get(check, :type),
      description: describe_check(check),
      fact: fact_status(facts, check)
    }
  end

  # Mirrors Ash.Policy.Policy.fetch_fact/2 (:error means "the solver never
  # needed this check" — the `?` of Ash's own breakdowns).
  defp fact_status(facts, %{check_module: module, check_opts: opts}),
    do: fact_status(facts, {module, opts})

  defp fact_status(facts, check_ref) do
    case Ash.Policy.Policy.fetch_fact(facts, check_ref) do
      {:ok, fact} when is_boolean(fact) -> fact
      _ -> :unknown
    end
  end

  # Mirrors the applicability rule behind
  # `Ash.Policy.Policy.responsible_for_forbidden/2`: a condition applies when
  # none of its checks resolved to false.
  defp condition_applies?(policy, facts) do
    policy.condition
    |> List.wrap()
    |> Enum.all?(fn check -> fetch_fact?(facts, check) != false end)
  end

  defp fetch_fact?(facts, %{check_module: module, check_opts: opts}),
    do: fetch_fact?(facts, {module, opts})

  defp fetch_fact?(facts, check_ref) do
    case Ash.Policy.Policy.fetch_fact(facts, check_ref) do
      {:ok, fact} -> fact == true
      _ -> :unknown
    end
  end

  defp responsible(nil), do: nil

  defp responsible(%Ash.Error.Forbidden.Policy{} = policy_error) do
    policies = List.wrap(policy_error.policies)
    facts = policy_error.facts

    case Ash.Policy.Policy.responsible_for_forbidden(policies, facts) do
      {policy, reason} when is_atom(reason) ->
        index = Enum.find_index(policies, &(&1 == policy))

        %{
          index: index,
          reason: reason,
          bypass?: Map.get(policy, :bypass?, false),
          access_type: Map.get(policy, :access_type),
          condition: Enum.map(List.wrap(policy.condition), &describe_check/1),
          checks: Enum.map(List.wrap(policy.policies), &check_entry(&1, facts))
        }

      nil ->
        nil
    end
  end

  # -- subject construction ---------------------------------------------------

  defp build_subject(resource, action, params, target) do
    case action.type do
      :create -> Ash.Changeset.for_create(resource, action.name, params, error?: false)
      :update -> Ash.Changeset.for_update(target, action.name, params, error?: false)
      :destroy -> Ash.Changeset.for_destroy(target, action.name, params, error?: false)
      :read -> Ash.Query.for_read(resource, action.name, params, error?: false)
      :action -> Ash.ActionInput.for_action(resource, action.name, params)
    end
  end

  # -- actor + target resolution ----------------------------------------------

  defp resolve_actor!(nil, _resource, _action, _opts),
    do: {nil, %{kind: :none, resource: nil, id: nil}}

  defp resolve_actor!(:none, _resource, _action, _opts),
    do: {nil, %{kind: :none, resource: nil, id: nil}}

  # The target record itself acts: resolved from `record:` first, then used
  # as the changeset's data too (the default target).
  defp resolve_actor!(:record, resource, _action, opts) do
    case Keyword.fetch(opts, :record) do
      {:ok, %^resource{} = record} ->
        {record,
         %{kind: :record, resource: resource, id: Types.to_json_safe(Map.get(record, :id))}}

      {:ok, id} ->
        record = get_target!(resource, id)

        {record,
         %{kind: :record, resource: resource, id: Types.to_json_safe(Map.get(record, :id))}}

      :error ->
        raise ArgumentError,
              "actor spec :record needs the :record option (a target record or id) to resolve"
    end
  end

  defp resolve_actor!(%{resource: resource, id: id}, _resource, _action, _opts)
       when is_atom(resource),
       do: fetch_actor!(resource, id)

  defp resolve_actor!(%{"resource" => resource, "id" => id}, _resource, _action, _opts)
       when is_binary(resource),
       do: fetch_actor!(Module.concat([resource]), id)

  defp resolve_actor!(actor, _resource, _action, _opts) when is_struct(actor),
    do: {actor, %{kind: :record, resource: actor.__struct__, id: Map.get(actor, :id)}}

  defp resolve_actor!(other, _resource, _action, _opts) do
    raise ArgumentError,
          "invalid actor spec #{inspect(other)}: use nil, :none," <>
            " %{resource: Module, id: id}, or an actor record struct"
  end

  defp fetch_actor!(resource, id) do
    case get_record(resource, id) do
      {:ok, record} ->
        {record,
         %{
           kind: :record,
           resource: resource,
           id: Types.to_json_safe(record |> Map.get(:id))
         }}

      {:error, message} ->
        emit_resolve_gap!(resource, id)
        name = Registry.module_name(resource)

        raise ArgumentError,
              "could not resolve the actor record #{name} with id #{inspect(id)}:" <>
                " #{message}. did_you_mean: #{inspect(actor_did_you_mean(name))}"
    end
  end

  # The only data-layer touch of the tool: the actor read, unauthorized by
  # construction (authorize?: false).
  defp get_record(resource, id) do
    {:ok, Ash.get!(resource, id, authorize?: false)}
  rescue
    error -> {:error, Types.error_message(error)}
  end

  defp actor_did_you_mean(name), do: Suggest.closest(name, resource_names())

  defp resource_names do
    Enum.flat_map(Registry.list_resources(), fn resource ->
      [Registry.module_name(resource)]
    end)
  end

  # The actor-resource miss is a tool miss like any other: the agent named a
  # resource this VM does not have (or an id that does not exist).
  defp emit_resolve_gap!(resource, id) do
    name = Registry.module_name(resource)

    Kaizen.emit(:can, :actor_resolve_miss, "#{name}/#{inspect(id)}", %{
      resource: name,
      id: Types.to_json_safe(id),
      did_you_mean: actor_did_you_mean(name)
    })
  end

  # update/destroy subjects need a target record: `record:` (record or id)
  # wins, then the resolved actor record, then an empty struct (the changeset
  # is only built, never run).
  defp resolve_target!(_resource, %{type: type}, _actor_record, _opts)
       when type in [:create, :read, :action] do
    {nil, nil}
  end

  defp resolve_target!(resource, _action, actor_record, opts) do
    case Keyword.fetch(opts, :record) do
      {:ok, %^resource{} = record} when not is_nil(record) ->
        {record, "target record: #{Registry.module_name(resource)} resolved from :record"}

      {:ok, id} when not is_nil(id) ->
        record = get_target!(resource, id)
        {record, "target record: #{Registry.module_name(resource)} resolved by id"}

      _ when actor_record != nil ->
        {actor_record,
         "target record: the actor's own record (pass record: to target a different record)"}

      _ ->
        {struct(resource, %{}),
         "target record: an empty #{Registry.module_name(resource)} struct (the changeset is " <>
           "only built, never run; pass record: for a real target)"}
    end
  end

  defp get_target!(resource, id) do
    case get_record(resource, id) do
      {:ok, record} ->
        record

      {:error, message} ->
        raise ArgumentError,
              "could not resolve the target record #{Registry.module_name(resource)}" <>
                " with id #{inspect(id)}: #{message}"
    end
  end

  # Human-readable check descriptions: the same renderer explain_forbidden
  # uses, so both tools describe a policy identically.
  defp describe_check(check), do: Forbidden.describe_check(check)
end
