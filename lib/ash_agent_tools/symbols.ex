# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Symbols do
  @moduledoc """
  The shared symbol index over loaded Ash resources and domains.

  One projection of the DSL state that every position-aware tool consumes
  (`context/3`, name-path resolution, edits): each DSL entity becomes a
  plain map with its kind, name, normalized type, canonical `dsl_path`
  segment (`"attributes"`, `"actions"`, ..., `"policies"`), its occurrence
  `position` among same-kind-same-name symbols (policies are unnamed, so
  they are addressed as `policy[0]`, `policy[1]`, ...), and its best-effort
  Spark `source` location — `nil` for transformer-injected declarations
  (e.g. actions created by `defaults`), which is exactly the provenance
  signal the edit tools refuse on.

  Nothing here touches a file; spans are derived in `with_spans/2` from
  consecutive annotation starts, the same best-effort discipline as ever.
  """

  alias AshAgentTools.Source
  alias AshAgentTools.Types

  @typedoc "A canonical dsl_path segment for one symbol kind."
  @type dsl_path ::
          :attributes
          | :actions
          | :calculations
          | :relationships
          | :policies
          | :resource_references
          | :code_interfaces

  @spec resource_symbols(module()) :: [map()]
  def resource_symbols(resource) do
    Enum.map(Ash.Resource.Info.attributes(resource), fn attribute ->
      symbol(:attribute, "attributes", attribute.name, Types.normalize(attribute.type), attribute)
    end) ++
      Enum.map(Ash.Resource.Info.actions(resource), fn action ->
        symbol(:action, "actions", action.name, action.type, action)
      end) ++
      Enum.map(Ash.Resource.Info.calculations(resource), fn calculation ->
        symbol(
          :calculation,
          "calculations",
          calculation.name,
          Types.normalize(calculation.type),
          calculation
        )
      end) ++
      Enum.map(Ash.Resource.Info.relationships(resource), fn relationship ->
        symbol(:relationship, "relationships", relationship.name, relationship.type, relationship)
      end) ++
      policies(resource)
  end

  # Policies are unnamed DSL entities: addressed by occurrence
  # (`policies/policy[0]`), reported with the synthetic name `policy`.
  # Entities are read directly (and only when the resource actually uses
  # the policy authorizer) — the Ash.Policy.Info accessor requires a domain
  # and merges access types, which is report semantics, not index
  # semantics. Occurrences follow declaration order in the `policies` block
  # (bypass and policy groups included as declared).
  defp policies(resource) do
    if Ash.Policy.Authorizer in Ash.Resource.Info.authorizers(resource) do
      resource
      |> Spark.Dsl.Extension.get_entities([:policies])
      |> Enum.with_index()
      |> Enum.map(fn {policy, index} ->
        symbol(:policy, "policies", :policy, nil, policy, index)
      end)
    else
      []
    end
  end

  @spec domain_symbols(module()) :: [map()]
  def domain_symbols(domain) do
    references = Ash.Domain.Info.resource_references(domain)

    # Enum.map for the single-symbol builders: flat_map would flatten a
    # returned map into its {key, value} entries.
    Enum.map(references, fn reference ->
      symbol(:resource_reference, "resource_references", reference.resource, nil, reference)
    end) ++
      Enum.flat_map(references, fn reference ->
        Enum.map(Map.get(reference, :definitions, []), fn define ->
          symbol(
            :code_interface,
            "code_interfaces",
            define.name,
            Map.get(define, :action),
            define
          )
        end)
      end)
  end

  @spec module_symbols(module(), :resource | :domain) :: [map()]
  def module_symbols(module, :resource), do: resource_symbols(module)
  def module_symbols(module, :domain), do: domain_symbols(module)

  # A symbol keeps its Spark annotation as `source` when it pins both a
  # file and a line; transformer-injected declarations carry `source: nil`
  # and `provenance: :synthetic`.
  defp symbol(kind, dsl_path, name, type, entity, position \\ 0) do
    source = Source.from_entity(entity)

    %{
      kind: kind,
      dsl_path: dsl_path,
      name: name,
      type: type,
      position: position,
      source: source,
      provenance: if(source && source[:file] && source[:line], do: :source, else: :synthetic)
    }
  end

  @doc """
  A symbol's span runs from its annotated start line to the line before the
  next annotated symbol starts (best-effort: annotations carry starts, not
  ends). The last symbol's span extends to the end of the file. Symbols
  without an annotation get no span.
  """
  @spec with_spans([map()], non_neg_integer() | nil) :: [map()]
  def with_spans(symbols, line_count) do
    positioned = Enum.filter(symbols, & &1.source)

    positioned
    |> Enum.with_index()
    |> Enum.map(fn {symbol, index} ->
      start_line = symbol.source.line

      end_line =
        case Enum.at(positioned, index + 1) do
          nil -> line_count || start_line
          next -> max(next.source.line - 1, start_line)
        end

      Map.put(symbol, :span, %{start_line: start_line, end_line: end_line})
    end)
  end

  @spec line_count(String.t()) :: non_neg_integer() | nil
  def line_count(file) do
    case File.read(file) do
      {:ok, contents} -> contents |> String.split("\n") |> length()
      _ -> nil
    end
  end
end
