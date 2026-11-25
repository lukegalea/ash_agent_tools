# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Gate do
  @moduledoc """
  The pre-flight tool-call gate's deterministic rung: a repository's own
  rules, as DMN decision tables, asked before an agent's tool call runs.

  A harness hook (see `priv/hooks/`) posts the tool call it is about to make;
  the gate normalises it (`AshAgentTools.Gate.Request`) and evaluates it
  against the tables, in order:

    1. the host's own table, `priv/decisions/agent_gate_rules.dmn` under the
       project root, when it exists;
    2. this package's generic seed, `priv/gate/agent_gate_rules.dmn`.

  The first answer that is not `"defer"` wins, so a host can allow a narrow
  case (force-pushing a branch the agent owns) before the seed's broader
  refusal is reached. A call that touches several paths is evaluated once
  per path and the strictest answer wins (`deny`, then `ask`, then `defer`,
  then `allow`).

  Each table has hit policy `FIRST`, outputs `decision` (`allow | ask | deny
  | defer`), `rule_id` and `reason`, and ends with a rule that matches
  everything and defers, which is what makes it complete. `verify/1` runs
  the `ash_decisions` publish-time verifier over every table.

  Evaluation is `ash_decisions`' own (`AshDecisions.Evaluator.evaluate/3`
  with `record: false`): a dry evaluation that writes no `Evaluation` row.
  Compiled tables are cached by content hash, so editing a table takes
  effect on the next call. No model is called.

  ## What the answers mean

    * `deny` — the call breaks a rule the repository states; the harness
      refuses it with the rule's reason.
    * `ask` — a person decides. So does an error: a table that does not
      load, or a request the gate cannot read, is answered `ask` with
      `rule_id: "gate_error"`, never `allow` or `defer`.
    * `allow` — a rule allows the call explicitly, which stops later tables
      refusing it. The adapters do not turn it into a permission grant: the
      harness's own permissions still apply.
    * `defer` — no rule spoke. The harness's own permissions decide.

  The gate is a guardrail, not a security boundary: an agent can phrase a
  command no pattern anticipates. Sandboxes and permissions remain the
  security controls.

  ## The System One rung (optional)

  A call no rule speaks to (`defer`) is the residual: an obfuscated or a
  novel command. A host can put it to a model through a second rung:

      config :ash_agent_tools, :gate, system_one: MyApp.AgentGate.Rung

  The module exports `judge(request, opts)`, called with the normalised
  request and `root:`. It asks the host's declared questions about the
  request (the model call happens there, in the gate service, never inside
  a read, a calculation or a policy check) and returns

      {:ok, %{inputs: %{"destructive" => "no", ...}, certified: true, audit: %{...}}}

  or `{:error, reason}`. `inputs` are what the host's banding table,
  `priv/decisions/agent_gate.dmn`, reads (with `tool` and `repo_kind`
  added); it answers `allow`, `ask` or `deny` with a `rule_id` and a
  `reason`, like the rules tables. `certified` says whether the band
  tables behind `inputs` are certified; `audit` is logged as given. A
  module that exports `child_spec/1` is started by the daemon
  (`system_one_children/1`): the rung's own runtime, such as its repo.

  The rung can only make a call stricter, never let one through on its
  own (law 4 of the judgment substrate: advisory in tooling):

    * an `allow` from tables that are not certified is an `ask`
      (uncertified judgment never allows);
    * a `deny` is an `ask`: the model rung never refuses a call by itself;
    * an error, a timeout (`:system_one_timeout`, default 4000 ms), a
      missing banding table or an answer the table cannot read is an `ask`
      with `rule_id: "system_one_unavailable"`, never an `allow`.

  An `allow` the rung keeps means what a rule's `allow` means: the
  harness's own permissions decide. A `deny` from the rules tables never
  reaches the rung, and nor does any answer other than `defer`.

  ## Audit

  `check/2` appends one JSON line per decision to
  `.agents/logs/gate.jsonl` under the project root: the request, the
  decision, `rule_id`, the deciding table's `definition_hash` (SHA-256 of
  its XML) and `matched_rule_ids` (the engine's account of the rules that
  matched), and every table evaluated on the way. `explain/2` answers the
  same question without writing.
  """

  alias AshAgentTools.Availability
  alias AshAgentTools.Gate.Request

  @host_table "priv/decisions/agent_gate_rules.dmn"
  @system_one_table "priv/decisions/agent_gate.dmn"
  @system_one_timeout 4_000
  @system_one_decisions ~w(allow ask deny)
  @config_file ".agents/gate.json"
  @log_file ".agents/logs/gate.jsonl"
  @decisions ~w(allow ask deny defer)
  @strictness %{"deny" => 0, "ask" => 1, "defer" => 2, "allow" => 3}

  @typedoc "A gate decision."
  @type result :: %{
          decision: String.t(),
          rule_id: String.t(),
          reason: String.t(),
          table: String.t() | nil,
          definition_hash: String.t() | nil,
          matched_rule_ids: [String.t()],
          path: String.t() | nil,
          evaluations: [map()],
          request: Request.t() | nil,
          rung: String.t(),
          system_one: map() | nil,
          duration_us: non_neg_integer()
        }

  @doc """
  Checks a tool call and appends the decision to the audit log.

  `payload` is a harness payload or a request (see
  `AshAgentTools.Gate.Request`). Never raises: an error is an `ask`.

  Options:

    * `:root` — the project root (default `File.cwd!/0`): where the host
      table, `.agents/gate.json` and the log live
    * `:tables` — the table files to evaluate, in order, instead of the
      default pair
    * `:log` — `false` to skip the audit line, or a path to append it to
    * `:system_one` — the System One rung's module, or `false` for none
      (default `config :ash_agent_tools, :gate, system_one: ...`)
    * `:system_one_timeout` — milliseconds the rung may take (default
      4000, or the `:gate` config's `:system_one_timeout`)
    * `:system_one_table` — the rung's banding table (default
      `priv/decisions/agent_gate.dmn` under the root)
  """
  @spec check(map(), keyword()) :: result()
  def check(payload, opts \\ []) do
    result = decide(payload, opts)
    log(result, opts)
    result
  end

  @doc """
  Answers the same question as `check/2` without writing the audit line:
  for debugging a rule (`mix ash_agent.gate --explain`).
  """
  @spec explain(map(), keyword()) :: result()
  def explain(payload, opts \\ []), do: decide(payload, opts)

  @doc """
  The table files the gate evaluates, in order.
  """
  @spec tables(keyword()) :: [String.t()]
  def tables(opts \\ []) do
    Keyword.get_lazy(opts, :tables, fn ->
      host = Path.join(root(opts), @host_table)
      Enum.filter([host], &File.regular?/1) ++ [seed_table()]
    end)
  end

  @doc """
  Compiles every table into the cache, so the first hook call after the
  daemon starts does not pay for it. Returns the tables that did not
  compile (each one's calls will be answered `ask`).
  """
  @spec warm(keyword()) :: [{String.t(), term()}]
  def warm(opts \\ []) do
    for table <- tables(opts),
        {:error, reason} <- [definition(table)],
        do: {table, reason}
  end

  @doc "The generic seed table shipped with this package."
  @spec seed_table() :: String.t()
  def seed_table, do: Application.app_dir(:ash_agent_tools, "priv/gate/agent_gate_rules.dmn")

  @doc """
  Runs the `ash_decisions` compiler and publish-time verifier over every
  table. A table passes when it compiles, no finding has severity `:error`
  or `:warning`, and nothing was left undecided (no obligations): under hit
  policy `FIRST` an overlap is legal and reported as `:info`.
  """
  @spec verify(keyword()) :: %{ok?: boolean(), tables: [map()]}
  def verify(opts \\ []) do
    Availability.ensure_active!(:ash_decisions)

    reports =
      Enum.map(tables(opts) ++ system_one_tables(opts), fn path ->
        with {:ok, xml} <- File.read(path),
             {:ok, graph} <- AshDecisions.Compiler.compile(xml) do
          result = AshDecisions.Verifier.verify(graph)

          blocking =
            Enum.filter(result.findings, &(&1.severity in [:error, :warning]))

          %{
            table: path,
            definition_hash: hash(xml),
            ok?: blocking == [] and result.obligations == [],
            findings: Enum.map(result.findings, &AshDecisions.Verification.Finding.to_map/1),
            obligations:
              Enum.map(result.obligations, &AshDecisions.Verification.Obligation.to_map/1)
          }
        else
          {:error, reason} ->
            %{table: path, ok?: false, error: inspect(reason), findings: [], obligations: []}
        end
      end)

    %{ok?: Enum.all?(reports, & &1.ok?), tables: reports}
  end

  @doc """
  The System One rung's children for a supervisor: `[module]` when the
  configured rung exports `child_spec/1`, else `[]`.
  """
  @spec system_one_children(keyword()) :: [module()]
  def system_one_children(opts \\ []) do
    case system_one(opts) do
      nil ->
        []

      module ->
        if Code.ensure_loaded?(module) and function_exported?(module, :child_spec, 1),
          do: [module],
          else: []
    end
  end

  @doc """
  The Claude Code `PreToolUse` hook output for a decision: a
  `permissionDecision` of `deny` or `ask` with the reason, or an empty
  object for `allow` and `defer`, which leaves the decision to Claude Code's
  own permissions.
  """
  @spec claude_code_output(result()) :: map()
  def claude_code_output(%{decision: decision} = result) when decision in ["deny", "ask"] do
    %{
      "hookSpecificOutput" => %{
        "hookEventName" => "PreToolUse",
        "permissionDecision" => decision,
        "permissionDecisionReason" => "#{result.reason} (gate rule #{result.rule_id})"
      }
    }
  end

  def claude_code_output(_result), do: %{}

  # ── deciding ──────────────────────────────────────────────────────────────

  defp decide(payload, opts) do
    started = System.monotonic_time(:microsecond)

    result =
      try do
        Availability.ensure_active!(:ash_decisions)
        request = Request.normalize(payload, config(opts))

        request
        |> evaluate_request(tables(opts))
        |> Map.merge(%{rung: "deterministic", system_one: nil})
        |> system_one_rung(system_one(opts), opts)
      rescue
        error -> error_result("the gate could not decide: #{Exception.message(error)}")
      end

    Map.put(result, :duration_us, System.monotonic_time(:microsecond) - started)
  end

  defp evaluate_request(request, tables) do
    subjects =
      case request.targets do
        [] -> [%{path: "", kind: request.repo.kind}]
        targets -> targets
      end

    subjects
    |> Enum.map(fn %{path: path, kind: kind} ->
      inputs = %{
        "tool" => request.tool,
        "command" => request.command || "",
        "path" => path,
        "repo_kind" => kind
      }

      tables
      |> first_answer(inputs, [])
      |> Map.put(:path, if(path == "", do: nil, else: path))
    end)
    |> Enum.min_by(&Map.fetch!(@strictness, &1.decision))
    |> Map.put(:request, request)
  end

  defp first_answer([], _inputs, evaluations) do
    # Every table deferred: the last one's catch-all is the answer.
    case evaluations do
      [last | _] -> answer(last, Enum.reverse(evaluations))
      [] -> error_result("no gate table to evaluate")
    end
  end

  defp first_answer([table | rest], inputs, evaluations) do
    case evaluate_table(table, inputs) do
      {:ok, %{decision: "defer"} = evaluation} ->
        first_answer(rest, inputs, [evaluation | evaluations])

      {:ok, evaluation} ->
        answer(evaluation, Enum.reverse([evaluation | evaluations]))

      {:error, reason} ->
        error_result("table #{table} could not be evaluated: #{inspect(reason)}")
    end
  end

  defp answer(evaluation, evaluations) do
    %{
      decision: evaluation.decision,
      rule_id: evaluation.rule_id,
      reason: evaluation.reason,
      table: evaluation.table,
      definition_hash: evaluation.definition_hash,
      matched_rule_ids: evaluation.matched_rule_ids,
      evaluations: evaluations
    }
  end

  defp error_result(reason) do
    %{
      decision: "ask",
      rule_id: "gate_error",
      reason: reason,
      table: nil,
      definition_hash: nil,
      matched_rule_ids: [],
      path: nil,
      evaluations: [],
      request: nil,
      rung: "deterministic",
      system_one: nil
    }
  end

  defp evaluate_table(table, inputs) do
    with {:ok, definition} <- definition(table),
         {:ok, result} <- AshDecisions.Evaluator.evaluate(definition, inputs, record: false),
         %{"decision" => decision, "rule_id" => rule_id, "reason" => reason}
         when decision in @decisions <- result.outputs do
      {:ok,
       %{
         table: table,
         definition_hash: definition.content_hash,
         decision: decision,
         rule_id: rule_id,
         reason: reason,
         matched_rule_ids: result.matched_rule_ids
       }}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_outputs, other}}
    end
  end

  # The compiled graph is cached by the XML's hash: compiling validates the
  # document (a process spawn), and the hash changes whenever the file does.
  defp definition(table) do
    with {:ok, xml} <- File.read(table) do
      hash = hash(xml)
      key = {__MODULE__, :definition, hash}

      case :persistent_term.get(key, :miss) do
        :miss -> compile_and_cache(key, table, xml, hash)
        definition -> {:ok, definition}
      end
    end
  end

  defp compile_and_cache(key, table, xml, hash) do
    case AshDecisions.Compiler.compile(xml) do
      {:ok, graph} ->
        definition = %{
          key: Path.basename(table, ".dmn"),
          version: 1,
          xml: xml,
          graph: graph,
          content_hash: hash
        }

        :persistent_term.put(key, definition)
        {:ok, definition}

      {:error, errors} ->
        {:error, {:compile_failed, errors}}
    end
  end

  defp hash(xml), do: :crypto.hash(:sha256, xml) |> Base.encode16(case: :lower)

  # ── the System One rung ───────────────────────────────────────────────────

  defp system_one_rung(%{decision: "defer"} = result, module, opts) when module != nil do
    started = System.monotonic_time(:microsecond)

    outcome =
      with {:ok, answer} <- rung_answer(call_rung(module, result.request, opts)),
           {:ok, evaluation} <- band(answer, result.request, opts) do
        {:ok, answer, evaluation}
      end

    us = System.monotonic_time(:microsecond) - started

    case outcome do
      {:ok, answer, evaluation} -> rung_result(result, answer, evaluation, us)
      {:error, reason} -> rung_unavailable(result, reason, us)
    end
  end

  defp system_one_rung(result, _module, _opts), do: result

  defp rung_result(result, answer, evaluation, us) do
    {decision, reason, capped} = bound(evaluation, answer.certified)

    %{
      result
      | decision: decision,
        rule_id: evaluation.rule_id,
        reason: reason,
        table: evaluation.table,
        definition_hash: evaluation.definition_hash,
        matched_rule_ids: evaluation.matched_rule_ids,
        rung: "system_one",
        system_one: %{
          outcome: "answered",
          table_decision: evaluation.decision,
          capped: capped,
          certified: answer.certified,
          inputs: answer.inputs,
          audit: answer.audit,
          duration_us: us
        }
    }
  end

  # Law 4: the model rung makes a call stricter, never lets one through.
  defp bound(%{decision: "deny", reason: reason}, _certified),
    do:
      {"ask", "System One would refuse this: #{reason} (a model never refuses on its own)",
       "deny"}

  defp bound(%{decision: "allow", reason: reason}, false),
    do:
      {"ask",
       "System One would allow this (#{reason}), but its band tables are not certified: a person decides",
       "uncertified_allow"}

  defp bound(%{decision: decision, reason: reason}, _certified), do: {decision, reason, nil}

  defp rung_unavailable(result, reason, us) do
    %{
      result
      | decision: "ask",
        rule_id: "system_one_unavailable",
        reason: "System One could not answer (#{reason_text(reason)}): a person decides",
        table: nil,
        definition_hash: nil,
        matched_rule_ids: [],
        rung: "system_one",
        system_one: %{outcome: "model_unavailable", error: inspect(reason), duration_us: us}
    }
  end

  defp reason_text(:timeout), do: "timed out"
  defp reason_text({:raised, _message}), do: "the rung raised"
  defp reason_text({:exited, _reason}), do: "the rung exited"
  defp reason_text({:banding_table, _reason}), do: "its banding table could not be evaluated"

  defp reason_text({:not_a_system_one_decision, decision}),
    do: "its banding table answered #{decision}"

  defp reason_text({:unexpected_answer, _answer}), do: "the rung's answer is not the contract"
  defp reason_text(_reason), do: "the rung returned an error"

  # The rung runs in its own process, so a timeout can stop it and a crash
  # cannot take the hook's request with it.
  defp call_rung(module, request, opts) do
    caller = self()
    ref = make_ref()
    rung_opts = [root: root(opts)]

    {pid, monitor} =
      spawn_monitor(fn ->
        answer =
          try do
            module.judge(request, rung_opts)
          rescue
            error -> {:error, {:raised, Exception.message(error)}}
          end

        send(caller, {ref, answer})
      end)

    receive do
      {^ref, answer} ->
        Process.demonitor(monitor, [:flush])
        answer

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:exited, reason}}
    after
      system_one_timeout(opts) ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        receive do
          {^ref, _late} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  defp rung_answer({:ok, %{inputs: %{} = inputs, certified: certified} = answer})
       when is_boolean(certified),
       do: {:ok, %{inputs: inputs, certified: certified, audit: Map.get(answer, :audit, %{})}}

  defp rung_answer({:error, reason}), do: {:error, reason}
  defp rung_answer(other), do: {:error, {:unexpected_answer, other}}

  defp band(answer, request, opts) do
    inputs =
      Map.merge(answer.inputs, %{"tool" => request.tool, "repo_kind" => request.repo.kind})

    case evaluate_table(system_one_table(opts), inputs) do
      {:ok, %{decision: decision} = evaluation} when decision in @system_one_decisions ->
        {:ok, evaluation}

      {:ok, evaluation} ->
        {:error, {:not_a_system_one_decision, evaluation.decision}}

      {:error, reason} ->
        {:error, {:banding_table, reason}}
    end
  end

  defp system_one(opts) do
    case Keyword.get_lazy(opts, :system_one, fn -> gate_config(:system_one) end) do
      false -> nil
      module -> module
    end
  end

  defp system_one_timeout(opts) do
    Keyword.get_lazy(opts, :system_one_timeout, fn ->
      gate_config(:system_one_timeout) || @system_one_timeout
    end)
  end

  defp system_one_table(opts),
    do:
      Keyword.get_lazy(opts, :system_one_table, fn -> Path.join(root(opts), @system_one_table) end)

  # The rung's banding table is verified with the rules tables when the rung
  # is configured and the table exists.
  defp system_one_tables(opts) do
    if system_one(opts), do: Enum.filter([system_one_table(opts)], &File.regular?/1), else: []
  end

  defp gate_config(key),
    do: :ash_agent_tools |> Application.get_env(:gate, []) |> Keyword.get(key)

  # ── configuration and audit ───────────────────────────────────────────────

  defp root(opts), do: Keyword.get_lazy(opts, :root, &File.cwd!/0)

  defp config(opts) do
    with {:ok, body} <- File.read(Path.join(root(opts), @config_file)),
         {:ok, %{} = config} <- Jason.decode(body) do
      config
    else
      _ -> %{}
    end
  end

  defp log(result, opts) do
    case Keyword.get(opts, :log, Path.join(root(opts), @log_file)) do
      false ->
        :ok

      path ->
        line = Jason.encode!(audit_line(result)) <> "\n"

        with :ok <- File.mkdir_p(Path.dirname(path)) do
          File.write(path, line, [:append])
        end

        :ok
    end
  end

  defp audit_line(result) do
    request = result.request || %{}

    %{
      at: DateTime.utc_now() |> DateTime.to_iso8601(),
      harness: request[:harness],
      session_id: request[:session_id],
      tool: request[:tool],
      command: request[:command],
      paths: request[:paths] || [],
      cwd: request[:cwd],
      repo_kind: get_in(request, [:repo, :kind]),
      decision: result.decision,
      rule_id: result.rule_id,
      reason: result.reason,
      table: result.table,
      definition_hash: result.definition_hash,
      matched_rule_ids: result.matched_rule_ids,
      evaluations:
        Enum.map(
          result.evaluations,
          &Map.take(&1, [:table, :definition_hash, :rule_id, :matched_rule_ids])
        ),
      rung: result.rung,
      system_one: result.system_one,
      duration_us: result.duration_us
    }
  end
end
