# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ast-forks/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Diff do
  @moduledoc """
  Structural diff of two semantic-manifest JSON documents, keyed on stable
  symbol ids.

  Symbol ids follow the grammar proposed in the *Spark/Ash Semantic Manifest,
  v0* RFC (§4.3): `ash:v0:<Module>#<dsl_path>/<name>` — e.g.
  `ash:v0:AshEnterprise.Accounts.Team#attributes/team_type`. Diffing by id
  turns "did my DSL change?" into set arithmetic: a symbol present only in
  the new document was **added**, only in the old one **removed**, and
  present in both but semantically different **changed**.

  What "semantically different" means follows the RFC's content definition
  (§4.4): a symbol's content is everything except `hashes`, `span`, and
  `property_spans`. Comparing that structurally — rather than trusting the
  document's hash values — means hand-authored fixtures with placeholder
  hashes diff correctly, and a moved declaration (span-only change) is
  correctly reported as *unchanged*, since moving code must not invalidate
  semantic caches.

  Works on hand-authored manifest documents today. The RFC's exporter
  (`mix ash.manifest.dump --semantic`, §3.6) is future work; once it lands,
  the same diff applies to real exported manifests unchanged.
  """

  # Per RFC §4.4, these carry no semantic content: spans are excluded so
  # moving a declaration does not count as a change, and hashes are excluded
  # because the structural comparison *produces* the content verdict.
  @non_content_keys ["hashes", "span", "property_spans"]

  @doc """
  Diffs the symbols of two semantic-manifest JSON documents.

  Returns a plain, JSON-encodable report:

    * `summary` — counts of `added`, `removed`, `changed`, `unchanged` symbols
    * `added` / `removed` — `%{id, kind, name}` references, sorted by id
    * `changed` — `%{id, kind, name, changed_fields}` entries, sorted by id,
      where `changed_fields` lists `%{field, old, new}` for every field that
      differs after ignoring `hashes`, `span`, and `property_spans`
      (a field missing on one side reports `nil` there)

  Raises `ArgumentError` when a file cannot be read, is not valid JSON, is
  not a semantic manifest (no `symbols` array), or contains a symbol without
  a string `id` (RFC §4.3) — or duplicate ids.

  ## Examples

      iex> report = AshAgentTools.diff_manifest("test/fixtures/manifest_v1.json", "test/fixtures/manifest_v2.json")
      iex> report.summary
      %{added: 1, removed: 1, changed: 1, unchanged: 2}

      iex> report = AshAgentTools.diff_manifest("test/fixtures/manifest_v1.json", "test/fixtures/manifest_v2.json")
      iex> Enum.map(report.added, & &1.id)
      ["ash:v0:Example.Post#actions/publish"]

      iex> report = AshAgentTools.diff_manifest("test/fixtures/manifest_v1.json", "test/fixtures/manifest_v2.json")
      iex> changed = hd(report.changed)
      iex> {changed.id, Enum.map(changed.changed_fields, & &1.field)}
      {"ash:v0:Example.Post#attributes/title", ["constraints"]}

  """
  @spec diff_manifest(String.t(), String.t()) :: map()
  def diff_manifest(old_path, new_path) do
    old_symbols = load_symbols!(old_path)
    new_symbols = load_symbols!(new_path)

    old_ids = MapSet.new(Map.keys(old_symbols))
    new_ids = MapSet.new(Map.keys(new_symbols))

    added_ids = new_ids |> MapSet.difference(old_ids) |> MapSet.to_list() |> Enum.sort()
    removed_ids = old_ids |> MapSet.difference(new_ids) |> MapSet.to_list() |> Enum.sort()
    common_ids = old_ids |> MapSet.intersection(new_ids) |> MapSet.to_list() |> Enum.sort()

    added = Enum.map(added_ids, &symbol_ref(Map.fetch!(new_symbols, &1)))
    removed = Enum.map(removed_ids, &symbol_ref(Map.fetch!(old_symbols, &1)))

    changed =
      for id <- common_ids,
          changes = content_changes(Map.fetch!(old_symbols, id), Map.fetch!(new_symbols, id)),
          changes != [] do
        new_symbols |> Map.fetch!(id) |> symbol_ref() |> Map.put(:changed_fields, changes)
      end

    %{
      old_file: old_path,
      new_file: new_path,
      summary: %{
        added: length(added),
        removed: length(removed),
        changed: length(changed),
        unchanged: length(common_ids) - length(changed)
      },
      added: added,
      removed: removed,
      changed: changed
    }
  end

  # -- document loading ---------------------------------------------------

  defp load_symbols!(path) do
    document = load_document!(path)
    symbols = Map.fetch!(document, "symbols")

    Enum.reduce(symbols, %{}, fn symbol, acc ->
      id = Map.fetch!(symbol, "id")

      if Map.has_key?(acc, id) do
        raise ArgumentError, "#{path}: duplicate symbol id #{inspect(id)}"
      end

      Map.put(acc, id, symbol)
    end)
  end

  defp load_document!(path) do
    case File.read(path) do
      {:ok, contents} ->
        decode_document!(path, contents)

      {:error, reason} ->
        raise ArgumentError,
              "cannot read semantic manifest #{inspect(path)}: #{:file.format_error(reason)}"
    end
  end

  defp decode_document!(path, contents) do
    case Jason.decode(contents) do
      {:ok, %{"symbols" => symbols}} when is_list(symbols) ->
        Enum.each(symbols, &ensure_symbol!(path, &1))
        %{"symbols" => symbols}

      {:ok, _} ->
        raise ArgumentError,
              "#{inspect(path)} is not a semantic manifest: no \"symbols\" array" <>
                " (see the RFC's manifest shape, §4.1)"

      {:error, reason} ->
        raise ArgumentError, "#{inspect(path)} is not valid JSON: #{Exception.message(reason)}"
    end
  end

  defp ensure_symbol!(_path, %{"id" => id}) when is_binary(id), do: :ok

  defp ensure_symbol!(path, other) do
    raise ArgumentError,
          "#{inspect(path)}: symbol without a string \"id\" (RFC §4.3 id grammar): #{inspect(other)}"
  end

  # -- content comparison ---------------------------------------------------

  defp symbol_ref(symbol) do
    %{id: symbol["id"], kind: symbol["kind"], name: symbol["name"]}
  end

  defp content_changes(old_symbol, new_symbol) do
    old_content = Map.drop(old_symbol, @non_content_keys)
    new_content = Map.drop(new_symbol, @non_content_keys)

    fields =
      (Map.keys(old_content) ++ Map.keys(new_content))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.flat_map(fields, fn field ->
      old_value = Map.get(old_content, field)
      new_value = Map.get(new_content, field)

      if old_value == new_value do
        []
      else
        [%{field: field, old: old_value, new: new_value}]
      end
    end)
  end
end
