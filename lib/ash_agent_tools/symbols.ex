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

  Beyond the core sections, `resource_symbols/1` also projects the entities
  of the resource's *other* Spark extension sections generically (see
  `extension_symbols/1`): custom DSLs — an `a2ui do … end` block, a rules
  DSL — become symbols without any per-DSL code, so search, context,
  name paths and edits reach them through the same index.
  """

  alias AshAgentTools.Source
  alias AshAgentTools.Types

  @typedoc "A canonical dsl_path segment for one symbol kind."
  @type dsl_path :: String.t()

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
      policies(resource) ++
      extension_symbols(resource)
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

  @doc """
  The generic projection of the resource's *custom* Spark extension
  sections — everything beyond Ash's core DSL that the dedicated accessors
  above cover.

  ## Naming scheme

  Each section becomes one symbol kind named
  `<extension_short_name>_<section_path>`, where the extension short name
  is the underscored last component of the extension module with a
  trailing `_extension`/`_dsl` stripped (falling back to the previous
  component when that empties the name). `MyApp.Rules.Dsl` declaring
  `fact_schema do … end` projects kind `:"rules_fact_schema"` (dsl_path
  `"rules_fact_schema"`); a section nested inside another extends the path
  (`widgets` containing `gears` → `"probe_widgets_gears"`). The first
  extension to reach a section path owns its symbols: Spark merges
  same-named sections across extensions, so reading a path twice would
  double-project the same entities.

  Entity names come from the entity's own fields — the first of `:name`,
  `:id`, `:tag` holding an atom, binary, or integer, atomized. An entity
  exposing none of those (or an unexpected shape entirely) is projected
  with the positional fallback `<section>_<index>`, so foreign DSLs
  degrade into addressable symbols instead of raising. `type` is `nil`
  (nothing normalized to report), everything else matches the shared
  symbol shape: Spark annotation `source` when the entity carries one,
  `:synthetic` provenance otherwise.
  """
  @spec extension_symbols(module()) :: [map()]
  def extension_symbols(resource) do
    resource
    |> extensions()
    |> Enum.reject(&core_extension?/1)
    |> Enum.flat_map_reduce(MapSet.new(), fn extension, seen ->
      section_symbols(resource, extension, sections_of(extension), [], seen)
    end)
    |> elem(0)
    |> List.flatten()
  end

  # The extension modules Spark persisted on the resource: data layers,
  # authorizers, the core resource DSL, and every custom extension alike.
  defp extensions(resource) do
    resource
    |> Spark.Dsl.Extension.get_persisted(:spark_extensions, [])
    |> List.wrap()
    |> Enum.uniq()
  rescue
    _ -> []
  end

  # Ash's own namespaces are never projected generically: their sections
  # are either projected by the dedicated accessors above or deliberately
  # not symbols at all (validations, changes, aggregates, ...).
  defp core_extension?(extension) do
    case Module.split(extension) do
      ["Elixir", "Ash" | _rest] -> true
      _other -> false
    end
  end

  # Symbols for one extension's section tree, at any nesting depth. The
  # `seen` set is the dsl paths already claimed by an earlier extension —
  # Spark stores entities by section path, so two extensions declaring the
  # same section name share one path and one read.
  defp section_symbols(resource, extension, sections, prefix, seen) do
    Enum.flat_map_reduce(sections, seen, fn section, seen ->
      path = prefix ++ [section.name]

      if MapSet.member?(seen, path) do
        {[], seen}
      else
        seen = MapSet.put(seen, path)
        dsl_path = dsl_path(extension, path)

        entities =
          if reserved_section?(section.name), do: [], else: get_entities(resource, path)

        symbols =
          entities
          |> Enum.with_index()
          |> Enum.map(fn {entity, index} ->
            symbol(
              String.to_atom(dsl_path),
              dsl_path,
              entity_name(entity, section.name, index),
              nil,
              entity,
              index
            )
          end)

        {nested, seen} =
          section_symbols(resource, extension, section.sections, path, seen)

        {symbols ++ nested, seen}
      end
    end)
  end

  # A section tree, or [] for extension kinds that declare none (data
  # layers, authorizers, notifiers) or that return anything unexpected —
  # this is introspection over foreign DSLs, and a weird extension must
  # degrade, not crash.
  defp sections_of(extension) do
    if function_exported?(extension, :sections, 0) do
      extension.sections()
    else
      []
    end
    |> List.wrap()
    |> Enum.filter(&is_struct(&1, Spark.Dsl.Section))
  rescue
    _ -> []
  end

  # Section names owned by the core projections (or by Ash's core DSL).
  # A foreign extension declaring one of these names would be merged into
  # the same dsl path by Spark, so reading it generically would
  # double-project core entities as custom symbols.
  @reserved_sections ~w(attributes relationships actions calculations aggregates
    identities validations changes preparations policies code_interface
    code_interfaces resource_references resources)a

  defp reserved_section?(name), do: name in @reserved_sections

  defp dsl_path(extension, path) do
    "#{short_name(extension)}_#{Enum.map_join(path, "_", &to_string(&1))}"
  end

  defp short_name(extension) do
    parts = Module.split(extension)
    last = parts |> List.last() |> Macro.underscore()

    stripped =
      last
      |> String.replace_suffix("_extension", "")
      |> String.replace_suffix("_dsl", "")

    cond do
      stripped != "" -> stripped
      length(parts) >= 2 -> parts |> Enum.at(-2) |> Macro.underscore()
      true -> last
    end
  end

  # The first of :name, :id, :tag holding an atom, binary, or integer —
  # atomized for the index (every name in it is an atom, and search
  # stringifies with Atom.to_string/1). Everything else falls back to the
  # positional `<section>_<index>`; no shape raises.
  defp entity_name(entity, section_name, index) do
    value =
      Enum.find_value([:name, :id, :tag], fn field ->
        case entity do
          %{^field => value}
          when not is_nil(value) and (is_atom(value) or is_binary(value) or is_integer(value)) ->
            value

          _ ->
            nil
        end
      end)

    case value do
      nil -> :"#{section_name}_#{index}"
      value -> String.to_atom(to_string(value))
    end
  end

  defp get_entities(resource, path) do
    resource
    |> Spark.Dsl.Extension.get_entities(path)
    |> List.wrap()
  rescue
    _ -> []
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
