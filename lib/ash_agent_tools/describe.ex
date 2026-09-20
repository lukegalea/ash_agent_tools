# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Describe do
  @moduledoc """
  Read-only structural descriptions of Ash resources and actions.

  Every function here is a pure projection of `Ash.Resource.Info` /
  `Ash.Domain.Info` state into plain, JSON-encodable maps, with source
  locations lifted from Spark annotations where available. Nothing mutates,
  executes, or persists anything.
  """

  alias AshAgentTools.Registry
  alias AshAgentTools.Source
  alias AshAgentTools.Suggest
  alias AshAgentTools.Types

  @doc """
  Describes a resource: identity, fields, relationships, and actions.

  Raises `ArgumentError` when `resource` is not a loaded Ash resource.
  """
  @spec describe_resource(module()) :: map()
  def describe_resource(resource) do
    ensure_resource!(resource)

    %{
      module: resource,
      short_name: Ash.Resource.Info.short_name(resource),
      domain: Ash.Resource.Info.domain(resource),
      description: Ash.Resource.Info.description(resource),
      data_layer: Registry.module_name(Ash.DataLayer.data_layer(resource)),
      primary_key: Ash.Resource.Info.primary_key(resource),
      multitenancy: multitenancy(resource),
      source: Source.from_module(resource),
      fields: fields(resource),
      relationships: relationships(resource),
      actions: actions(resource)
    }
  end

  @doc """
  Describes a single action: input contract, return shape, code interfaces,
  source location.

  Raises `ArgumentError` for unknown resources and actions.
  """
  @spec describe_action(module(), atom() | String.t()) :: map()
  def describe_action(resource, action_name) do
    ensure_resource!(resource)
    action = resolve_action!(resource, action_name)

    %{
      resource: resource,
      name: action.name,
      type: action.type,
      description: Map.get(action, :description),
      accept: accept(action),
      returns: return_shape(resource, action),
      arguments: Enum.map(action.arguments, &argument_info/1),
      input: input_contract(resource, action),
      code_interfaces: code_interfaces(resource, action),
      source: Source.from_entity(action)
    }
  end

  @doc false
  # Resolves an action name (atom or string) against `resource` and returns
  # the action entity. Agent-supplied action names arrive as JSON strings;
  # `String.to_existing_atom/1` on a name whose atom does not exist raises a
  # bare ArgumentError (and is non-deterministic — it succeeds whenever the
  # atom happens to be in the table), so both failure modes are funneled
  # into one enriched error with did_you_mean candidates from the real
  # action list.
  def resolve_action!(resource, name) when is_atom(name) do
    Ash.Resource.Info.action(resource, name) || unknown_action!(resource, Atom.to_string(name))
  end

  def resolve_action!(resource, name) when is_binary(name) do
    atom =
      try do
        String.to_existing_atom(name)
      rescue
        ArgumentError -> :error
      end

    case atom do
      :error -> unknown_action!(resource, name)
      atom -> Ash.Resource.Info.action(resource, atom) || unknown_action!(resource, name)
    end
  end

  @doc """
  The action names of `resource` closest to a missed action name, closest
  first (at most 3). Never raises; an unknown resource suggests nothing.
  The same candidates back the enriched unknown-action errors.
  """
  @spec action_did_you_mean(module(), atom() | String.t()) :: [String.t()]
  def action_did_you_mean(resource, name) do
    if function_exported?(resource, :spark_is, 0) do
      Suggest.closest(to_string(name), action_names(resource))
    else
      []
    end
  end

  defp action_names(resource),
    do: Enum.map(Ash.Resource.Info.actions(resource), &Atom.to_string(&1.name))

  defp unknown_action!(resource, name) do
    did_you_mean = action_did_you_mean(resource, name)

    hint =
      if did_you_mean == [] do
        "Valid actions: #{inspect(Enum.map(Ash.Resource.Info.actions(resource), & &1.name))}"
      else
        "Did you mean: #{inspect(did_you_mean)}?"
      end

    raise ArgumentError,
          "#{Registry.module_name(resource)} has no action named #{inspect(name)}. #{hint}"
  end

  # -- describe_resource ------------------------------------------------

  defp fields(resource) do
    Enum.map(Ash.Resource.Info.attributes(resource), fn attribute ->
      %{
        name: attribute.name,
        type: Types.normalize(attribute.type),
        constraints: constraints(attribute.constraints),
        allow_nil?: attribute.allow_nil?,
        default: default_value(attribute.default),
        primary_key?: Map.get(attribute, :primary_key?, false),
        sensitive?: Map.get(attribute, :sensitive?, false),
        public?: Map.get(attribute, :public?, false),
        description: Map.get(attribute, :description),
        source: Source.from_entity(attribute)
      }
    end)
  end

  defp relationships(resource) do
    Enum.map(Ash.Resource.Info.relationships(resource), fn relationship ->
      %{
        name: relationship.name,
        type: relationship.type,
        destination: relationship.destination,
        cardinality: Map.get(relationship, :cardinality),
        source_attribute: Map.get(relationship, :source_attribute),
        destination_attribute: Map.get(relationship, :destination_attribute),
        public?: Map.get(relationship, :public?, false),
        description: Map.get(relationship, :description),
        source: Source.from_entity(relationship)
      }
    end)
  end

  defp actions(resource) do
    Enum.map(Ash.Resource.Info.actions(resource), fn action ->
      %{
        name: action.name,
        type: action.type,
        description: Map.get(action, :description),
        accept: accept(action),
        arguments: Enum.map(action.arguments, &argument_info/1),
        source: Source.from_entity(action)
      }
    end)
  end

  defp multitenancy(resource) do
    %{
      strategy: Ash.Resource.Info.multitenancy_strategy(resource),
      attribute: Ash.Resource.Info.multitenancy_attribute(resource),
      global?: Ash.Resource.Info.multitenancy_global?(resource)
    }
  end

  # -- describe_action --------------------------------------------------

  defp argument_info(argument) do
    %{
      name: argument.name,
      type: Types.normalize(argument.type),
      required?: argument.allow_nil? == false and is_nil(argument.default),
      allow_nil?: argument.allow_nil?,
      default: default_value(argument.default),
      public?: Map.get(argument, :public?, true),
      description: Map.get(argument, :description),
      source: Source.from_entity(argument)
    }
  end

  # The union of action arguments and accepted attributes, split into what an
  # agent *must* provide and what it *may* provide. On :create, accepted
  # attributes without a default that disallow nil are required; on the other
  # action types the record already exists (or no record is involved), so
  # accepted attributes are optional.
  defp input_contract(resource, action) do
    arguments = action.arguments
    attributes = accepted_attributes(resource, action)

    required_arguments = Enum.filter(arguments, &required_argument?/1)

    required_attributes =
      if action.type == :create, do: required_create_attributes(attributes), else: []

    required_names =
      Enum.map(required_arguments, & &1.name) ++ Enum.map(required_attributes, & &1.name)

    %{
      required: required_names,
      optional:
        for(
          entry <- arguments ++ attributes,
          entry.name not in required_names,
          do: %{name: entry.name, type: Types.normalize(entry.type)}
        ),
      private:
        for(
          entry <- arguments ++ attributes,
          Map.get(entry, :public?, true) == false,
          do: entry.name
        )
    }
  end

  defp required_argument?(argument) do
    argument.allow_nil? == false and is_nil(argument.default)
  end

  defp accepted_attributes(resource, action) do
    case accept(action) do
      nil -> []
      accept -> Enum.filter(Ash.Resource.Info.attributes(resource), &(&1.name in accept))
    end
  end

  defp required_create_attributes(attributes) do
    Enum.filter(attributes, fn attribute ->
      attribute.allow_nil? == false and is_nil(attribute.default) and
        not Map.get(attribute, :primary_key?, false)
    end)
  end

  defp return_shape(resource, action) do
    case action.type do
      :create -> %{kind: :record, type: resource}
      :update -> %{kind: :record, type: resource}
      :destroy -> %{kind: :record, type: resource}
      :read -> %{kind: :list, type: resource}
      :action -> generic_return_shape(action)
      _ -> %{kind: :unknown, type: nil}
    end
  end

  defp generic_return_shape(action) do
    case Map.get(action, :returns) do
      nil -> %{kind: :value, type: nil}
      returns -> %{kind: :value, type: Types.normalize(returns)}
    end
  end

  # Code interfaces can be defined on the resource itself (`code_interface`
  # block with a `domain` option) or on a domain (`define` inside the
  # domain's `resources` block). Report both, attributing the domain.
  defp code_interfaces(resource, action) do
    resource_interfaces =
      for interface <- Ash.Resource.Info.interfaces(resource),
          interface.action == action.name or interface.name == action.name do
        %{
          name: interface.name,
          domain: Ash.Resource.Info.code_interface_domain(resource),
          on_resource?: true,
          get?: Map.get(interface, :get?, false),
          get_by: Map.get(interface, :get_by, []),
          args: Map.get(interface, :args, [])
        }
      end

    domain_interfaces =
      for domain <- Registry.domains_for_resource(resource),
          reference <- Ash.Domain.Info.resource_references(domain),
          reference.resource == resource,
          interface <- Map.get(reference, :define, []),
          interface.action == action.name or interface.name == action.name do
        %{
          name: interface.name,
          domain: domain,
          on_resource?: false,
          get?: Map.get(interface, :get?, false),
          get_by: Map.get(interface, :get_by, []),
          args: Map.get(interface, :args, [])
        }
      end

    Enum.uniq_by(resource_interfaces ++ domain_interfaces, &{&1.name, &1.domain})
  end

  # -- shared helpers ---------------------------------------------------

  defp accept(action), do: Map.get(action, :accept)

  defp default_value(default), do: Types.to_json_safe(default)

  defp constraints(constraints) do
    Map.new(constraints, fn {key, value} -> {key, Types.to_json_safe(value)} end)
  end

  @doc false
  def ensure_resource!(resource) do
    if function_exported?(resource, :spark_is, 0) and resource.spark_is() == Ash.Resource do
      :ok
    else
      raise ArgumentError,
            "#{inspect(resource)} is not a loaded Ash resource." <>
              " Compile your application and make sure the module is loaded" <>
              " (see AshAgentTools.list_resources/0)."
    end
  end
end
