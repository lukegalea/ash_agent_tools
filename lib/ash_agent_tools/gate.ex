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
      Enum.map(tables(opts), fn path ->
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
        evaluate_request(request, tables(opts))
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
      request: nil
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
      duration_us: result.duration_us
    }
  end
end
