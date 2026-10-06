# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Edit.Writer do
  @moduledoc false
  import AshAgentTools.Edit.Support

  alias AshAgentTools.Registry
  alias AshAgentTools.Types

  def finish_write(%{expected_digest: expected_digest, current_digest: current_digest} = plan) do
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

  def atomic_write(file, content) do
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
  def gate_and_finish(plan) do
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

  def post_edit_gate(modules, file) do
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

  def diagnostic(diag) do
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
  def validate_canary(modules) do
    Enum.reduce_while(modules, :ok, fn module, :ok ->
      case canary_module(module) do
        :ok -> {:cont, :ok}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  def canary_module(module) do
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
  def format_pass(file, original, new_content) do
    if format_clean?(file, original) do
      {try_format(file, new_content), true}
    else
      {new_content, false}
    end
  end

  def format_clean?(file, content) do
    try_format(file, content) == content
  end

  def try_format(file, content) do
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
  def formatter_opts(file) do
    [locals_without_parens: locals_without_parens(file)]
  rescue
    _ -> []
  end

  @max_formatter_walk 12

  def locals_without_parens(file) do
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
  def project_formatter_file(dir, tries)

  def project_formatter_file(_dir, 0), do: nil

  def project_formatter_file(dir, tries) do
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

  def dep_locals_without_parens(formatter_file, dep) do
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

  def format_note(diff, formatted?) do
    if formatted? and is_binary(diff),
      do: diff <> "\n(whole-file mix format applied)",
      else: diff
  end

  # formatted?: false means the file was not format-clean before the edit, so
  # the rest of the file was left untouched — tell the agent how to finish.
  def maybe_format_hint(report, formatted?) do
    if formatted? == false,
      do: Map.put(report, :format_hint, "run mix format"),
      else: report
  end

  # ── creation ────────────────────────────────────────────────────────────────
end
