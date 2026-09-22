# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.NamePath do
  @moduledoc """
  Name-path addressing over the shared symbol index — one stable string
  that pins a DSL entity the way `Class/method` pins a Serena symbol.

  ## Grammar

      name_path := ["/"] module_path ["/" dsl_path "/" name ["[" index "]"]]

    * the **module path** is a resource or domain (`MyApp.Accounts.User`)
    * without a leading `/`, the module may be given as a **suffix** on dot
      boundaries (`User/actions/read`); with a leading `/` it must match a
      full module name exactly
    * the optional **segment** is one level under the module: a canonical
      `dsl_path` (`attributes`, `actions`, `calculations`, `relationships`,
      `policies` for resources; `resource_references`, `code_interfaces`
      for domains) and the entity name
    * unnamed entities (policies) are addressed by occurrence:
      `User/policies/policy[0]`. A named entity is unique, so an index is
      only accepted as `...[0]`

  ## Examples

      iex> {:ok, report} = AshAgentTools.NamePath.resolve("Post/actions/by_tag")
      iex> report.name_path
      "AshAgentTools.Test.Post/actions/by_tag"
      iex> report.symbol.provenance
      :source

      iex> {:ok, report} = AshAgentTools.NamePath.resolve("/AshAgentTools.Test.Guarded/policies/policy[0]")
      iex> {report.symbol.kind, report.symbol.position}
      {:policy, 0}

      iex> {:ok, report} = AshAgentTools.NamePath.resolve("Post")
      iex> report.symbol.kind
      :resource

  Ambiguity and misses raise `ArgumentError` with the closest candidates —
  the same discipline as `describe_action/2`; over-broad suffixes fail with
  the full match list so the query can be refined.
  """

  alias AshAgentTools.Registry
  alias AshAgentTools.Source
  alias AshAgentTools.Symbols

  @kind_paths %{
    "attributes" => :attribute,
    "actions" => :action,
    "calculations" => :calculation,
    "relationships" => :relationship,
    "policies" => :policy,
    "resource_references" => :resource_reference,
    "code_interfaces" => :code_interface
  }

  @segment_regex ~r/^(?<name>[^\[\]]+)(?:\[(?<index>\d+)\])?$/

  @doc """
  Resolves a name path to a symbol report.

  Returns `{:ok, report}` with:

    * `name_path` — the canonical, absolute, indexed form
    * `module` — the owning resource/domain (`module`, `name`, `kind`,
      `domain`)
    * `symbol` — `kind`, `name`, `type`, `dsl_path`, `position`,
      `provenance` (`:source` or `:synthetic` for transformer-injected
      declarations), best-effort `source`, and the context-style `span`
      (nil for synthetic symbols)
    * `file_shape` — when the symbol has a source file that exists: the
      file's shape digest (see `AshAgentTools.Edit`) for the
      read-before-edit handshake

  Raises `ArgumentError` for malformed paths, unknown modules or segments
  (with did_you_mean), and ambiguous suffix matches (with the match list).
  """
  def resolve(name_path, opts \\ [])

  def resolve(name_path, opts) when is_binary(name_path) and is_list(opts) do
    path = String.trim(name_path)

    if path == "" do
      raise ArgumentError, "name_path must be a non-blank string"
    end

    absolute? = String.starts_with?(path, "/")
    parts = path |> String.trim_leading("/") |> String.split("/")

    {module_part, segment_parts} =
      case parts do
        [module_part] ->
          {module_part, nil}

        [module_part, kind, name] ->
          {module_part, {kind, name}}

        _ ->
          raise ArgumentError,
                ~s(malformed name_path #{inspect(name_path)}: expected) <>
                  ~s( "Module" or "Module/dsl_path/name[index]") <>
                  " (one segment level)"
      end

    module = resolve_module!(module_part, absolute?)
    module_kind = if module in Registry.list_domains(), do: :domain, else: :resource

    symbol =
      case segment_parts do
        nil -> module_symbol(module, module_kind)
        {kind, name} -> segment_symbol!(module, module_kind, kind, name, name_path)
      end

    {:ok,
     %{
       name_path: canonical_name_path(module, symbol),
       module: module_info(module, module_kind),
       symbol: symbol,
       file_shape: file_shape(symbol, opts)
     }}
  end

  def resolve(name_path, _opts) do
    raise ArgumentError, "name_path must be a string, got: #{inspect(name_path)}"
  end

  # -- module resolution -------------------------------------------------------

  defp resolve_module!(part, absolute?) do
    modules = Enum.uniq(Registry.list_domains() ++ Registry.list_resources())
    names = Map.new(modules, fn module -> {module, Registry.module_name(module)} end)

    exact =
      for {module, name} <- names, name == part do
        module
      end

    cond do
      exact != [] ->
        hd(exact)

      absolute? ->
        raise ArgumentError,
              "no Ash module named #{inspect(part)}" <>
                "#{did_you_mean_hint(part, Map.values(names))}." <>
                " Absolute name paths (leading \"/\") require the full module name"

      true ->
        suffixes =
          for {module, name} <- names, String.ends_with?(name, "." <> part) do
            module
          end

        case Enum.uniq(suffixes) do
          [module] ->
            module

          [] ->
            raise ArgumentError,
                  "no Ash module matching #{inspect(part)}" <>
                    "#{did_you_mean_hint(part, Map.values(names))}"

          matches ->
            raise ArgumentError,
                  "ambiguous module suffix #{inspect(part)} matches:" <>
                    " #{inspect(Enum.map(matches, &Registry.module_name/1))}." <>
                    " Use the full module name (or a leading \"/\" for exact matches)"
        end
    end
  end

  # Candidates are matched against the modules' last path components
  # (short names) — an agent typing "Pst" means "Post", not the 24-character
  # full name.
  defp did_you_mean_hint(part, names) do
    short_names = Enum.map(names, &List.last(String.split(&1, ".")))

    case AshAgentTools.Suggest.closest(part, short_names ++ names, 3, 4) do
      [] -> ""
      candidates -> " (did you mean: #{inspect(candidates)})"
    end
  end

  # -- symbol resolution ---------------------------------------------------------

  defp module_symbol(module, module_kind) do
    source = Source.from_module(module)

    %{
      kind: module_kind,
      dsl_path: nil,
      name: module,
      type: nil,
      position: 0,
      source: source,
      provenance: if(source, do: :source, else: :synthetic),
      span: nil
    }
  end

  defp segment_symbol!(module, module_kind, raw_kind, raw_target, name_path) do
    {target, index} = parse_target!(raw_target, name_path)

    symbols = Symbols.module_symbols(module, module_kind)
    ensure_known_dsl_path!(symbols, raw_kind, name_path)

    symbols =
      Enum.filter(symbols, &(&1.dsl_path == raw_kind and to_string(&1.name) == target))

    cond do
      symbols == [] ->
        raise ArgumentError,
              unknown_segment_message(module, module_kind, raw_kind, target, index)

      index == nil and length(symbols) > 1 ->
        # unnamed entities (policies): every occurrence shares the name, so
        # an index is mandatory
        raise ArgumentError,
              "ambiguous #{inspect(raw_kind <> "/" <> target)} in" <>
                " #{Registry.module_name(module)}: unnamed entities are addressed by" <>
                " occurrence, e.g. \"#{Registry.module_name(module)}/#{raw_kind}/#{target}[0]\"" <>
                " (occurrences: #{length(symbols)})"

      true ->
        symbol = Enum.find(symbols, &(&1.position == (index || 0)))

        symbol ||
          raise ArgumentError,
                unknown_segment_message(module, module_kind, raw_kind, target, index)

        Map.put(symbol, :span, span_for(module, module_kind, symbol))
    end
  end

  # The core dsl_paths are fixed; custom extension sections (see
  # `AshAgentTools.Symbols.extension_symbols/1`) are addressed through
  # their namespaced dsl_path and are valid exactly when the module's
  # index projects one.
  defp ensure_known_dsl_path!(symbols, raw_kind, name_path) do
    known_paths = MapSet.new(Map.keys(@kind_paths))

    unless MapSet.member?(known_paths, raw_kind) or
             Enum.any?(symbols, &(&1.dsl_path == raw_kind)) do
      raise ArgumentError,
            "unknown dsl_path #{inspect(raw_kind)} in #{inspect(name_path)}." <>
              " Valid dsl_paths: #{inspect(Enum.sort(Enum.uniq(MapSet.to_list(known_paths) ++ Enum.map(symbols, & &1.dsl_path))))}"
    end
  end

  # The context-style span (annotation start to the next annotation's
  # start): best-effort, nil for synthetic symbols, which have no
  # annotation to start from.
  defp span_for(module, module_kind, symbol) do
    file = symbol.source && symbol.source[:file]

    line_count =
      if is_binary(file) and File.exists?(file), do: Symbols.line_count(file), else: nil

    module
    |> Symbols.module_symbols(module_kind)
    |> Symbols.with_spans(line_count)
    |> Enum.find(fn candidate ->
      candidate.kind == symbol.kind and candidate.name == symbol.name and
        candidate.position == symbol.position
    end)
    |> case do
      nil -> nil
      positioned -> positioned.span
    end
  end

  defp parse_target!(raw_target, name_path) do
    case Regex.named_captures(@segment_regex, raw_target) do
      %{"name" => name, "index" => ""} ->
        {name, nil}

      %{"name" => name, "index" => index} ->
        {name, String.to_integer(index)}

      nil ->
        raise ArgumentError, "malformed segment #{inspect(raw_target)} in #{inspect(name_path)}"
    end
  end

  defp unknown_segment_message(module, module_kind, raw_kind, target, index) do
    all =
      module
      |> Symbols.module_symbols(module_kind)
      |> Enum.map(&"#{&1.dsl_path}/#{to_string(&1.name)}[#{&1.position}]")

    candidates = AshAgentTools.Suggest.closest("#{raw_kind}/#{target}", all, 3, 5)

    base =
      "#{Registry.module_name(module)} has no #{raw_kind}/#{target}" <>
        if(index, do: "[#{index}]", else: "")

    if candidates == [] do
      "#{base}. Known symbols: #{inspect(Enum.take(all, 25))}"
    else
      "#{base} (did you mean: #{inspect(candidates)})"
    end
  end

  # -- projections --------------------------------------------------------------

  defp canonical_name_path(module, %{dsl_path: nil}) do
    Registry.module_name(module)
  end

  defp canonical_name_path(module, symbol) do
    Registry.module_name(module) <>
      "/" <>
      symbol.dsl_path <>
      "/" <>
      to_string(symbol.name) <>
      if(symbol.position > 0 or symbol.name == :policy, do: "[#{symbol.position}]", else: "")
  end

  defp module_info(module, kind) do
    %{
      module: module,
      name: Registry.module_name(module),
      kind: kind,
      domain:
        case kind do
          :resource -> Ash.Resource.Info.domain(module)
          _ -> nil
        end
    }
  end

  defp file_shape(%{source: %{file: file}} = _symbol, _opts) when is_binary(file) do
    if File.exists?(file), do: AshAgentTools.Edit.shape(file), else: nil
  end

  defp file_shape(_symbol, _opts), do: nil
end
