# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Types do
  @moduledoc """
  Rendering helpers that turn Ash type/value terms into stable,
  JSON-encodable descriptions.

  Agents consume plain data. Ash types are atoms (`:string`),
  two-tuples (`{:array, :string}`), or modules (`Ash.Type.CiString`);
  cast results can be `Decimal`, `Date`, `DateTime`, and friends. This module
  gives every one of those a deterministic representation.
  """

  @short_names Ash.Type.short_names()

  @doc """
  Normalizes an Ash type into a readable string.

  Built-in types report their short name; extensions keep their module name.

  ## Examples

      iex> AshAgentTools.Types.normalize(:string)
      "string"

      iex> AshAgentTools.Types.normalize({:array, :integer})
      "array<integer>"

      iex> AshAgentTools.Types.normalize(Ash.Type.CiString)
      "ci_string"

  """
  @spec normalize(term()) :: String.t()
  def normalize({:array, inner}), do: "array<" <> normalize(inner) <> ">"

  def normalize({:or, subtypes}) when is_list(subtypes) do
    Enum.map_join(subtypes, " | ", &normalize/1)
  end

  def normalize(type) when is_atom(type) do
    if String.starts_with?(Atom.to_string(type), "Elixir.") do
      case Enum.find(@short_names, fn {_name, module} -> module == type end) do
        {name, _module} -> Atom.to_string(name)
        nil -> module_name(type)
      end
    else
      # plain atoms (:string, :integer, ...) are already the short form
      Atom.to_string(type)
    end
  end

  def normalize(other), do: inspect(other)

  @doc """
  Converts a term into something `Jason.encode!/1` accepts, deterministically:

    * atoms become strings
    * `Decimal` becomes its string form (precision-preserving)
    * dates and times become their ISO 8601 form
    * lists and maps recurse; any other struct or term falls back to `inspect/1`
  """
  @spec to_json_safe(term()) :: term()
  def to_json_safe(nil), do: nil
  def to_json_safe(value) when is_binary(value), do: value
  def to_json_safe(value) when is_number(value), do: value
  def to_json_safe(value) when is_boolean(value), do: value
  def to_json_safe(value) when is_atom(value), do: Atom.to_string(value)
  def to_json_safe(%Decimal{} = value), do: Decimal.to_string(value)

  def to_json_safe(%Date{} = value), do: Date.to_iso8601(value)
  def to_json_safe(%Time{} = value), do: Time.to_iso8601(value)
  def to_json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def to_json_safe(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  def to_json_safe(value) when is_list(value), do: Enum.map(value, &to_json_safe/1)

  def to_json_safe(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, value} -> {to_json_safe(key), to_json_safe(value)} end)
  end

  # Structs outside the primitives above (Money, Ash.CiString, ...) are
  # reduced to their inspect form rather than leaking internal fields.
  def to_json_safe(value), do: inspect(value)

  @doc """
  Normalizes an error term (message string, splode exception, ...) into a
  plain message string, for uniform report entries.
  """
  @spec error_message(term()) :: String.t()
  def error_message(message) when is_binary(message), do: message
  def error_message(error) when is_exception(error), do: Exception.message(error)
  def error_message(%{message: message}) when is_binary(message), do: message
  def error_message(other), do: inspect(other)

  defp module_name(type) do
    type |> Module.split() |> Enum.join(".")
  end
end
