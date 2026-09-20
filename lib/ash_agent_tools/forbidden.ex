# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Forbidden do
  @moduledoc """
  Explains what can forbid an action: a policy listing with general guidance.

  This is intentionally a *guidance stub*, not an authorization evaluator.
  Determining an actual verdict requires an actor and a query/changeset —
  use `Ash.can?/3` (or the generated `can_*?` code interfaces) for that.
  What agents usually need after a `Forbidden` error is to see *which rules
  exist*, which this module reports in human-readable form via
  `Ash.Policy.Check.describe/2`.
  """

  alias AshAgentTools.Describe
  alias AshAgentTools.Registry

  @doc """
  Lists the resource's authorization policies (and field policies) with
  general hints.

  `action_name` is optional; it is echoed into the report for context. The
  report is a plain, JSON-encodable map. Resources without the
  `Ash.Policy.Authorizer` return `policies: []` with a note.
  """
  @spec explain_forbidden(module(), atom() | String.t() | nil) :: map()
  def explain_forbidden(resource, action_name \\ nil) do
    Describe.ensure_resource!(resource)
    action_name = normalize_action_name(action_name)

    authorizers = Ash.Resource.Info.authorizers(resource)
    policy_authorizer? = Ash.Policy.Authorizer in authorizers

    %{
      resource: resource,
      action: action_name,
      authorizers: Enum.map(authorizers, &Registry.module_name/1),
      policies: policies(resource, policy_authorizer?),
      field_policies: field_policies(resource, policy_authorizer?),
      guidance: guidance(resource, policy_authorizer?)
    }
  end

  defp policies(resource, true = _policy_authorizer?) do
    resource
    |> Ash.Policy.Info.policies()
    |> Enum.map(fn policy ->
      %{
        bypass?: policy.bypass?,
        access_type: policy.access_type,
        description: Map.get(policy, :description),
        condition: Enum.map(List.wrap(policy.condition), &describe_check/1),
        checks: Enum.map(policy.policies, &describe_check/1)
      }
    end)
  end

  defp policies(_resource, false), do: []

  defp field_policies(resource, true = _policy_authorizer?) do
    resource
    |> Ash.Policy.Info.field_policies()
    |> Enum.map(fn field_policy ->
      %{
        fields: List.wrap(Map.get(field_policy, :fields)),
        bypass?: field_policy.bypass?,
        access_type: field_policy.access_type,
        condition: Enum.map(List.wrap(field_policy.condition), &describe_check/1),
        checks: Enum.map(field_policy.policies, &describe_check/1)
      }
    end)
  end

  defp field_policies(_resource, false), do: []

  # Condition/check entries are `%Ash.Policy.Check{}` structs (from `condition`
  # blocks) or `{module, opts}` / `module` refs (from policy-group
  # conditions); normalize all shapes.
  defp describe_check(%Ash.Policy.Check{} = check) do
    Ash.Policy.Check.describe(check.check_module, check.check_opts || [])
  rescue
    _ -> "#{Registry.module_name(check.check_module)} (description unavailable)"
  end

  defp describe_check({module, opts}) do
    Ash.Policy.Check.describe(module, opts || [])
  rescue
    _ -> "#{Registry.module_name(module)} (description unavailable)"
  end

  defp describe_check(module) when is_atom(module) do
    describe_check({module, []})
  end

  defp describe_check(other), do: inspect(other)

  defp guidance(_resource, true = _policy_authorizer?) do
    [
      "Authorization is deny-by-default: every policy that applies to the action must pass.",
      "Within a policy, the first authorize_if/forbid_if/authorize_unless/forbid_unless check " <>
        "that produces a decision decides the policy; remaining checks are skipped.",
      "authorize_if checks are alternatives (OR): any passing authorize_if makes the policy pass. " <>
        "To require several conditions, use multiple policies or forbid_unless.",
      "bypass policies run before regular policies and, when their condition matches, can grant " <>
        "access regardless of the other policies — typically reserved for admins.",
      "Filter checks (:filter access type) scope the query instead of erroring: an unexpectedly " <>
        "empty result may mean the action was filtered rather than explicitly forbidden.",
      "To test a verdict, use Ash.can?/3 (or the generated can_<action>? code interface) with the " <>
        "intended actor rather than reasoning from the policy text alone."
    ]
  end

  defp guidance(resource, false = _policy_authorizer?) do
    [
      "#{Registry.module_name(resource)} does not use Ash.Policy.Authorizer, so policies are not " <>
        "the source of Forbidden errors here. Check the resource's other authorizers, " <>
        "tenancy (tenant mismatch), or the domain's authorization settings."
    ]
  end

  defp normalize_action_name(nil), do: nil
  defp normalize_action_name(name) when is_atom(name), do: name
  defp normalize_action_name(name) when is_binary(name), do: String.to_existing_atom(name)
end
