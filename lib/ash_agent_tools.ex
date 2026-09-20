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
    * `semantic_search/2` — find symbols by name substring across resources
    * `diff_manifest/2` — structural diff of two semantic-manifest JSON files
   * `context/3` — the Ash resource/symbol at a file position, plus what
     references it (collapses the grep → read → re-grep loop into one call)
   * `explain_trace/2` — the budget-bounded reduction of an OTel span list
     (errors innermost first, queries with N+1 detection, policies,
     notifications, async, symbols)
   * `resolve/1` — name-path addressing over DSL entities
     (`MyApp.Post/actions/by_tag`, `.../policies/policy[0]`), with spans,
     provenance, and shape digests — the addressing layer for
     `AshAgentTools.Edit`'s semantic edit operations
   * `eval_docs/0` — the exact snippets for using this API in-VM, without a
     mix boot, when your session is already attached to a running node

  All functions raise `ArgumentError` when pointed at something that is not a
  loaded Ash resource (or an action that does not exist); discovery functions
  never raise.

  The typical consumer is an agent with code execution. The Mix tasks wrap the
  same functions for shell-only agents:

  ```
  $ mix ash_agent.describe MyApp.Post
  $ mix ash_agent.describe MyApp.Post --action create
  $ mix ash_agent.validate MyApp.Post create '{"title": "Hello"}'
  $ mix ash_agent.search tag
  $ mix ash_agent.diff old.json new.json
  $ mix ash_agent.context lib/my_app/accounts/post.ex:42
  $ mix ash_agent.runtime snapshot   # also: top 20 | tree MyApp
  $ mix ash_agent.gaps               # the kaizen tool-gap digest
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

      iex> resources = AshAgentTools.list_resources() |> Enum.map(&AshAgentTools.Registry.module_name/1)
      iex> Enum.all?(["AshAgentTools.Test.Author", "AshAgentTools.Test.Comment", "AshAgentTools.Test.ContextProbe", "AshAgentTools.Test.Guarded", "AshAgentTools.Test.Post"], &(&1 in resources))
      true

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

  @doc """
  Searches attributes, actions, calculations, and relationships across all
  loaded Ash resources by name substring.

  Returns a sorted, JSON-encodable list of hits — each with the declaring
  `resource`, symbol `kind`, `name`, normalized `type`, and best-effort
  Spark `source` location. Matching is case-insensitive on the symbol name;
  pass `kinds:` to restrict the search (see `AshAgentTools.Search.semantic_search/2`
  for the full contract). Raises `ArgumentError` for a blank term or an
  unknown kind in the filter.

  ## Examples

      iex> results = AshAgentTools.semantic_search("tag")
      iex> hit = Enum.find(results, &(&1.resource == AshAgentTools.Test.Post and &1.kind == :action and &1.name == :by_tag))
      iex> hit.type
      :read

      iex> results = AshAgentTools.semantic_search("score", kinds: [:attribute])
      iex> Enum.map(results, & &1.type)
      ["integer"]

  """
  @spec semantic_search(String.t(), keyword()) :: [map()]
  def semantic_search(term, opts \\ []), do: AshAgentTools.Search.semantic_search(term, opts)

  @doc """
  Structurally diffs two semantic-manifest JSON documents by stable symbol
  id (`ash:v0:<Module>#<dsl_path>/<name>`, RFC §4.3).

  Returns a JSON-encodable report with `added`, `removed`, and `changed`
  symbol sets (plus counts in `summary`). "Changed" compares each symbol's
  content per RFC §4.4 — everything except `hashes`, `span`, and
  `property_spans` — so moved declarations do not count as changes and
  hand-authored fixtures with placeholder hashes diff correctly. Works on
  hand-authored manifest documents today; the RFC's
  `mix ash.manifest.dump --semantic` exporter is future work. Raises
  `ArgumentError` for unreadable files, invalid JSON, or documents without
  well-formed symbol ids.

  ## Examples

      iex> report = AshAgentTools.diff_manifest("test/fixtures/manifest_v1.json", "test/fixtures/manifest_v2.json")
      iex> report.summary
      %{added: 1, removed: 1, changed: 1, unchanged: 2}

      iex> report = AshAgentTools.diff_manifest("test/fixtures/manifest_v1.json", "test/fixtures/manifest_v2.json")
      iex> Enum.map(report.removed, & &1.id)
      ["ash:v0:Example.Post#attributes/score"]

  """
  @spec diff_manifest(String.t(), String.t()) :: map()
  def diff_manifest(old_path, new_path), do: AshAgentTools.Diff.diff_manifest(old_path, new_path)

  @doc """
  Returns the Ash context for a position in a source file.

  Given a repo-relative (or absolute) file path and a 1-based line, returns
  `{:ok, report}` describing which loaded Ash resource/domain declares at or
  near that position, which symbol's declaration span covers the line, the
  nearest symbols, what references the matched symbol (accepting actions,
  code interfaces, relationships), and — when semantic manifests exist —
  manifest-derived relations for the module. A miss is graceful: `{:ok, ...}`
  with `match: nil` and/or `module: nil`, never a raise.

  This is the one-call replacement for the grep → read → re-grep loop: point
  it at wherever the cursor (or a compiler error, or a diff hunk) landed.
  See `AshAgentTools.Context.context/3` for the full report contract and
  options.

  ## Examples

      iex> {:ok, report} = AshAgentTools.context("test/support/context_probe.ex", 1)
      iex> {report.match, report.module.module}
      {nil, AshAgentTools.Test.ContextProbe}

      iex> {:ok, report} = AshAgentTools.context("test/support/context_probe.ex", 21)
      iex> {report.match.kind, report.match.name}
      {:attribute, :excerpt}

  """
  @spec context(String.t(), pos_integer(), keyword()) :: {:ok, map()}
  def context(file, line, opts \\ []), do: AshAgentTools.Context.context(file, line, opts)

  @doc """
  Reduces an OpenTelemetry span list into a budget-bounded report an agent
  can actually read.

  This is the pure, dependency-free half of trace tooling: give it spans
  from anywhere (an in-BEAM ring buffer, an OTLP export, a fixture) and it
  answers the diagnostic questions — where did it fail (errors innermost
  first), which queries ran (with N+1 detection: identical sources under one
  parent collapse into one flagged entry), which policies applied, what
  notifications and async branches fired, which `ash.symbol_id`s are in the
  trace — all within a character budget (default ~8000) with an honest
  `truncated?` flag and an optional `backend_url` deep-link echoed back.

  See `AshAgentTools.Trace.explain/2` for the full contract and accepted
  span shapes.

  ## Examples

      iex> spans = [%{name: "ash.read", status: :ok, attributes: %{}, start: 0, end: 90, trace_id: "t", span_id: "a", parent_id: nil}]
      iex> report = AshAgentTools.explain_trace(spans)
      iex> {report.root.name, report.truncated?}
      {"ash.read", false}

  """
  @spec explain_trace([map()], keyword()) :: map()
  def explain_trace(spans, opts \\ []), do: AshAgentTools.Trace.explain(spans, opts)

  @doc """
  Resolves a DSL-entity name path to a symbol report.

  Name paths pin DSL entities the way `Class/method` pins a Serena symbol:
  `"MyApp.Accounts.User/actions/read"`, `".../policies/policy[0]"`, with
  dot-boundary suffix matching for the module (`"User/actions/read"`) and a
  leading `/` requiring the full module name. Returns `{:ok, report}` with
  the canonical `name_path`, the owning `module`, the `symbol` (kind, type,
  span, `provenance: :source | :synthetic`), and — when the symbol has a
  source file — its `file_shape` digest for the edit tools' read-before-edit
  handshake.

  Raises `ArgumentError` for malformed paths, unknown modules or segments
  (with did_you_mean candidates), and ambiguous suffix matches (with the
  match list). See `AshAgentTools.NamePath` for the full grammar.

  ## Examples

      iex> {:ok, report} = AshAgentTools.resolve("Post/actions/by_tag")
      iex> {report.name_path, report.symbol.kind, report.symbol.provenance}
      {"AshAgentTools.Test.Post/actions/by_tag", :action, :source}

      iex> {:ok, report} = AshAgentTools.resolve("AshAgentTools.Test.Post")
      iex> report.symbol.kind
      :resource

  """
  @spec resolve(String.t(), keyword()) :: {:ok, map()}
  def resolve(name_path, opts \\ []), do: AshAgentTools.NamePath.resolve(name_path, opts)

  @doc """
  Returns the snippet an agent should evaluate to use this API in-VM.

  Per-query `mix` boots cost seconds to minutes (cold compile, dependency
  resolution); a node that already runs the application has everything the
  tools need in memory. When your session is attached to such a node —
  `iex --server`/`iex -S mix phx.server`, a Tidewave `project_eval`-style
  tool, Livebook — evaluate the returned string's snippets directly instead
  of shelling out to `mix ash_agent.*`: they name the facade module, every
  public function with an arity, and a worked example, so no mix boot and no
  extra context is needed.

  The returned string is plain text, stable in shape, and safe to paste
  verbatim into an agent transcript.

  ## Examples

      iex> docs = AshAgentTools.eval_docs()
      iex> String.contains?(docs, "AshAgentTools.describe_action") and String.contains?(docs, "AshAgentTools.context")
      true

      iex> AshAgentTools.eval_docs() =~ "do not"
      true

  """
  @spec eval_docs() :: String.t()
  def eval_docs do
    """
    AshAgentTools is loaded in this VM already — call it directly, do not
    shell out to `mix ash_agent.*`: a per-query mix boot costs seconds to
    minutes, while these calls are instant. All functions are read-only
    (nothing executes against your data) and return plain JSON-encodable
    maps.

    Facade functions on the `AshAgentTools` module:

        AshAgentTools.list_domains()                          # loaded Ash domains
        AshAgentTools.list_resources()                        # loaded Ash resources
        AshAgentTools.describe_resource(MyApp.Post)           # fields, relationships, actions, source locations
        AshAgentTools.describe_action(MyApp.Post, :create)    # input contract, return shape, code interfaces
        AshAgentTools.validate_input(MyApp.Post, :create, %{"title" => "Hi"})
                                                              # cast + validate WITHOUT running: %{valid?: ..., errors: [...], normalized_inputs: ...}
        AshAgentTools.explain_forbidden(MyApp.Post, :create)  # policies that can deny the action (guidance; use Ash.can?/3 for verdicts)
        AshAgentTools.semantic_search("tag")                  # symbol hits across resources: resource, kind, name, type, source
        AshAgentTools.diff_manifest("old.json", "new.json")   # semantic-manifest diff by stable symbol id
        AshAgentTools.context("lib/my_app/accounts/post.ex", 42)
                                                              # {:ok, %{module, match, nearest, references, manifests}} for a file position
        AshAgentTools.explain_trace(spans)                    # trace reduction: errors, queries (N+1 flagged), policies, budget-bounded
        AshAgentTools.resolve("MyApp.Post/actions/by_tag")    # name-path resolution: symbol, span, provenance, shape digest
                                                              # (edits: AshAgentTools.Edit.replace_entity_block/3 et al. — dry-run by default)

    Runtime state (the other half of debugging — pair with a trace via
    trace_id): `AshAgentTools.Runtime.snapshot()`, `AshAgentTools.Runtime.top(20)`,
    `AshAgentTools.Runtime.tree("MyApp")` — read-only BEAM views, JSON-safe.

    Every tool miss (unknown input, search miss, context miss) emits a
    `[:ash_agent, :tool_gap]` telemetry event. Attach the dev sink once per
    session and read the aggregate:

        AshAgentTools.Kaizen.attach()                         # ETS sink + handler, idempotent
        AshAgentTools.Kaizen.digest()                         # counts + did_you_mean candidates per gap

    Helper module: `AshAgentTools.Registry` (`list_domains/0`,
    `list_resources/0`, `domains_for_resource/1`, `module_name/1`).

    Example loop — describe, validate, then execute through the project's
    own code interface:

        iex> AshAgentTools.describe_action(MyApp.Post, :create).input.required
        [:title]
        iex> report = AshAgentTools.validate_input(MyApp.Post, :create, %{"title" => "Hi", "score" => "7"})
        iex> {report.valid?, report.normalized_inputs["score"]}
        {true, 7}
        iex> MyApp.create_post!("Hi")  # the project's code interface, not this library

    `AshAgentTools.context/3` collapses the grep -> read -> re-grep loop:
    point it at any file:line (a compiler error, a diff hunk, your cursor)
    and read `report.module`, `report.match`, and `report.references`.
    """
  end
end
