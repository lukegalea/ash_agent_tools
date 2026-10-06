# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Edit.Batch do
  @moduledoc false

  import AshAgentTools.Edit.Support
  import AshAgentTools.Edit.Creator
  import AshAgentTools.Edit.Writer

  alias AshAgentTools.NamePath
  alias AshAgentTools.Registry

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

  def run_batch(ops, opts) do
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

  def merge_batch({:ok, report}, base) do
    {:ok, Map.merge(report, Map.take(base, [:op, :ops, :combined_diff, :formatted?, :op_count]))}
  end

  def merge_batch({:error, report}, base) do
    {:error, Map.merge(report, Map.take(base, [:ops, :combined_diff, :formatted?, :op_count]))}
  end

  def normalize_ops(ops) do
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

  def normalize_op(op) when is_map(op) do
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

  def normalize_op(op), do: {:error, %{error: "invalid_op", message: inspect(op)}}

  def fetch_key(map, string_key, atom_key) do
    Map.get(map, string_key) || Map.get(map, atom_key)
  end

  def position(nil), do: nil
  def position("before"), do: :before
  def position("after"), do: :after
  def position(p) when p in [:before, :after], do: p
  def position(other), do: {:invalid, other}

  # Every op must land in the same file: the module behind each name path or
  # section path owns exactly one source file.
  def batch_file(normalized) do
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

  def resolve_module_only(name_path) when is_binary(name_path) do
    module_part = name_path |> String.trim_leading("/") |> String.split("/") |> hd()

    case NamePath.resolve(module_part) do
      {:ok, report} -> report.module.module
      _ -> nil
    end
  end

  def batch_digest_check(_normalized, opts, current_shape) do
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
  def apply_ops(ops, state, index)

  def apply_ops([], state, _index), do: state

  def apply_ops(ops, state, index) do
    [op | rest] = ops

    case apply_one(op, state) do
      {:ok, {state, report}} ->
        apply_ops(rest, %{state | per_ops: [report | state.per_ops]}, index + 1)

      {:error, detail} ->
        {:error, index, detail}
    end
  end

  def apply_one(%{kind: :create_entity} = op, state) do
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

  def apply_one(%{kind: kind, name_path: name_path} = op, state)
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
  def maybe_register_inserted(state, kind, name_path, body, range, body_lines)
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

  def maybe_register_inserted(state, _kind, _name_path, _body, _range, _body_lines),
    do: state

  def length_of_last_segment(name_path) do
    name_path
    |> String.split("/")
    |> List.last()
    |> byte_size()
  end

  def locate_target(name_path, state) do
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

  def current_line(symbols, name_path) when is_binary(name_path) do
    Enum.find_value(symbols, fn %{name_path: np, line: line} ->
      if np == name_path and not is_nil(line), do: line, else: nil
    end)
  end

  def target_range({:created, s}, content, name_path) do
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

  def target_range({:compiled, _resolved, line}, content, name_path) do
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

  def target_provenance({:created, _s}, _name_path), do: :ok

  def target_provenance({:compiled, resolved, _line}, _name_path),
    do: check_provenance(resolved)

  def target_references(:safe_delete_entity, {:compiled, resolved, _line}, _name_path),
    do: check_references(:safe_delete_entity, resolved)

  # a created entity has no compiled references yet — nothing can reference
  # what the compiler has not seen
  def target_references(_kind, _target, _name_path), do: :ok

  def register_created(state, _content, _inserted, nil), do: state

  def register_created(state, _content, inserted, name_path) do
    %{state | created: Map.put(state.created, name_path, inserted)}
  end

  # After a splice that changed the line count by delta below `range`:
  # entities inside the spliced region are gone, entities below shift.
  def shift_symbols(symbols, range, delta) do
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
  def shift_created(created, range, delta) do
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
  def splice_shift(:insert_before_entity, range, body_lines),
    do: {%{start_line: range.start_line, end_line: range.start_line - 1}, length(body_lines) + 1}

  def splice_shift(:insert_after_entity, range, body_lines),
    do: {%{start_line: range.end_line + 1, end_line: range.end_line}, length(body_lines) + 1}

  def splice_shift(op, range, body_lines) do
    span = range.end_line - range.start_line + 1
    count = length(body_lines)
    delta = if op == :replace_entity_block, do: count - span, else: -span
    {range, delta}
  end

  # A line-level diff of the whole file (Myers), for the batch's combined
  # view: removals and additions only, so the report stays readable.
  @max_diff_lines 2_000

  def combined_diff(original, final) do
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
