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
  alias AshAgentTools.Kaizen
  alias AshAgentTools.Registry
  alias AshAgentTools.Source
  alias AshAgentTools.Suggest
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

  Unknown-input errors carry a `did_you_mean` list: the closest names from
  the action's real input contract, so the agent can self-correct in one
  round-trip. Every unknown input is also reported to the kaizen loop
  (`AshAgentTools.Kaizen` — a `[:ash_agent, :tool_gap]` telemetry event with
  the unknown keys and their candidates) so recurring input-contract
  friction surfaces without anyone filing a bug by hand.
  """
  @spec validate_input(module(), atom() | String.t(), map()) :: map()
  def validate_input(resource, action_name, params) do
    started = System.monotonic_time(:millisecond)
    Describe.ensure_resource!(resource)

    action = Describe.resolve_action!(resource, action_name)
    action_name = action.name

    params = params || %{}
    contract = Describe.describe_action(resource, action_name).input
    valid_names = valid_input_names(resource, action)

    {normalized, cast_errors, unknowns} = cast_params(resource, action, params, valid_names)
    missing_errors = missing_errors(contract, params)
    build_errors = build_errors(resource, action, params, normalized)

    errors = dedupe_errors(cast_errors, missing_errors, build_errors)

    report = %{
      resource: resource,
      action: action_name,
      action_type: action.type,
      valid?: errors == [],
      errors: errors,
      normalized_inputs: normalized,
      expected: contract
    }

    emit_gap!(resource, action, report, unknowns, valid_names, started)
    report
  end

  # The kaizen event fires when the tool could not fully answer the
  # question — here: inputs the agent invented that the contract does not
  # have. Best-effort by construction (Kaizen.emit never raises).
  defp emit_gap!(_resource, _action, report, [], _valid_names, _started), do: report

  defp emit_gap!(resource, action, _report, unknowns, valid_names, started) do
    duration_ms = System.monotonic_time(:millisecond) - started

    Kaizen.emit(
      :validate,
      :unknown_input,
      "#{Registry.module_name(resource)}.#{action.name}",
      %{
        unknown: unknowns,
        candidates: Map.new(unknowns, &{&1, Suggest.closest(&1, valid_names)})
      },
      duration_ms: duration_ms
    )

    :ok
  end

  # Every name a valid input could take, as strings — the candidate set for
  # did_you_mean suggestions (arguments and accepted attributes, mirroring
  # how Ash resolves inputs).
  defp valid_input_names(resource, action) do
    argument_names = Enum.map(action.arguments, &Atom.to_string(&1.name))

    attribute_names =
      resource
      |> accepted_attributes(action)
      |> Enum.map(&Atom.to_string(&1.name))

    Enum.uniq(argument_names ++ attribute_names)
  end

  # Cast-stage and missing-input errors are authoritative; build-stage errors
  # are only kept when they say something new. Two duplicate shapes exist:
  #
  #   * Ash re-reports unknown inputs at build stage ("No such input `x` ...
  #     Perhaps you meant ...? ... Valid Inputs: ..."). The duplicate entry is
  #     noise, but its hint is valuable — it is carried in `ash_hint` (see
  #     build_errors/4), folded into our structured error (matched by input
  #     path), and the build-stage copy is dropped.
  #   * Other build-stage errors restate earlier errors in wrapped form
  #     ("Invalid value provided for price: is invalid...", "attribute title
  #     is required"), removed by a containment check on the message.
  defp dedupe_errors(cast_errors, missing_errors, build_errors) do
    base = merge_ash_suggestions(cast_errors ++ missing_errors, build_errors)

    base_messages = Enum.map(base, &String.downcase(&1.message))

    build_kept =
      Enum.reject(build_errors, fn error ->
        duplicate_of_base?(error, base_messages)
      end)

    base ++ build_kept
  end

  defp merge_ash_suggestions(base, build_errors) do
    Enum.reduce(build_errors, base, fn
      # not an Ash unknown-input duplicate: nothing to merge
      %{ash_hint: nil}, base ->
        base

      %{ash_input_key: key, ash_hint: hint}, base ->
        Enum.map(base, fn entry ->
          if entry.path == key do
            %{entry | message: entry.message <> "; Ash says: " <> hint}
          else
            entry
          end
        end)
    end)
  end

  defp duplicate_of_base?(%{ash_hint: hint}, _base_messages) when hint != nil, do: true

  defp duplicate_of_base?(error, base_messages) do
    message = String.downcase(error.message)
    Enum.any?(base_messages, &String.contains?(message, &1))
  end

  # Cast each provided param with Ash.Type.cast_input/3 against its
  # argument or accepted-attribute definition. Pure: nothing is persisted.
  # Report paths and normalized-input keys are always strings so the report
  # round-trips through JSON exactly as the agent provided it.
  #
  # Returns {normalized, errors, unknowns}: the unknowns list (the string
  # keys the contract does not have) feeds the kaizen event, and each
  # unknown-input entry carries its closest real names as `did_you_mean`.
  defp cast_params(resource, action, params, valid_names) do
    Enum.reduce(params, {%{}, [], []}, fn {raw_key, value}, {normalized, errors, unknowns} ->
      key = input_key(raw_key)
      path = key_path(key)

      case resolve_input(resource, action, key) do
        nil ->
          {normalized,
           [
             %{
               path: path,
               message: "unknown input #{inspect(path)} for action #{inspect(action.name)}",
               source: nil,
               did_you_mean: Suggest.closest(path, valid_names)
             }
             | errors
           ], [path | unknowns]}

        target ->
          case Ash.Type.cast_input(target.type, value, target.constraints) do
            {:ok, cast} ->
              {Map.put(normalized, path, Types.to_json_safe(cast)), errors, unknowns}

            {:error, message} ->
              {normalized,
               [
                 %{path: path, message: Types.error_message(message), source: target.source}
                 | errors
               ], unknowns}

            :error ->
              {normalized, [%{path: path, message: "is invalid", source: target.source} | errors],
               unknowns}
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
      %{path: Atom.to_string(required), message: "is required", source: nil, did_you_mean: nil}
    end
  end

  # Build the subject the way an action run would — with `error?: false` so
  # failures accumulate instead of raising — and collect whatever errors Ash
  # reports at build time (e.g. argument casting and change setup). The
  # subject is discarded; nothing is executed.
  #
  # Raw splode structs are flattened to plain entries here, so any struct
  # info dedupe needs must be captured up front: build-stage NoSuchInput
  # errors duplicate our unknown-input entry, and their hint is kept in
  # `ash_hint` for `dedupe_errors/3` to fold in.
  defp build_errors(resource, action, params, normalized) do
    subject = build_subject(resource, action, params, normalized)

    subject
    |> subject_errors()
    |> Enum.map(fn error ->
      %{
        path: Map.get(error, :path) |> build_error_path(),
        message: Types.error_message(error),
        source: nil,
        did_you_mean: nil,
        ash_hint: ash_hint(error),
        ash_input_key: ash_input_key(error)
      }
    end)
  rescue
    error ->
      [
        %{
          path: nil,
          message: Types.error_message(error),
          source: nil,
          did_you_mean: nil,
          ash_hint: nil,
          ash_input_key: nil
        }
      ]
  end

  # The NoSuchInput's own input name — not the splode `path`, which is empty
  # on create/update subjects — is what ties the build-stage duplicate to
  # our unknown-input entry.
  defp ash_input_key(%Ash.Error.Invalid.NoSuchInput{input: input}), do: to_string(input)
  defp ash_input_key(_), do: nil

  # For an Ash "No such input ..." error, the hint is the message minus its
  # leading "No such input ..." line (which duplicates ours), with lines
  # joined for compactness.
  defp ash_hint(%Ash.Error.Invalid.NoSuchInput{} = error) do
    hint =
      error
      |> Exception.message()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> case do
        [_duplicate_first_line | rest] -> Enum.join(rest, " | ")
        [] -> ""
      end

    if hint == "", do: nil, else: hint
  end

  defp ash_hint(_), do: nil

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
end
