# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Edit.Support do
  @moduledoc false

  alias AshAgentTools.Context
  alias AshAgentTools.NamePath
  alias AshAgentTools.Registry
  alias AshAgentTools.Symbols
  alias AshAgentTools.Types

  @max_body_bytes 256 * 1024

  @doc """
  The shape of a source file: the symbol table plus the file content,
  hashed.

  The digest mixes the `name_path@line` symbol table with the raw file
  bytes, so *any* change between a read and a write — external or
  structural — invalidates it and the edit refuses. The compiled module's
  annotations only update on recompile, so the content bytes are what make
  the staleness check honest. `nil` when no loaded Ash module annotates the
  file.
  """
  @spec shape(String.t()) :: map() | nil
  def shape(file) when is_binary(file) do
    case owning_module(file) do
      nil ->
        nil

      module ->
        kind = if module in Registry.list_domains(), do: :domain, else: :resource

        symbols =
          module
          |> Symbols.module_symbols(kind)
          |> Enum.filter(& &1.source)
          |> Enum.sort_by(&(&1.source.line || 0))
          |> Enum.map(&%{name_path: shape_name_path(module, &1), line: &1.source.line})

        digest_input =
          Enum.join(
            ["file:" <> Path.expand(file), "content:" <> File.read!(file)] ++
              Enum.map(symbols, &"#{&1.name_path}@#{&1.line}"),
            "\n"
          )

        %{
          file: file,
          digest: Base.encode16(:crypto.hash(:sha256, digest_input), case: :lower),
          symbols: symbols
        }
    end
  end

  def shape(_file), do: nil

  def shape_name_path(module, symbol) do
    indexed =
      if symbol.name == :policy, do: "[#{symbol.position}]", else: ""

    "#{Registry.module_name(module)}/#{symbol.dsl_path}/#{to_string(symbol.name)}" <> indexed
  end

  # -- operations ------------------------------------------------------------

  @doc """
  Creates a new entity inside a section — empty sections included.

  `section_path` addresses the section the way a name path addresses an
  entity, minus the entity name: `"MyApp.Post/actions"`,
  `"/Full.Module/policies"`. `body` is the entity's source, e.g.
  `"update :check_in do accept [:status] end"` — one entity per call.

  Placement (reported as `placement`):

    * `anchor:` (a name path in the same section) with `position:` —
      `:after` (default) or `:before` → `:after_anchor` / `:before_anchor`
    * otherwise, with source-annotated siblings — appended after the last
      one (`:section_tail`)
    * otherwise, when the section's block exists but holds no annotated
      entities (an empty `actions do end`, or one holding only
      transformer-injected entities) — inserted inside the block before
      its `end` (`:inside_section_block`)
    * otherwise the block does not exist and is **synthesized**
      (`:synthesized_section`): placed after the last known section block
      in the module body, or immediately before the module's final `end`
      when there is none

  The full safety model applies: parse check + size cap, a duplicate-name
  guard (with a pointer to the existing entity), dry-run default,
  `:expected_digest` handshake, atomic write, recompile + canary + revert.
  """
  def resolve(name_path) when is_binary(name_path) do
    # NamePath.resolve/2 returns {:ok, report} and raises ArgumentError on
    # misses; the rescue funnels those into structured error reports.
    NamePath.resolve(name_path)
  rescue
    error in ArgumentError ->
      {:error, %{error: "unresolvable_name_path", message: Exception.message(error)}}
  end

  def resolve(name_path) do
    {:error, %{error: "invalid_name_path", message: inspect(name_path)}}
  end

  def check_body(:safe_delete_entity, _body), do: :ok

  def check_body(_op, body) when is_binary(body) do
    if byte_size(body) > @max_body_bytes do
      {:error, %{error: "body_too_large", max_bytes: @max_body_bytes}}
    else
      case Code.string_to_quoted(body) do
        {:ok, _ast} ->
          :ok

        {:error, error} ->
          {:error, %{error: "unparseable_body", message: Types.error_message(error)}}
      end
    end
  end

  def check_body(_op, body) do
    {:error, %{error: "invalid_body", message: "body must be a string, got: #{inspect(body)}"}}
  end

  # Transformer-injected declarations have no Spark annotation: their
  # "source" is the transformer, not the file, and splicing there would
  # corrupt whatever happens to be on the guessed line.
  def check_provenance(resolved) do
    case resolved.symbol.provenance do
      :source ->
        :ok

      :synthetic ->
        {:error,
         %{
           error: "synthetic_symbol",
           message:
             "#{resolved.name_path} is transformer-injected (no Spark annotation in any" <>
               " source file). Edit the declaring DSL construct instead" <>
               " (e.g. the `defaults` list), not the generated entity.",
           name_path: resolved.name_path
         }}
    end
  end

  def read_target(resolved) do
    file = resolved.symbol.source && resolved.symbol.source[:file]

    cond do
      not is_binary(file) ->
        {:error, %{error: "no_source_file", name_path: resolved.name_path}}

      not File.exists?(file) ->
        {:error,
         %{
           error: "file_not_found",
           file: file,
           message: "the annotated source file is gone"
         }}

      true ->
        case File.read(file) do
          {:ok, content} ->
            {:ok, file, content}

          {:error, reason} ->
            {:error, %{error: "unreadable_file", file: file, reason: inspect(reason)}}
        end
    end
  end

  def shape!(file) do
    case shape(file) do
      nil ->
        {:error,
         %{error: "no_shape", file: file, message: "no loaded Ash module annotates this file"}}

      shape ->
        {:ok, shape}
    end
  end

  # Locate the entity's source block: the outermost AST node whose range
  # starts exactly on the annotated line. Spark annotations are precise
  # about starts; Sourceror turns the parsed AST into exact ranges, so the
  # splice is never guessed from line arithmetic.
  def locate_block(file, content, resolved) do
    case locate_block_at(content, resolved.symbol.source.line) do
      {:ok, range} ->
        {:ok, range}

      :error ->
        {:error,
         %{
           error: "span_mismatch",
           file: file,
           line: resolved.symbol.source.line,
           message:
             "no source construct starts on line #{resolved.symbol.source.line} (the Spark annotation's" <>
               " line). The file and the compiled module have drifted; re-read the file"
         }}
    end
  end

  def locate_block_at(content, anno_line) do
    case Sourceror.parse_string(content) do
      {:ok, ast} ->
        case collect_at_line(ast, anno_line) do
          [%{node: node} | _] ->
            %Sourceror.Range{
              start: [line: start_line, column: _],
              end: [line: end_line, column: _]
            } = Sourceror.get_range(node)

            {:ok, %{start_line: start_line, end_line: end_line}}

          [] ->
            :error
        end

      {:error, _error} ->
        :error
    end
  end

  def collect_at_line(ast, line) do
    {_, candidates} =
      Macro.prewalk(ast, [], fn node, acc ->
        case range_start_line(node) do
          %{start_line: ^line} = range ->
            {node, [Map.put(range, :node, node) | acc]}

          _ ->
            {node, acc}
        end
      end)

    # prewalk collects inner nodes before their parents; reversing restores
    # document order so the outermost construct starting on the line wins.
    Enum.reverse(candidates)
  end

  # Sourceror 1.x ranges are %Sourceror.Range{} with [line:, column:]
  # lists for both endpoints.
  def range_start_line(node) do
    case Sourceror.get_range(node) do
      %Sourceror.Range{start: [line: line, column: _]} -> %{start_line: line}
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def check_references(:safe_delete_entity, resolved) do
    symbol = resolved.symbol

    references =
      resolved.module.module
      |> Context.references_for(symbol.kind, symbol.name)
      |> references_list()

    if references == [] do
      :ok
    else
      {:error,
       %{
         error: "has_references",
         message:
           "refusing to delete #{resolved.name_path}: " <>
             "#{length(references)} reference(s) depend on it. Update or delete them first.",
         references: references
       }}
    end
  end

  def check_references(_op, _resolved), do: :ok

  # references_for/3 projects the reference groups as a map; the delete
  # gate only cares about the flat list of referencing things.
  def references_list(%{
        actions: actions,
        code_interfaces: code_interfaces,
        relationships: relationships
      }) do
    List.flatten(List.wrap(actions) ++ List.wrap(code_interfaces) ++ List.wrap(relationships))
  end

  def references_list(list) when is_list(list), do: list

  # Body preparation: parse-verified body text, split to the file's EOL
  # style and re-indented so its least-indented line sits at the anchor's
  # indentation.
  def prepare_body(:safe_delete_entity, _body, _content, _range), do: []

  def prepare_body(_op, body, content, range) do
    anchor_indent = anchor_indent(content, range.start_line)
    shift_body(body, String.length(anchor_indent))
  end

  def shift_body(body, target_width) do
    body = String.replace(body, "\r\n", "\n")
    lines = body |> String.trim_trailing("\n") |> String.split("\n")
    delta = indent_delta(lines, target_width)

    Enum.map(lines, fn line ->
      cond do
        String.trim_leading(line) == "" ->
          ""

        delta >= 0 ->
          String.duplicate(" ", delta) <> line

        true ->
          String.slice(line, -delta, String.length(line))
      end
    end)
  end

  def anchor_indent(content, start_line) do
    line = content |> String.split("\n") |> Enum.at(start_line - 1, "")

    case Regex.run(~r/^ */, line) do
      [indent] -> indent
      _ -> ""
    end
  end

  def indent_delta(lines, anchor_width) do
    min_width =
      lines
      |> Enum.reject(&(String.trim_leading(&1) == ""))
      |> Enum.map(&String.length(Regex.run(~r/^ */, &1) |> hd()))
      |> Enum.min(fn -> 0 end)

    anchor_width - min_width
  end

  # Splice on the AST range's line boundaries, producing both the new
  # content and a minimal textual diff of the change.
  def splice(op, content, range, body_lines) do
    eol = detect_eol(content)
    trailing_newline? = String.ends_with?(content, "\n")

    lines =
      content
      |> String.replace_suffix("\n", "")
      |> String.replace_suffix("\r", "")
      |> String.split(eol)

    before = Enum.take(lines, range.start_line - 1)
    anchor = Enum.slice(lines, range.start_line - 1, range.end_line - range.start_line + 1)
    rest = Enum.drop(lines, range.end_line)

    {middle, rest} =
      case op do
        # the guaranteed blank goes between the body and the anchor
        :insert_before_entity -> {body_lines ++ [""], rest}
        # blank after the anchor; blank_normalize then guarantees exactly
        # one blank between the body and whatever follows it
        :insert_after_entity -> {["" | body_lines], blank_normalize(rest)}
        :safe_delete_entity -> {[], rest}
        :replace_entity_block -> {body_lines, rest}
      end

    # inserts keep the anchor; replace and delete splice over it
    new_lines =
      case op do
        :insert_before_entity -> before ++ middle ++ anchor ++ rest
        :insert_after_entity -> before ++ (anchor ++ middle) ++ rest
        _op -> before ++ middle ++ rest
      end

    new_content =
      Enum.join(new_lines, eol) <>
        if(trailing_newline?, do: eol, else: "")

    {new_content, diff_lines(anchor, middle, range.start_line)}
  end

  # Exactly one blank line between an inserted block and what follows.
  def blank_normalize(["" | _] = rest), do: rest
  def blank_normalize([]), do: []
  def blank_normalize(rest), do: ["" | rest]

  def detect_eol(content) do
    if String.contains?(content, "\r\n"), do: "\r\n", else: "\n"
  end

  def diff_lines(anchor, middle, at_line) do
    removed = Enum.map(anchor, &("- " <> &1))
    added = Enum.map(middle, &("+ " <> &1))

    body = (removed ++ added) |> Enum.reject(&(&1 in ["- ", "+ "])) |> Enum.join("\n")

    if body == "" do
      "(no change)"
    else
      "@@ line #{at_line} @@\n" <> body
    end
  end

  # -- write path -----------------------------------------------------------------

  def owning_module(file) do
    expanded = Path.expand(file)

    (Registry.list_domains() ++ Registry.list_resources())
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.find(fn module ->
      case AshAgentTools.Source.from_module(module) do
        %{file: source_file} when is_binary(source_file) ->
          Path.expand(source_file) == expanded

        _ ->
          false
      end
    end)
  end
end
