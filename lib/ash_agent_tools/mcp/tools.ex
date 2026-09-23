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
  defp more_tools("ash_daemon_status", args), do: daemon_tool("ash_daemon_status", args)
  defp more_tools("ash_reload", args), do: daemon_tool("ash_reload", args)

  defp more_tools(other, _args) do
    {:error,
     %{
       error: "unknown tool #{inspect(other)}",
       did_you_mean: Suggest.closest(other, tool_names())
     }}
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
