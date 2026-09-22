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

  alias AshAgentTools.Kaizen
  alias AshAgentTools.Registry
  alias AshAgentTools.Source
  alias AshAgentTools.Suggest
  alias AshAgentTools.Symbols
  alias AshAgentTools.Types

  @valid_kinds [:attribute, :action, :calculation, :relationship]

  @default_max_results 100

  @kind_lookup Map.new(@valid_kinds, fn kind -> {Atom.to_string(kind), kind} end)

  @doc """
  The symbol kinds `semantic_search/2` knows, in result-order preference:
  the four core kinds, plus whatever kinds the generic extension-section
  probe (`AshAgentTools.Symbols.extension_symbols/1`) currently projects
  across loaded resources — a custom Spark DSL's sections become
  searchable (and filterable) the moment a resource declares them.
  """
  @spec valid_kinds() :: [atom()]
  def valid_kinds, do: Enum.uniq(@valid_kinds ++ dynamic_kinds())

  @doc """
  Searches symbol names across all loaded Ash resources by substring.

  Matching is case-insensitive on the symbol name; the declaring resource's
  module name is *not* matched. Results are sorted by resource, kind, then
  name, so the output is deterministic. Each hit carries:

    * `resource` — the declaring resource module
    * `kind` — `:attribute`, `:action`, `:calculation`, `:relationship`,
      or a namespaced custom extension kind (see `valid_kinds/0`)
    * `name` — the symbol name
    * `type` — the normalized type (`Types.normalize/1` for fields,
      the action/relationship type for actions and relationships)
    * `source` — the Spark annotation location (`file`, `line`, `column`),
      best-effort and `nil` where unavailable

  Options:

    * `:kinds` — restrict the search to one kind or a list of kinds
      (atoms or strings). Unknown kinds raise `ArgumentError`; the valid
      set is `valid_kinds/0` — the core kinds plus the custom extension
      kinds currently projected.
    * `:max_results` — refinement limit (positive integer, default
      #{@default_max_results}): when more symbols match, the search raises
      with per-resource counts instead of returning a wall of hits
      (Serena's over-limit refinement).

  Raises `ArgumentError` for a non-binary or blank search term, or an
  unknown kind in the filter. Like the other discovery functions, it never
  raises for *what it finds* — no match is an empty list (and the miss is
  reported to the kaizen loop, see `did_you_mean/1`).

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
    started = System.monotonic_time(:millisecond)
    term = String.trim(term)

    if term == "" do
      raise ArgumentError, "search term must be a non-blank string"
    end

    kinds = validate_kinds!(Keyword.get(opts, :kinds))
    max_results = max_results!(opts)
    needle = String.downcase(term)

    results =
      for result <- collect(needle), kind_allowed?(result, kinds) do
        result
      end
      |> Enum.sort_by(&{Registry.module_name(&1.resource), Atom.to_string(&1.kind), &1.name})

    results =
      if length(results) > max_results do
        # Serena-style over-limit refinement: refuse with the per-resource
        # counts instead of returning a wall of hits.
        counts =
          Enum.frequencies_by(results, &Registry.module_name(&1.resource))

        raise ArgumentError,
              "too many results for #{inspect(term)}: #{length(results)} symbols across" <>
                " #{map_size(counts)} resource(s), exceeding :max_results (#{max_results})." <>
                " Refine the term or raise :max_results. Counts: #{inspect(counts)}"
      else
        results
      end

    if results == [] do
      # The tool could not answer: report the miss (with the closest real
      # symbol names) to the kaizen loop, then still return the honest [].
      duration_ms = System.monotonic_time(:millisecond) - started

      Kaizen.emit(:search, :search_miss, term, %{term: term, did_you_mean: did_you_mean(term)},
        duration_ms: duration_ms
      )
    end

    results
  end

  def semantic_search(term, _opts) do
    raise ArgumentError, "search term must be a string, got: #{inspect(term)}"
  end

  defp max_results!(opts) do
    max = Keyword.get(opts, :max_results, @default_max_results)

    if is_integer(max) and max > 0 do
      max
    else
      raise ArgumentError, ":max_results must be a positive integer, got: #{inspect(max)}"
    end
  end

  @doc """
  The closest known symbol names to a missed search term, closest first
  (at most 5, case-insensitive Levenshtein distance at most 3). Never
  raises: a blank or non-binary term, or a world with no symbols, simply
  suggests nothing. The same suggestions ride the kaizen
  `[:ash_agent, :tool_gap]` event for every search miss.

  ## Examples

      iex> AshAgentTools.Search.did_you_mean("tgas")
      ["tags", "read"]

      iex> AshAgentTools.Search.did_you_mean("")
      []

  """
  @spec did_you_mean(term()) :: [String.t()]
  def did_you_mean(term)

  def did_you_mean(term) when is_binary(term) do
    case String.trim(term) do
      "" ->
        []

      trimmed ->
        candidates =
          for resource <- Registry.list_resources(),
              entry <- symbols(resource),
              uniq: true do
            Atom.to_string(entry.name)
          end

        Suggest.closest(trimmed, candidates, 5)
    end
  end

  def did_you_mean(_term), do: []

  defp validate_kinds!(nil), do: nil

  defp validate_kinds!(kind) when is_atom(kind) or is_binary(kind), do: validate_kinds!([kind])

  defp validate_kinds!(kinds) when is_list(kinds) do
    MapSet.new(kinds, fn kind ->
      normalized =
        cond do
          is_atom(kind) and kind in valid_kinds() -> kind
          is_binary(kind) and Map.has_key?(@kind_lookup, kind) -> Map.fetch!(@kind_lookup, kind)
          is_binary(kind) and kind in dynamic_kind_names() -> String.to_atom(kind)
          true -> raise ArgumentError, unknown_kind_message(kind)
        end

      normalized
    end)
  end

  defp validate_kinds!(other), do: raise(ArgumentError, unknown_kind_message(other))

  defp unknown_kind_message(kind) do
    "unknown symbol kind #{inspect(kind)}." <>
      " Valid kinds: #{inspect(valid_kinds())} (strings accepted too)"
  end

  # The kinds the generic extension-section probe currently projects
  # (empty in an application with no custom Spark resource extensions).
  defp dynamic_kinds do
    for resource <- Registry.list_resources(),
        symbol <- Symbols.extension_symbols(resource),
        uniq: true do
      symbol.kind
    end
  end

  defp dynamic_kind_names, do: Enum.map(dynamic_kinds(), &Atom.to_string/1)

  defp kind_allowed?(_result, nil), do: true
  defp kind_allowed?(result, kinds), do: MapSet.member?(kinds, result.kind)

  # One pass over every loaded resource, collecting the core kinds plus
  # whatever custom extension sections are projected. All resources are
  # visited even with a kind filter: the filter is cheap,
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
      end) ++ extension_symbols(resource)
  end

  # Custom extension-section symbols (see
  # `AshAgentTools.Symbols.extension_symbols/1`), mapped into the search
  # hit shape. The four core kinds stay in `symbols/1` above: their
  # projections and this one must not double-report.
  defp extension_symbols(resource) do
    for symbol <- Symbols.extension_symbols(resource) do
      %{
        resource: resource,
        kind: symbol.kind,
        name: symbol.name,
        type: symbol.type,
        source: symbol.source
      }
    end
  end
end
