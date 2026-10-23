# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

# Compiled conditionally (Ecto's optional-Jason pattern): this reads facts
# through the optional `ash_judgments` dependency.
if Code.ensure_loaded?(AshJudgments.Query) do
  defmodule AshAgentTools.CodeSubjects.Standing do
    @moduledoc """
    The standing re-scan over a checkout: which code subjects need a
    (re)assessment for one question, and what each unit's facts say now.

    Code is not a table, so its current projection digest is not kept by
    the subject's own transaction (RFC S1-24 §7.4 normative 2). It is
    recomputed from the checkout instead: scan, digest each subject under
    the question's projection, and read the facts table against those
    digests. A unit edited since its fact was admitted reads `:stale`; a
    new unit reads `:no_fact`. Both come back from `assess/4` as work for
    the judge, and nothing here calls a model.

    Run it on `main` after each merge (a CI job, an AshOban cron in the
    host) and feed `assess/4`'s result to the question's judge action. A
    new violation then surfaces as a fact entering `in`, which a standing
    query on the facts table turns into an alert.

    Units too large for the decision model are judged as chunks
    (`AshAgentTools.CodeSubjects.chunk/3`); `statuses/4` rolls each unit's
    chunk statuses back up with `AshAgentTools.CodeSubjects.roll_up/2`.

    A unit whose declared context alone exceeds the token budget cannot be
    chunked (`AshAgentTools.CodeSubjects.fit/3`). It does not stop the scan:
    `assess/4` returns it whole with the reason `:context_too_large`, and
    `statuses/4` reads it `{:unknown, [:context_too_large]}`. Such a unit is
    not judgeable at that budget, so the caller reports it rather than
    sending it to the judge.
    """

    alias AshAgentTools.CodeSubjects

    @doc """
    The subjects under `root` to judge next for `predicate`: those whose
    facts are missing, stale, expired or below the grade floor, as
    `[{subject, reason}]` (chunks where a unit was chunked).

    Units whose declared context alone exceeds the budget follow, each
    whole, as `{unit, :context_too_large}`. They are not judgeable at this
    budget and are never sent to the facts query; `:limit` does not count
    them.

    Options:

      * `:projection` — the question's projection (module or context list,
        default `[]`); also the context captured at scan
      * `:type` — the subject type the facts store (see
        `AshAgentTools.CodeSubjects.subject_term/2`)
      * `:kinds`, `:paths`, `:repository` — passed to
        `AshAgentTools.CodeSubjects.scan/2`
      * `:max_tokens`, `:reserve_tokens` — passed to
        `AshAgentTools.CodeSubjects.chunk/3`
      * `:limit`, `:scope`, `:min_grade`, `:priority` — passed to
        `AshJudgments.Query.assess/4`
    """
    @spec assess(Path.t(), module(), String.t(), keyword()) :: [{map(), atom()}]
    def assess(root, facts_resource, predicate, opts \\ []) do
      {_units, judged, oversized, current, by_term} = prepare(root, opts)

      pending =
        facts_resource
        |> AshJudgments.Query.assess(
          Enum.map(judged, &CodeSubjects.subject_term(&1, term_opts(opts))),
          predicate,
          Keyword.merge(query_opts(opts), current_digests: current, resource: facts_resource)
        )
        |> Enum.map(fn {term, reason} -> {Map.fetch!(by_term, term), reason} end)

      pending ++ Enum.map(oversized, &{&1, :context_too_large})
    end

    @doc """
    Every unit's current status for `predicate`, rolled up over its chunks:
    `[{unit, :in | :out | {:unknown, reasons}}]`. A unit whose context
    cannot fit the budget reads `{:unknown, [:context_too_large]}`.

    Takes the options of `assess/4` plus `:mode` (`:any`, the default, or
    `:all`; see `AshAgentTools.CodeSubjects.roll_up/2`).
    """
    @spec statuses(Path.t(), module(), String.t(), keyword()) :: [{map(), term()}]
    def statuses(root, facts_resource, predicate, opts \\ []) do
      {units, judged, oversized, current, _by_term} = prepare(root, opts)
      mode = Keyword.get(opts, :mode, :any)
      query_opts = Keyword.put(query_opts(opts), :current_digests, current)

      judged
      |> Enum.group_by(&parent_id/1)
      |> Enum.map(fn {_unit_id, [first | _] = pieces} ->
        status =
          pieces
          |> Enum.map(fn piece ->
            AshJudgments.Query.status(
              facts_resource,
              CodeSubjects.subject_term(piece, term_opts(opts)),
              predicate,
              query_opts
            )
          end)
          |> CodeSubjects.roll_up(mode)

        {Map.fetch!(units, parent_id(first)), status}
      end)
      |> Enum.concat(Enum.map(oversized, &{&1, {:unknown, [:context_too_large]}}))
      |> Enum.sort_by(fn {unit, _} -> unit.id end)
    end

    defp prepare(root, opts) do
      projection = Keyword.get(opts, :projection, [])

      scan_opts =
        opts
        |> Keyword.take([:kinds, :paths, :repository])
        |> Keyword.put(:context, projection)

      chunk_opts = Keyword.take(opts, [:max_tokens, :reserve_tokens, :token_count])

      units = root |> CodeSubjects.scan(scan_opts) |> Map.fetch!(:subjects)

      {judged, oversized} =
        Enum.reduce(units, {[], []}, fn unit, {judged, oversized} ->
          case CodeSubjects.fit(unit, projection, chunk_opts) do
            {:ok, chunks} -> {Enum.reverse(chunks, judged), oversized}
            {:error, {:context_too_large, _budget}} -> {judged, [unit | oversized]}
          end
        end)

      judged = Enum.reverse(judged)
      oversized = Enum.reverse(oversized)

      current = CodeSubjects.current_digests(judged, projection, term_opts(opts))
      by_term = Map.new(judged, &{CodeSubjects.subject_term(&1, term_opts(opts)), &1})
      {Map.new(units, &{&1.id, &1}), judged, oversized, current, by_term}
    end

    defp term_opts(opts), do: Keyword.take(opts, [:type])

    defp query_opts(opts), do: Keyword.take(opts, [:limit, :scope, :min_grade, :priority])

    defp parent_id(%{chunk: %{parent_id: parent}}), do: parent
    defp parent_id(subject), do: subject.id
  end
end
