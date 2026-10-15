# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Mcp.Cards do
  @moduledoc """
  The tool cards: each tool's name, description, and JSON Schema input
  schema, in one place.

  Every surface that serves these tools reads its cards from here: the
  `mix ash_agent.serve` daemon (through `AshAgentTools.Mcp.Tools`), the
  serve task's banner and docs, and the optional ash_ai adapter. The
  descriptions are tuned against the trigger eval in `eval/trigger_eval`,
  so a wording change here changes what agents pick on every surface at
  once. Rerun the eval after one.
  """

  @typedoc "A tool card, shaped like an MCP `tools/list` entry."
  @type card :: %{name: String.t(), description: String.t(), inputSchema: map()}

  @doc """
  Every tool card, in the order `tools/list` serves them.
  """
  @spec all() :: [card()]
  def all do
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
          "policies in human-readable form. Guidance, not verdicts — use ash_can " <>
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
  The tool names, as strings, in card order.
  """
  @spec names() :: [String.t()]
  def names, do: Enum.map(all(), & &1.name)

  @doc """
  The card for one tool name. Raises `KeyError` for an unknown name.
  """
  @spec fetch!(String.t()) :: card()
  def fetch!(name) when is_binary(name) do
    case Enum.find(all(), &(&1.name == name)) do
      nil -> raise KeyError, key: name, term: names()
      card -> card
    end
  end

  @doc """
  The description of one tool.
  """
  @spec description(String.t()) :: String.t()
  def description(name), do: fetch!(name).description

  @doc """
  The JSON Schema input schema of one tool.
  """
  @spec input_schema(String.t()) :: map()
  def input_schema(name), do: fetch!(name).inputSchema

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
