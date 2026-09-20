# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Runtime do
  @moduledoc """
  Read-only BEAM runtime introspection for agents: the *state* plane that
  pairs with the *time* plane of a trace (join key: `trace_id`).

  Three read-only views over the running VM:

    * `snapshot/1` — memory, processes, schedulers, ETS at a glance
    * `top/2` — the busiest processes (message-queue length, memory,
      reductions) — the classic hidden-queue hunt
    * `tree/2` — the supervision tree of one application or all of them

  Two backends, chosen per call (or forced with the `:backend` opt):

    * `:observer_cli` — when the host application ships observer_cli 2.0
      (with recon), each view delegates to
      `observer_cli_snapshot:dispatch/4`: a heap-capped, byte-capped,
      JSON-safe worker whose response is the versioned `observer_cli.cli/v1`
      envelope, passed through verbatim so its upstream JSON Schema
      guarantees hold. This package never installs or starts it.
    * `:builtin` — plain `Process.list/0` walks, `:ets` info, and
      `:supervisor.which_children/1` traversal rooted at each started
      application. Always available; output is normalized through the same
      JSON-safe discipline as the rest of this package and capped in size.

  Every result echoes optional `:trace_id` and `:correlation_id` opts back
  into the map, so a snapshot captured while investigating a trace can be
  joined to it later.

  Nothing here mutates the VM: no tracing, no signals, no reads beyond
  `Process.info/2` and `:supervisor.which_children/1`.
  """

  alias AshAgentTools.Types

  @type backend :: :auto | :observer_cli | :builtin
  @type sort_key :: :message_queue_len | :memory | :reductions

  @default_n 10
  @default_sort :message_queue_len
  @default_depth 5
  @default_max_children 100
  @default_max_nodes 2_000
  @ets_top 10
  @default_timeout_ms 10_000

  @valid_sorts [:message_queue_len, :memory, :reductions]
  @valid_backends [:auto, :observer_cli, :builtin]

  # -- snapshot ------------------------------------------------------------

  @doc """
  Snapshots the VM: memory, process/port/ETS counts, schedulers, run queues,
  and the current top processes (by memory, `:n` of them).

  See the module doc for backends; accepted options: `:backend`, `:n`,
  `:trace_id`, `:correlation_id`. Raises `ArgumentError` for invalid options
  or a forced-but-unavailable backend.
  """
  @spec snapshot(keyword()) :: map()
  def snapshot(opts \\ []) do
    opts = validate_common_opts!(opts)

    case Keyword.fetch!(opts, :backend) do
      :observer_cli ->
        observer_response(:snapshot, %{}, opts)

      :builtin ->
        builtin_system()
        |> Map.merge(base(opts))
        |> Map.put(:processes, top_processes(Keyword.fetch!(opts, :n), :memory))
    end
  end

  # -- top -------------------------------------------------------------------

  @doc """
  Lists the `n` busiest processes, sorted by `:sort` (default
  `:message_queue_len` — the classic hidden-queue suspect).

  On the observer_cli backend the sort/limit feed its `processes` probe;
  on the builtin backend this walks `Process.list/0`.
  """
  @spec top(pos_integer(), keyword()) :: map()
  def top(n, opts \\ [])

  def top(n, opts) when is_integer(n) and n > 0 do
    opts = validate_common_opts!(opts)
    sort = Keyword.fetch!(opts, :sort)

    case Keyword.fetch!(opts, :backend) do
      :observer_cli ->
        observer_response(:processes, %{sort: sort, limit: n}, opts)

      :builtin ->
        processes = top_processes(n, sort)

        base(opts)
        |> Map.put(:sort, Atom.to_string(sort))
        |> Map.put(:count, length(processes))
        |> Map.put(:processes, processes)
    end
  end

  def top(n, _opts) do
    raise ArgumentError, "n must be a positive integer, got: #{inspect(n)}"
  end

  # -- tree --------------------------------------------------------------------

  @doc """
  Walks supervision trees, rooted at each started application (sorted by
  name). With `app` (atom or string), only that application is walked; an
  unknown or unstarted app raises `ArgumentError` listing the started
  applications.

  The builtin traversal resolves each application's root supervisor with
  `:application.get_supervisor/1` (the same resolution observer_cli uses)
  and walks `:supervisor.which_children/1` under depth/width/node caps:
  `:depth` (default #{@default_depth}), `:max_children` per level
  (default #{@default_max_children}), `:max_nodes` per application
  (default #{@default_max_nodes}). Applications without a running top
  supervisor (pure libraries) report `root: nil`. With `app` given on the
  observer_cli backend, its `supervision_tree` probe answers instead.
  """
  @spec tree(atom() | String.t() | nil, keyword()) :: map()
  def tree(app \\ nil, opts \\ [])

  def tree(app, opts) when is_atom(app) or is_binary(app) or is_nil(app) do
    opts = validate_common_opts!(opts)

    case Keyword.fetch!(opts, :backend) do
      :observer_cli when not is_nil(app) ->
        observer_response(:supervision_tree, %{app: app_text(app)}, opts)

      _backend ->
        tree_builtin(app, opts)
    end
  end

  def tree(app, _opts) do
    raise ArgumentError, "app must be an atom, a string, or nil, got: #{inspect(app)}"
  end

  # -- backends ------------------------------------------------------------------

  # Feature detection: the optional dep is only compiled into envs that
  # declare it (dev of the host app), so presence is checked at call time,
  # never assumed at compile time.
  defp observer_cli_available? do
    match?({:module, _}, Code.ensure_loaded(:observer_cli_snapshot))
  end

  # Dynamic dispatch (apply, not a direct remote call): observer_cli is an
  # optional dependency, so neither this package's nor a host's compiler or
  # Dialyzer should see — or warn on — the call when the dep is absent.
  defp observer_response(command, request, opts) do
    options = %{
      identifier_policy: Keyword.fetch!(opts, :identifier_policy),
      timeout_ms: Keyword.fetch!(opts, :timeout_ms)
    }

    # The arity IS known — apply/3 is deliberate: a direct remote call to
    # the optional dep's module would raise compile-time (and Dialyzer)
    # "undefined function" warnings in every env where observer_cli is not
    # a dependency.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    response = apply(:observer_cli_snapshot, :dispatch, [self(), command, request, options])

    base(opts)
    |> Map.put(:backend, "observer_cli")
    |> Map.put(:command, Atom.to_string(command))
    |> Map.put(:response, response)
  end

  # -- builtin snapshot pieces -------------------------------------------------------

  defp builtin_system do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    memory =
      :erlang.memory()
      |> Map.new()
      |> Map.take([:total, :processes, :processes_used, :system, :atom, :binary, :code, :ets])
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

    %{
      node: to_string(node()),
      otp_release: to_string(:erlang.system_info(:otp_release)),
      uptime_seconds: div(uptime_ms, 1000),
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      port_count: length(:erlang.ports()),
      schedulers: %{
        online: :erlang.system_info(:schedulers_online),
        total: :erlang.system_info(:schedulers)
      },
      run_queue_length: :erlang.statistics(:run_queue),
      memory: memory,
      ets: builtin_ets()
    }
  end

  defp builtin_ets do
    tables = :ets.all()

    infos =
      for table <- tables,
          info = ets_info(table) do
        info
      end

    %{
      table_count: length(tables),
      total_memory_words: Enum.sum(Enum.map(infos, & &1.memory)),
      top: infos |> Enum.sort_by(&{-&1.memory, &1.name}) |> Enum.take(@ets_top)
    }
  end

  # Single-item :ets.info/2 per field: the list form is not accepted on all
  # supported OTP releases, and a table deleted mid-scan answers :undefined.
  defp ets_info(table) do
    name = :ets.info(table, :name)
    size = :ets.info(table, :size)
    memory = :ets.info(table, :memory)

    if name != :undefined and is_integer(size) and is_integer(memory) do
      %{name: Types.to_json_safe(name), size: size, memory: memory}
    else
      nil
    end
  rescue
    _ -> nil
  end

  # -- builtin process walk ---------------------------------------------------------

  defp top_processes(n, sort) do
    Process.list()
    |> Enum.map(&process_info/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&{-(Map.fetch!(&1, sort) || 0), &1.pid})
    |> Enum.take(n)
  end

  defp process_info(pid) do
    case Process.info(pid, [
           :message_queue_len,
           :memory,
           :reductions,
           :registered_name,
           :initial_call
         ]) do
      nil ->
        # exited between list and info: skip
        nil

      fields ->
        %{
          pid: inspect(pid),
          name: registered_name(fields[:registered_name]),
          initial_call: initial_call(fields[:initial_call]),
          message_queue_len: fields[:message_queue_len],
          memory: fields[:memory],
          reductions: fields[:reductions]
        }
    end
  end

  # Elixir's Process.info hands registered names back as atoms (or [] when
  # unregistered).
  defp registered_name(nil), do: nil
  defp registered_name([]), do: nil
  defp registered_name(name) when is_atom(name), do: Atom.to_string(name)

  defp initial_call({module, function, arity}) when is_atom(module) and is_atom(function) do
    "#{Types.to_json_safe(module)}.#{function}/#{arity}"
  end

  defp initial_call(other), do: Types.to_json_safe(other)

  # -- builtin supervision tree ---------------------------------------------------

  defp tree_builtin(app, opts) do
    started = started_applications()
    filter = app && app!(app, started)

    applications =
      started
      |> Enum.filter(fn {name, _, _} -> is_nil(filter) or name == filter end)
      |> Enum.sort_by(&Atom.to_string(elem(&1, 0)))
      |> Enum.map(&application_tree(&1, opts))

    base(opts)
    |> Map.put(:filter, filter && Atom.to_string(filter))
    |> Map.put(:applications, applications)
  end

  defp started_applications do
    :application.which_applications()
    |> Enum.map(fn {name, description, version} ->
      {name, app_label(description), app_label(version)}
    end)
  end

  # which_applications hands back charlists for description/version.
  defp app_label(term) when is_list(term) do
    if Enum.all?(term, &is_integer/1) do
      List.to_string(term)
    else
      Types.to_json_safe(term)
    end
  end

  defp app_label(term), do: Types.to_json_safe(term)

  # The node budget ({:nodes, n}) threads through the whole walk, so one
  # deep branch cannot starve the caps: every node — supervisor or worker —
  # costs one.
  defp application_tree({name, description, version}, opts) do
    {root, _} =
      case :application.get_supervisor(name) do
        {:ok, root_pid} when is_pid(root_pid) ->
          walk_supervisor(root_pid, 0, opts, %{nodes: Keyword.fetch!(opts, :max_nodes)})

        _ ->
          # not running, or no top supervisor (library app): reported, not failed
          {nil, nil}
      end

    %{
      name: Atom.to_string(name),
      description: description,
      version: version,
      root: root
    }
  end

  defp walk_supervisor(pid, depth, opts, state) do
    if state.nodes <= 0 do
      {%{id: inspect(pid), name: nil, type: "supervisor", truncated: true}, state}
    else
      state = %{state | nodes: state.nodes - 1}

      registered =
        case Process.info(pid, :registered_name) do
          {:registered_name, name} -> name
          _ -> []
        end

      {children, state} =
        if depth >= Keyword.fetch!(opts, :depth) do
          {[], state}
        else
          child_nodes(pid, depth, opts, state)
        end

      node = %{
        id: inspect(pid),
        name: registered_name(registered),
        type: "supervisor",
        child_count: child_count(pid),
        children: children
      }

      {node, state}
    end
  end

  defp child_nodes(pid, depth, opts, state) do
    max_children = Keyword.fetch!(opts, :max_children)

    pid
    |> :supervisor.which_children()
    |> Enum.take(max_children)
    |> Enum.flat_map_reduce(state, fn {_id, child_pid, type, _modules}, state ->
      cond do
        is_pid(child_pid) and type == :supervisor ->
          {child, state} = walk_supervisor(child_pid, depth + 1, opts, state)
          {[child], state}

        is_pid(child_pid) and state.nodes > 0 ->
          {[worker_node(child_pid)], %{state | nodes: state.nodes - 1}}

        true ->
          # restarting/undefined children have no pid yet; out of node budget
          {[], state}
      end
    end)
  end

  defp worker_node(pid) do
    info = Process.info(pid, [:registered_name])

    %{
      id: inspect(pid),
      name: registered_name((info && info[:registered_name]) || []),
      type: "worker",
      children: []
    }
  end

  defp child_count(pid) do
    length(:supervisor.which_children(pid))
  rescue
    _ -> 0
  end

  defp app_text(app) when is_atom(app), do: Atom.to_string(app)
  defp app_text(app) when is_binary(app), do: app

  # App filters match by name; unknown or unstarted apps raise with the
  # started list — mirroring how describe/validate raise for unknown
  # resources/actions instead of answering silently.
  defp app!(app, started) do
    wanted = app_text(app)

    case Enum.find(started, fn {name, _, _} -> Atom.to_string(name) == wanted end) do
      {name, _, _} ->
        name

      nil ->
        available = started |> Enum.map(&Atom.to_string(elem(&1, 0))) |> Enum.sort()

        raise ArgumentError,
              "#{inspect(app)} is not a started application." <>
                " Started applications: #{Enum.join(available, ", ")}"
    end
  end

  # -- shared plumbing -------------------------------------------------------------

  defp base(opts) do
    %{
      backend: "builtin",
      trace_id: Keyword.fetch!(opts, :trace_id),
      correlation_id: Keyword.fetch!(opts, :correlation_id)
    }
  end

  # -- shared plumbing (option validation) -------------------------------------------

  # One validation pass for every public function: Keyword.validate!/2 both
  # rejects unknown keys and fills the defaults, so downstream fetches are
  # total. Each check gets its own tiny function — easier to read than one
  # sprawling validator, and the error messages stay precise.
  @opt_defaults [
    backend: :auto,
    trace_id: nil,
    correlation_id: nil,
    identifier_policy: :include,
    timeout_ms: @default_timeout_ms,
    n: @default_n,
    sort: @default_sort,
    depth: @default_depth,
    max_children: @default_max_children,
    max_nodes: @default_max_nodes
  ]

  defp validate_common_opts!(opts) when is_list(opts) do
    opts
    |> Keyword.validate!(@opt_defaults)
    |> validate_echo!(:trace_id)
    |> validate_echo!(:correlation_id)
    |> validate_member!(:backend, @valid_backends, ":backend")
    |> validate_member!(:identifier_policy, [:include, :redact], ":identifier_policy")
    |> validate_sort!()
    |> validate_positive!([:n, :depth, :max_children, :max_nodes, :timeout_ms])
    |> normalize_sort()
    |> resolve_backend()
  end

  defp validate_common_opts!(opts) do
    raise ArgumentError, "opts must be a keyword list, got: #{inspect(opts)}"
  end

  defp validate_echo!(opts, key) do
    value = Keyword.fetch!(opts, key)

    unless is_binary(value) or is_nil(value) do
      raise ArgumentError, "#{inspect(key)} must be a string or nil, got: #{inspect(value)}"
    end

    opts
  end

  defp validate_member!(opts, key, valid, label) do
    value = Keyword.fetch!(opts, key)

    unless value in valid do
      raise ArgumentError, "#{label} must be one of #{inspect(valid)}, got: #{inspect(value)}"
    end

    opts
  end

  defp validate_sort!(opts) do
    sort = Keyword.fetch!(opts, :sort)
    string_sorts = Enum.map(@valid_sorts, &Atom.to_string/1)

    unless sort in @valid_sorts or (is_binary(sort) and sort in string_sorts) do
      raise ArgumentError, ":sort must be one of #{inspect(@valid_sorts)} (strings accepted)"
    end

    opts
  end

  defp validate_positive!(opts, keys) do
    for key <- keys do
      value = Keyword.fetch!(opts, key)

      unless is_integer(value) and value > 0 do
        raise ArgumentError, "#{inspect(key)} must be a positive integer, got: #{inspect(value)}"
      end
    end

    opts
  end

  # Normalize a string sort to its atom form (the atom necessarily exists —
  # it is in @valid_sorts — so to_existing_atom is safe), then resolve :auto
  # to the concrete backend: every caller cases on :observer_cli/:builtin.
  defp normalize_sort(opts) do
    case Keyword.fetch!(opts, :sort) do
      sort when sort in @valid_sorts -> opts
      sort -> Keyword.put(opts, :sort, String.to_existing_atom(sort))
    end
  end

  defp resolve_backend(opts) do
    resolved =
      case Keyword.fetch!(opts, :backend) do
        :auto ->
          if observer_cli_available?(), do: :observer_cli, else: :builtin

        :observer_cli ->
          unless observer_cli_available?() do
            raise ArgumentError,
                  "backend: :observer_cli was forced but observer_cli 2.0 is not loaded." <>
                    " Add {:observer_cli, \"~> 2.0\", only: :dev, optional: true}" <>
                    " (with {:recon, \"2.5.6\", only: :dev, optional: true}) to the host" <>
                    " application, or use backend: :builtin"
          end

          :observer_cli

        :builtin ->
          :builtin
      end

    Keyword.put(opts, :backend, resolved)
  end
end
