# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Trace do
  @moduledoc """
  Budget-bounded reduction of an OpenTelemetry span list for agents.

  A trace export gives an agent hundreds of spans; what it needs to know is
  *did it fail, where, which queries ran, was there an N+1, what policies
  were applied?* — in a few thousand characters, not a raw dump. `explain/2`
  is that reduction: a **pure** function over an already-captured span list,
  with no ETS, OpenTelemetry, or backend dependency. Bring it spans from any
  source (an in-BEAM ring buffer, an OTLP export, a fixture) and it returns
  a plain, JSON-encodable report.

  The span input is forgiving: plain maps with either atom or string keys,
  each carrying `name`, `kind`, `status`, `attributes`, `start`/`end` times
  (any unit — durations are reported in the input's own units), and
  `trace_id`/`span_id`/`parent_id`. Status accepts `:ok`/`:error`/`:unset`
  (atoms, strings, or the OTel integer codes `0`/`1`/`2`), or a map with a
  `code` and optional `message`.

  What the report contains:

    * `root` — the span with no in-set parent (earliest start wins), with
      its attributes; slimmed if the fixed part alone busts the budget
    * `errors` — spans whose status is `:error`, **innermost first** (deepest
      in the parent chain first, then latest start)
    * `policy` — policy spans (names containing "policy") with any recorded
      decision
    * `queries` — database/client spans, with **N+1 detection**: identical
      sources (same `db.statement`) under one parent collapse into a single
      entry with `n_plus_one?: true` and a repeat `count`
    * `notifications` — notification spans, grouped by name with counts
    * `async` — producer/consumer spans (the async half of the trace)
    * `symbols` — distinct `ash.symbol_id` attribute values and the spans
      carrying them (the symbol↔trace join key)
    * `summary` — trace id, span count, root duration
    * `truncated?` — true when the `:budget` (default ~8000 characters of
      encoded JSON) forced whole entries to be dropped; entries leave from
      the tail of the lowest-priority sections first, and strings are capped
      up front, never silently shortened mid-entry
    * `backend_url` — the `:backend_url` opt echoed back (a SigNoz/Tempo
      deep-link when the host configures one), `nil` otherwise

  ## Examples

      iex> spans = [
      ...>   %{name: "ash.read", status: :ok, attributes: %{}, start: 0, end: 90,
      ...>      trace_id: "t1", span_id: "s1", parent_id: nil},
      ...>   %{name: "query", status: :ok, attributes: %{"db.statement" => "select posts"},
      ...>      start: 10, end: 30, trace_id: "t1", span_id: "s2", parent_id: "s1"}
      ...> ]
      iex> report = AshAgentTools.Trace.explain(spans)
      iex> report.root.name
      "ash.read"
      iex> {report.truncated?, report.summary.span_count}
      {false, 2}

  """

  alias AshAgentTools.Types

  @default_budget 8000

  # Budget enforcement order: sections whose entries multiply under a flood
  # (many queries, many async branches) lose items first; errors survive
  # longest, because they are what the agent came for.
  @drop_priority [:queries, :async, :notifications, :symbols, :policy, :errors]

  @string_cap 256
  @spans_per_symbol 10

  # OTel span kinds, in their wire-code order (0..4).
  @known_kinds [:internal, :server, :client, :producer, :consumer]

  @type span_input :: map()

  @doc """
  Reduces a span list into a budget-bounded report.

  `spans` is a list of span maps (see the module doc for the accepted
  shapes). Options:

    * `:budget` — maximum size, in characters, of the JSON-encoded report
      (positive integer, default `#{@default_budget}`). Whole entries are
      dropped — lowest-priority sections first, tail entries first — until
      the report fits; `truncated?` reports that honestly.
    * `:backend_url` — deep-link to the trace backend (SigNoz/Tempo) to echo
      into the report, for the agent to hand back to a human.

  Raises `ArgumentError` for a non-list of spans, a non-map span, or an
  invalid option. An empty list is a valid (fully empty) report.

  ## Examples

  An error trace — errors innermost first, deepest in the parent chain
  first, with the status message surfaced:

      iex> spans = [
      ...>   %{name: "http.request", kind: :server, status: :error, attributes: %{},
      ...>      start: 0, end: 100, trace_id: "t1", span_id: "s1", parent_id: nil},
      ...>   %{name: "ash.create", status: %{code: :error, message: "title is required"},
      ...>      attributes: %{}, start: 10, end: 50, trace_id: "t1", span_id: "s2", parent_id: "s1"}
      ...> ]
      iex> report = AshAgentTools.Trace.explain(spans)
      iex> Enum.map(report.errors, & &1.name)
      ["ash.create", "http.request"]
      iex> hd(report.errors).message
      "title is required"

  The N+1 pattern — identical sources under one parent collapse into one
  entry, flagged and counted:

      iex> parent = %{name: "ash.read", status: :ok, attributes: %{}, start: 0, end: 90,
      ...>            trace_id: "t", span_id: "p", parent_id: nil}
      iex> queries = for i <- 1..3 do
      ...>   %{name: "query", kind: :client, status: :ok,
      ...>      attributes: %{"db.statement" => "select comments"},
      ...>      start: i, end: i + 9, trace_id: "t", span_id: "q\#{i}", parent_id: "p"}
      ...> end
      iex> [entry] = AshAgentTools.Trace.explain([parent | queries]).queries
      iex> {entry.source, entry.count, entry.n_plus_one?}
      {"select comments", 3, true}

  Budget truncation — the report is capped honestly, `truncated?` says so:

      iex> spans = for i <- 1..50 do
      ...>   %{name: "query", kind: :client, status: :ok,
      ...>      attributes: %{"db.statement" => "SELECT \#{i}"},
      ...>      start: i, end: i + 1, trace_id: "t", span_id: "s\#{i}", parent_id: nil}
      ...> end
      iex> report = AshAgentTools.Trace.explain(spans, budget: 600)
      iex> {report.truncated?, length(report.queries) < 50}
      {true, true}

  """
  @spec explain([span_input()], keyword()) :: map()
  def explain(spans, opts \\ [])

  def explain(spans, opts) when is_list(spans) and is_list(opts) do
    budget = budget!(opts)
    backend_url = backend_url!(opts)

    normalized = Enum.map(spans, &normalize_span/1)
    by_id = index_by_id(normalized)
    depths = depth_map(normalized, by_id)

    root = find_root(normalized, by_id)
    duration = raw_duration(root)

    reduction = %{
      root: project_root(root),
      errors: error_entries(normalized, depths),
      policy: policy_entries(normalized),
      queries: query_entries(normalized),
      notifications: notification_entries(normalized),
      async: async_entries(normalized),
      symbols: symbol_entries(normalized),
      summary: %{
        trace_id: trace_id(normalized, root),
        span_count: length(normalized),
        duration: duration
      },
      truncated?: false,
      backend_url: backend_url
    }

    enforce_budget(reduction, budget)
  end

  def explain(spans, _opts) do
    raise ArgumentError, "spans must be a list of span maps, got: #{inspect(spans)}"
  end

  # -- span normalization ----------------------------------------------------

  defp normalize_span(span) when is_map(span) do
    %{
      name: name(span),
      kind: kind(span),
      status: status(span),
      attributes: attributes(span),
      start: fetch(span, [:start, :start_time]),
      end: fetch(span, [:end, :end_time]),
      trace_id: fetch(span, [:trace_id]),
      span_id: fetch(span, [:span_id]),
      parent_id: fetch(span, [:parent_id])
    }
  end

  defp normalize_span(span) do
    raise ArgumentError, "each span must be a map, got: #{inspect(span)}"
  end

  defp name(span) do
    case fetch(span, [:name]) do
      nil -> "unknown"
      name -> to_string(name)
    end
  end

  defp kind(span) do
    case fetch(span, [:kind]) do
      nil -> :internal
      value when is_integer(value) and value in 0..4 -> Enum.at(@known_kinds, value)
      value when is_atom(value) -> kind_atom(Atom.to_string(value))
      value when is_binary(value) -> kind_atom(value)
      _ -> :internal
    end
  end

  defp kind_atom(value) do
    normalized = value |> String.downcase() |> String.trim_leading("span_kind_")

    if normalized in Enum.map(@known_kinds, &Atom.to_string/1) do
      String.to_existing_atom(normalized)
    else
      :internal
    end
  end

  # Status accepts atoms, strings, the OTel integer codes (0 unset, 1 ok,
  # 2 error), or a map carrying a code and an optional message.
  defp status(span) do
    case fetch(span, [:status]) do
      nil ->
        %{code: :unset, message: nil}

      status when is_map(status) ->
        code = Map.get(status, :code) || Map.get(status, "code")

        message =
          Map.get(status, :message) || Map.get(status, "message") ||
            Map.get(status, :description) || Map.get(status, "description")

        status_code(code, message)

      other ->
        status_code(other, nil)
    end
  end

  defp status_code(code, message) when code in [:ok, :error, :unset],
    do: %{code: code, message: message_text(message)}

  defp status_code(code, message) when is_integer(code) and code in 0..2,
    do: status_code(Enum.at([:unset, :ok, :error], code), message)

  defp status_code(code, message) when is_binary(code) do
    atom =
      case String.downcase(code) do
        "error" -> :error
        "ok" -> :ok
        _ -> :unset
      end

    status_code(atom, message)
  end

  defp status_code(_code, message), do: %{code: :unset, message: message_text(message)}

  defp message_text(nil), do: nil
  defp message_text(message), do: cap_string(to_string(message))

  defp attributes(span) do
    case fetch(span, [:attributes]) do
      attributes when is_map(attributes) ->
        Map.new(attributes, fn {key, value} -> {to_string(key), value} end)

      _ ->
        %{}
    end
  end

  # Looks a key up in both spellings (atoms and strings), so JSON-decoded
  # span maps work exactly like hand-written atom-keyed ones.
  defp fetch(span, keys) do
    Enum.find_value(keys, fn key ->
      Map.get(span, key) || Map.get(span, Atom.to_string(key))
    end)
  end

  # -- root and depth ----------------------------------------------------------

  # The trace root: a span with no parent, or a parent outside the exported
  # set (partial export). Earliest start wins; missing starts sort last.
  defp find_root(spans, by_id) do
    roots =
      Enum.filter(spans, fn span ->
        is_nil(span.parent_id) or not Map.has_key?(by_id, span.parent_id)
      end)

    case roots do
      [] -> nil
      roots -> Enum.min_by(roots, &{is_nil(&1.start), &1.start || 0})
    end
  end

  defp index_by_id(spans) do
    spans
    |> Enum.filter(& &1.span_id)
    |> Map.new(&{&1.span_id, &1})
  end

  # Depth = distance from the span's chain root (the ancestor with no
  # in-set parent). Walks the parent chain once per span with a visited set
  # guarding against cycles.
  defp depth_map(spans, by_id) do
    Enum.reduce(spans, %{}, fn span, depths ->
      if span.span_id do
        Map.put_new(depths, span.span_id, walk_depth(span, by_id, 0, MapSet.new([span.span_id])))
      else
        depths
      end
    end)
  end

  defp walk_depth(span, by_id, depth, visited) do
    parent = by_id[span.parent_id]

    case parent do
      nil ->
        depth

      parent ->
        if parent.span_id in visited do
          # Parent cycle in (hand-built) input data: stop climbing, keep the
          # depth reached so far.
          depth
        else
          walk_depth(parent, by_id, depth + 1, MapSet.put(visited, parent.span_id))
        end
    end
  end

  # -- sections -----------------------------------------------------------------

  defp error_entries(spans, depths) do
    spans
    |> Enum.filter(&(&1.status.code == :error))
    |> Enum.sort_by(&{-(depths[&1.span_id] || 0), is_nil(&1.start), &1.start || 0})
    |> Enum.map(fn span ->
      %{
        name: span.name,
        span_id: span.span_id,
        depth: depths[span.span_id] || 0,
        message:
          span.status.message || nil_or_cap(span.attributes["error.message"]) ||
            nil_or_cap(span.attributes["error.type"])
      }
    end)
  end

  defp nil_or_cap(nil), do: nil
  defp nil_or_cap(value), do: cap_string(to_string(value))

  defp policy_entries(spans) do
    spans
    |> Enum.filter(&String.contains?(String.downcase(&1.name), "policy"))
    |> Enum.map(fn span ->
      decision =
        span.attributes["ash.policy.decision"] || span.attributes["policy.decision"] ||
          span.attributes["ash.policy"]

      %{
        name: span.name,
        span_id: span.span_id,
        decision: nil_or_cap(decision)
      }
    end)
  end

  # Database/client spans, with N+1 collapse: identical sources under one
  # parent become a single entry with n_plus_one?: true and the repeat count.
  # Entries with a detected N+1 come first (highest count first).
  defp query_entries(spans) do
    queries = Enum.filter(spans, &query_span?/1)

    queries
    |> Enum.group_by(&{query_source(&1), &1.parent_id})
    |> Enum.map(fn {{source, parent_id}, group} ->
      %{
        source: cap_string(source),
        name: hd(group).name,
        count: length(group),
        n_plus_one?: length(group) > 1,
        parent_span_id: parent_id,
        duration: Enum.sum(Enum.map(group, &raw_duration/1))
      }
    end)
    |> Enum.sort_by(&{not &1.n_plus_one?, -&1.count, &1.source})
  end

  defp query_span?(span) do
    Map.has_key?(span.attributes, "db.statement") or
      Map.has_key?(span.attributes, "db.query") or
      span.kind == :client
  end

  defp query_source(span) do
    span.attributes["db.statement"] || span.attributes["db.query"] || span.name
  end

  defp notification_entries(spans) do
    spans
    |> Enum.filter(
      &(String.contains?(String.downcase(&1.name), "notification") or
          Map.has_key?(&1.attributes, "ash.notification"))
    )
    |> Enum.frequencies_by(& &1.name)
    |> Enum.map(fn {name, count} -> %{name: name, count: count} end)
    |> Enum.sort_by(& &1.name)
  end

  defp async_entries(spans) do
    spans
    |> Enum.filter(&(&1.kind in [:producer, :consumer]))
    |> Enum.sort_by(& &1.name)
    |> Enum.map(fn span ->
      %{name: span.name, kind: Atom.to_string(span.kind), span_id: span.span_id}
    end)
  end

  defp symbol_entries(spans) do
    spans
    |> Enum.filter(&Map.has_key?(&1.attributes, "ash.symbol_id"))
    |> Enum.group_by(&to_string(&1.attributes["ash.symbol_id"]))
    |> Enum.map(fn {symbol, group} ->
      names =
        group
        |> Enum.map(& &1.name)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.take(@spans_per_symbol)

      %{symbol: cap_string(symbol), span_count: length(group), spans: names}
    end)
    |> Enum.sort_by(& &1.symbol)
  end

  # -- projections ---------------------------------------------------------------

  defp project_root(nil), do: nil

  defp project_root(root) do
    %{
      name: root.name,
      kind: Atom.to_string(root.kind),
      span_id: root.span_id,
      trace_id: root.trace_id,
      duration: raw_duration(root),
      attributes:
        Map.new(root.attributes, fn {key, value} -> {key, Types.to_json_safe(value)} end)
    }
  end

  # Durations are reported in the input's own time units (the caller knows
  # whether their exporter produced nanoseconds or milliseconds); a missing
  # half contributes zero.
  defp raw_duration(nil), do: nil

  defp raw_duration(span) do
    with start when is_number(start) <- span.start,
         finish when is_number(finish) <- span.end,
         true <- finish >= start do
      finish - start
    else
      _ -> nil
    end
  end

  defp trace_id(_spans, %{trace_id: trace_id}), do: trace_id
  defp trace_id([first | _], nil), do: first.trace_id
  defp trace_id([], _), do: nil

  # -- budget ----------------------------------------------------------------------

  # The budget counts characters of the JSON-encoded report. Whole entries
  # are dropped (highest-churn section first, tail entry first) until it
  # fits; if the fixed part alone is still over budget, the root's
  # attributes are dropped. `truncated?` is raised the moment anything had
  # to go.
  defp enforce_budget(reduction, budget) do
    fixed = Map.take(reduction, [:root, :summary, :truncated?, :backend_url])
    fixed_size = encoded_size(fixed)

    lists =
      Map.new(@drop_priority, fn key ->
        {key, Enum.map(Map.fetch!(reduction, key), &{&1, encoded_size(&1)})}
      end)

    {lists, truncated?} = trim_to_budget(lists, fixed_size, budget)

    reduction =
      reduction
      |> Map.merge(Map.new(lists, fn {key, items} -> {key, Enum.map(items, &elem(&1, 0))} end))
      |> Map.put(:truncated?, truncated?)

    if encoded_size(reduction) > budget and is_map(reduction.root) do
      %{reduction | root: Map.delete(reduction.root, :attributes), truncated?: true}
    else
      reduction
    end
  end

  defp trim_to_budget(lists, fixed_size, budget) do
    total =
      fixed_size +
        Enum.sum(Enum.map(lists, fn {_key, items} -> Enum.sum(Enum.map(items, &elem(&1, 1))) end))

    if total <= budget do
      {lists, false}
    else
      case Enum.find(@drop_priority, &(Map.fetch!(lists, &1) != [])) do
        nil ->
          {lists, true}

        key ->
          {_dropped, rest} = List.pop_at(Map.fetch!(lists, key), -1)
          trim_to_budget(Map.put(lists, key, rest), fixed_size, budget)
      end
    end
  end

  defp encoded_size(term), do: term |> Jason.encode_to_iodata!() |> :erlang.iolist_size()

  defp cap_string(string) when is_binary(string) do
    if String.length(string) > @string_cap do
      String.slice(string, 0, @string_cap) <> "…"
    else
      string
    end
  end

  # -- option validation -----------------------------------------------------------

  defp budget!(opts) do
    budget = Keyword.get(opts, :budget, @default_budget)

    if is_integer(budget) and budget > 0 do
      budget
    else
      raise ArgumentError, ":budget must be a positive integer, got: #{inspect(budget)}"
    end
  end

  defp backend_url!(opts) do
    case Keyword.get(opts, :backend_url) do
      nil -> nil
      url when is_binary(url) -> url
      other -> raise ArgumentError, ":backend_url must be a string, got: #{inspect(other)}"
    end
  end
end
