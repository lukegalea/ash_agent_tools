# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools do
  @moduledoc """
  Read-only Ash introspection for AI agents.

  `AshAgentTools` answers the questions an agent asks while composing Ash
  actions on your behalf: *what resources exist?* *what does this action
  accept?* *is this input valid?* *why was I forbidden?*

  ## Design constraints

  * **Read-only.** Every function is a pure function over already-loaded Ash
    modules. Nothing is written, executed, or committed: `validate_input/3`
    builds (and inspects) a changeset/query/action input but never runs it.
  * **No tool registration.** This package deliberately does *not* register
    MCP tools or any other editor/agent-side tool surface. The accepted
    pattern for agent-facing libraries is to ship plain, introspectable code
    plus `usage-rules.md`, and let agents compose it themselves (via
    `project_eval`, Livebook, or the bundled `mix ash_agent.*` tasks).
  * **Forward-compatible.** The API is plain data in, plain maps out. If a
    hosted tool-definition API settles upstream (e.g. Tidewave's exploration
    in PR #215), each function maps 1:1 onto a tool with a JSON input schema.

  ## Primary API

    * `list_domains/0` and `list_resources/0` — discover what is loaded
    * `describe_resource/1` — fields, relationships, actions, source locations
    * `describe_action/2` — accepted inputs, types, return shape, code interfaces
    * `validate_input/3` — cast and validate params without running anything
    * `explain_forbidden/2` — list the policies that can deny an action

  All functions raise `ArgumentError` when pointed at something that is not a
  loaded Ash resource (or an action that does not exist); discovery functions
  never raise.

  The typical consumer is an agent with code execution. The Mix tasks wrap the
  same functions for shell-only agents:

  ```
  $ mix ash_agent.describe MyApp.Post
  $ mix ash_agent.describe MyApp.Post --action create
  $ mix ash_agent.validate MyApp.Post create '{"title": "Hello"}'
  ```

  See `usage-rules.md` at the package root for agent-oriented guidance.
  """

  @doc """
  Lists the Ash domains of all currently loaded modules.

  Modules are discovered via the code server; modules that are compiled but
  never loaded are not visible. The bundled Mix tasks run your application
  first, and agents with a running node naturally have application modules
  loaded. Sorted, deduplicated, never raises.

  ## Examples

      iex> AshAgentTools.Test.Domain in AshAgentTools.list_domains()
      true

  """
  @spec list_domains() :: [module()]
  def list_domains, do: AshAgentTools.Registry.list_domains()

  @doc """
  Lists the Ash resources of all currently loaded modules.

  See `list_domains/0` for the discovery caveat. Sorted, deduplicated, never
  raises.

  ## Examples

      iex> AshAgentTools.list_resources() |> Enum.map(&AshAgentTools.Registry.module_name/1)
      ["AshAgentTools.Test.Author", "AshAgentTools.Test.Comment", "AshAgentTools.Test.Guarded", "AshAgentTools.Test.Post"]

  """
  @spec list_resources() :: [module()]
  def list_resources, do: AshAgentTools.Registry.list_resources()

  @doc """
  Describes an Ash resource: fields, relationships, and actions.

  Returns a plain (JSON-encodable) map. Attribute/relationship/action entries
  include source locations extracted from Spark annotations where available.

  Raises `ArgumentError` if the module is not a loaded Ash resource.

  ## Examples

      iex> AshAgentTools.describe_resource(AshAgentTools.Test.Post) |> Map.get(:primary_key)
      [:id]

      iex> action = AshAgentTools.describe_resource(AshAgentTools.Test.Post) |> Map.get(:actions) |> Enum.find(&(&1.name == :publish))
      iex> {action.type, action.accept}
      {:update, []}

  """
  @spec describe_resource(module()) :: map()
  def describe_resource(resource), do: AshAgentTools.Describe.describe_resource(resource)

  @doc """
  Describes a single action on an Ash resource.

  Includes the accepted input contract (required vs optional keys with
  normalized types), the return shape, and any code interfaces that call the
  action. Raises `ArgumentError` for unknown resources or actions.

  ## Examples

      iex> action = AshAgentTools.describe_action(AshAgentTools.Test.Post, :create)
      iex> action.input.required
      [:title]
      iex> action.returns.kind
      :record

  """
  @spec describe_action(module(), atom() | String.t()) :: map()
  def describe_action(resource, action_name),
    do: AshAgentTools.Describe.describe_action(resource, action_name)

  @doc """
  Validates `params` against a resource action *without executing anything*.

  Each provided value is cast with `Ash.Type.cast_input/3` (the same machinery
  Ash itself uses), unknown keys and missing required keys are reported, and a
  changeset/query/action-input is built with `error?: false` purely to surface
  framework-level build errors. The subject is never run: no action executes,
  nothing touches a data layer.

  Returns a report map (JSON-encodable). Always returns the report — check
  `report.valid?`.

  ## Examples

      iex> report = AshAgentTools.validate_input(AshAgentTools.Test.Post, :create, %{"title" => "Hi", "score" => "7"})
      iex> {report.valid?, report.normalized_inputs["score"]}
      {true, 7}

      iex> report = AshAgentTools.validate_input(AshAgentTools.Test.Post, :create, %{"score" => "not a number"})
      iex> {report.valid?, report.normalized_inputs["score"]}
      {false, nil}

  """
  @spec validate_input(module(), atom() | String.t(), map()) :: map()
  def validate_input(resource, action_name, params \\ %{}),
    do: AshAgentTools.Validate.validate_input(resource, action_name, params)

  @doc """
  Explains what could forbid an action: the resource's authorization policies.

  This is a guidance stub rather than an evaluator: it lists policies and
  field policies in human-readable form (via `Ash.Policy.Check.describe/2`)
  and attaches general hints an agent can reason from. Determining an actual
  verdict requires an actor and a query/changeset — use `Ash.can?/3` for that.

  ## Examples

      iex> report = AshAgentTools.explain_forbidden(AshAgentTools.Test.Guarded, :read)
      iex> report.policies |> length()
      2

      iex> report = AshAgentTools.explain_forbidden(AshAgentTools.Test.Guarded, :read)
      iex> Enum.any?(report.policies, &(&1.bypass? == true))
      true

  """
  @spec explain_forbidden(module(), atom() | String.t() | nil) :: map()
  def explain_forbidden(resource, action_name \\ nil),
    do: AshAgentTools.Forbidden.explain_forbidden(resource, action_name)
end
