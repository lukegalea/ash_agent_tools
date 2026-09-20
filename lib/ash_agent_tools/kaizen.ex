# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Kaizen do
  @moduledoc """
  The reactive kaizen loop: when a tool *fails to answer*, that gap is a
  telemetry event — not a hand-filed log entry.

  Diagnostics are written on every analysis pass, never by hand: each time
  `validate_input/3` meets an unknown input, `semantic_search/2` finds
  nothing, or `context/3` lands on no Ash module, the tool emits

      :telemetry.execute([:ash_agent, :tool_gap], %{count: 1, duration_ms: ...},
        %{tool: :search, gap_kind: :search_miss, question: "...",
          detail: %{term: "...", did_you_mean: [...]}})

  so a host can attach any `:telemetry` handler to `[:ash_agent, :tool_gap]`
  and aggregate on its own terms.

  `attach/0` is the built-in dev sink: a `:telemetry` handler that folds
  every event into a public ETS table (counts, first/last seen, last
  question, capped per-gap samples) and logs each one structurally. Attach
  it once in dev — from `iex`, a `.iex.exs`, or your dev application start —
  and `digest/0` (or `mix ash_agent.gaps`) turns the aggregate into the
  "propose an alias / a doc fix / a new default" list. Gaps whose
  `did_you_mean` candidates recur across sessions are exactly the
  alias-and-docs work this loop exists to surface.

  The sink is best-effort by design: emitting never raises, the handler
  never raises, and a missing table just means "no gaps recorded yet".
  """

  require Logger

  @event_name [:ash_agent, :tool_gap]
  @handler_id "ash_agent_tools.kaizen"
  @table :ash_agent_kaizen
  @max_samples 10

  @type tool :: atom()
  @type gap_kind :: :unknown_input | :search_miss | :context_miss | atom()

  @doc """
  The telemetry event name the tools emit (and hosts can attach to): the
  list `[:ash_agent, :tool_gap]`.
  """
  @spec event_name() :: [atom()]
  def event_name, do: @event_name

  @doc """
  Attaches the built-in dev sink (idempotent): the `[:ash_agent, :tool_gap]`
  handler plus the public `:ash_agent_kaizen` ETS aggregate. Returns `:ok`.

  Typically called once from a long-lived dev session (`iex`, `.iex.exs`)
  or the dev application start.
  """
  @spec attach() :: :ok
  def attach do
    ensure_table!()
    ensure_handler!()
    :ok
  end

  @doc """
  Detaches the built-in handler. The ETS aggregate is kept, so a re-attach
  resumes accumulating on top of it. Returns `:ok` even when not attached.
  """
  @spec detach() :: :ok
  def detach do
    case :telemetry.detach(@handler_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  @doc """
  Emits one tool-gap event. Called by the tools themselves; host code may
  emit its own gap kinds the same way. Never raises — a tool must deliver
  its answer even when a handler is broken.

  `opts` accepts `:duration_ms` (the tool's measured answering time), folded
  into the measurements.
  """
  @spec emit(tool(), gap_kind(), String.t(), map(), keyword()) :: :ok
  def emit(tool, gap_kind, question, detail, opts \\ [])

  def emit(tool, gap_kind, question, detail, opts)
      when is_atom(tool) and is_atom(gap_kind) and is_binary(question) and is_map(detail) and
             is_list(opts) do
    measurements =
      case Keyword.get(opts, :duration_ms) do
        duration when is_number(duration) -> %{count: 1, duration_ms: duration}
        _ -> %{count: 1}
      end

    try do
      :telemetry.execute(@event_name, measurements, %{
        tool: tool,
        gap_kind: gap_kind,
        question: question,
        detail: detail
      })
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  def emit(_tool, _gap_kind, _question, _detail, _opts), do: :ok

  @doc false
  # The :telemetry handler. Runs in the emitting (tool) process; every ETS
  # touch is guarded so a wiped or absent table degrades to a no-op instead
  # of breaking the tool mid-answer.
  def handle_event(@event_name, _measurements, metadata, _config) do
    gap_key = {metadata.tool, metadata.gap_kind}
    now = System.system_time(:millisecond)

    :ets.update_counter(@table, {:count, gap_key}, {2, 1}, {{:count, gap_key}, 0})

    case :ets.lookup(@table, {:seen, gap_key}) do
      [{_key, {first, _last}}] -> :ets.insert(@table, {{:seen, gap_key}, {first, now}})
      [] -> :ets.insert(@table, {{:seen, gap_key}, {now, now}})
    end

    :ets.insert(@table, {{:last, gap_key}, {now, metadata.question}})

    # A ring of the last @max_samples raw events per gap: the digest reads
    # aggregates, but the concrete question/detail pairs are what propose
    # the alias or doc fix. The ring index rides along in the row so the
    # digest can replay events in emission order even within one timestamp.
    index_key = {:sample_index, gap_key}
    index = :ets.update_counter(@table, index_key, {2, 1}, {index_key, 0})
    sample_key = {:sample, gap_key, rem(index, @max_samples)}
    :ets.insert(@table, {sample_key, {now, index, metadata.question, metadata.detail}})

    Logger.debug(fn ->
      "ash_agent tool gap: #{inspect(metadata.tool)}/#{inspect(metadata.gap_kind)}" <>
        " — #{metadata.question}"
    end)

    :ok
  rescue
    error ->
      Logger.debug("ash_agent kaizen sink skipped an event: #{Exception.message(error)}")
      :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @doc """
  Reads the ETS aggregate as a plain, JSON-encodable map: one entry per
  `(tool, gap_kind)` pair with its count, first/last seen, last question,
  and the capped raw samples. A fresh VM (or a wiped table) digests to
  `gaps: []`.
  """
  @spec digest() :: map()
  def digest do
    gaps =
      if table_present?() do
        @table
        |> :ets.tab2list()
        |> Enum.group_by(fn {key, _value} -> gap_key(key) end)
        |> Map.delete(nil)
        |> Enum.map(&gap_entry/1)
        |> Enum.sort_by(&{&1.tool, &1.gap_kind})
      else
        []
      end

    %{
      event: Enum.join(@event_name, "."),
      attached?: attached?(),
      table_present?: table_present?(),
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      total: Enum.sum(Enum.map(gaps, & &1.count)),
      gaps: gaps
    }
  end

  @doc """
  Wipes the ETS aggregate (the handler, if attached, stays attached). Handy
  in tests and to start a fresh kaizen window. Returns `:ok`.
  """
  @spec reset() :: :ok
  def reset do
    if table_present?() do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  @doc """
  Whether the built-in handler is currently attached.
  """
  @spec attached?() :: boolean()
  def attached? do
    @event_name
    |> :telemetry.list_handlers()
    |> Enum.any?(&(&1.id == @handler_id))
  end

  # -- plumbing -------------------------------------------------------------

  # The table outlives the attaching process: an owner process is spawned
  # first and creates the table itself, so the aggregate survives the iex
  # expression (or startup call) that attached it. Concurrent attaches race
  # only on table creation, and the loser finds the table already there.
  defp ensure_table! do
    unless table_present?() do
      spawn(fn ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

        receive do
          :stop -> :ok
        end
      end)

      wait_for_table(50)
    end

    :ok
  end

  defp wait_for_table(tries) do
    cond do
      table_present?() ->
        :ok

      tries <= 0 ->
        raise "could not create the #{inspect(@table)} table"

      true ->
        Process.sleep(10)
        wait_for_table(tries - 1)
    end
  end

  defp ensure_handler! do
    :telemetry.attach(@handler_id, @event_name, &__MODULE__.handle_event/4, nil)
    :ok
  end

  defp table_present? do
    :ets.whereis(@table) != :undefined
  end

  # Every row kind of a gap ({:count, gk}, {:seen, gk}, {:last, gk},
  # {:sample_index, gk}, {:sample, gk, i}) groups under the same gap key.
  defp gap_key({_kind, gap_key}), do: gap_key
  defp gap_key({_kind, gap_key, _index}), do: gap_key
  defp gap_key(_row_key), do: nil

  defp gap_entry({gap_key, rows}) do
    {_, count} = List.keyfind(rows, {:count, gap_key}, 0)

    {first_seen, last_seen} =
      case List.keyfind(rows, {:seen, gap_key}, 0) do
        {_, seen} -> seen
        nil -> {nil, nil}
      end

    {last_at, last_question} =
      case List.keyfind(rows, {:last, gap_key}, 0) do
        {_, last} -> last
        nil -> {nil, nil}
      end

    samples =
      for {{:sample, ^gap_key, _index}, {at, seq, question, detail}} <- rows do
        %{at: iso8601(at), seq: seq, question: question, detail: detail}
      end
      |> Enum.sort_by(& &1.seq)

    %{
      tool: to_string(elem(gap_key, 0)),
      gap_kind: to_string(elem(gap_key, 1)),
      count: count,
      first_seen_at: iso8601_maybe(first_seen),
      last_seen_at: iso8601_maybe(last_seen),
      last_question: last_question,
      last_question_at: iso8601_maybe(last_at),
      samples: samples
    }
  end

  defp iso8601_maybe(nil), do: nil
  defp iso8601_maybe(ms) when is_integer(ms), do: iso8601(ms)

  defp iso8601(ms) do
    ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  end
end
