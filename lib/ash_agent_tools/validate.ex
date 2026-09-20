# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Validate do
  @moduledoc """
  Input validation for Ash actions, without execution.

  `validate_input/3` answers "would the agent's params be accepted?" using
  exactly the casting machinery Ash itself uses (`Ash.Type.cast_input/3` —
  the same path `Ash.Resource.Info`-backed runtime casting takes), then
  additionally builds the changeset/query/action-input with `error?: false`
  to surface any errors Ash reports at build time. **The subject is never
  run** — no action executes, nothing reaches a data layer.
  """

  alias AshAgentTools.Describe
  alias AshAgentTools.Source
  alias AshAgentTools.Types

  @doc """
  Validates `params` against `action` of `resource`.

  The report is a plain, JSON-encodable map:

    * `valid?` — true when no errors were found
    * `errors` — entries with `path` (input key), `message`, and optionally
      the DSL source of the input it was checked against
    * `normalized_inputs` — the cast values (JSON-safe), for keys that cast
      successfully
    * `expected` — the action's input contract, mirrored from
      `AshAgentTools.describe_action/2`

  Always returns the report; check `valid?`.
  """
  @spec validate_input(module(), atom() | String.t(), map()) :: map()
  def validate_input(resource, action_name, params) do
    Describe.ensure_resource!(resource)

    action_name = to_action_name(action_name)
    action = Ash.Resource.Info.action(resource, action_name)

    action ||
      raise ArgumentError,
            "#{AshAgentTools.Registry.module_name(resource)} has no action named #{inspect(action_name)}"

    params = params || %{}
    contract = Describe.describe_action(resource, action_name).input

    {normalized, cast_errors} = cast_params(resource, action, params)
    missing_errors = missing_errors(contract, params)
    build_errors = build_errors(resource, action, params, normalized)

    errors = dedupe_errors(cast_errors, missing_errors, build_errors)

    %{
      resource: resource,
      action: action_name,
      action_type: action.type,
      valid?: errors == [],
      errors: errors,
      normalized_inputs: normalized,
      expected: contract
    }
  end

  # Cast-stage and missing-input errors are authoritative; build-stage errors
  # are only kept when they say something new. Ash's build-stage messages
  # restate earlier errors in wrapped form ("Invalid value provided for
  # price: is invalid...", "attribute title is required"), so a containment
  # check on the downcased message removes those duplicates.
  defp dedupe_errors(cast_errors, missing_errors, build_errors) do
    base = cast_errors ++ missing_errors

    base_messages = Enum.map(base, &String.downcase(&1.message))

    build_kept =
      Enum.reject(build_errors, fn error ->
        message = String.downcase(error.message)
        Enum.any?(base_messages, &String.contains?(message, &1))
      end)

    base ++ build_kept
  end

  # Cast each provided param with Ash.Type.cast_input/3 against its
  # argument or accepted-attribute definition. Pure: nothing is persisted.
  # Report paths and normalized-input keys are always strings so the report
  # round-trips through JSON exactly as the agent provided it.
  defp cast_params(resource, action, params) do
    Enum.reduce(params, {%{}, []}, fn {raw_key, value}, {normalized, errors} ->
      key = input_key(raw_key)
      path = key_path(key)

      case resolve_input(resource, action, key) do
        nil ->
          {normalized,
           [
             %{
               path: path,
               message: "unknown input #{inspect(path)} for action #{inspect(action.name)}",
               source: nil
             }
             | errors
           ]}

        target ->
          case Ash.Type.cast_input(target.type, value, target.constraints) do
            {:ok, cast} ->
              {Map.put(normalized, path, Types.to_json_safe(cast)), errors}

            {:error, message} ->
              {normalized,
               [
                 %{path: path, message: Types.error_message(message), source: target.source}
                 | errors
               ]}

            :error ->
              {normalized, [%{path: path, message: "is invalid", source: target.source} | errors]}
          end
      end
    end)
  end

  # Arguments take precedence over accepted attributes, mirroring how Ash
  # resolves inputs.
  defp resolve_input(resource, action, key) do
    argument = Enum.find(action.arguments, &(&1.name == key))

    target =
      argument ||
        resource
        |> accepted_attributes(action)
        |> Enum.find(&(&1.name == key))

    case target do
      nil ->
        nil

      target ->
        %{type: target.type, constraints: target.constraints, source: Source.from_entity(target)}
    end
  end

  defp accepted_attributes(resource, action) do
    case Map.get(action, :accept) do
      nil -> []
      accept -> Enum.filter(Ash.Resource.Info.attributes(resource), &(&1.name in accept))
    end
  end

  defp missing_errors(contract, params) do
    provided = MapSet.new(params, fn {raw_key, _} -> input_key(raw_key) end)

    for required <- contract.required, required not in provided do
      %{path: Atom.to_string(required), message: "is required", source: nil}
    end
  end

  # Build the subject the way an action run would — with `error?: false` so
  # failures accumulate instead of raising — and collect whatever errors Ash
  # reports at build time (e.g. argument casting and change setup). The
  # subject is discarded; nothing is executed.
  defp build_errors(resource, action, params, normalized) do
    subject = build_subject(resource, action, params, normalized)

    subject
    |> subject_errors()
    |> Enum.map(fn error ->
      %{
        path: Map.get(error, :path) |> build_error_path(),
        message: Types.error_message(error),
        source: nil
      }
    end)
  rescue
    error -> [%{path: nil, message: Types.error_message(error), source: nil}]
  end

  defp build_subject(resource, action, params, _normalized) do
    case action.type do
      :create ->
        Ash.Changeset.for_create(resource, action.name, params, error?: false)

      :update ->
        Ash.Changeset.for_update(empty_record(resource), action.name, params, error?: false)

      :destroy ->
        Ash.Changeset.for_destroy(empty_record(resource), action.name, params, error?: false)

      :read ->
        Ash.Query.for_read(resource, action.name, params, error?: false)

      # ActionInput.for_action/4 does not support error?: false; it already
      # accumulates errors on the input instead of raising.
      :action ->
        Ash.ActionInput.for_action(resource, action.name, params)
    end
  end

  # Update/destroy subjects need a record; an empty struct is enough because
  # the changeset is only built, never run.
  defp empty_record(resource), do: struct(resource, %{})

  defp subject_errors(subject) do
    # There is no public errors/1 accessor on the subjects; the field is part
    # of their documented shape (AshPhoenix reads it the same way).
    subject.errors
  end

  defp build_error_path(path) when is_list(path) do
    case Enum.map(path, &to_string/1) do
      [] -> nil
      path -> List.last(path)
    end
  end

  defp build_error_path(_), do: nil

  # Param keys arrive as JSON strings; DSL entity names are atoms that are
  # necessarily in the atom table (they were loaded with the resource), so
  # to_existing_atom is safe *whenever a match is possible*. A key with no
  # existing atom cannot match any input, so it is reported as unknown under
  # its original (string) key instead of adding an atom to the table.
  defp input_key(key) when is_atom(key), do: key

  defp input_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> {:unknown_key, key}
  end

  defp key_path({:unknown_key, key}), do: key
  defp key_path(key) when is_atom(key), do: Atom.to_string(key)

  defp to_action_name(name) when is_atom(name), do: name
  defp to_action_name(name) when is_binary(name), do: String.to_existing_atom(name)
end
