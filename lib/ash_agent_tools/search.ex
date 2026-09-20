# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Search do
  @moduledoc """
  Substring search over the symbols of all loaded Ash resources.

  `semantic_search/2` is the "where is `tag` defined?" entry point for an
  agent that knows a name fragment but not which resource declares it. It is
  a pure function over already-loaded modules (see `AshAgentTools.list_domains/0`
  for the loaded-modules caveat): every hit is projected into a plain,
  JSON-encodable map with the declaring resource, the symbol kind, its
  normalized type, and its Spark source location.
  """

  alias AshAgentTools.Registry
  alias AshAgentTools.Source
  alias AshAgentTools.Types

  @valid_kinds [:attribute, :action, :calculation, :relationship]

  @kind_lookup Map.new(@valid_kinds, fn kind -> {Atom.to_string(kind), kind} end)

  @doc """
  The symbol kinds `semantic_search/2` knows, in result-order preference.
  """
  @spec valid_kinds() :: [:attribute | :action | :calculation | :relationship]
  def valid_kinds, do: @valid_kinds

  @doc """
  Searches symbol names across all loaded Ash resources by substring.

  Matching is case-insensitive on the symbol name; the declaring resource's
  module name is *not* matched. Results are sorted by resource, kind, then
  name, so the output is deterministic. Each hit carries:

    * `resource` — the declaring resource module
    * `kind` — `:attribute`, `:action`, `:calculation`, or `:relationship`
    * `name` — the symbol name
    * `type` — the normalized type (`Types.normalize/1` for fields,
      the action/relationship type for actions and relationships)
    * `source` — the Spark annotation location (`file`, `line`, `column`),
      best-effort and `nil` where unavailable

  Options:

    * `:kinds` — restrict the search to one kind or a list of kinds
      (atoms or strings). Unknown kinds raise `ArgumentError`.

  Raises `ArgumentError` for a non-binary or blank search term, or an
  unknown kind in the filter. Like the other discovery functions, it never
  raises for *what it finds* — no match is an empty list.

  ## Examples

      iex> results = AshAgentTools.semantic_search("tag")
      iex> hit = Enum.find(results, &(&1.resource == AshAgentTools.Test.Post and &1.kind == :action and &1.name == :by_tag))
      iex> hit.type
      :read

      iex> results = AshAgentTools.semantic_search("TAG", kinds: [:attribute])
      iex> Enum.map(results, & &1.name)
      [:tags]

      iex> results = AshAgentTools.semantic_search("author", kinds: :relationship)
      iex> Enum.map(results, &{&1.resource, &1.name})
      [{AshAgentTools.Test.Post, :author}]

  """
  @spec semantic_search(String.t(), keyword()) :: [map()]
  def semantic_search(term, opts \\ [])

  def semantic_search(term, opts) when is_binary(term) do
    term = String.trim(term)

    if term == "" do
      raise ArgumentError, "search term must be a non-blank string"
    end

    kinds = validate_kinds!(Keyword.get(opts, :kinds))
    needle = String.downcase(term)

    for result <- collect(needle), kind_allowed?(result, kinds) do
      result
    end
    |> Enum.sort_by(&{Registry.module_name(&1.resource), Atom.to_string(&1.kind), &1.name})
  end

  def semantic_search(term, _opts) do
    raise ArgumentError, "search term must be a string, got: #{inspect(term)}"
  end

  defp validate_kinds!(nil), do: nil

  defp validate_kinds!(kind) when is_atom(kind) or is_binary(kind), do: validate_kinds!([kind])

  defp validate_kinds!(kinds) when is_list(kinds) do
    MapSet.new(kinds, fn kind ->
      normalized =
        cond do
          is_atom(kind) and kind in @valid_kinds -> kind
          is_binary(kind) and Map.has_key?(@kind_lookup, kind) -> Map.fetch!(@kind_lookup, kind)
          true -> raise ArgumentError, unknown_kind_message(kind)
        end

      normalized
    end)
  end

  defp validate_kinds!(other), do: raise(ArgumentError, unknown_kind_message(other))

  defp unknown_kind_message(kind) do
    "unknown symbol kind #{inspect(kind)}." <>
      " Valid kinds: #{inspect(@valid_kinds)} (strings accepted too)"
  end

  defp kind_allowed?(_result, nil), do: true
  defp kind_allowed?(result, kinds), do: MapSet.member?(kinds, result.kind)

  # One pass over every loaded resource, collecting the four symbol kinds.
  # All resources are visited even with a kind filter: the filter is cheap,
  # and the sorted result makes the ordering deterministic either way.
  defp collect(needle) do
    for resource <- Registry.list_resources(),
        entry <- symbols(resource),
        String.contains?(String.downcase(Atom.to_string(entry.name)), needle) do
      entry
    end
  end

  defp symbols(resource) do
    Enum.map(Ash.Resource.Info.attributes(resource), fn attribute ->
      %{
        resource: resource,
        kind: :attribute,
        name: attribute.name,
        type: Types.normalize(attribute.type),
        source: Source.from_entity(attribute)
      }
    end) ++
      Enum.map(Ash.Resource.Info.actions(resource), fn action ->
        %{
          resource: resource,
          kind: :action,
          name: action.name,
          type: action.type,
          source: Source.from_entity(action)
        }
      end) ++
      Enum.map(Ash.Resource.Info.calculations(resource), fn calculation ->
        %{
          resource: resource,
          kind: :calculation,
          name: calculation.name,
          type: Types.normalize(calculation.type),
          source: Source.from_entity(calculation)
        }
      end) ++
      Enum.map(Ash.Resource.Info.relationships(resource), fn relationship ->
        %{
          resource: resource,
          kind: :relationship,
          name: relationship.name,
          type: relationship.type,
          source: Source.from_entity(relationship)
        }
      end)
  end
end
