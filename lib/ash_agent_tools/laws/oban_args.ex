# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Laws.ObanArgs do
  @moduledoc """
  The `:ast` detectors for law #08 (Oban args are string-keyed) and law #09
  (store ids, not structs): they parse the source with
  `Code.string_to_quoted/2` and look at the args of an Oban job being built.

  A call is a *job constructor* when it is:

    * `Oban.Job.new/2`, or any `X.new/1,2` handed to `Oban.insert*`
      (as an argument, or piped into it): `:likely`
    * `Some.Worker.new/1,2` (last alias segment ends in `Worker`), or
      `__MODULE__.new/1,2` in a source with `use Oban.Worker`: `:likely`
    * `Some.SyncJob.new/1,2` (last alias segment ends in `Job`): `:review`

  Any other `X.new(%{...})` is not judged: `Map.new`, `MapSet.new` and a
  hundred struct constructors share the name.

  Its first argument, a map literal (or a variable bound once to one in the
  same function), is then checked:

    * #08 reports an atom key at any depth of the literal.
    * #09 reports a struct literal, a `__struct__` key, or a variable bound
      to a struct literal (`user = %User{}`, `%User{} = user`) used as an
      args value. `user.id`, `Map.from_struct(user)` and plain ids are not.

  Variables bound by anything else (function arguments, `case`) are unknown,
  and unknown is never reported. A source that does not parse reports
  nothing, and in diff mode each run of added lines is parsed on its own
  (falling back to line by line), so a call split across hunks is not seen.
  """

  @worker_use ~r/\buse\s+Oban(\.Pro)?\.Worker\b/
  @defs [:def, :defp, :defmacro, :defmacrop]

  @doc "Law #08: atom keys in the args of an Oban job."
  @spec keys(String.t(), map()) :: [map()]
  def keys(source, meta), do: check(source, meta, :keys)

  @doc "Law #09: structs in the args of an Oban job."
  @spec structs(String.t(), map()) :: [map()]
  def structs(source, meta), do: check(source, meta, :structs)

  defp check(source, meta, mode) do
    worker_source? = Regex.match?(@worker_use, source)

    meta
    |> units(source)
    |> Enum.flat_map(fn {text, offset} ->
      case Code.string_to_quoted(text, columns: true) do
        {:ok, ast} -> hits(ast, mode, worker_source?, offset)
        {:error, _} -> []
      end
    end)
    |> Enum.uniq_by(& &1.line)
  end

  # The texts to parse, each with the diff/source line its first line is on.
  defp units(%{diff?: false}, source), do: [{source, 0}]

  defp units(%{lines: lines}, _source) do
    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _no} ->
      String.starts_with?(line, "+") and not String.starts_with?(line, "+++")
    end)
    |> Enum.chunk_while(
      [],
      fn {_, no} = item, acc ->
        case acc do
          [{_, prev} | _] when prev + 1 != no -> {:cont, Enum.reverse(acc), [item]}
          _ -> {:cont, [item | acc]}
        end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.flat_map(&run_units/1)
  end

  defp run_units([{_, first} | _] = run) do
    text = Enum.map_join(run, "\n", fn {line, _} -> String.slice(line, 1..-1//1) end)

    case Code.string_to_quoted(text) do
      {:ok, _} -> [{text, first - 1}]
      {:error, _} -> Enum.map(run, fn {line, no} -> {String.slice(line, 1..-1//1), no - 1} end)
    end
  end

  defp hits(ast, mode, worker_source?, offset) do
    ast
    |> scopes()
    |> Enum.flat_map(&scope_hits(&1, mode, worker_source?))
    |> Enum.map(fn {line, tier, hint} -> %{line: line + offset, tier: tier, hint: hint} end)
  end

  defp scopes(ast) do
    {_, defs} =
      Macro.prewalk(ast, [], fn
        {kind, _, [_ | _]} = node, acc when kind in @defs -> {node, [node | acc]}
        node, acc -> {node, acc}
      end)

    if defs == [], do: [ast], else: Enum.reverse(defs)
  end

  defp scope_hits(scope, mode, worker_source?) do
    bindings = bindings(scope)
    {oban_news, piped} = oban_context(scope)

    {_, found} =
      Macro.prewalk(scope, [], fn node, acc ->
        {node,
         candidate(node, piped, oban_news, worker_source?) |> add(acc, node, mode, bindings)}
      end)

    Enum.reverse(found)
  end

  defp add(nil, acc, _node, _mode, _bindings), do: acc

  defp add({tier, first_arg}, acc, node, mode, bindings) do
    case verdict(mode, first_arg, bindings) do
      nil -> acc
      hint -> [{line(node), tier, hint} | acc]
    end
  end

  defp line({_, meta, _}), do: Keyword.get(meta, :line, 1)

  # {tier, first_arg} for a job constructor, nil otherwise.
  defp candidate(node, piped, oban_news, worker_source?) do
    with {mod, args} <- new_call(node),
         first when first != nil <- Map.get(piped, node) || List.first(args),
         tier when tier != nil <- tier(mod, MapSet.member?(oban_news, node), worker_source?) do
      {tier, first}
    else
      _ -> nil
    end
  end

  defp new_call({{:., _, [mod, :new]}, _, args}) when is_list(args), do: {mod, args}
  defp new_call(_), do: nil

  defp tier(_mod, true, _worker_source?), do: :likely
  defp tier({:__aliases__, _, [:Oban, :Job]}, _, _), do: :likely
  defp tier({:__MODULE__, _, _}, _, true), do: :likely

  defp tier({:__aliases__, _, parts}, _, _) do
    last = parts |> List.last() |> to_string()

    cond do
      String.ends_with?(last, "Worker") -> :likely
      String.ends_with?(last, "Job") -> :review
      true -> nil
    end
  end

  defp tier(_, _, _), do: nil

  # The `.new` calls handed to Oban.insert* (argument or pipe), and the
  # first argument of each piped call (`%{a: 1} |> Worker.new()`).
  defp oban_context(scope) do
    {_, {news, piped}} =
      Macro.prewalk(scope, {MapSet.new(), %{}}, fn
        {:|>, _, [lhs, {{:., _, _}, _, _} = rhs]} = node, {news, piped} ->
          piped = if new_call(rhs), do: Map.put(piped, rhs, lhs), else: piped
          {node, {news_in(oban_insert?(rhs), [lhs], news), piped}}

        {{:., _, _}, _, args} = node, {news, piped} when is_list(args) ->
          {node, {news_in(oban_insert?(node), args, news), piped}}

        node, acc ->
          {node, acc}
      end)

    {news, piped}
  end

  defp oban_insert?({{:., _, [{:__aliases__, _, [:Oban]}, fun]}, _, _})
       when fun in [:insert, :insert!, :insert_all, :insert_all!],
       do: true

  defp oban_insert?(_), do: false

  defp news_in(false, _args, news), do: news

  defp news_in(true, args, news) do
    {_, news} =
      Macro.prewalk(args, news, fn node, acc ->
        if new_call(node), do: {node, MapSet.put(acc, node)}, else: {node, acc}
      end)

    news
  end

  # name => [:struct | {:map, literal} | :other], from `=` matches in scope.
  defp bindings(scope) do
    {_, acc} =
      Macro.prewalk(scope, %{}, fn
        {:=, _, [l, r]} = node, acc -> {node, bind(acc, l, r)}
        node, acc -> {node, acc}
      end)

    acc
  end

  defp bind(acc, l, r) do
    cond do
      var?(l) -> put_binding(acc, l, kind(r))
      var?(r) and struct_pattern?(l) -> put_binding(acc, r, :struct)
      var?(r) -> put_binding(acc, r, :other)
      true -> acc
    end
  end

  defp put_binding(acc, {name, _, _}, kind), do: Map.update(acc, name, [kind], &[kind | &1])

  defp kind({:=, _, [_, r]}), do: kind(r)
  defp kind({:%, _, [_, {:%{}, _, _}]}), do: :struct
  defp kind({:%{}, _, _} = map), do: {:map, map}
  defp kind(_), do: :other

  defp var?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: name != :_
  defp var?(_), do: false

  defp struct_pattern?({:%, _, [_, {:%{}, _, _}]}), do: true
  defp struct_pattern?({:=, _, [l, r]}), do: struct_pattern?(l) or struct_pattern?(r)
  defp struct_pattern?(_), do: false

  # A variable counts as bound only when every binding in scope agrees.
  defp resolve({name, _, ctx} = node, bindings) when is_atom(name) and is_atom(ctx) do
    case Map.get(bindings, name) do
      [:struct | _] = kinds -> if Enum.all?(kinds, &(&1 == :struct)), do: :struct, else: node
      [{:map, map}] -> map
      _ -> node
    end
  end

  defp resolve(node, _bindings), do: node

  defp verdict(:keys, arg, bindings) do
    case resolve(arg, bindings) do
      {:%{}, _, _} = map ->
        if atom_key?(map),
          do:
            "atom keys in Oban job args come back as strings after the JSON round trip — " <>
              "build the args with string keys (\"id\" => id) and match string keys in perform/1"

      _ ->
        nil
    end
  end

  defp verdict(:structs, arg, bindings) do
    if struct_arg?(arg, bindings),
      do:
        "a struct in Oban job args freezes its state at enqueue time and does not survive " <>
          "the JSON round trip — pass the id and re-read the record in perform/1"
  end

  defp atom_key?({:%{}, _, pairs}) do
    Enum.any?(pairs, fn
      {k, v} -> is_atom(k) or nested_atom_key?(v)
      _ -> false
    end)
  end

  defp nested_atom_key?({:%{}, _, _} = map), do: atom_key?(map)
  defp nested_atom_key?(list) when is_list(list), do: Enum.any?(list, &nested_atom_key?/1)
  defp nested_atom_key?(_), do: false

  defp struct_arg?(arg, bindings) do
    case resolve(arg, bindings) do
      :struct -> true
      {:%, _, [_, {:%{}, _, _}]} -> true
      {:%{}, _, pairs} -> Enum.any?(pairs, &struct_pair?(&1, bindings))
      list when is_list(list) -> Enum.any?(list, &struct_arg?(&1, bindings))
      {a, b} -> struct_arg?(a, bindings) or struct_arg?(b, bindings)
      _ -> false
    end
  end

  defp struct_pair?({:__struct__, _}, _bindings), do: true
  defp struct_pair?({_k, v}, bindings), do: struct_arg?(v, bindings)
  defp struct_pair?(_, _bindings), do: false
end
