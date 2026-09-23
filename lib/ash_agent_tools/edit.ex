# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Edit do
  @moduledoc """
  Semantic edit operations on Ash DSL entities — Serena's anchor edits,
  made DSL-native.

  Five operations, addressed by name path (see `AshAgentTools.NamePath`):

    * `create_entity/3` — insert a new entity into a section, **empty
      sections included**: a missing `section do … end` block is
      synthesized and placed inside the module body
    * `replace_entity_block/3` — swap an entity's source block for `body`
    * `insert_before_entity/3` / `insert_after_entity/3` — anchor inserts
      with blank-line normalization
    * `safe_delete_entity/2` — refuses while anything still references the
      entity (accepting actions, relationships, code interfaces)

  `apply_batch/2` applies any mix of the above to one file
  transactionally: one digest handshake, sequential in-memory application
  (later ops may anchor on entities created earlier in the batch), one
  atomic write, one gate — any failure reverts everything.

  The safety model around every operation:

    * **Dry-run default.** Without `:write`, the tool returns the planned
      diff plus the file's *shape digest* and touches nothing.
    * **Mechanical read-before-edit.** Writes require `:expected_digest` —
      the shape digest from a prior `shape/1`, resolve, or dry-run — and
      refuse on mismatch. The digest covers the symbol table (which
      entities sit on which lines), so cosmetic edits between read and
      write keep it valid; structural movement invalidates it.
    * **Provenance guard.** Transformer-injected declarations (no Spark
      annotation — `defaults [:read]` actions and friends) and annotations
      that no longer match the source text are refused, never spliced.
    * **Atomic write** (tempfile + rename in the target directory) with the
      file's own EOLs and indentation preserved.
    * **Post-edit gate.** After writing, the file is recompiled with
      diagnostics captured and the affected resources run a per-action
      validate canary; a failed gate reverts the file to its pre-edit
      content and reports the diagnostics.

  The formatter contract: region-correct indentation is unconditional; a
  whole-file reformat happens **if and only if** the touched file was
  already format-clean (`mix format` of the pre-edit bytes round-trips
  byte-identical). A dirty file is left exactly as spliced and the report
  carries `format_hint: "run mix format"` — never surprise-diff a file
  that wasn't clean.

  Every function returns `{:ok, report}` or `{:error, report}` — reports
  are plain, JSON-encodable maps on every path, success or failure.

  Boundaries: edits are compile-time DSL text only — there is no daemon or
  MCP edit tool (an edit surface driven by client JSON over a daemon would
  be RCE). Policies remain positional; rename propagation remains future
  work.
  """

  alias AshAgentTools.Context
  alias AshAgentTools.NamePath
  alias AshAgentTools.Registry
  alias AshAgentTools.Symbols
  alias AshAgentTools.Types

  @max_body_bytes 256 * 1024

  @type op ::
          :replace_entity_block
          | :insert_before_entity
          | :insert_after_entity
          | :safe_delete_entity
          | :create_entity

  # dsl_path → the source call name of the section block. Sections absent
  # from this map can still be edited through anchors (sibling entities),
  # but an *absent or empty* block cannot be located by name and therefore
  # cannot be synthesized.
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

  # -- shape digests ---------------------------------------------------------

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

  defp shape_name_path(module, symbol) do
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

  @doc """
  Replaces the source block of the entity at `name_path` with `body`.

  `body` is entity source text (e.g.
  `"attribute :score, :integer, public?: true"`) — parsed for sanity,
  re-indented to the anchor's indentation, and spliced over the entity's
  exact AST range.
  """
  def replace_entity_block(name_path, body, opts \\ []),
    do: run(:replace_entity_block, name_path, body, opts)

  @doc """
  Inserts `body` (one or more entity declarations) immediately before the
  entity at `name_path`, with exactly one blank line between.
  """
  def insert_before_entity(name_path, body, opts \\ []),
    do: run(:insert_before_entity, name_path, body, opts)

  @doc """
  Inserts `body` (one or more entity declarations) immediately after the
  entity at `name_path`, with exactly one blank line between.
  """
  def insert_after_entity(name_path, body, opts \\ []),
    do: run(:insert_after_entity, name_path, body, opts)

  @doc """
  Deletes the entity at `name_path` — but only when nothing references it.

  References are the `context/3` projection (actions accepting an
  attribute, relationships wired through it, code interfaces calling an
  action); a non-empty list refuses the delete with the list attached, the
  way Serena's `safe_delete_symbol` does.
  """
  def safe_delete_entity(name_path, opts \\ []),
    do: run(:safe_delete_entity, name_path, nil, opts)

  @doc """
  Applies a list of edit operations to one file, transactionally.

  `ops` is a list of maps, each describing one operation:

      %{
        "op" => "create_entity",
        "section_path" => "MyApp.Post/actions",
        "body" => "update :check_in do accept [:status] end"
      }
      %{"op" => "replace_entity_block", "name_path" => "MyApp.Post/attributes/score",
        "body" => "attribute :score, :integer"}
      %{"op" => "insert_after_entity", "name_path" => "MyApp.Post/attributes/score",
        "body" => "attribute :reviewed, :boolean"}
      %{"op" => "safe_delete_entity", "name_path" => "…"}

  `create_entity` entries may carry `"anchor"` (a name path) and
  `"position"` (`"after"`/`"before"`). The CLI verb names — `"replace"`,
  `"insert-before"`, `"insert-after"`, `"delete"`, `"create"` — are
  accepted as `op` aliases.

  The transactional contract:

    * **One digest handshake** — `:expected_digest` (required for a write)
      is checked once against the file's initial state.
    * **Sequential in-memory application** — each op is planned against the
      result of the previous one; anchors and targets may reference
      entities created earlier in the same batch.
    * **One atomic write, one gate** — nothing touches the disk until every
      op has planned cleanly; then a single write and a single
      recompile + canary gate. Any failure at any step reverts everything:
      there is no partial application.
  """
  def apply_batch(ops, opts \\ [])

  def apply_batch(ops, opts) when is_list(ops) and is_list(opts) do
    run_batch(ops, opts)
  end

  def apply_batch(ops, _opts) do
    {:error,
     %{
       error: "invalid_batch",
       message: "ops must be a list of operation maps, got: #{inspect(ops)}"
     }}
  end

  # -- the single-op common flow -----------------------------------------------

  defp run(op, name_path, body, opts) when is_list(opts) do
    with {:ok, resolved} <- resolve(name_path),
         :ok <- check_body(op, body),
         :ok <- check_provenance(resolved),
         {:ok, file, content} <- read_target(resolved),
         {:ok, current_shape} <- shape!(file),
         {:ok, range} <- locate_block(file, content, resolved),
         :ok <- check_references(op, resolved) do
      {spliced, diff} =
        splice(op, content, range, prepare_body(op, body, content, range))

      {new_content, formatted?} = format_pass(file, content, spliced)
      diff = format_note(diff, formatted?)

      if opts[:write] do
        finish_write(%{
          op: Atom.to_string(op),
          name_path: resolved.name_path,
          file: file,
          original: content,
          new_content: new_content,
          diff: diff,
          current_digest: current_shape.digest,
          expected_digest: opts[:expected_digest],
          modules: [resolved.module.module],
          formatted?: formatted?
        })
      else
        {:ok,
         %{
           op: Atom.to_string(op),
           name_path: resolved.name_path,
           file: file,
           dry_run?: true,
           write?: false,
           diff: diff,
           formatted?: formatted?,
           current_digest: current_shape.digest
         }
         |> maybe_format_hint(formatted?)}
      end
    end
  end

  defp run(_op, name_path, _body, _opts) do
    {:error,
     %{
       error: "invalid_name_path",
       message: "name_path must be a string, got: #{inspect(name_path)}"
     }}
  end

  # -- steps -----------------------------------------------------------------

  defp resolve(name_path) when is_binary(name_path) do
    # NamePath.resolve/2 returns {:ok, report} and raises ArgumentError on
    # misses; the rescue funnels those into structured error reports.
    NamePath.resolve(name_path)
  rescue
    error in ArgumentError ->
      {:error, %{error: "unresolvable_name_path", message: Exception.message(error)}}
  end

  defp resolve(name_path) do
    {:error, %{error: "invalid_name_path", message: inspect(name_path)}}
  end

  defp check_body(:safe_delete_entity, _body), do: :ok

  defp check_body(_op, body) when is_binary(body) do
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

  defp check_body(_op, body) do
    {:error, %{error: "invalid_body", message: "body must be a string, got: #{inspect(body)}"}}
  end

  # Transformer-injected declarations have no Spark annotation: their
  # "source" is the transformer, not the file, and splicing there would
  # corrupt whatever happens to be on the guessed line.
  defp check_provenance(resolved) do
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

  defp read_target(resolved) do
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

  defp shape!(file) do
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
  defp locate_block(file, content, resolved) do
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

  defp locate_block_at(content, anno_line) do
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

  defp collect_at_line(ast, line) do
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
  defp range_start_line(node) do
    case Sourceror.get_range(node) do
      %Sourceror.Range{start: [line: line, column: _]} -> %{start_line: line}
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp check_references(:safe_delete_entity, resolved) do
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

  defp check_references(_op, _resolved), do: :ok

  # references_for/3 projects the reference groups as a map; the delete
  # gate only cares about the flat list of referencing things.
  defp references_list(%{
         actions: actions,
         code_interfaces: code_interfaces,
         relationships: relationships
       }) do
    List.flatten(List.wrap(actions) ++ List.wrap(code_interfaces) ++ List.wrap(relationships))
  end

  defp references_list(list) when is_list(list), do: list

  # Body preparation: parse-verified body text, split to the file's EOL
  # style and re-indented so its least-indented line sits at the anchor's
  # indentation.
  defp prepare_body(:safe_delete_entity, _body, _content, _range), do: []

  defp prepare_body(_op, body, content, range) do
    anchor_indent = anchor_indent(content, range.start_line)
    shift_body(body, String.length(anchor_indent))
  end

  defp shift_body(body, target_width) do
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

  defp anchor_indent(content, start_line) do
    line = content |> String.split("\n") |> Enum.at(start_line - 1, "")

    case Regex.run(~r/^ */, line) do
      [indent] -> indent
      _ -> ""
    end
  end

  defp indent_delta(lines, anchor_width) do
    min_width =
      lines
      |> Enum.reject(&(String.trim_leading(&1) == ""))
      |> Enum.map(&String.length(Regex.run(~r/^ */, &1) |> hd()))
      |> Enum.min(fn -> 0 end)

    anchor_width - min_width
  end

  # Splice on the AST range's line boundaries, producing both the new
  # content and a minimal textual diff of the change.
  defp splice(op, content, range, body_lines) do
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
  defp blank_normalize(["" | _] = rest), do: rest
  defp blank_normalize([]), do: []
  defp blank_normalize(rest), do: ["" | rest]

  defp detect_eol(content) do
    if String.contains?(content, "\r\n"), do: "\r\n", else: "\n"
  end

  defp diff_lines(anchor, middle, at_line) do
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

  defp finish_write(%{expected_digest: expected_digest, current_digest: current_digest} = plan) do
    cond do
      not is_binary(expected_digest) ->
        {:error,
         %{
           error: "expected_digest_required",
           message: "writes require :expected_digest (the shape digest from your last read)",
           op: plan.op,
           name_path: plan.name_path,
           file: plan.file,
           current_digest: current_digest,
           diff: plan.diff,
           dry_run?: false
         }}

      expected_digest != current_digest ->
        {:error,
         %{
           error: "stale_file",
           message: "the file changed since it was read; re-read and re-plan the edit",
           op: plan.op,
           name_path: plan.name_path,
           file: plan.file,
           expected_digest: expected_digest,
           current_digest: current_digest,
           diff: plan.diff,
           dry_run?: false
         }}

      true ->
        case atomic_write(plan.file, plan.new_content) do
          :ok ->
            gate_and_finish(plan)

          {:error, reason} ->
            {:error,
             %{
               error: "write_failed",
               op: plan.op,
               file: plan.file,
               reason: inspect(reason),
               dry_run?: false
             }}
        end
    end
  end

  defp atomic_write(file, content) do
    tmp =
      Path.join(Path.dirname(file), ".ash_agent_edit_#{System.unique_integer([:positive])}")

    with :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  # The post-edit gate: recompile with diagnostics captured, then sanity
  # checks + a per-action validate canary on the affected resources. Any
  # compile error or canary crash reverts the file to its pre-edit content
  # and reports the diagnostics — an edit tool that leaves the tree broken
  # is worse than no edit tool.
  defp gate_and_finish(plan) do
    case post_edit_gate(plan.modules, plan.file) do
      {:ok, gate} ->
        {:ok,
         %{
           op: plan.op,
           name_path: plan.name_path,
           file: plan.file,
           dry_run?: false,
           write?: true,
           applied?: true,
           diff: plan.diff,
           gate: gate,
           new_digest: shape(plan.file) && shape(plan.file).digest
         }
         |> Map.put(:formatted?, !!plan.formatted?)
         |> maybe_format_hint(plan.formatted?)}

      {:error, gate} ->
        File.write!(plan.file, plan.original)
        _ = shape(plan.file)

        {:error,
         %{
           error: "post_edit_gate_failed",
           message: "the edit compiled or validated badly; the file was reverted",
           op: plan.op,
           name_path: plan.name_path,
           file: plan.file,
           gate: gate,
           reverted?: true,
           dry_run?: false,
           diff: plan.diff
         }}
    end
  end

  defp post_edit_gate(modules, file) do
    # ignore_module_conflict: the file's module is usually already loaded.
    # debug_info: Spark records entity annotations only when the compiler
    # keeps debug info — and hosts may run with it off (`mix test` does) —
    # so force it on or the recompiled resource loses its annos.
    previous = Code.get_compiler_option(:ignore_module_conflict)
    previous_debug_info = Code.get_compiler_option(:debug_info)

    Code.put_compiler_option(:ignore_module_conflict, true)
    Code.put_compiler_option(:debug_info, true)

    {_result, diagnostics} = Code.with_diagnostics(fn -> Code.compile_file(file) end)

    Code.put_compiler_option(:ignore_module_conflict, previous)
    Code.put_compiler_option(:debug_info, previous_debug_info)

    errors = Enum.filter(diagnostics, &(&1.severity == :error))

    if errors != [] do
      {:error, %{compile: "error", diagnostics: Enum.map(diagnostics, &diagnostic/1)}}
    else
      warnings = Enum.map(diagnostics, &diagnostic/1)

      case validate_canary(modules) do
        :ok ->
          {:ok, %{compile: "ok", validate: "ok", warnings: warnings}}

        {:error, message} ->
          {:error, %{compile: "ok", validate: "error", message: message, warnings: warnings}}
      end
    end
  rescue
    error ->
      {:error, %{compile: "error", message: Types.error_message(error), diagnostics: []}}
  end

  defp diagnostic(diag) do
    %{
      severity: diag.severity,
      message: diag.message,
      line: (is_tuple(diag.position) && elem(diag.position, 0)) || diag.position,
      file: diag.file && Path.relative_to_cwd(diag.file)
    }
  rescue
    _ -> %{severity: diag.severity, message: diag.message, line: nil, file: nil}
  end

  # Structural canary over every touched module: resources must still be
  # resources and every action must still *build* an input without crashing;
  # domains only need to still resolve. Expected validation errors
  # ("is required" with empty params) are not failures; crashes are.
  defp validate_canary(modules) do
    Enum.reduce_while(modules, :ok, fn module, :ok ->
      case canary_module(module) do
        :ok -> {:cont, :ok}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp canary_module(module) do
    AshAgentTools.Describe.ensure_resource!(module)

    crash =
      Enum.find(Ash.Resource.Info.actions(module), fn action ->
        try do
          AshAgentTools.validate_input(module, action.name, %{})
          false
        rescue
          _ -> true
        end
      end)

    case crash do
      nil ->
        :ok

      action ->
        {:error, "#{Registry.module_name(module)}/#{action.name} no longer builds an input"}
    end
  rescue
    # domains (and any non-resource the edit touched) pass on the compile
    # gate alone
    _ in ArgumentError -> :ok
  end

  # ── the formatter contract ──────────────────────────────────────────────────

  # Region-correct indentation is unconditional (the splice). A whole-file
  # reformat happens if and only if the touched file was already format-clean:
  # `mix format` of the pre-edit bytes round-trips byte-identical. A dirty
  # file is left exactly as spliced, and the report carries a format_hint —
  # never surprise-diff a file that wasn't clean.
  defp format_pass(file, original, new_content) do
    if format_clean?(file, original) do
      {try_format(file, new_content), true}
    else
      {new_content, false}
    end
  end

  defp format_clean?(file, content) do
    try_format(file, content) == content
  end

  defp try_format(file, content) do
    formatted =
      content
      |> Code.format_string!(formatter_opts(file))
      |> IO.iodata_to_binary()

    # format_string! strips the trailing newline; the file's own convention
    # is preserved
    if String.ends_with?(content, "\n") and not String.ends_with?(formatted, "\n") do
      formatted <> "\n"
    else
      formatted
    end
  rescue
    _ -> content
  end

  # "Format-clean" is defined by the host project's own formatter rules: the
  # .formatter.exs of the project the edited file lives in (found by walking
  # up from the file), plus the `locals_without_parens` its `import_deps`
  # export — ash's DSL calls are written without parens, which the plain
  # formatter would re-parenthesize. Anything unresolvable falls back to
  # plain formatting; the only cost is a false "not clean", never a wrong
  # edit.
  defp formatter_opts(file) do
    [locals_without_parens: locals_without_parens(file)]
  rescue
    _ -> []
  end

  @max_formatter_walk 12

  defp locals_without_parens(file) do
    dir = Path.dirname(Path.expand(file))

    case project_formatter_file(dir, @max_formatter_walk) do
      nil ->
        []

      formatter_file ->
        {evaluated, _} = Code.eval_file(formatter_file)

        deps =
          evaluated
          |> Keyword.get(:import_deps, [])
          |> Enum.flat_map(&dep_locals_without_parens(formatter_file, &1))

        own = Keyword.get(evaluated, :locals_without_parens, [])
        Enum.uniq(own ++ deps)
    end
  end

  # The project root owning `file`: the nearest ancestor with both a mix.exs
  # and a .formatter.exs (the formatter is what defines format-clean here).
  defp project_formatter_file(dir, tries)

  defp project_formatter_file(_dir, 0), do: nil

  defp project_formatter_file(dir, tries) do
    formatter = Path.join(dir, ".formatter.exs")
    mixfile = Path.join(dir, "mix.exs")

    cond do
      File.exists?(formatter) and File.exists?(mixfile) ->
        formatter

      File.exists?(mixfile) ->
        nil

      true ->
        project_formatter_file(Path.dirname(dir), tries - 1)
    end
  end

  defp dep_locals_without_parens(formatter_file, dep) do
    dep_formatter =
      Path.join([Path.dirname(formatter_file), "deps", Atom.to_string(dep), ".formatter.exs"])

    case File.exists?(dep_formatter) do
      true ->
        {evaluated, _} = Code.eval_file(dep_formatter)

        evaluated
        |> Keyword.get(:export, [])
        |> Keyword.get(:locals_without_parens, [])

      false ->
        []
    end
  end

  defp format_note(diff, formatted?) do
    if formatted? and is_binary(diff),
      do: diff <> "\n(whole-file mix format applied)",
      else: diff
  end

  # formatted?: false means the file was not format-clean before the edit, so
  # the rest of the file was left untouched — tell the agent how to finish.
  defp maybe_format_hint(report, formatted?) do
    if formatted? == false,
      do: Map.put(report, :format_hint, "run mix format"),
      else: report
  end

  # ── creation ────────────────────────────────────────────────────────────────

  defp resolve_section(section_path) when is_binary(section_path) do
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

  defp resolve_section(other),
    do: {:error, %{error: "invalid_section_path", message: inspect(other)}}

  defp ensure_section_known!(module, kind, dsl_path, section_path) do
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
  defp entity_identifier(body) do
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

  defp single_statement({:__block__, _, [statement]}), do: {:ok, statement}
  defp single_statement({:__block__, _, statements}) when length(statements) > 1, do: :multiple
  defp single_statement(statement), do: {:ok, statement}

  defp check_duplicate(module, module_kind, dsl_path, identifier, created)
  defp check_duplicate(_module, _kind, _dsl_path, nil, _created), do: :ok

  defp check_duplicate(module, module_kind, dsl_path, identifier, created) do
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
  defp resolve_anchor(nil, _module, _dsl_path, _created), do: {:ok, nil}

  defp resolve_anchor(anchor, module, dsl_path, created) when is_binary(anchor) do
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

  defp create_target(module, anchor) do
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

  defp file_of(module) do
    case AshAgentTools.Source.from_module(module) do
      %{file: file} when is_binary(file) -> file
      _ -> nil
    end
  end

  # ── creation placement ─────────────────────────────────────────────────────

  defp plan_creation(module, module_kind, dsl_path, content, anchor_line, opts) do
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

  defp last_annotated_sibling(module, module_kind, dsl_path) do
    module
    |> Symbols.module_symbols(module_kind)
    |> Enum.filter(&(&1.dsl_path == dsl_path and &1.provenance == :source and &1.source))
    |> Enum.sort_by(&(&1.source.line || 0))
    |> List.last()
  end

  # The source block of the section itself: the call in the module body
  # whose name is the section's (`actions do … end`).
  defp section_block(content, module, call_name) when not is_nil(call_name) do
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

  defp section_block(_content, _module, _call_name), do: :error

  defp module_source_line(module) do
    case AshAgentTools.Source.from_module(module) do
      %{line: line} when is_integer(line) -> line
      _ -> nil
    end
  end

  # Finds the section's own call node: a call with the section's name whose
  # last argument is a do-block.
  defp find_section_call(node, call_name) do
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
  defp do_block?(args) do
    case List.last(args) do
      [[do: _]] -> true
      [{{:__block__, _, [:do]}, _body}] -> true
      _ -> false
    end
  end

  # Synthesis: no block to splice into, so the whole `section do … end` is
  # appended — after the last known section block in the module body, or
  # immediately before the module's final `end` when there is none.
  defp synthesize(module, module_kind, dsl_path, call_name, content) do
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
  defp last_section_block_end(content, module, module_kind) do
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

  defp top_level_section_calls(module_node, names) do
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

  defp section_call_range({name, _meta, args} = node, names)
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

  defp section_call_range(_node, _names), do: :skip

  defp module_node_range(content, module) do
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

  defp indent_of_line(content, line) do
    anchor_indent(content, line)
  end

  # ── creation insertion ──────────────────────────────────────────────────────

  # The body's least-indented line lands at the placement's target width:
  # the anchor's indentation, two spaces inside the section keyword, or two
  # spaces inside the synthesized block.
  defp creation_body_lines(content, insertion, body) do
    target_width =
      case insertion do
        {:anchor, range, _before?} -> String.length(anchor_indent(content, range.start_line))
        {:inside_block, range} -> String.length(anchor_indent(content, range.start_line)) + 2
        {:synthesize, _line, _call, indent} -> String.length(indent) + 2
      end

    shift_body(body, target_width)
  end

  defp insert_lines(content, insertion, body_lines) do
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

  defp inserted_range(:insert_before_entity, range, body_lines),
    do: {range.start_line, range.start_line + length(body_lines)}

  defp inserted_range(:insert_after_entity, range, body_lines),
    do: {range.end_line + 2, range.end_line + 1 + length(body_lines)}

  # Inserts body_lines inside an existing section block, just before its
  # `end`. A one-line `actions do end` is expanded in place.
  defp insert_inside_block(content, range, body_lines) do
    if range.start_line == range.end_line do
      expand_inline_section(content, range, body_lines)
    else
      {new_content, diff} = insert_at_line(content, range.end_line, body_lines)
      count = length(body_lines)
      {new_content, diff, {range.end_line, range.end_line + count - 1}}
    end
  end

  defp expand_inline_section(content, range, body_lines) do
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
  defp insert_at_line(content, line, new_lines) do
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

  # ── batch application ───────────────────────────────────────────────────────

  @op_names %{
    "create_entity" => :create_entity,
    "create" => :create_entity,
    "replace_entity_block" => :replace_entity_block,
    "replace" => :replace_entity_block,
    "insert_before_entity" => :insert_before_entity,
    "insert-before" => :insert_before_entity,
    "insert_after_entity" => :insert_after_entity,
    "insert-after" => :insert_after_entity,
    "safe_delete_entity" => :safe_delete_entity,
    "delete" => :safe_delete_entity
  }

  defp run_batch(ops, opts) do
    with {:ok, normalized} <- normalize_ops(ops),
         {:ok, file} <- batch_file(normalized),
         {:ok, current_shape} <- shape!(file),
         :ok <- batch_digest_check(normalized, opts, current_shape) do
      content = File.read!(file)

      state = %{
        content: content,
        symbols: current_shape.symbols,
        created: %{},
        modules: MapSet.new(),
        per_ops: []
      }

      case apply_ops(normalized, state, 0) do
        {:error, index, detail} ->
          {:error,
           %{
             error: "batch_aborted",
             message: "op #{index + 1} failed; nothing was written (the batch is transactional)",
             index: index,
             detail: detail,
             applied?: false,
             dry_run?: not (!!opts[:write]),
             file: file
           }}

        state ->
          {final_content, formatted?} = format_pass(file, content, state.content)
          combined = combined_diff(content, final_content)

          base = %{
            op: "apply_batch",
            file: file,
            ops: Enum.reverse(state.per_ops),
            combined_diff: combined,
            formatted?: formatted?,
            op_count: length(normalized)
          }

          if opts[:write] do
            finish_write(%{
              op: "apply_batch",
              name_path: nil,
              file: file,
              original: content,
              new_content: final_content,
              diff: combined,
              current_digest: current_shape.digest,
              expected_digest: opts[:expected_digest],
              modules: MapSet.to_list(state.modules),
              formatted?: formatted?
            })
            |> merge_batch(base)
          else
            {:ok,
             base
             |> Map.merge(%{
               dry_run?: true,
               write?: false,
               applied?: false,
               current_digest: current_shape.digest
             })
             |> maybe_format_hint(formatted?)}
          end
      end
    end
  end

  defp merge_batch({:ok, report}, base) do
    {:ok, Map.merge(report, Map.take(base, [:op, :ops, :combined_diff, :formatted?, :op_count]))}
  end

  defp merge_batch({:error, report}, base) do
    {:error, Map.merge(report, Map.take(base, [:ops, :combined_diff, :formatted?, :op_count]))}
  end

  defp normalize_ops(ops) do
    ops
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {op, index}, {:ok, acc} ->
      case normalize_op(op) do
        {:ok, normalized} ->
          {:cont, {:ok, acc ++ [normalized]}}

        {:error, detail} ->
          {:halt,
           {:error,
            Map.merge(%{error: "invalid_op", message: "op #{index + 1} is invalid"}, detail)
            |> Map.put(:index, index)}}
      end
    end)
    |> case do
      {:ok, []} ->
        {:error, %{error: "empty_batch", message: "ops must contain at least one operation"}}

      other ->
        other
    end
  end

  defp normalize_op(op) when is_map(op) do
    op_name = fetch_key(op, "op", :op)
    kind = op_name && Map.get(@op_names, op_name)

    cond do
      is_nil(kind) ->
        {:error,
         %{
           error: "unknown_operation",
           message:
             "unknown op #{inspect(op_name)}. Valid ops: #{inspect(Enum.uniq(Map.values(@op_names)))}"
         }}

      kind == :create_entity ->
        section_path = fetch_key(op, "section_path", :section_path)
        body = fetch_key(op, "body", :body)

        if is_binary(section_path) do
          {:ok,
           %{
             kind: kind,
             section_path: section_path,
             body: body,
             anchor: fetch_key(op, "anchor", :anchor),
             position: position(fetch_key(op, "position", :position))
           }}
        else
          {:error, %{error: "invalid_op", message: "create_entity needs a string section_path"}}
        end

      true ->
        name_path = fetch_key(op, "name_path", :name_path)
        body = fetch_key(op, "body", :body)

        if is_binary(name_path) do
          {:ok, %{kind: kind, name_path: name_path, body: body}}
        else
          {:error, %{error: "invalid_op", message: "#{op_name} needs a string name_path"}}
        end
    end
  end

  defp normalize_op(op), do: {:error, %{error: "invalid_op", message: inspect(op)}}

  defp fetch_key(map, string_key, atom_key) do
    Map.get(map, string_key) || Map.get(map, atom_key)
  end

  defp position(nil), do: nil
  defp position("before"), do: :before
  defp position("after"), do: :after
  defp position(p) when p in [:before, :after], do: p
  defp position(other), do: {:invalid, other}

  # Every op must land in the same file: the module behind each name path or
  # section path owns exactly one source file.
  defp batch_file(normalized) do
    files =
      Enum.map(normalized, fn op ->
        module =
          case op.kind do
            :create_entity ->
              case resolve_section(op.section_path) do
                {:ok, {module, _kind, _dsl}} -> module
                _ -> nil
              end

            _ ->
              resolve_module_only(op.name_path)
          end

        file_of(module)
      end)

    cond do
      Enum.any?(files, &is_nil/1) ->
        {:error,
         %{
           error: "unresolvable_batch_target",
           message: "every op must address a loaded Ash module with a known source file"
         }}

      Enum.uniq(files) == [hd(files)] ->
        {:ok, hd(files)}

      true ->
        {:error,
         %{
           error: "batch_multiple_files",
           message: "a batch applies to one file; the ops address #{inspect(Enum.uniq(files))}"
         }}
    end
  end

  defp resolve_module_only(name_path) when is_binary(name_path) do
    module_part = name_path |> String.trim_leading("/") |> String.split("/") |> hd()

    case NamePath.resolve(module_part) do
      {:ok, report} -> report.module.module
      _ -> nil
    end
  end

  defp batch_digest_check(_normalized, opts, current_shape) do
    if opts[:write] == true and not is_binary(opts[:expected_digest]) do
      {:error,
       %{
         error: "expected_digest_required",
         message: "batch writes require :expected_digest (the shape digest from your last read)",
         current_digest: current_shape.digest
       }}
    else
      if opts[:write] == true and opts[:expected_digest] != current_shape.digest do
        {:error,
         %{
           error: "stale_file",
           message: "the file changed since it was read; re-read and re-plan the batch",
           expected_digest: opts[:expected_digest],
           current_digest: current_shape.digest
         }}
      else
        :ok
      end
    end
  end

  # The fold: each op is planned against the content the previous ops
  # produced. `state.symbols` tracks the current line of every compiled
  # entity (shifted by each splice; entities inside a spliced region go
  # stale); `state.created` holds the ranges of entities created by earlier
  # ops in the batch, so later ops can target or anchor on them.
  defp apply_ops(ops, state, index)

  defp apply_ops([], state, _index), do: state

  defp apply_ops(ops, state, index) do
    [op | rest] = ops

    case apply_one(op, state) do
      {:ok, {state, report}} ->
        apply_ops(rest, %{state | per_ops: [report | state.per_ops]}, index + 1)

      {:error, detail} ->
        {:error, index, detail}
    end
  end

  defp apply_one(%{kind: :create_entity} = op, state) do
    with {:ok, {module, module_kind, dsl_path}} <- resolve_section(op.section_path),
         :ok <- check_body(:create_entity, op.body),
         {:ok, _ast, identifier} <- entity_identifier(op.body),
         :ok <- check_duplicate(module, module_kind, dsl_path, identifier, state.created),
         {:ok, anchor} <- resolve_anchor(op.anchor, module, dsl_path, state.created),
         {:ok, placement, insertion} <-
           plan_creation(
             module,
             module_kind,
             dsl_path,
             state.content,
             anchor && anchor.line,
             position: op.position || :after
           ) do
      body_lines = creation_body_lines(state.content, insertion, op.body)
      {content2, diff, inserted} = insert_lines(state.content, insertion, body_lines)

      new_name_path =
        identifier && "#{Registry.module_name(module)}/#{dsl_path}/#{identifier}"

      state2 = register_created(state, content2, inserted, new_name_path)

      report = %{
        op: "create_entity",
        name_path: new_name_path,
        placement: placement,
        diff: diff
      }

      {:ok, {%{state2 | content: content2, modules: MapSet.put(state2.modules, module)}, report}}
    end
  end

  defp apply_one(%{kind: kind, name_path: name_path} = op, state)
       when kind in [
              :replace_entity_block,
              :insert_before_entity,
              :insert_after_entity,
              :safe_delete_entity
            ] do
    with {:ok, target} <- locate_target(name_path, state),
         :ok <- target_provenance(target, name_path),
         {:ok, range} <- target_range(target, state.content, name_path),
         :ok <- target_references(kind, target, name_path),
         :ok <- check_body(kind, op.body) do
      body_lines = prepare_body(kind, op.body, state.content, range)
      {content2, diff} = splice(kind, state.content, range, body_lines)
      {shift_range, delta} = splice_shift(kind, range, body_lines)

      report = %{
        op: Atom.to_string(kind),
        name_path: name_path,
        diff: diff
      }

      state2 =
        state
        |> Map.put(:content, content2)
        |> Map.put(:symbols, shift_symbols(state.symbols, shift_range, delta))
        |> Map.put(:created, shift_created(state.created, shift_range, delta))
        |> maybe_register_inserted(kind, name_path, op.body, range, body_lines)

      {:ok, {state2, report}}
    end
  end

  # An anchor insert that carries a single identifiable entity registers it
  # in the batch's created map, so later ops can target or anchor on it —
  # the same courtesy create_entity gets.
  defp maybe_register_inserted(state, kind, name_path, body, range, body_lines)
       when kind in [:insert_before_entity, :insert_after_entity] do
    with {:ok, _ast, identifier} <- entity_identifier(body),
         false <- is_nil(identifier) do
      section_prefix =
        binary_part(name_path, 0, byte_size(name_path) - length_of_last_segment(name_path))

      inserted = inserted_range(kind, range, body_lines)
      %{state | created: Map.put(state.created, section_prefix <> identifier, inserted)}
    else
      _ -> state
    end
  end

  defp maybe_register_inserted(state, _kind, _name_path, _body, _range, _body_lines),
    do: state

  defp length_of_last_segment(name_path) do
    name_path
    |> String.split("/")
    |> List.last()
    |> byte_size()
  end

  defp locate_target(name_path, state) do
    case Map.fetch(state.created, name_path) do
      {:ok, {s, _e}} ->
        {:ok, {:created, s}}

      :error ->
        with {:ok, resolved} <- resolve(name_path) do
          case current_line(state.symbols, resolved.name_path) do
            nil ->
              {:error,
               %{
                 error: "stale_target",
                 message:
                   "#{resolved.name_path} was replaced by an earlier op in this batch;" <>
                     " address a different entity",
                 name_path: name_path
               }}

            line ->
              {:ok, {:compiled, resolved, line}}
          end
        end
    end
  end

  defp current_line(symbols, name_path) when is_binary(name_path) do
    Enum.find_value(symbols, fn %{name_path: np, line: line} ->
      if np == name_path and not is_nil(line), do: line, else: nil
    end)
  end

  defp target_range({:created, s}, content, name_path) do
    case locate_block_at(content, s) do
      {:ok, range} ->
        {:ok, range}

      :error ->
        {:error,
         %{
           error: "stale_target",
           message:
             "the entity created earlier in this batch no longer sits where it was" <>
               " placed; a previous op spliced over it",
           name_path: name_path
         }}
    end
  end

  defp target_range({:compiled, _resolved, line}, content, name_path) do
    case locate_block_at(content, line) do
      {:ok, range} ->
        {:ok, range}

      :error ->
        {:error,
         %{
           error: "span_mismatch",
           name_path: name_path,
           line: line,
           message:
             "no source construct starts on line #{line} for #{name_path}." <>
               " An earlier op in this batch moved it; address a different entity"
         }}
    end
  end

  defp target_provenance({:created, _s}, _name_path), do: :ok

  defp target_provenance({:compiled, resolved, _line}, _name_path),
    do: check_provenance(resolved)

  defp target_references(:safe_delete_entity, {:compiled, resolved, _line}, _name_path),
    do: check_references(:safe_delete_entity, resolved)

  # a created entity has no compiled references yet — nothing can reference
  # what the compiler has not seen
  defp target_references(_kind, _target, _name_path), do: :ok

  defp register_created(state, _content, _inserted, nil), do: state

  defp register_created(state, _content, inserted, name_path) do
    %{state | created: Map.put(state.created, name_path, inserted)}
  end

  # After a splice that changed the line count by delta below `range`:
  # entities inside the spliced region are gone, entities below shift.
  defp shift_symbols(symbols, range, delta) do
    Enum.map(symbols, fn %{line: line} = symbol ->
      cond do
        not is_integer(line) ->
          symbol

        line >= range.start_line and line <= range.end_line ->
          %{symbol | line: :stale}

        line > range.end_line ->
          %{symbol | line: line + delta}

        true ->
          symbol
      end
    end)
  end

  # entities inside a spliced region are gone; entities below shift
  defp shift_created(created, range, delta) do
    created
    |> Enum.map(fn {name_path, {s, e}} ->
      cond do
        e < range.start_line ->
          {name_path, {s + delta, e + delta}}

        s >= range.start_line and e <= range.end_line ->
          {name_path, :stale}

        true ->
          {name_path, {s, e}}
      end
    end)
    |> Enum.reject(fn {_name_path, range} -> range == :stale end)
    |> Map.new()
  end

  # Where a splice's line-count change lands: inserts shift every line after
  # the anchor, replaces and deletes stale out their own region.
  defp splice_shift(:insert_before_entity, range, body_lines),
    do: {%{start_line: range.start_line, end_line: range.start_line - 1}, length(body_lines) + 1}

  defp splice_shift(:insert_after_entity, range, body_lines),
    do: {%{start_line: range.end_line + 1, end_line: range.end_line}, length(body_lines) + 1}

  defp splice_shift(op, range, body_lines) do
    span = range.end_line - range.start_line + 1
    count = length(body_lines)
    delta = if op == :replace_entity_block, do: count - span, else: -span
    {range, delta}
  end

  # A line-level diff of the whole file (Myers), for the batch's combined
  # view: removals and additions only, so the report stays readable.
  @max_diff_lines 2_000

  defp combined_diff(original, final) do
    a = String.split(String.replace_suffix(original, "\n", ""), ["\r\n", "\n"])
    b = String.split(String.replace_suffix(final, "\n", ""), ["\r\n", "\n"])

    if length(a) + length(b) > @max_diff_lines do
      "(diff too large to display)"
    else
      lines =
        Enum.flat_map(List.myers_difference(a, b), fn
          {:del, del} -> Enum.map(del, &("- " <> &1))
          {:ins, ins} -> Enum.map(ins, &("+ " <> &1))
          {:eq, _eq} -> []
        end)

      if lines == [],
        do: "(no change)",
        else: "@@ line 1 @@\n" <> Enum.join(lines, "\n")
    end
  end

  # -- file ownership ----------------------------------------------------------------

  defp owning_module(file) do
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
