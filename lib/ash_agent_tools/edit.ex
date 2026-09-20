# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Edit do
  @moduledoc """
  Semantic edit operations on Ash DSL entities — Serena's anchor edits,
  made DSL-native.

  Four operations, all addressed by name path (see `AshAgentTools.NamePath`):

    * `replace_entity_block/3` — swap an entity's source block for `body`
    * `insert_before_entity/3` / `insert_after_entity/3` — anchor inserts
      with blank-line normalization
    * `safe_delete_entity/2` — refuses while anything still references the
      entity (accepting actions, relationships, code interfaces)

  The safety model around every operation:

    * **Dry-run default.** Without `:write?`, the tool returns the planned
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
      diagnostics captured and the affected resource runs a per-action
      validate canary; a failed gate reverts the file to its pre-edit
      content and reports the diagnostics.

  Every function returns `{:ok, report}` or `{:error, report}` — reports
  are plain, JSON-encodable maps on every path, success or failure.
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

  # -- the common flow -----------------------------------------------------------

  defp run(op, name_path, body, opts) when is_list(opts) do
    with {:ok, resolved} <- resolve(name_path),
         :ok <- check_body(op, body),
         :ok <- check_provenance(resolved),
         {:ok, file, content} <- read_target(resolved),
         {:ok, current_shape} <- shape!(file),
         {:ok, range} <- locate_block(file, content, resolved),
         :ok <- check_references(op, resolved) do
      {new_content, diff} =
        splice(op, content, range, prepare_body(op, body, content, range))

      if opts[:write] do
        write(op, resolved, file, content, new_content, diff, current_shape.digest, opts)
      else
        {:ok,
         %{
           op: Atom.to_string(op),
           name_path: resolved.name_path,
           file: file,
           dry_run?: true,
           write?: false,
           diff: diff,
           current_digest: current_shape.digest
         }}
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
    anno_line = resolved.symbol.source.line

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
            {:error,
             %{
               error: "span_mismatch",
               file: file,
               line: anno_line,
               message:
                 "no source construct starts on line #{anno_line} (the Spark annotation's" <>
                   " line). The file and the compiled module have drifted; re-read the file"
             }}
        end

      {:error, error} ->
        {:error, %{error: "unparseable_file", file: file, message: Types.error_message(error)}}
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
    body = String.replace(body, "\r\n", "\n")
    lines = body |> String.trim_trailing("\n") |> String.split("\n")
    anchor_indent = anchor_indent(content, range.start_line)
    delta = indent_delta(lines, String.length(anchor_indent))

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

  defp write(op, resolved, file, original, new_content, diff, current_digest, opts) do
    expected_digest = opts[:expected_digest]

    cond do
      not is_binary(expected_digest) ->
        {:error,
         %{
           error: "expected_digest_required",
           message: "writes require :expected_digest (the shape digest from your last read)",
           op: Atom.to_string(op),
           name_path: resolved.name_path,
           file: file,
           current_digest: current_digest,
           diff: diff,
           dry_run?: false
         }}

      expected_digest != current_digest ->
        {:error,
         %{
           error: "stale_file",
           message: "the file changed since it was read; re-read and re-plan the edit",
           op: Atom.to_string(op),
           name_path: resolved.name_path,
           file: file,
           expected_digest: expected_digest,
           current_digest: current_digest,
           diff: diff,
           dry_run?: false
         }}

      true ->
        case atomic_write(file, new_content) do
          :ok ->
            gate_and_finish(op, resolved, file, original, diff)

          {:error, reason} ->
            {:error,
             %{
               error: "write_failed",
               op: Atom.to_string(op),
               file: file,
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
  # checks + a per-action validate canary on the affected resource. Any
  # compile error or canary crash reverts the file to its pre-edit content
  # and reports the diagnostics — an edit tool that leaves the tree broken
  # is worse than no edit tool.
  defp gate_and_finish(op, resolved, file, original, diff) do
    case post_edit_gate(resolved, file) do
      {:ok, gate} ->
        {:ok,
         %{
           op: Atom.to_string(op),
           name_path: resolved.name_path,
           file: file,
           dry_run?: false,
           write?: true,
           applied?: true,
           diff: diff,
           gate: gate,
           new_digest: shape(file) && shape(file).digest
         }}

      {:error, gate} ->
        File.write!(file, original)
        _ = shape(file)

        {:error,
         %{
           error: "post_edit_gate_failed",
           message: "the edit compiled or validated badly; the file was reverted",
           op: Atom.to_string(op),
           name_path: resolved.name_path,
           file: file,
           gate: gate,
           reverted?: true,
           dry_run?: false,
           diff: diff
         }}
    end
  end

  defp post_edit_gate(resolved, file) do
    # ignore_module_conflict: the file's module is usually already loaded.
    # debug_info: Spark records entity annotations only when the compiler
    # keeps debug info — and hosts may run with it off (`mix test` does) —
    # so force it on or the recompiled resource loses its annos.
    previous = Code.get_compiler_option(:ignore_module_conflict)
    previous_debug_info = Code.get_compiler_option(:debug_info)

    Code.put_compiler_option(:ignore_module_conflict, true)
    Code.put_compiler_option(:debug_info, true)

    {result, diagnostics} = Code.with_diagnostics(fn -> Code.compile_file(file) end)

    Code.put_compiler_option(:ignore_module_conflict, previous)
    Code.put_compiler_option(:debug_info, previous_debug_info)

    errors = Enum.filter(diagnostics, &(&1.severity == :error))

    if errors != [] do
      {:error, %{compile: "error", diagnostics: Enum.map(diagnostics, &diagnostic/1)}}
    else
      warnings = Enum.map(diagnostics, &diagnostic/1)

      case validate_canary(resolved, result) do
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

  # Structural canary: the recompiled module must still be an Ash resource
  # and every action must still *build* an input without crashing.
  # Expected validation errors ("is required" with empty params) are not
  # failures; crashes are.
  defp validate_canary(resolved, _compile_result) do
    resource = resolved.module.module
    AshAgentTools.Describe.ensure_resource!(resource)

    crash =
      Enum.find(Ash.Resource.Info.actions(resource), fn action ->
        try do
          AshAgentTools.validate_input(resource, action.name, %{})
          false
        rescue
          _ -> true
        end
      end)

    case crash do
      nil ->
        :ok

      action ->
        {:error, "#{Registry.module_name(resource)}/#{action.name} no longer builds an input"}
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
