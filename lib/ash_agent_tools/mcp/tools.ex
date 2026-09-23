# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Mcp.Tools do
  @moduledoc """
  The MCP tool surface: the facade functions mapped 1:1 onto tools with JSON
  input schemas (the moduledoc's forward-compatibility promise, realized).

  Every tool is a thin adapter over the `AshAgentTools` facade or the
  `AshAgentTools.Daemon.Runtime` cache (used when the daemon runtime is
  alive, so repeated calls hit the checksum-keyed cache):

  | Tool | Backing call |
  |---|---|
  | `ash_describe` | `describe_resource/1` / `describe_action/2`; no args → discovery summary |
  | `ash_validate` | `validate_input/3` — validate-by-casting without executing |
  | `ash_can` | `can/4` — actor-aware policy verdicts, no execution |
  | `ash_search` | `semantic_search/2` |
  | `ash_context` | `context/3` — the grep → read → re-grep collapse |
  | `ash_forbidden` | `explain_forbidden/2` — the static policy listing |
  | `ash_rules` | `rule_sets/0` / `evaluate_rules/3` — optional `ash_rules` tooling |
  | `ash_transitions` | `transitions/2` — optional `ash_state_machine` tooling |
  | `ash_processes` | `processes/2` — optional `ash_bpmn`: definitions per key |
  | `ash_process_graph` | `process_graph/2` — one definition's compiled graph |
  | `ash_process_instance` | `process_instance/1` — in-flight state, read-only |
  | `ash_decisions` | `decisions/2` — optional `ash_decisions`: the catalogue |
  | `ash_decision_evaluate` | `decision_evaluate/3` — dry evaluation, `record: false` |
  | `ash_daemon_status` | `AshAgentTools.Daemon.Runtime.status/1` |
  | `ash_reload` | `AshAgentTools.Daemon.Runtime.request_reload/2` |

  `ash_diff` is deliberately deferred: it reads semantic-manifest files the
  RFC exporter does not emit yet (`mix ash.manifest.dump --semantic` is
  future work). All tools are read-only: nothing executes, nothing writes.

  Failures follow the mix tasks' structured-error pattern: a bad resource,
  action, or search term becomes
  `{:error, %{error: message, did_you_mean: candidates}}` — never a raised
  crash out of the daemon.
  """

  alias AshAgentTools.Describe
  alias AshAgentTools.Registry
  alias AshAgentTools.Suggest

  @valid_kind_strings Map.new(AshAgentTools.Search.valid_kinds(), fn kind ->
                        {Atom.to_string(kind), kind}
                      end)

  @typedoc "A tool result: the report map, or the structured error."
  @type result ::
          {:ok, map() | [map()]} | {:error, %{error: String.t(), did_you_mean: [String.t()]}}

  @typedoc false
  @type structured :: {:error, %{error: String.t(), did_you_mean: [String.t()]}}

  @doc """
  The tool cards served by `tools/list`: name, description, and JSON Schema
  input schemas.
  """
  @spec tool_cards() :: [map()]
  def tool_cards do
    [
      card(
        "ash_describe",
        "Describe Ash resources and actions: fields, relationships, actions, " <>
          "the arguments and input contract each action accepts, types, and " <>
          "source locations. With no arguments, returns the discovery summary " <>
          "(loaded domains and resources). Read-only.",
        %{
          "resource" => %{
            type: "string",
            description:
              "Resource module name, e.g. \"MyApp.Post\". Omit for the discovery summary."
          },
          "action" => %{
            type: "string",
            description: "Action name to describe a single action's input contract."
          }
        },
        []
      ),
      card(
        "ash_validate",
        "Validate params against an Ash resource action WITHOUT executing it: " <>
          "casts every value the way Ash does, reports unknown/missing keys and " <>
          "cast errors. Nothing runs, nothing touches a data layer.",
        %{
          "resource" => %{
            type: "string",
            description: "Resource module name, e.g. \"MyApp.Post\"."
          },
          "action" => %{type: "string", description: "Action name, e.g. \"create\"."},
          "params" => %{
            type: "object",
            description: "The input to validate (JSON object). Defaults to {}.",
            additionalProperties: true
          }
        },
        ["resource", "action"]
      ),
      card(
        "ash_can",
        "Answer whether an actor can perform an Ash action — a policy " <>
          "verdict WITHOUT executing anything: resolves the actor record, " <>
          "builds the changeset/query, and evaluates it with Ash.can/3 " <>
          "(run_queries? disabled, so data-dependent checks come back as " <>
          "a maybe verdict).",
        %{
          "resource" => %{type: "string", description: "Resource module name."},
          "action" => %{type: "string", description: "Action name, e.g. \"create\"."},
          "actor" => %{
            description:
              "The actor: none (default), MODULE:ID, an object with resource " <>
                "and id keys, or record (the target record acts)."
          },
          "params" => %{
            type: "object",
            description: "Optional input the changeset/query would carry.",
            additionalProperties: true
          },
          "record" => %{
            type: "string",
            description:
              "Target record id for update/destroy actions (default: the actor's own record)."
          }
        },
        ["resource", "action"]
      ),
      card(
        "ash_search",
        "Search attributes, actions, calculations, and relationships across all " <>
          "loaded Ash resources by name substring (case-insensitive).",
        %{
          "term" => %{type: "string", description: "Name substring to search for."},
          "kinds" => %{
            type: "array",
            description: "Restrict the search to these symbol kinds.",
            items: %{
              type: "string",
              enum: Enum.map(AshAgentTools.Search.valid_kinds(), &Atom.to_string/1)
            }
          }
        },
        ["term"]
      ),
      card(
        "ash_context",
        "The Ash context for a file position: which loaded Ash resource/domain " <>
          "declares there, which symbol's span covers the line, and what " <>
          "references it. One call replaces the grep → read → re-grep loop.",
        %{
          "file" => %{type: "string", description: "Repo-relative (or absolute) file path."},
          "line" => %{type: "integer", description: "1-based line number."}
        },
        ["file", "line"]
      ),
      card(
        "ash_forbidden",
        "Explain what could forbid an Ash action: the resource's authorization " <>
          "policies in human-readable form. Guidance, not verdicts — use Ash.can? " <>
          "with a real actor for an actual decision.",
        %{
          "resource" => %{type: "string", description: "Resource module name."},
          "action" => %{
            type: "string",
            description: "Action name (optional; all policies when omitted)."
          }
        },
        ["resource"]
      ),
      card(
        "ash_rules",
        "AshRules rule-set tooling (requires the optional ash_rules dep; " <>
          "otherwise returns the structured install hint). No arguments: " <>
          "list every loaded rule set with fact schemas and rules. With " <>
          "module/bundle and facts: DRY-evaluate the bundle against fact " <>
          "triples and return the full result — pure evaluation, zero host state.",
        %{
          "module" => %{
            type: "string",
            description:
              "Rule set module name. Omit to list all loaded rule sets (unless bundle is given)."
          },
          "bundle" => %{
            type: "string",
            description: "Path to a bundle JSON document (alternative to module)."
          },
          "facts" => %{
            type: "array",
            description:
              "Fact triples for dry evaluation: objects with subject, predicate and " <>
                "value keys, or [subject, predicate, value] arrays.",
            items: %{}
          }
        },
        []
      ),
      card(
        "ash_transitions",
        "Describe an AshStateMachine resource: states, transitions " <>
          "(action/from/to), initial states, and the extension's own Mermaid " <>
          "stateDiagram/flowchart. Requires the optional ash_state_machine dep " <>
          "(otherwise returns the structured install hint).",
        %{
          "resource" => %{type: "string", description: "Resource module name."},
          "mermaid" => %{
            type: "boolean",
            description: "Generate the Mermaid diagrams (default true)."
          }
        },
        ["resource"]
      ),
      card(
        "ash_processes",
        "List BPMN process definitions per key (requires the optional " <>
          "ash_bpmn dep; otherwise returns the structured install hint). " <>
          "Per key: representative version, status, content hash, draft " <>
          "flag, stored error count, latest published version. The raw xml " <>
          "is never returned. Read-only.",
        %{
          "domain" => %{
            type: "string",
            description: "Domain module name. Omit to scan all engine domains."
          },
          "key" => %{type: "string", description: "Restrict to one process key."}
        },
        []
      ),
      card(
        "ash_process_graph",
        "One BPMN definition's compiled graph: nodes, flows, joins, " <>
          "boundaries, plus per-element occupancy digests (requires the " <>
          "optional ash_bpmn dep). An uncompiled draft renders its stored " <>
          "compile errors instead of a graph. Read-only.",
        %{
          "key" => %{type: "string", description: "Process key."},
          "version" => %{
            type: "integer",
            description: "Pin one version (default: latest published)."
          },
          "draft" => %{
            type: "boolean",
            description: "Look at the key's draft instead (default false)."
          },
          "domain" => %{type: "string", description: "Domain module name."},
          "include_elements" => %{
            type: "boolean",
            description: "Include the per-element occupancy digests (default true)."
          }
        },
        ["key"]
      ),
      card(
        "ash_process_instance",
        "What is in flight in the BPMN engine: instances, their tokens " <>
          "(interpreted against the pinned definition), and open human tasks " <>
          "with candidates. Correlation keys stay digested unless explicitly " <>
          "requested. Read-only: nothing is completed or advanced (requires " <>
          "the optional ash_bpmn dep).",
        %{
          "instance_id" => %{type: "string", description: "One instance."},
          "subject_type" => %{type: "string", description: "Instances of this subject type."},
          "subject_id" => %{type: "string", description: "With subject_type: pin the subject."},
          "definition_key" => %{type: "string", description: "Instances of one process key."},
          "statuses" => %{
            type: "array",
            description: "Instance statuses to include (default [running]).",
            items: %{
              type: "string",
              enum: ["running", "completed", "failed", "errored", "cancelled", "superseded"]
            }
          },
          "include_children" => %{
            type: "boolean",
            description: "Follow call-activity children (default true)."
          },
          "include_correlation_keys" => %{
            type: "boolean",
            description: "Emit correlation keys in the clear (default false — digested)."
          },
          "actor" => %{type: "string", description: "Actor as MODULE:ID (reads thread it)."},
          "scope" => %{
            type: "string",
            enum: ["engine"],
            description: "Force the engine scope even with an actor given."
          }
        },
        []
      ),
      card(
        "ash_decisions",
        "List DMN decision definitions per key: the AshDecisions.Catalogue " <>
          "projection — status, draft flag, latest published version, and the " <>
          "decisions each document declares (requires the optional " <>
          "ash_decisions dep). Stored verification available per request; the " <>
          "Verifier is not re-run. Read-only.",
        %{
          "domain" => %{
            type: "string",
            description: "Domain module name. Omit to scan all decision domains."
          },
          "key" => %{type: "string", description: "Restrict to one decision key."},
          "graph" => %{
            type: "boolean",
            description: "Include the stored graph snapshot of the representative document."
          },
          "verification" => %{
            type: "boolean",
            description: "Include the stored publish-time verification attribute as-is."
          }
        },
        []
      ),
      card(
        "ash_decision_evaluate",
        "Dry-evaluate a DMN decision against inputs — a designer preview " <>
          "with record: false hard-coded, so no Evaluation row is ever " <>
          "written (requires the optional ash_decisions dep). Published by " <>
          "default; drafts only via the explicit draft flag.",
        %{
          "key" => %{type: "string", description: "Decision definition key."},
          "inputs" => %{
            type: "object",
            description: "The decision inputs (JSON object).",
            additionalProperties: true
          },
          "decision" => %{
            type: "string",
            description: "Decision name, when the document declares more than one."
          },
          "version" => %{
            type: "integer",
            description: "Pin one version (default: latest published)."
          },
          "draft" => %{
            type: "boolean",
            description: "Evaluate the key's draft instead (default false)."
          },
          "domain" => %{type: "string", description: "Domain module name."}
        },
        ["key", "inputs"]
      ),
      card(
        "ash_daemon_status",
        "The daemon's own status: boot/compile times, reload count, loaded " <>
          "domain and resource counts, describe-cache size, BEAM memory.",
        %{},
        []
      ),
      card(
        "ash_reload",
        "Manually reload the compiled context: re-run the compile-only boot, " <>
          "refresh discovery, invalidate caches. The backstop when the file " <>
          "watcher missed a change.",
        %{},
        []
      )
    ]
  end

  @doc """
  The tool names served, as strings.
  """
  @spec tool_names() :: [String.t()]
  def tool_names, do: Enum.map(tool_cards(), & &1.name)

  @doc """
  Dispatches a `tools/call`: `{"name" => tool, "arguments" => args}` (JSON,
  string keys) to the facade. Returns `{:ok, report}` or the structured
  error tuple. Never raises.
  """
  @spec call(String.t() | term(), map() | nil | term()) :: result()
  def call(name, args) when is_binary(name) and is_map(args) do
    dispatch(name, args)
  rescue
    # Facade-layer failures (unknown action, blank search term, ...) carry
    # no resolution context at this level, so candidates are empty here —
    # the resolution-aware paths below enrich their own errors.
    error in ArgumentError ->
      {:error, %{error: Exception.message(error), did_you_mean: []}}
  end

  def call(name, _args),
    do:
      {:error,
       %{
         error:
           "tool name and arguments must be provided (name must be a string, arguments an object)",
         did_you_mean: Suggest.closest(if(is_binary(name), do: name, else: ""), tool_names())
       }}

  defp dispatch(name, args) do
    case name do
      "ash_describe" ->
        describe(args)

      "ash_validate" ->
        validate(args)

      "ash_search" ->
        search(args)

      "ash_context" ->
        context(args)

      "ash_forbidden" ->
        forbidden(args)

      _other ->
        more_tools(name, args)
    end
  end

  # The newer/daemon-only tools, split out of dispatch/2 to keep each case
  # flat.
  defp more_tools("ash_can", args), do: can(args)
  defp more_tools("ash_rules", args), do: rules(args)
  defp more_tools("ash_transitions", args), do: transitions(args)

  defp more_tools("ash_processes", args), do: processes(args)
  defp more_tools("ash_process_graph", args), do: process_graph(args)
  defp more_tools("ash_process_instance", args), do: process_instance(args)
  defp more_tools("ash_decisions", args), do: decisions(args)
  defp more_tools("ash_decision_evaluate", args), do: decision_evaluate(args)

  defp more_tools("ash_daemon_status", args), do: daemon_tool("ash_daemon_status", args)
  defp more_tools("ash_reload", args), do: daemon_tool("ash_reload", args)

  defp more_tools(other, _args) do
    {:error,
     %{
       error: "unknown tool #{inspect(other)}",
       did_you_mean: Suggest.closest(other, tool_names())
     }}
  end

  # The list-shaped tools: a domain argument is optional, an empty report is
  # a valid answer.
  defp processes(args) do
    with {:ok, domain} <- optional_resource(args["domain"]) do
      {:ok, AshAgentTools.processes(domain, key: args["key"])}
    end
  end

  defp decisions(args) do
    with {:ok, domain} <- optional_resource(args["domain"]) do
      {:ok,
       AshAgentTools.decisions(domain,
         key: args["key"],
         graph: args["graph"] == true,
         verification: args["verification"] == true
       )}
    end
  end

  defp process_graph(%{} = args) do
    with {:ok, key} <- required_string(args["key"], "key") do
      safely(nil, nil, fn ->
        AshAgentTools.process_graph(key,
          version: args["version"],
          draft: args["draft"] == true,
          domain: args["domain"],
          include_elements: args["include_elements"] != false
        )
      end)
    end
  end

  defp process_instance(args) do
    with {:ok, statuses} <- statuses(args["statuses"]),
         {:ok, actor} <- optional_actor(args["actor"]),
         {:ok, scope} <- scope(args["scope"]) do
      {:ok,
       AshAgentTools.process_instance(
         instance_id: args["instance_id"],
         subject_type: args["subject_type"],
         subject_id: args["subject_id"],
         definition_key: args["definition_key"],
         statuses: statuses,
         include_children: args["include_children"] != false,
         include_correlation_keys: args["include_correlation_keys"] == true,
         actor: actor,
         scope: scope
       )}
    end
  end

  defp statuses(nil), do: {:ok, nil}

  defp statuses(statuses) when is_list(statuses) do
    Enum.reduce_while(statuses, {:ok, []}, fn
      status, {:ok, acc} when is_binary(status) ->
        {:cont, {:ok, [status | acc]}}

      other, _acc ->
        {:halt,
         {:error, %{error: "statuses must be strings, got: #{inspect(other)}", did_you_mean: []}}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = error -> error
    end
  end

  defp statuses(other),
    do: {:error, %{error: "statuses must be an array, got: #{inspect(other)}", did_you_mean: []}}

  defp optional_actor(nil), do: {:ok, nil}
  defp optional_actor("none"), do: {:ok, nil}

  defp optional_actor(actor) when is_binary(actor) do
    case String.split(actor, ":", parts: 2) do
      [resource, id] ->
        {:ok, %{"resource" => resource, "id" => id}}

      _ ->
        {:error,
         %{error: "actor must be MODULE:ID or none, got: #{inspect(actor)}", did_you_mean: []}}
    end
  end

  defp optional_actor(other),
    do: {:error, %{error: "actor must be a string, got: #{inspect(other)}", did_you_mean: []}}

  defp scope(nil), do: {:ok, nil}
  defp scope("engine"), do: {:ok, :engine}

  defp scope(other),
    do: {:error, %{error: "scope must be \"engine\", got: #{inspect(other)}", did_you_mean: []}}

  defp decision_evaluate(%{} = args) do
    with {:ok, key} <- required_string(args["key"], "key"),
         :ok <- check_params(args["inputs"]) do
      safely(nil, nil, fn ->
        AshAgentTools.decision_evaluate(key, args["inputs"] || %{},
          decision: args["decision"],
          version: args["version"],
          draft: args["draft"] == true,
          domain: args["domain"]
        )
      end)
    end
  end

  # The daemon-only pair, split out of dispatch/2 to keep each case flat.
  defp daemon_tool("ash_daemon_status", _args) do
    case runtime_server() do
      nil ->
        {:ok,
         %{
           status: :no_runtime,
           hint: "the daemon runtime is not started; run mix ash_agent.serve"
         }}

      server ->
        {:ok, AshAgentTools.Daemon.Runtime.status(server)}
    end
  end

  defp daemon_tool("ash_reload", _args) do
    case runtime_server() do
      nil ->
        {:error,
         %{
           error: "the daemon runtime is not started",
           did_you_mean: [],
           hint: "ash_reload only works inside mix ash_agent.serve"
         }}

      server ->
        {:ok, AshAgentTools.Daemon.Runtime.request_reload(server)}
    end
  end

  defp daemon_tool(other, _args) do
    {:error,
     %{
       error: "unknown tool #{inspect(other)}",
       did_you_mean: Suggest.closest(other, tool_names())
     }}
  end

  # -- tools ---------------------------------------------------------------

  defp describe(%{} = args) do
    with {:ok, resource} <- optional_resource(args["resource"]),
         {:ok, action} <- optional_string(args["action"], "action") do
      case {resource, action} do
        {nil, _} ->
          {:ok, daemon_discovery()}

        {module, nil} ->
          facade_describe(module, nil)

        {module, action} ->
          facade_describe(module, action)
      end
    end
  end

  defp validate(%{} = args) do
    with {:ok, module} <- required_resource(args["resource"]),
         {:ok, action} <- required_string(args["action"], "action"),
         :ok <- check_params(args["params"]) do
      params = args["params"] || %{}

      safely(module, action, fn -> AshAgentTools.validate_input(module, action, params) end)
    end
  end

  defp search(%{} = args) do
    with {:ok, term} <- required_string(args["term"], "term"),
         {:ok, opts} <- kinds_opts(args["kinds"]) do
      {:ok, AshAgentTools.semantic_search(term, opts)}
    end
  end

  defp context(%{} = args) do
    with {:ok, file} <- required_string(args["file"], "file"),
         {:ok, line} <- required_line(args["line"]) do
      {:ok, report} = AshAgentTools.context(file, line)
      {:ok, report}
    end
  end

  defp forbidden(%{} = args) do
    with {:ok, module} <- required_resource(args["resource"]) do
      safely(module, args["action"], fn ->
        AshAgentTools.explain_forbidden(module, args["action"])
      end)
    end
  end

  defp can(%{} = args) do
    with {:ok, module} <- required_resource(args["resource"]),
         {:ok, action} <- required_string(args["action"], "action"),
         {:ok, actor} <- parse_actor(args["actor"]),
         {:ok, record} <- optional_record(args["record"]),
         :ok <- check_params(args["params"]) do
      safely(module, action, fn ->
        AshAgentTools.Can.can(module, action, actor, args["params"] || %{}, record: record)
      end)
    end
  end

  # Modes: no arguments → list every loaded rule set; `module` → one
  # bundle report; `module`/`bundle` + `facts` → dry evaluation. One clause
  # per mode keeps each branch flat.
  defp rules(%{"module" => module, "bundle" => bundle})
       when module != nil and bundle != nil do
    {:error, %{error: "pass either \"module\" or \"bundle\", not both", did_you_mean: []}}
  end

  defp rules(%{"module" => module, "facts" => facts} = args)
       when module != nil and facts != nil do
    rules_eval(module, nil, args)
  end

  defp rules(%{"bundle" => bundle, "facts" => facts} = args)
       when bundle != nil and facts != nil do
    rules_eval(nil, bundle, args)
  end

  defp rules(%{"facts" => _facts}) do
    {:error,
     %{
       error: "dry evaluation needs \"module\" (rule set module) or \"bundle\" (file path)",
       did_you_mean: []
     }}
  end

  defp rules(%{"bundle" => bundle}) when bundle != nil do
    {:error,
     %{
       error: "\"bundle\" is only read for dry evaluation — pass \"facts\" too",
       did_you_mean: []
     }}
  end

  defp rules(%{"module" => module}) when module != nil do
    with {:ok, module} <- required_resource(module) do
      safely(module, nil, fn -> AshAgentTools.Rules.describe(module) end)
    end
  end

  defp rules(_args), do: {:ok, AshAgentTools.rule_sets()}

  defp rules_eval(module, bundle, args) do
    with {:ok, subject} <- rules_subject(module, bundle),
         {:ok, triples} <- parse_facts(args["facts"]) do
      safely(subject, nil, fn -> AshAgentTools.evaluate_rules(subject, triples) end)
    end
  end

  # A string "module" is a rule set module name (resolved to its atom); a
  # "bundle" stays a path — the impl reads the document itself.
  defp rules_subject(module, _bundle) when is_binary(module) do
    case required_resource(module) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, _} = error -> error
    end
  end

  defp rules_subject(_module, bundle) when is_binary(bundle), do: {:ok, bundle}

  defp rules_subject(module, _bundle),
    do:
      {:error, %{error: "\"module\" must be a string, got: #{inspect(module)}", did_you_mean: []}}

  # JSON fact triples → {subject, predicate, value} terms; decoding and
  # validation is the impl's job (schema-typed value conversion included).
  defp parse_facts(facts) when is_list(facts), do: {:ok, facts}

  defp parse_facts(other),
    do:
      {:error,
       %{error: "\"facts\" must be an array of triples, got: #{inspect(other)}", did_you_mean: []}}

  defp transitions(%{} = args) do
    with {:ok, module} <- required_resource(args["resource"]) do
      safely(module, nil, fn ->
        AshAgentTools.transitions(module, mermaid: args["mermaid"] != false)
      end)
    end
  end

  # -- argument plumbing -----------------------------------------------------

  # An absent resource argument is legal (it selects the discovery summary);
  # a present one must resolve to a loaded Ash module.
  defp optional_resource(nil), do: {:ok, nil}

  defp optional_resource(name), do: required_resource(name)

  defp required_resource(name) when is_binary(name) do
    module = Module.concat([name])

    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        {:ok, module}

      {:error, _reason} ->
        {:error,
         %{
           error: "Cannot load #{inspect(name)}: not a loaded module. #{resource_hint(name)}",
           did_you_mean: resource_did_you_mean(name)
         }}
    end
  end

  defp required_resource(other) do
    {:error,
     %{error: "resource must be a string module name, got: #{inspect(other)}", did_you_mean: []}}
  end

  defp required_string(value, _key) when is_binary(value), do: {:ok, value}

  defp required_string(nil, key),
    do: {:error, %{error: "a string \"#{key}\" argument is required", did_you_mean: []}}

  defp required_string(other, key),
    do:
      {:error,
       %{
         error: "\"#{key}\" must be a string, got: #{inspect(other)}",
         did_you_mean: []
       }}

  defp optional_string(nil, _key), do: {:ok, nil}
  defp optional_string(value, _key) when is_binary(value), do: {:ok, value}

  defp optional_string(other, key),
    do:
      {:error, %{error: "\"#{key}\" must be a string, got: #{inspect(other)}", did_you_mean: []}}

  defp required_line(line) when is_integer(line) and line > 0, do: {:ok, line}

  defp required_line(other),
    do:
      {:error,
       %{error: "\"line\" must be a positive integer, got: #{inspect(other)}", did_you_mean: []}}

  defp check_params(nil), do: :ok
  defp check_params(params) when is_map(params), do: :ok

  defp check_params(other),
    do:
      {:error, %{error: "\"params\" must be an object, got: #{inspect(other)}", did_you_mean: []}}

  # The MCP spelling of the facade's actor spec: absent/"none" → :none,
  # "MODULE:ID"/{"resource","id"} → that spec, "record" → :record.
  defp parse_actor(nil), do: {:ok, :none}
  defp parse_actor("none"), do: {:ok, :none}
  defp parse_actor("record"), do: {:ok, :record}

  defp parse_actor(actor) when is_binary(actor) do
    case String.split(actor, ":", parts: 2) do
      [resource, id] -> {:ok, %{"resource" => resource, "id" => id}}
      _ -> {:error, actor_spec_error(actor)}
    end
  end

  defp parse_actor(%{"resource" => resource, "id" => id} = spec)
       when is_binary(resource) and (is_binary(id) or is_number(id)),
       do: {:ok, Map.take(spec, ["resource", "id"])}

  defp parse_actor(other), do: {:error, actor_spec_error(other)}

  defp actor_spec_error(other) do
    %{
      error:
        "actor must be none, record, MODULE:ID, or an object with resource " <>
          "and id keys, got: #{inspect(other)}",
      did_you_mean: []
    }
  end

  defp optional_record(nil), do: {:ok, nil}
  defp optional_record(record) when is_binary(record), do: {:ok, record}

  defp optional_record(other),
    do:
      {:error,
       %{error: "\"record\" must be a string id, got: #{inspect(other)}", did_you_mean: []}}

  defp kinds_opts(nil), do: {:ok, []}

  defp kinds_opts(kinds) when is_list(kinds) do
    # JSON gives strings; check each against the known kinds so the
    # structured unknown-kind error is precise (not an atom-table miss).
    result =
      Enum.reduce_while(kinds, {:ok, []}, fn
        kind, {:ok, acc} when is_binary(kind) ->
          case Map.fetch(@valid_kind_strings, kind) do
            {:ok, atom} -> {:cont, {:ok, [atom | acc]}}
            :error -> {:halt, {:error, unknown_kind_error(kind)}}
          end

        other, _acc ->
          {:halt,
           {:error,
            %{error: "search kinds must be strings, got: #{inspect(other)}", did_you_mean: []}}}
      end)

    case result do
      {:ok, atoms} -> {:ok, [kinds: Enum.reverse(atoms)]}
      {:error, _} = error -> error
    end
  end

  defp kinds_opts(other),
    do:
      {:error,
       %{error: "\"kinds\" must be an array of strings, got: #{inspect(other)}", did_you_mean: []}}

  defp unknown_kind_error(kind) do
    %{
      error:
        "unknown search kind #{inspect(kind)}. Valid kinds: #{inspect(AshAgentTools.Search.valid_kinds())}",
      did_you_mean: Suggest.closest(kind, Map.keys(@valid_kind_strings))
    }
  end

  # -- facade + runtime plumbing ----------------------------------------------

  defp facade_describe(module, action) do
    case runtime_server() do
      nil ->
        safely(module, action, fn ->
          case action do
            nil -> AshAgentTools.describe_resource(module)
            action -> AshAgentTools.describe_action(module, action)
          end
        end)

      server ->
        AshAgentTools.Daemon.Runtime.describe(server, module, action)
    end
  end

  # Run a facade call; on the expected ArgumentError (unknown action), attach
  # did_you_mean candidates from the real action list — the enriched
  # structured-error shape the mix tasks emit.
  defp safely(module, action, fun) do
    {:ok, fun.()}
  rescue
    error in ArgumentError ->
      {:error,
       %{error: Exception.message(error), did_you_mean: action_did_you_mean(module, action)}}
  end

  defp action_did_you_mean(_module, action) when is_nil(action), do: []

  defp action_did_you_mean(module, action) when is_binary(action) or is_atom(action),
    do: Describe.action_did_you_mean(module, action)

  defp action_did_you_mean(_module, _other), do: []

  defp runtime_server do
    case GenServer.whereis(AshAgentTools.Daemon.Runtime) do
      nil -> nil
      pid when is_pid(pid) -> AshAgentTools.Daemon.Runtime
    end
  end

  defp daemon_discovery do
    case runtime_server() do
      nil -> discovery_summary()
      server -> AshAgentTools.Daemon.Runtime.discovery(server)
    end
  end

  defp discovery_summary do
    %{
      domain_count: length(AshAgentTools.list_domains()),
      resource_count: length(AshAgentTools.list_resources()),
      domains: Enum.map(AshAgentTools.list_domains(), &Registry.module_name/1),
      resources: Enum.map(AshAgentTools.list_resources(), &Registry.module_name/1)
    }
  end

  # An exact short-name hit ("Post") most likely means the agent used the
  # short name where the full module is needed — suggest that directly.
  defp resource_did_you_mean(name) do
    target = String.downcase(name)

    short_pairs =
      Map.new(AshAgentTools.list_resources(), fn resource ->
        short = resource |> Ash.Resource.Info.short_name() |> to_string() |> String.downcase()

        {short, Registry.module_name(resource)}
      end)

    case Map.fetch(short_pairs, target) do
      {:ok, full_name} -> [full_name]
      :error -> Suggest.closest(name, Map.values(short_pairs))
    end
  end

  defp resource_hint(name) do
    target = String.downcase(name)

    if Enum.any?(AshAgentTools.list_resources(), fn resource ->
         resource |> Ash.Resource.Info.short_name() |> to_string() |> String.downcase() == target
       end) do
      "A resource with that short name is loaded — use its full module name."
    else
      "No loaded Ash resources matched."
    end
  end

  defp card(name, description, properties, required) do
    %{
      name: name,
      description: description,
      inputSchema: %{
        type: "object",
        properties: properties,
        required: required,
        additionalProperties: false
      }
    }
  end
end
