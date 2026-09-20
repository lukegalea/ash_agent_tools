# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Source do
  @moduledoc """
  Source-location extraction for Ash DSL entities.

  Spark stores the source annotation of each DSL entity on the built struct
  under `__spark_metadata__` (`%Spark.Dsl.Entity.Meta{anno: anno}`). This
  module converts those annotations into plain `%{file, line, column}` maps —
  the same underlying anno format `Clarity.SourceLocation` consumes — so
  agents can jump to the exact DSL block they are describing. All extraction
  is defensive: annotations are optional and their shape varies across
  Elixir/OTP versions, so any failure yields `nil` fields rather than raising.
  """

  @type location :: %{
          optional(:file) => String.t(),
          optional(:line) => pos_integer(),
          optional(:column) => pos_integer()
        }

  @doc """
  Best-effort source location of a DSL entity (attribute, action,
  relationship, ...), extracted from its Spark annotation.
  """
  @spec from_entity(struct() | map()) :: location() | nil
  def from_entity(entity)

  def from_entity(%{__spark_metadata__: %{anno: anno}}) when anno != nil do
    from_anno(anno)
  end

  def from_entity(_), do: nil

  @doc """
  Best-effort source location of a module itself (its compile-time source
  file, line 1).
  """
  @spec from_module(module()) :: location() | nil
  def from_module(module) when is_atom(module) do
    case module.__info__(:compile)[:source] do
      source when is_list(source) -> %{file: List.to_string(source), line: 1}
      source when is_binary(source) -> %{file: source, line: 1}
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Converts an `:erl_anno` annotation (integer, `{line, column}` tuple, or
  location map — the shapes Elixir and OTP produce across versions) into a
  plain location map.
  """
  @spec from_anno(term()) :: location() | nil
  def from_anno(anno) do
    anno
    |> anno_fields()
    |> case do
      fields when fields == %{} -> nil
      fields -> fields
    end
  end

  defp anno_fields(anno) do
    %{}
    |> put_file(:erl_anno.file(anno))
    |> put_line(:erl_anno.line(anno))
    |> put_column(:erl_anno.column(anno))
  rescue
    _ -> fallback_fields(anno)
  end

  # Newer Elixir versions hand out `%{location: ...}` maps that :erl_anno
  # does not accept directly; normalize those ourselves.
  defp fallback_fields(%{location: {line, column}}) when is_integer(line) do
    %{line: line, column: column}
  end

  defp fallback_fields(%{line: line}) when is_integer(line), do: %{line: line}
  defp fallback_fields(line) when is_integer(line), do: %{line: line}
  defp fallback_fields(_), do: %{}

  defp put_file(fields, :undefined), do: fields
  defp put_file(fields, file) when is_list(file), do: Map.put(fields, :file, List.to_string(file))
  defp put_file(fields, file) when is_binary(file), do: Map.put(fields, :file, file)
  defp put_file(fields, _), do: fields

  defp put_line(fields, line) when is_integer(line), do: Map.put(fields, :line, line)
  defp put_line(fields, _), do: fields

  defp put_column(fields, :undefined), do: fields
  defp put_column(fields, column) when is_integer(column), do: Map.put(fields, :column, column)
  defp put_column(fields, _), do: fields
end
