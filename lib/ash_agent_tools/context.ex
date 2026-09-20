# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Context do
  @moduledoc """
  Position-based context: *what Ash thing lives at this file and line?*

  `context/3` answers the question an agent asks after opening a source
  file — "which resource is this, which action/attribute am I looking at,
  what references it?" — as one pure projection over already-loaded Ash
  modules, collapsing the usual grep → read → re-grep loop into a single
  call. Positions are matched against the Spark `__spark_metadata__`
  annotations of every symbol of every loaded Ash resource and domain
  (the same anno handling `AshAgentTools.Source` uses), so the answer is
  exact where annotations exist and gracefully empty where they do not.

  Like every discovery function in this package it is read-only and never
  raises for *what it finds*: a file that belongs to no loaded Ash module
  is a `{:ok, report}` with `match: nil` and `module: nil`, not an error.
  Only malformed input (blank file, non-positive line) raises
  `ArgumentError`.
  """

  alias AshAgentTools.Kaizen
  alias AshAgentTools.Registry
  alias AshAgentTools.Source
  alias AshAgentTools.Types

  @default_nearest 5

  # Where per-module semantic manifests are looked up when the caller does
  # not point `:manifests` at something explicit. Matches the location the
  # semantic-manifest tooling validates (`priv/semantic/**/*.json`).
  @default_manifest_glob "priv/semantic/**/*.json"

  @doc """
  Returns the Ash context for a position in a source file.

  `file` is the path of the file to locate — repo-relative or absolute;
  matching is done against the compile-time file recorded in each symbol's
  Spark annotation, at path-component boundaries (so `lib/my_app/post.ex`
  matches `/home/me/app/lib/my_app/post.ex`). `line` is a 1-based line
  number. Both must be well-formed or `ArgumentError` is raised.

  Returns `{:ok, report}` — always; a miss is a report with `match: nil`,
  never a raise. The report is plain and JSON-encodable:

    * `file`, `line` — the (trimmed) inputs, echoed
    * `module` — the loaded Ash resource/domain that declares at or near
      the position: its module, name, kind (`:resource` or `:domain`),
      domain, and compile source; `nil` when no loaded Ash module owns
      this file
    * `match` — the symbol whose declaration span covers `line` (spans
      run from a symbol's annotated start line to the next symbol's start
      line — best-effort, derived purely from annotations), with `kind`,
      `name`, normalized `type`, `source`, and `span`
    * `nearest` — up to `opts[:nearest]` (default 5) symbols of the
      module, sorted by distance from the position, each with its `line`
      and `distance` (0 when the position is inside its span)
    * `references` — what references the matched symbol: `actions` that
      accept a matched attribute (via `accept` or a same-named argument),
      `relationships` using it as source/destination attribute, and the
      `code_interfaces` calling a matched action
    * `manifests` — when semantic manifests are available (`priv/semantic/
      **/*.json` by default, or `opts[:manifests]`), the matched module's
      manifest symbols and the relations (RFC §4.5 edges) that touch its
      symbol ids; `nil` when none are found or readable
    * `did_you_mean` — on a miss (no loaded Ash module declares this file),
      up to 3 declared files sharing the most path components with the
      request (a shared directory or filename), so a near-miss path
      self-corrects; `nil` otherwise. The same miss is reported to the
      kaizen loop (`AshAgentTools.Kaizen`).

  ## Options

    * `:nearest` — how many nearby symbols to report (non-negative
      integer, default 5)
    * `:manifests` — manifest paths or glob strings to consult instead of
      the `priv/semantic/**/*.json` default

  ## Examples

      iex> {:ok, report} = AshAgentTools.context("test/support/context_probe.ex", 1)
      iex> {report.match, report.module.module}
      {nil, AshAgentTools.Test.ContextProbe}

      iex> {:ok, report} = AshAgentTools.context("test/support/context_probe.ex", 21)
      iex> {report.match.kind, report.match.name}
      {:attribute, :excerpt}

      iex> {:ok, report} = AshAgentTools.context("lib/no/such/module.ex", 10)
      iex> {report.module, report.match, report.nearest}
      {nil, nil, []}

  """
  @spec context(String.t(), pos_integer(), keyword()) :: {:ok, map()}
  def context(file, line, opts \\ [])

  def context(file, line, opts) when is_binary(file) and is_integer(line) and is_list(opts) do
    started = System.monotonic_time(:millisecond)
    file = String.trim(file)
    nearest_count = nearest_count!(opts)

    if file == "" do
      raise ArgumentError, "file must be a non-blank string"
    end

    if line < 1 do
      raise ArgumentError, "line must be a positive integer, got: #{inspect(line)}"
    end

    {module_info, symbols} = locate_module(indexed_modules(), file, line)
    spans = with_spans(symbols, line_count(file))
    match = containing_symbol(spans, line)

    # A file that no loaded Ash module declares is an honest miss: report it
    # to the kaizen loop (with the closest declared files as suggestions) and
    # fold the same suggestions into the report.
    suggestions = if module_info, do: nil, else: file_suggestions(file)

    unless module_info do
      duration_ms = System.monotonic_time(:millisecond) - started

      Kaizen.emit(
        :context,
        :context_miss,
        "#{file}:#{line}",
        %{file: file, did_you_mean: suggestions},
        duration_ms: duration_ms
      )
    end

    {:ok,
     %{
       file: file,
       line: line,
       module: module_info,
       match: match && project_match(match),
       nearest: project_nearest(nearest_symbols(spans, line, nearest_count), line),
       references: references(module_info, match),
       manifests: manifest_report(opts, module_info),
       did_you_mean: suggestions
     }}
  end

  def context(file, _line, _opts) when not is_binary(file) do
    raise ArgumentError, "file must be a non-blank string, got: #{inspect(file)}"
  end

  def context(_file, line, _opts) do
    raise ArgumentError, "line must be a positive integer, got: #{inspect(line)}"
  end

  # -- module location ----------------------------------------------------

  # Every loaded Ash resource and domain, as %{module, kind, symbols}.
  # A module is included even when its symbols carry no annotations; it
  # simply cannot be file-matched in that case (documented limitation).
  defp indexed_modules do
    domains = MapSet.new(Registry.list_domains())

    for module <- Enum.uniq(Registry.list_domains() ++ Registry.list_resources()) do
      kind = if MapSet.member?(domains, module), do: :domain, else: :resource
      %{module: module, kind: kind, symbols: module_symbols(module, kind)}
    end
  end

  # The DSL symbols of one module that carry a usable (file + line) Spark
  # annotation, flattened from the four resource symbol kinds and, for
  # domains, resource references and code-interface definitions.
  defp module_symbols(module, :resource), do: resource_symbols(module)
  defp module_symbols(module, :domain), do: domain_symbols(module)

  defp resource_symbols(resource) do
    Enum.flat_map(Ash.Resource.Info.attributes(resource), fn attribute ->
      symbol(:attribute, attribute.name, Types.normalize(attribute.type), attribute)
    end) ++
      Enum.flat_map(Ash.Resource.Info.actions(resource), fn action ->
        symbol(:action, action.name, action.type, action)
      end) ++
      Enum.flat_map(Ash.Resource.Info.calculations(resource), fn calculation ->
        symbol(:calculation, calculation.name, Types.normalize(calculation.type), calculation)
      end) ++
      Enum.flat_map(Ash.Resource.Info.relationships(resource), fn relationship ->
        symbol(:relationship, relationship.name, relationship.type, relationship)
      end)
  end

  defp domain_symbols(domain) do
    references = Ash.Domain.Info.resource_references(domain)

    Enum.flat_map(references, fn reference ->
      symbol(:resource_reference, reference.resource, nil, reference)
    end) ++
      Enum.flat_map(references, fn reference ->
        Enum.flat_map(Map.get(reference, :define, []), fn define ->
          symbol(:code_interface, define.name, Map.get(define, :action), define)
        end)
      end)
  end

  # Keeps only symbols whose Spark annotation pins both a file and a line;
  # without both, a symbol cannot be positioned and is silently skipped.
  defp symbol(kind, name, type, entity) do
    case Source.from_entity(entity) do
      %{file: file, line: line} = source when is_binary(file) and is_integer(line) ->
        [%{kind: kind, name: name, type: type, source: source}]

      _ ->
        []
    end
  end

  # Pick the module that declares at/near the position: among the modules
  # owning this file (by annotated symbol file), the one whose symbols sit
  # closest to the line; ties resolve to the alphabetically first module.
  # Returns {%{module info map}, [symbols in that file]} — or {nil, []}.
  defp locate_module(modules, file, line) do
    candidates =
      for entry <- modules,
          symbols = Enum.filter(entry.symbols, &same_file?(&1.source.file, file)),
          symbols != [] do
        starts = Enum.map(symbols, & &1.source.line)
        nearest_start = Enum.min_by(starts, &abs(line - &1))
        {entry, symbols, abs(line - nearest_start)}
      end

    case candidates do
      [] ->
        {nil, []}

      candidates ->
        {entry, symbols, _} =
          Enum.min_by(candidates, fn {entry, _, distance} ->
            {distance, Registry.module_name(entry.module)}
          end)

        module_info = %{
          module: entry.module,
          name: Registry.module_name(entry.module),
          kind: entry.kind,
          domain: module_domain(entry),
          source: Source.from_module(entry.module)
        }

        {module_info, symbols}
    end
  end

  defp module_domain(%{kind: :resource, module: resource}),
    do: Ash.Resource.Info.domain(resource)

  defp module_domain(%{kind: :domain}), do: nil

  # did_you_mean for a context miss: the compile-time files of loaded Ash
  # modules sharing the most path components with the request (at least one
  # — a shared directory or filename), so a near-miss path self-corrects.
  # Cheap because the candidate set is "the modules already loaded".
  defp file_suggestions(file) do
    parts = MapSet.new(path_parts(file))

    candidates =
      (Registry.list_domains() ++ Registry.list_resources())
      |> Enum.uniq()
      |> Enum.flat_map(fn module ->
        case Source.from_module(module) do
          %{file: candidate} when is_binary(candidate) -> [candidate]
          _ -> []
        end
      end)
      |> Enum.uniq()

    candidates
    |> Enum.map(fn candidate ->
      shared =
        candidate
        |> path_parts()
        |> MapSet.new()
        |> MapSet.intersection(parts)
        |> MapSet.size()

      {shared, candidate}
    end)
    |> Enum.filter(fn {shared, _candidate} -> shared >= 1 end)
    |> Enum.sort_by(fn {shared, candidate} -> {-shared, candidate} end)
    |> Enum.take(3)
    |> Enum.map(&elem(&1, 1))
  end

  # Path-component-suffix match: the requested path must equal the tail of
  # the annotated file, split on path separators in both directions.
  defp same_file?(anno_file, requested) do
    anno_parts = path_parts(anno_file)
    requested_parts = path_parts(requested)

    length(requested_parts) <= length(anno_parts) and
      Enum.slice(anno_parts, -length(requested_parts), length(requested_parts)) ==
        requested_parts
  end

  defp path_parts(path) do
    path |> String.replace("\\", "/") |> Path.split()
  end

  # -- spans, match, nearest ------------------------------------------------

  defp line_count(file) do
    case File.read(file) do
      {:ok, contents} -> contents |> String.split("\n") |> length()
      _ -> nil
    end
  end

  # A symbol's span runs from its annotated start line to the line before
  # the next symbol starts (best-effort: annotations carry starts, not
  # ends). The last symbol's span extends to the end of the file.
  defp with_spans(symbols, line_count) do
    symbols
    |> Enum.with_index()
    |> Enum.map(fn {symbol, index} ->
      start_line = symbol.source.line

      end_line =
        case Enum.at(symbols, index + 1) do
          nil -> line_count || start_line
          next -> max(next.source.line - 1, start_line)
        end

      Map.put(symbol, :span, %{start_line: start_line, end_line: end_line})
    end)
  end

  defp containing_symbol(spans, line) do
    spans
    |> Enum.filter(&(&1.span.start_line <= line))
    |> case do
      [] -> nil
      covering -> Enum.max_by(covering, & &1.span.start_line)
    end
  end

  # Distance from the line to the symbol's span: 0 when inside it,
  # otherwise the distance to the nearer edge.
  defp symbol_distance(%{span: %{start_line: start, end_line: end_line}}, line) do
    cond do
      line < start -> start - line
      line > end_line -> line - end_line
      true -> 0
    end
  end

  defp symbol_distance(symbol, line), do: abs(line - symbol.source.line)

  defp nearest_symbols(spans, line, count) do
    spans
    |> Enum.map(&{symbol_distance(&1, line), &1})
    |> Enum.sort_by(fn {distance, symbol} -> {distance, symbol.source.line} end)
    |> Enum.take(count)
  end

  # -- projections (JSON-safe) ------------------------------------------------

  defp project_match(symbol) do
    %{
      kind: symbol.kind,
      name: symbol.name,
      type: symbol.type,
      source: symbol.source,
      span: symbol.span
    }
  end

  defp project_nearest(nearest, _line) do
    Enum.map(nearest, fn {distance, symbol} ->
      %{
        kind: symbol.kind,
        name: symbol.name,
        line: symbol.source.line,
        distance: distance
      }
    end)
  end

  # -- references -------------------------------------------------------------

  # What references the matched symbol. Attributes report the actions that
  # accept them (accept list or same-named argument) and the relationships
  # wired through them; actions report the code interfaces calling them.
  defp references(%{module: resource}, %{kind: :attribute, name: name}) do
    %{
      actions: accepting_actions(resource, name),
      code_interfaces: [],
      relationships: relationships_using(resource, name)
    }
  end

  defp references(%{module: resource}, %{kind: :action, name: name}) do
    %{
      actions: [],
      code_interfaces: code_interfaces(resource, name),
      relationships: []
    }
  end

  defp references(_module_info, _match) do
    %{actions: [], code_interfaces: [], relationships: []}
  end

  # describe_action/2 raises for unknown actions — cannot happen for a name
  # that came out of the resource's own symbol index, but the rescue keeps
  # context/3 graceful no matter what.
  defp code_interfaces(resource, name) do
    AshAgentTools.describe_action(resource, name).code_interfaces
  rescue
    _ -> []
  end

  defp accepting_actions(resource, name) do
    for action <- Ash.Resource.Info.actions(resource),
        accepts?(action, name) do
      %{name: action.name, type: action.type}
    end
  end

  defp accepts?(action, name) do
    accept = Map.get(action, :accept)

    attribute_accepted? =
      is_list(accept) and action.type in [:create, :update] and name in accept

    attribute_accepted? or Enum.any?(action.arguments, &(&1.name == name))
  end

  defp relationships_using(resource, name) do
    for relationship <- Ash.Resource.Info.relationships(resource),
        relationship.source_attribute == name or
          Map.get(relationship, :destination_attribute) == name do
      %{
        name: relationship.name,
        type: relationship.type,
        destination: relationship.destination
      }
    end
  end

  # -- semantic manifests -------------------------------------------------------

  # Manifest-derived relations for the matched module, when any semantic
  # manifest is available. Everything here is best-effort: unreadable or
  # malformed documents are skipped, and no manifests at all is `nil`.
  defp manifest_report(_opts, nil), do: nil

  defp manifest_report(opts, %{name: module_name}) do
    paths = manifest_paths(opts)
    prefix = "ash:v0:" <> module_name <> "#"

    documents =
      for path <- paths,
          {:ok, contents} <- [File.read(path)],
          {:ok, document} <- [Jason.decode(contents)] do
        {path, document}
      end

    symbols =
      for {_path, document} <- documents,
          document["module"] == module_name,
          symbol <- document["symbols"] || [] do
        %{id: symbol["id"], kind: symbol["kind"], name: symbol["name"]}
      end

    relations =
      for {_path, document} <- documents,
          relation <- document["relations"] || [],
          touches?(relation, prefix) do
        %{from: relation["from"], to: relation["to"], kind: relation["kind"]}
      end

    if symbols == [] and relations == [] do
      nil
    else
      %{paths: paths, symbols: symbols, relations: relations}
    end
  end

  defp touches?(relation, prefix) do
    binary_prefix?(relation["from"], prefix) or binary_prefix?(relation["to"], prefix)
  end

  defp binary_prefix?(value, prefix) when is_binary(value), do: String.starts_with?(value, prefix)
  defp binary_prefix?(_, _), do: false

  defp manifest_paths(opts) do
    opts
    |> Keyword.get(:manifests, [@default_manifest_glob])
    |> List.wrap()
    |> Enum.flat_map(fn
      path when is_binary(path) ->
        if String.contains?(path, ["*", "?", "[", "{"]) do
          Enum.sort(Path.wildcard(path))
        else
          if File.exists?(path), do: [path], else: []
        end

      _ ->
        []
    end)
  end

  # -- option validation ---------------------------------------------------------

  defp nearest_count!(opts) do
    count = Keyword.get(opts, :nearest, @default_nearest)

    if is_integer(count) and count >= 0 do
      count
    else
      raise ArgumentError, ":nearest must be a non-negative integer, got: #{inspect(count)}"
    end
  end
end
