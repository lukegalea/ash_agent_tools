# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Edit.Creator do
  @moduledoc false

  import AshAgentTools.Edit.Support
  import AshAgentTools.Edit.Writer

  alias AshAgentTools.Registry
  alias AshAgentTools.Symbols
  alias AshAgentTools.Types

  @section_calls %{
    "attributes" => :attributes,
    "actions" => :actions,
    "calculations" => :calculations,
    "relationships" => :relationships,
    "policies" => :policies,
    "resource_references" => :resources,
    "code_interfaces" => :code_interface
  }

  @resource_paths MapSet.new([
                    "attributes",
                    "actions",
                    "calculations",
                    "relationships",
                    "policies"
                  ])
  @domain_paths MapSet.new(["resource_references", "code_interfaces"])

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
  def create_entity(section_path, body, opts \\ [])

  def create_entity(section_path, body, opts) when is_binary(section_path) and is_list(opts) do
    with {:ok, {module, module_kind, dsl_path}} <- resolve_section(section_path),
         :ok <- check_body(:create_entity, body),
         {:ok, _ast, identifier} <- entity_identifier(body),
         :ok <- check_duplicate(module, module_kind, dsl_path, identifier, %{}),
         {:ok, anchor} <- resolve_anchor(opts[:anchor], module, dsl_path, %{}),
         {:ok, file, content} <- create_target(module, anchor),
         {:ok, current_shape} <- shape!(file),
         {:ok, placement, insertion} <-
           plan_creation(module, module_kind, dsl_path, content, anchor && anchor.line,
             position: opts[:position] || :after
           ) do
      body_lines = creation_body_lines(content, insertion, body)
      {spliced, diff, _inserted} = insert_lines(content, insertion, body_lines)

      {new_content, formatted?} = format_pass(file, content, spliced)
      diff = format_note(diff, formatted?)

      new_name_path =
        identifier && "#{Registry.module_name(module)}/#{dsl_path}/#{identifier}"

      base = %{
        op: "create_entity",
        name_path: new_name_path,
        section_path: "#{Registry.module_name(module)}/#{dsl_path}",
        placement: placement,
        file: file,
        diff: diff
      }

      if opts[:write] do
        finish_write(%{
          op: "create_entity",
          name_path: new_name_path,
          file: file,
          original: content,
          new_content: new_content,
          diff: diff,
          current_digest: current_shape.digest,
          expected_digest: opts[:expected_digest],
          modules: [module],
          formatted?: formatted?
        })
      else
        {:ok,
         base
         |> Map.merge(%{
           dry_run?: true,
           write?: false,
           formatted?: formatted?,
           current_digest: current_shape.digest
         })
         |> maybe_format_hint(formatted?)}
      end
    end
  end

  def create_entity(section_path, _body, _opts) do
    {:error,
     %{
       error: "invalid_section_path",
       message: "section_path must be a string, got: #{inspect(section_path)}"
     }}
  end

  def resolve_section(section_path) when is_binary(section_path) do
    parts = section_path |> String.trim_leading("/") |> String.split("/")

    case parts do
      [module_part, dsl_path] ->
        with {:ok, report} <- resolve(module_part),
             module = report.module.module,
             kind = if(module in Registry.list_domains(), do: :domain, else: :resource),
             :ok <- ensure_section_known!(module, kind, dsl_path, section_path) do
          {:ok, {module, kind, dsl_path}}
        end

      _ ->
        {:error,
         %{
           error: "invalid_section_path",
           message:
             ~s(expected "Module/dsl_path" — e.g. "MyApp.Post/actions") <>
               ", got: #{inspect(section_path)}"
         }}
    end
  end

  def resolve_section(other),
    do: {:error, %{error: "invalid_section_path", message: inspect(other)}}

  def ensure_section_known!(module, kind, dsl_path, section_path) do
    core = if kind == :domain, do: @domain_paths, else: @resource_paths

    observed =
      module
      |> Symbols.module_symbols(kind)
      |> Enum.map(& &1.dsl_path)
      |> MapSet.new()

    if MapSet.member?(core, dsl_path) or MapSet.member?(observed, dsl_path) do
      :ok
    else
      valid = Enum.sort(MapSet.to_list(core) ++ MapSet.to_list(observed))

      {:error,
       %{
         error: "unknown_section",
         message:
           "unknown dsl_path #{inspect(dsl_path)} in #{inspect(section_path)}." <>
             " Valid dsl_paths: #{inspect(valid)}"
       }}
    end
  end

  # The created entity's identifier: the first literal atom argument of the
  # (single) top-level call — `update :check_in do … end` → "check_in".
  # Unnamed entities (a `policy` with a condition head) skip the duplicate
  # guard and are reported without a name_path.
  def entity_identifier(body) do
    case Code.string_to_quoted(body) do
      {:ok, ast} ->
        case single_statement(ast) do
          {:ok, {call, _meta, args}} when is_atom(call) and is_list(args) ->
            identifier =
              case args do
                [first | _] when is_atom(first) -> Atom.to_string(first)
                _ -> nil
              end

            {:ok, ast, identifier}

          {:ok, _other} ->
            {:error, %{error: "invalid_entity", message: "body must be a DSL entity call"}}

          :multiple ->
            {:error,
             %{
               error: "multiple_entities",
               message:
                 "create_entity takes one entity per call — use apply_batch/2 to apply several"
             }}
        end

      {:error, error} ->
        {:error, %{error: "unparseable_body", message: Types.error_message(error)}}
    end
  end

  def single_statement({:__block__, _, [statement]}), do: {:ok, statement}
  def single_statement({:__block__, _, statements}) when length(statements) > 1, do: :multiple
  def single_statement(statement), do: {:ok, statement}

  def check_duplicate(module, module_kind, dsl_path, identifier, created)
  def check_duplicate(_module, _kind, _dsl_path, nil, _created), do: :ok

  def check_duplicate(module, module_kind, dsl_path, identifier, created) do
    compiled? =
      module
      |> Symbols.module_symbols(module_kind)
      |> Enum.any?(&(&1.dsl_path == dsl_path and to_string(&1.name) == identifier))

    prefix = "#{Registry.module_name(module)}/#{dsl_path}/"

    created? =
      Enum.any?(created, fn {name_path, _range} ->
        String.starts_with?(name_path, prefix) and name_path == prefix <> identifier
      end)

    if compiled? or created? do
      existing = prefix <> identifier

      {:error,
       %{
         error: "duplicate_entity",
         message:
           "#{existing} already exists — did you mean to replace_entity_block/3 it," <>
             " or is the name a typo?",
         existing_name_path: existing
       }}
    else
      :ok
    end
  end

  # A normalized anchor: the current line of an existing entity in the
  # section, plus the file it lives in. An anchor may name an entity created
  # earlier in the same batch — those live in `created`, not in the compiled
  # DSL — so the created map is consulted first.
  def resolve_anchor(nil, _module, _dsl_path, _created), do: {:ok, nil}

  def resolve_anchor(anchor, module, dsl_path, created) when is_binary(anchor) do
    created_entry = Map.get(created, anchor)

    if created_entry do
      {s, _e} = created_entry

      if String.starts_with?(anchor, "#{Registry.module_name(module)}/#{dsl_path}/") do
        {:ok, %{line: s, file: file_of(module)}}
      else
        {:error,
         %{
           error: "anchor_section_mismatch",
           message: "anchor #{inspect(anchor)} is not in #{dsl_path}",
           anchor: anchor
         }}
      end
    else
      with {:ok, resolved} <- resolve(anchor) do
        cond do
          resolved.module.module != module ->
            {:error,
             %{
               error: "anchor_module_mismatch",
               message:
                 "anchor #{inspect(anchor)} belongs to #{Registry.module_name(resolved.module.module)}," <>
                   " not #{Registry.module_name(module)}",
               anchor: anchor
             }}

          resolved.symbol.dsl_path != dsl_path ->
            {:error,
             %{
               error: "anchor_section_mismatch",
               message:
                 "anchor #{inspect(anchor)} is in #{resolved.symbol.dsl_path}, not #{dsl_path}",
               anchor: anchor
             }}

          true ->
            {:ok, %{line: resolved.symbol.source.line, file: resolved.symbol.source[:file]}}
        end
      end
    end
  end

  def create_target(module, anchor) do
    file = (anchor && anchor[:file]) || file_of(module)

    cond do
      not is_binary(file) ->
        {:error, %{error: "no_source_file", message: "no source file is known for this module"}}

      not File.exists?(file) ->
        {:error,
         %{error: "file_not_found", file: file, message: "the annotated source file is gone"}}

      true ->
        case File.read(file) do
          {:ok, content} ->
            {:ok, file, content}

          {:error, reason} ->
            {:error, %{error: "unreadable_file", file: file, reason: inspect(reason)}}
        end
    end
  end

  def file_of(module) do
    case AshAgentTools.Source.from_module(module) do
      %{file: file} when is_binary(file) -> file
      _ -> nil
    end
  end

  # ── creation placement ─────────────────────────────────────────────────────

  def plan_creation(module, module_kind, dsl_path, content, anchor_line, opts) do
    position = opts[:position]

    cond do
      not is_nil(anchor_line) ->
        {:ok, range} = locate_block_at(content, anchor_line)
        placement = if position == :before, do: :before_anchor, else: :after_anchor
        {:ok, placement, {:anchor, range, position == :before}}

      sibling = last_annotated_sibling(module, module_kind, dsl_path) ->
        {:ok, range} = locate_block_at(content, sibling.source.line)
        {:ok, :section_tail, {:anchor, range, false}}

      true ->
        call_name = Map.get(@section_calls, dsl_path)

        case section_block(content, module, call_name) do
          {:ok, range} ->
            {:ok, :inside_section_block, {:inside_block, range}}

          _ when call_name != nil ->
            synthesize(module, module_kind, dsl_path, call_name, content)

          _ ->
            {:error,
             %{
               error: "cannot_locate_section",
               message:
                 "the #{inspect(dsl_path)} section has no annotated entities and its block" <>
                   " cannot be located; anchor the creation to a sibling entity"
             }}
        end
    end
  end

  def last_annotated_sibling(module, module_kind, dsl_path) do
    module
    |> Symbols.module_symbols(module_kind)
    |> Enum.filter(&(&1.dsl_path == dsl_path and &1.provenance == :source and &1.source))
    |> Enum.sort_by(&(&1.source.line || 0))
    |> List.last()
  end

  # The source block of the section itself: the call in the module body
  # whose name is the section's (`actions do … end`).
  def section_block(content, module, call_name) when not is_nil(call_name) do
    with {:ok, ast} <- Sourceror.parse_string(content),
         module_line when is_integer(module_line) <- module_source_line(module),
         [%{node: node} | _] <- collect_at_line(ast, module_line),
         {:ok, call_node} <- find_section_call(node, call_name) do
      %Sourceror.Range{
        start: [line: start_line, column: _],
        end: [line: end_line, column: _]
      } = Sourceror.get_range(call_node)

      {:ok, %{start_line: start_line, end_line: end_line}}
    else
      _ -> :error
    end
  end

  def section_block(_content, _module, _call_name), do: :error

  def module_source_line(module) do
    case AshAgentTools.Source.from_module(module) do
      %{line: line} when is_integer(line) -> line
      _ -> nil
    end
  end

  # Finds the section's own call node: a call with the section's name whose
  # last argument is a do-block.
  def find_section_call(node, call_name) do
    {_, found} =
      Macro.prewalk(node, :error, fn
        {^call_name, _meta, args} = node, :error when is_list(args) ->
          if do_block?(args), do: {node, {:ok, node}}, else: {node, :error}

        node, acc ->
          {node, acc}
      end)

    case found do
      {:ok, node} -> {:ok, node}
      :error -> :error
    end
  end

  # `section do … end` parses as `[[do: body]]` — except that Sourceror wraps
  # the bare `:do` keyword in a `__block__` triple (comment metadata), so an
  # EMPTY block parses as `[[{{:__block__, _, [:do]}, {:__block__, _, []}}]]`.
  def do_block?(args) do
    case List.last(args) do
      [[do: _]] -> true
      [{{:__block__, _, [:do]}, _body}] -> true
      _ -> false
    end
  end

  # Synthesis: no block to splice into, so the whole `section do … end` is
  # appended — after the last known section block in the module body, or
  # immediately before the module's final `end` when there is none.
  def synthesize(module, module_kind, dsl_path, call_name, content) do
    case module_node_range(content, module) do
      {:ok, module_range} ->
        last = last_section_block_end(content, module, module_kind)

        # after the last section block's `end`, or immediately before the
        # module's final `end` when there is no section block to follow
        placement_line =
          if last.end_line, do: last.end_line + 1, else: module_range.end_line - 1

        indent = last.indent || "  "

        {:ok, :synthesized_section, {:synthesize, placement_line, call_name, indent}}

      :error ->
        {:error,
         %{
           error: "cannot_locate_module",
           message:
             "the module's defmodule block could not be located in the source;" <>
               " cannot synthesize the #{inspect(dsl_path)} section"
         }}
    end
  end

  # The end line + indent of the last top-level known section block, if any.
  def last_section_block_end(content, module, module_kind) do
    names =
      if(module_kind == :resource,
        do: MapSet.to_list(@resource_paths),
        else: MapSet.to_list(@domain_paths)
      )
      |> Enum.map(&Map.fetch!(@section_calls, &1))

    with {:ok, ast} <- Sourceror.parse_string(content),
         module_line when is_integer(module_line) <- module_source_line(module),
         [%{node: node} | _] <- collect_at_line(ast, module_line) do
      case top_level_section_calls(node, names) do
        [] ->
          %{end_line: nil, indent: nil}

        calls ->
          {_name, range} = Enum.max_by(calls, fn {_name, range} -> range.end[:line] end)
          %{end_line: range.end[:line], indent: indent_of_line(content, range.start[:line])}
      end
    else
      _ -> %{end_line: nil, indent: nil}
    end
  end

  def top_level_section_calls(module_node, names) do
    {_, acc} =
      Macro.prewalk(module_node, [], fn
        node, acc ->
          case section_call_range(node, names) do
            {:ok, entry} -> {node, acc ++ [entry]}
            :skip -> {node, acc}
          end
      end)

    acc
  end

  def section_call_range({name, _meta, args} = node, names)
      when is_atom(name) and is_list(args) do
    if name in names and do_block?(args) do
      case Sourceror.get_range(node) do
        %Sourceror.Range{} = range -> {:ok, {name, range}}
        _ -> :skip
      end
    else
      :skip
    end
  end

  def section_call_range(_node, _names), do: :skip

  def module_node_range(content, module) do
    with {:ok, ast} <- Sourceror.parse_string(content),
         module_line when is_integer(module_line) <- module_source_line(module),
         [%{node: node} | _] <- collect_at_line(ast, module_line),
         %Sourceror.Range{
           start: [line: start_line, column: _],
           end: [line: end_line, column: _]
         } <-
           Sourceror.get_range(node) do
      {:ok, %{start_line: start_line, end_line: end_line}}
    else
      _ -> :error
    end
  end

  def indent_of_line(content, line) do
    anchor_indent(content, line)
  end

  # ── creation insertion ──────────────────────────────────────────────────────

  # The body's least-indented line lands at the placement's target width:
  # the anchor's indentation, two spaces inside the section keyword, or two
  # spaces inside the synthesized block.
  def creation_body_lines(content, insertion, body) do
    target_width =
      case insertion do
        {:anchor, range, _before?} -> String.length(anchor_indent(content, range.start_line))
        {:inside_block, range} -> String.length(anchor_indent(content, range.start_line)) + 2
        {:synthesize, _line, _call, indent} -> String.length(indent) + 2
      end

    shift_body(body, target_width)
  end

  def insert_lines(content, insertion, body_lines) do
    case insertion do
      {:anchor, range, before?} ->
        op = if before?, do: :insert_before_entity, else: :insert_after_entity
        {new_content, diff} = splice(op, content, range, body_lines)
        {new_content, diff, inserted_range(op, range, body_lines)}

      {:inside_block, range} ->
        insert_inside_block(content, range, body_lines)

      {:synthesize, placement_line, call_name, indent} ->
        block =
          [indent <> "#{call_name} do"] ++
            body_lines ++
            [indent <> "end", ""]

        {new_content, diff} = insert_at_line(content, placement_line, block)

        {new_content, diff, {placement_line + 1, placement_line + length(body_lines)}}
    end
  end

  def inserted_range(:insert_before_entity, range, body_lines),
    do: {range.start_line, range.start_line + length(body_lines)}

  def inserted_range(:insert_after_entity, range, body_lines),
    do: {range.end_line + 2, range.end_line + 1 + length(body_lines)}

  # Inserts body_lines inside an existing section block, just before its
  # `end`. A one-line `actions do end` is expanded in place.
  def insert_inside_block(content, range, body_lines) do
    if range.start_line == range.end_line do
      expand_inline_section(content, range, body_lines)
    else
      {new_content, diff} = insert_at_line(content, range.end_line, body_lines)
      count = length(body_lines)
      {new_content, diff, {range.end_line, range.end_line + count - 1}}
    end
  end

  def expand_inline_section(content, range, body_lines) do
    eol = detect_eol(content)
    lines = String.split(String.replace_suffix(content, "\n", ""), eol)
    line_text = Enum.at(lines, range.start_line - 1, "")

    case Regex.run(~r/^(\s*)(\w+)(\s+do)(\s*end\s*)$/, line_text) do
      [_, leading, call, do_part, _trailing] ->
        replacement = [leading <> call <> do_part] ++ body_lines ++ [leading <> "end"]

        new_lines = List.replace_at(lines, range.start_line - 1, Enum.join(replacement, eol))

        new_content =
          Enum.join(new_lines, eol) <>
            if(String.ends_with?(content, "\n"), do: eol, else: "")

        diff =
          "@@ line #{range.start_line} @@\n" <>
            Enum.map_join([line_text], "\n", &("- " <> &1)) <>
            "\n" <>
            Enum.map_join(replacement, "\n", &("+ " <> &1))

        count = length(body_lines)
        {new_content, diff, {range.start_line + 1, range.start_line + count}}

      nil ->
        # not a recognizable one-line section: append after the line, keeping
        # the block untouched
        {new_content, diff} = insert_at_line(content, range.start_line, body_lines)
        count = length(body_lines)
        {new_content, diff, {range.start_line, range.start_line + count - 1}}
    end
  end

  # Inserts new_lines before the 1-based `line`, returning the new content,
  # an add-only diff, and the inserted range.
  def insert_at_line(content, line, new_lines) do
    eol = detect_eol(content)
    trailing_newline? = String.ends_with?(content, "\n")

    lines =
      content
      |> String.replace_suffix("\n", "")
      |> String.replace_suffix("\r", "")
      |> String.split(eol)

    before = Enum.take(lines, line - 1)
    rest = Enum.drop(lines, line - 1)

    new_content =
      Enum.join(before ++ new_lines ++ rest, eol) <>
        if(trailing_newline?, do: eol, else: "")

    diff = "@@ line #{line} @@\n" <> Enum.map_join(new_lines, "\n", &("+ " <> &1))

    {new_content, diff}
  end
end
