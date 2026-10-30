# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Laws do
  @moduledoc """
  The deterministic "iron-law judge": evaluates source text (a snippet, a
  diff, or a file's content) against the codified *26 Iron Laws* and reports
  violations as a JSON-encodable report.

  The laws are adapted from the phxagents project's published set
  (phxagents.dev/iron-laws, MIT — "every Iron Law is a scar"), recast here as
  mechanical, grep-tier detectors. Nothing executes and nothing is loaded
  from your project: `judge/2` is a pure function over the text you hand it,
  so it needs no application boot, no compile, and no Ash modules.

  ## Certainty tiers

  A hit means *the pattern matched*; the tier says how certain the pattern
  is:

    * `:definite` — the matched text is the violation (e.g. `String.to_atom(`)
    * `:likely` — the matched shape is almost always the violation (e.g.
      `Repo.all/1` inside `def mount`)
    * `:review` — the matched shape deserves a look (e.g. `cast_assoc/3`)

  `judge/2` reports violations at `:min_tier` and above (default
  `:likely`); `counts` always covers every tier, so filtered hits stay
  visible in the numbers.

  ## Coverage honesty

  Not every law is mechanically detectable — laws like "verify before
  claiming done" (#22) govern agent *behavior*, not code. Every law is in
  `laws/0`; those without detectors are listed in the report under
  `laws_without_detectors` — they are the review checklist a human or agent
  applies on top of the mechanical passes. The full law text ships as the
  `usage-rules/iron-laws.md` sub-rule so `mix usage_rules.sync` distributes
  it like any other agent rules file.

  ## Project laws

  A project can add its own laws (its UI conventions, say) and have them
  judged, tiered, filtered and reported exactly like the core 26. Name one or
  more modules implementing `AshAgentTools.Laws.Source` in config:

      config :ash_agent_tools, extra_laws: [MyAppWeb.Laws.UI]

  or pass them per call: `judge(source, extra_laws: [MyAppWeb.Laws.UI])`.
  Each module's `laws/0` returns law maps in the registry's own shape (`id`,
  `name`, `category`, `title`, `summary`, `detectors`) using the detector
  kinds below. Project laws are validated when loaded: an id must not be all
  digits — the numeric ids are the core numbering, now and later — and must
  be unique; a malformed law or detector raises `ArgumentError` naming it.
  Detectors match Elixir/HEEx source text, like the core ones.

  A law may carry `paths` and `exclude`: lists of globs (`**` crosses
  directories, `*` and `?` stay within one, `{a,b}` is alternatives) matched
  against the path `judge/2` is given as `:file`. With `paths` the law
  applies only to matching files; `exclude` keeps a law off matching files.
  In `:diff?` mode each added line is judged under its hunk's `+++` path, so
  a scoped law applies hunk by hunk. A source with no path — `--code`, or
  stdin that is not a diff — skips scoped laws, and `exclude` cannot fire.

  When a rule needs more than a regex (a tag spanning lines, a check that
  reads the whole file, a different language), a project writes it as a
  `:custom` detector: `check: &MyApp.Laws.click_targets/2`, a function of
  `(source, meta)` with `meta` as `%{file:, lines:, diff?:}`, returning the
  lines it objects to as line numbers or `%{line:, text:, hint:}` maps. It is
  tiered, selected, filtered and reported like any other detector.

  ## Comments

  The judge reads text, so a comment or a `@doc` that mentions a pattern
  trips the law about it. `judge(source, ignore_comments: true)` blanks
  comments and doc attributes first (`AshAgentTools.Laws.Comments`), line
  for line, so line numbers hold. Off by default.

  ## Examples

      iex> report = AshAgentTools.Laws.judge("def boom(x), do: String.to_atom(x)")
      iex> {report.clean?, hd(report.violations).law, hd(report.violations).tier}
      {false, "10", :definite}

      iex> laws = AshAgentTools.Laws.laws()
      iex> {length(laws), laws |> Enum.map(& &1.id) |> Enum.uniq() |> length()}
      {26, 26}
  """

  @typedoc "Certainty tier of a detector hit."
  @type tier :: :definite | :likely | :review

  @typedoc "One reported law violation."
  @type violation :: %{
          law: String.t(),
          name: String.t(),
          category: atom(),
          tier: tier(),
          file: String.t() | nil,
          line: pos_integer(),
          text: String.t(),
          hint: String.t()
        }

  @tiers [:definite, :likely, :review]

  @mount_def ~r/^\s*def(p)?\s+mount\s*\(/
  @keyword_do ~r/\bdo:\s/
  @block_opener ~r/\bdo\b(?!\s*:)/
  @block_closer ~r/\bend\b/
  # Bound a runaway scan (a def without a matching end) instead of walking
  # the rest of the file as "mount body".
  @block_cap 400

  # The codified registry. Ids are zero-padded to match the canonical
  # numbering; `category` mirrors the canonical grouping. Detectors:
  #
  #   * `:line`   — regex per line; `unless_next` suppresses the hit when the
  #                 following line matches (e.g. `join:` continued by `on:`)
  #   * `:mount`  — regex per line inside `def mount` bodies; `guarded_by`
  #                 suppresses the whole block when it matches (e.g. the
  #                 block contains `connected?`)
  #   * `:window` — anchor regex; the anchor line and the `window` following
  #                 lines must contain none of `none` (e.g. `use Oban.Worker`
  #                 without `unique`)
  #   * `:file`   — every `all` pattern present and no `none` pattern present
  #                 in the whole text (context laws)
  #   * `:custom` — a project's own `check.(source, meta)` function (project
  #                 laws only); returns the lines it objects to
  #
  # This is a grep-tier judge, not a parser: block scans count `do`/`end`
  # tokens and treat keyword `do:` as inert. The tiers carry that honesty.
  @laws [
    # ── LiveView ──────────────────────────────────────────────────────────
    %{
      id: "01",
      name: "no-db-queries-in-mount",
      category: :live_view,
      title: "No unconditional DB queries in mount",
      summary:
        "mount runs twice (dead render + connected render), so queries there double " <>
          "and the dead render leaks data into crawler HTML. Query in handle_params, " <>
          "or stream/assign_async so the connected render fills the data in.",
      detectors: [
        %{
          kind: :mount,
          tier: :definite,
          pattern: ~r/(Repo\.\w+|\bAsh\.(read|get|load|exists))/,
          hint:
            "mount runs on the dead render too — move the query to handle_params/3 or " <>
              "load asynchronously (assign_async/stream) so crawlers see the skeleton, not the data"
        }
      ]
    },
    %{
      id: "02",
      name: "streams-for-large-lists",
      category: :live_view,
      title: "Use streams for lists over ~100 items",
      summary:
        "Assigning big lists copies them into every LiveView process; streams keep the " <>
          "DOM differential and the memory flat. Use stream/3 + phx-update=\"stream\".",
      detectors: [
        %{
          kind: :line,
          tier: :review,
          pattern: ~r/<%=\s*for\s+\w+\s*<-\s*@/,
          hint:
            "for-comprehension over an assign: if the list can exceed ~100 items use " <>
              "LiveView streams (stream/3 with phx-update=\"stream\") instead"
        }
      ]
    },
    %{
      id: "03",
      name: "connected-before-pubsub",
      category: :live_view,
      title: "Check connected? before PubSub",
      summary:
        "Subscribing in mount runs on the dead render too, leaving orphan subscriptions " <>
          "behind. Subscribe inside if connected?(socket).",
      detectors: [
        %{
          kind: :mount,
          tier: :definite,
          pattern: ~r/(PubSub|Endpoint)\.subscribe/,
          guarded_by: ~r/connected\?\(/,
          hint:
            "subscribe/2 in mount also runs on the dead render and leaks a subscription — " <>
              "wrap it in if connected?(socket)"
        }
      ]
    },
    %{
      id: "18",
      name: "changeset-errors-before-ui-debugging",
      category: :live_view,
      title: "Check changeset errors before debugging the UI",
      summary:
        "A form that \"does nothing\" is usually a failed changeset, not broken markup. " <>
          "Inspect the changeset/action errors before touching the UI.",
      detectors: []
    },
    %{
      id: "21",
      name: "no-assign-new-for-per-mount-values",
      category: :live_view,
      title: "Never assign_new for per-mount values",
      summary:
        "assign_new re-runs per mount and silently hides where state comes from; assign " <>
          "directly. (Its sanctioned home is inside LiveComponents, reading from the parent.)",
      detectors: [
        %{
          kind: :line,
          tier: :likely,
          pattern: ~r/\bassign_new\b/,
          hint:
            "assign_new in a LiveView re-runs on every mount and obscures state; assign the " <>
              "value directly (assign_new is for LiveComponents reading from their parent)"
        }
      ]
    },
    %{
      id: "24",
      name: "match-changeset-error-explicitly",
      category: :live_view,
      title: "Match {:error, %Ecto.Changeset{}} explicitly",
      summary:
        "A catch-all {:error, _} clause around Repo mutations swallows changeset errors, " <>
          "so validation failures vanish instead of reaching the form/UI.",
      detectors: [
        %{
          kind: :file,
          tier: :review,
          all: [~r/Repo\.(insert|update|delete)/, ~r/\{:error, _\}/],
          none: [~r/%Ecto\.Changeset\{/],
          hint:
            "a catch-all {:error, _} clause near Repo mutations can swallow " <>
              "%Ecto.Changeset{} — match the changeset explicitly so validation errors reach the form"
        }
      ]
    },
    # ── Ecto ──────────────────────────────────────────────────────────────
    %{
      id: "04",
      name: "no-float-money",
      category: :ecto,
      title: "Never use :float for money",
      summary: "Floats round; money must not. Use :decimal (or :money) for any currency amount.",
      detectors: [
        %{
          kind: :line,
          tier: :definite,
          pattern: ~r/:(price|amount|total|balance|cost|fee|salary|money)\w*\s*,\s*:float/,
          hint:
            "a money-named field declared :float — floats cannot represent currency exactly; " <>
              "use :decimal (or :money)"
        }
      ]
    },
    %{
      id: "05",
      name: "pin-query-variables",
      category: :ecto,
      title: "Pin external values with ^ in queries",
      summary:
        "Interpolated values bypass parameterization: injection risk and cache misses. Pin " <>
          "with ^var, or pass fragment arguments.",
      detectors: [
        %{
          kind: :line,
          tier: :definite,
          pattern: ~r/fragment\([^)]*\#\{/,
          hint:
            "interpolating into fragment/3 bypasses parameterization — pass values as " <>
              "fragment arguments or pin them with ^"
        },
        %{
          kind: :line,
          tier: :definite,
          pattern: ~r/SQL\.(query|execute)[^)]*\#\{/,
          hint:
            "string interpolation into a raw SQL call is SQL injection — parameterize the query"
        }
      ]
    },
    %{
      id: "06",
      name: "has-many-queries-belongs-to-joins",
      category: :ecto,
      title: "Separate queries for has_many, JOIN for belongs_to",
      summary:
        "N+1-ing a has_many with per-row queries or joining a has_many (row multiplication) " <>
          "are both scars: preload with separate queries for has_many, join for belongs_to.",
      detectors: []
    },
    %{
      id: "15",
      name: "no-implicit-cross-joins",
      category: :ecto,
      title: "No implicit cross joins",
      summary: "A join without on: is a cartesian product. Every join: needs an explicit on:.",
      detectors: [
        %{
          kind: :line,
          tier: :likely,
          pattern: ~r/join:\s*\w+\s+in\s+\S+,?\s*$/,
          unless_next: ~r/^\s*on:/,
          hint:
            "a join: with no on: on the same or next line is a cross join — add the explicit on: condition"
        }
      ]
    },
    %{
      id: "17",
      name: "dedup-before-cast-assoc",
      category: :ecto,
      title: "Deduplicate before cast_assoc",
      summary:
        "cast_assoc replays every embedded change and happily duplicates rows at scale. " <>
          "Deduplicate input first, or use embeds_many/manage_relationship.",
      detectors: [
        %{
          kind: :line,
          tier: :review,
          pattern: ~r/\bcast_assoc\b/,
          hint:
            "cast_assoc re-inserts duplicates for large embeds — deduplicate the input first " <>
              "(or use embeds_many / manage_relationship)"
        }
      ]
    },
    %{
      id: "19",
      name: "hidden-inputs-for-embedded-required-fields",
      category: :ecto,
      title: "Echo hidden inputs for required embedded fields",
      summary:
        "Forms over embeds must round-trip the required PKs (hidden inputs) or the embed " <>
          "is treated as absent on submit and silently dropped.",
      detectors: [
        %{
          kind: :file,
          tier: :review,
          all: [~r/inputs_for/],
          none: [~r/hidden_input|type="hidden"/],
          hint:
            "inputs_for without hidden inputs: embed forms must echo required fields (e.g. the " <>
              "PK) back as hidden inputs or the embed disappears on submit"
        }
      ]
    },
    # ── Oban ──────────────────────────────────────────────────────────────
    %{
      id: "07",
      name: "oban-jobs-idempotent",
      category: :oban,
      title: "Oban jobs must be idempotent",
      summary:
        "Jobs run at-least-once (retries, rescue, duplicates). Declare worker uniqueness " <>
          "and make perform/1 safe to replay.",
      detectors: [
        %{
          kind: :window,
          tier: :likely,
          pattern: ~r/use Oban\.Worker/,
          window: 12,
          none: [~r/unique/],
          hint:
            "Oban.Worker with no unique: option — jobs run at-least-once; declare uniqueness " <>
              "and make perform/1 idempotent"
        }
      ]
    },
    %{
      id: "08",
      name: "oban-args-string-keyed",
      category: :oban,
      title: "Oban args are string-keyed",
      summary:
        "Oban serializes args through JSON: atom keys come back as strings and pattern " <>
          "matches in perform/1 silently miss. Build args with string keys.",
      detectors: []
    },
    %{
      id: "09",
      name: "oban-args-store-ids-not-structs",
      category: :oban,
      title: "Store IDs in Oban args, not structs",
      summary:
        "A struct in job args freezes state at enqueue time and breaks across schema " <>
          "drift. Pass the id and re-read fresh in perform/1.",
      detectors: []
    },
    # ── Security ──────────────────────────────────────────────────────────
    %{
      id: "10",
      name: "no-string-to-atom-on-user-input",
      category: :security,
      title: "No String.to_atom on user input",
      summary:
        "The atom table is never garbage-collected and has a hard size limit: turning user " <>
          "input into atoms is a DoS. Use String.to_existing_atom or a fixed allow-list. " <>
          "(A compile-time-constant call is the documented exception — the human judges context.)",
      detectors: [
        %{
          kind: :line,
          tier: :definite,
          pattern: ~r/\bString\.to_atom\(/,
          hint:
            "String.to_atom/1 on dynamic input exhausts the atom table (never GC'd) — use " <>
              "String.to_existing_atom/1 or a fixed allow-list (compile-time constants excepted)"
        },
        %{
          kind: :line,
          tier: :definite,
          pattern: ~r/\bList\.to_atom\(/,
          hint:
            "List.to_atom/1 on dynamic input exhausts the atom table — use " <>
              "List.to_existing_atom/1 or a fixed allow-list"
        },
        %{
          kind: :line,
          tier: :definite,
          pattern: ~r/:erlang\.list_to_atom\(/,
          hint:
            "list_to_atom/1 on dynamic input exhausts the atom table — use " <>
              "list_to_existing_atom/1 or a fixed allow-list"
        },
        %{
          kind: :line,
          tier: :definite,
          pattern: ~r/:erlang\.binary_to_atom\(/,
          hint:
            "binary_to_atom/2 on dynamic input exhausts the atom table — use " <>
              "binary_to_existing_atom/2 or a fixed allow-list"
        }
      ]
    },
    %{
      id: "11",
      name: "authorize-every-handle-event",
      category: :security,
      title: "Authorize in every handle_event",
      summary:
        "handle_event is a public endpoint. Every event needs authorization — via Ash " <>
          "actions with policies, or an explicit Ash.can? check.",
      detectors: [
        %{
          kind: :file,
          tier: :likely,
          all: [~r/def\s+handle_event/],
          none: [~r/Ash\.can\?\(/],
          hint:
            "handle_event defs with no Ash.can? in the file: every event handler is a public " <>
              "endpoint — authorize through Ash actions with policies, or check Ash.can? explicitly"
        }
      ]
    },
    %{
      id: "12",
      name: "no-raw-untrusted",
      category: :security,
      title: "Never raw/1 untrusted content",
      summary:
        "raw/1 marks content safe HTML. Applied to anything a user touched, it is stored " <>
          "XSS. Sanitize first or drop raw entirely.",
      detectors: [
        %{
          kind: :line,
          tier: :definite,
          pattern: ~r/(?<!def\s)(?<!defp\s)\braw\(\s*[\w.@\[\]]+\s*\)/,
          hint:
            "raw/1 on a non-literal marks user-reachable content as safe HTML (stored XSS) — " <>
              "sanitize first or remove the raw/1"
        }
      ]
    },
    # ── OTP ───────────────────────────────────────────────────────────────
    %{
      id: "13",
      name: "no-process-without-runtime-reason",
      category: :otp,
      title: "No process without a runtime reason",
      summary:
        "Processes exist to outlive calls (state, concurrency, fault isolation). A process " <>
          "started per page view or request dies meaningless — use a supervised singleton " <>
          "or plain functions.",
      detectors: [
        %{
          kind: :mount,
          tier: :likely,
          pattern:
            ~r/(Agent\.start(_link)?|GenServer\.start(_link)?|Task\.start(_link)?|start_supervised)/,
          hint:
            "a process started in mount dies with the render and duplicates per visitor — " <>
              "processes need a runtime reason (a supervised singleton), not a page view"
        },
        %{
          kind: :line,
          tier: :review,
          pattern: ~r/\bspawn(_link)?\(/,
          hint:
            "bare spawn is unmonitored, unsupervised, and unlogged — use Task.Supervisor or " <>
              "a supervised child"
        }
      ]
    },
    %{
      id: "14",
      name: "supervise-long-lived-processes",
      category: :otp,
      title: "Supervise all long-lived processes",
      summary:
        "Anything that should still be there tomorrow must be in a supervision tree. " <>
          "Task.start/Task.start_link from a request process leak on crash.",
      detectors: [
        %{
          kind: :line,
          tier: :likely,
          pattern: ~r/\bTask\.start(_link)?\(/,
          hint:
            "Task.start(_link)/1 is outside any supervision tree — failures vanish; run under " <>
              "Task.Supervisor or add the process to a supervisor"
        }
      ]
    },
    # ── Elixir ────────────────────────────────────────────────────────────
    %{
      id: "16",
      name: "external-resource-for-compile-time-files",
      category: :elixir,
      title: "Declare @external_resource for compile-time file reads",
      summary:
        "A module that reads a file at compile time must declare the path with " <>
          "@external_resource, or editing the file will not recompile the module.",
      detectors: [
        %{
          kind: :file,
          tier: :review,
          all: [~r/File\.read!/],
          none: [~r/@external_resource/],
          hint:
            "File.read! with no @external_resource in the module: edits to the read file will " <>
              "not trigger recompilation — declare the path with @external_resource"
        }
      ]
    },
    %{
      id: "20",
      name: "wrap-third-party-apis",
      category: :elixir,
      title: "Wrap third-party APIs",
      summary:
        "Call third parties through your own façade module so retries, timeouts, and " <>
          "shape-drift have one place to live.",
      detectors: []
    },
    %{
      id: "23",
      name: "mix-tasks-start-only-what-they-need",
      category: :elixir,
      title: "Mix tasks start only what they need",
      summary:
        "app.start boots the whole tree (queues, projectors, endpoints) for a task that " <>
          "usually needs app.config + a few apps. Require exactly what the task uses.",
      detectors: [
        %{
          kind: :line,
          tier: :definite,
          pattern: ~r/@requirements.*app\.start/,
          hint:
            "a mix task requiring app.start boots the entire application (Oban queues, " <>
              "projectors, endpoints) — require app.config and ensure_started only what it needs"
        },
        %{
          kind: :line,
          tier: :definite,
          pattern: ~r/Mix\.Task\.run\(\s*"app\.start"/,
          hint:
            "explicitly running app.start boots the entire application — start only the apps " <>
              "the task actually needs"
        }
      ]
    },
    %{
      id: "25",
      name: "capture-locale-before-spawning",
      category: :elixir,
      title: "Capture locale (and Process-store context) before spawning",
      summary:
        "Spawned tasks do not inherit the process dictionary. Capture locale and any " <>
          "Process-store context before the spawn; restore it inside.",
      detectors: [
        %{
          kind: :file,
          tier: :review,
          all: [~r/Gettext/, ~r/\bTask\.(async|start)\b|\bspawn(_link)?\(/],
          none: [~r/(get|put)_locale/],
          hint:
            "Gettext + spawning with no locale capture: spawned tasks lose the process " <>
              "dictionary — capture the locale before spawning and restore it inside"
        }
      ]
    },
    # ── Verification ──────────────────────────────────────────────────────
    %{
      id: "22",
      name: "verify-before-claiming-done",
      category: :verification,
      title: "Verify before claiming done",
      summary:
        "No \"done\" without running it: compile, test, and show the output. This judge is " <>
          "that law mechanized for style; the compile+test half has no shortcut.",
      detectors: []
    },
    # ── Style ─────────────────────────────────────────────────────────────
    %{
      id: "26",
      name: "comments-are-not-commit-messages",
      category: :style,
      title: "Comments aren't commit messages",
      summary:
        "Keep only durable facts in code. Narrative that belongs to the diff (\"changed " <>
          "this because...\") belongs to the commit message, not the file.",
      detectors: []
    }
  ]

  @core_ids Enum.map(@laws, & &1.id)
  @detector_kinds [:line, :mount, :window, :file, :custom]

  @doc """
  The law registry: the 26 iron laws with id, name, category, title,
  summary, and detectors (empty for the behavior-only laws), followed by any
  project laws (see "Project laws").

  Project laws come from `opts[:extra_laws]` when given, otherwise from
  `config :ash_agent_tools, :extra_laws`. With neither, this is the core
  registry. Raises `ArgumentError` when a project law is invalid.
  """
  @spec laws(keyword()) :: [map()]
  def laws(opts \\ []), do: @laws ++ project_laws(opts)

  @doc """
  The 26 core iron laws only, never project laws. Pure data, never raises.
  """
  @spec core_laws() :: [map()]
  def core_laws, do: @laws

  @doc """
  The validated project laws from `opts[:extra_laws]`, or from
  `config :ash_agent_tools, :extra_laws` when the option is absent. Entries
  are modules implementing `AshAgentTools.Laws.Source` or law maps.
  """
  @spec project_laws(keyword()) :: [map()]
  def project_laws(opts \\ []) do
    opts
    |> Keyword.get_lazy(:extra_laws, fn ->
      Application.get_env(:ash_agent_tools, :extra_laws, [])
    end)
    |> List.wrap()
    |> Enum.flat_map(&source_laws/1)
    |> validate_project_laws!()
  end

  @doc """
  The certainty tiers, most-certain first: `[:definite, :likely, :review]`.
  """
  @spec tiers() :: [tier(), ...]
  def tiers, do: @tiers

  @doc """
  Judges `source` against the codified iron laws and returns the report.

  A pure function over the text — no application boot, no project modules,
  nothing executed. Violations-only output: `violations` lists hits at
  `:min_tier` or above, sorted by line; `counts` covers every tier.

  ## Options

    * `:file` — the source's path, reported under `source` and on each
      violation (default `"inline"`); project laws scoped with `paths` or
      `exclude` are matched against it
    * `:ignore_comments` — blank comments and `@doc`/`@moduledoc`/`@typedoc`
      values before judging (`AshAgentTools.Laws.Comments.blank/2`), so
      prose that mentions a pattern is not a hit. Default `false`.
    * `:min_tier` — `:definite`, `:likely` (default), or `:review`; lower tiers
      are filtered out of `violations` (and still counted in `counts`)
    * `:laws` — list of law ids (e.g. `["10", "04"]`) restricting the
      judgement; unknown ids raise `ArgumentError` with the valid ids
    * `:extra_laws` — project laws to judge with, overriding
      `config :ash_agent_tools, :extra_laws` (see "Project laws")
    * `:diff?` — treat `source` as a unified diff and judge only added lines
      (`+` lines, `+++` headers excluded). Whole-text detectors (`:mount`,
      `:window`, `:file`) are skipped: they need full-file context, which a
      diff does not carry. `:custom` detectors run and receive the diff text
      with `diff?: true` in `meta`, so a project decides for itself.

  The report is JSON-encodable (`Jason.encode!/1` always works; atoms encode
  as strings). `clean?` is true exactly when the (filtered) `violations` list
  is empty. `laws_without_detectors` lists the selected laws this mechanical
  pass cannot see — the human/agent review checklist.
  """
  @spec judge(String.t(), keyword()) :: map()
  def judge(source, opts \\ []) when is_binary(source) do
    source =
      if Keyword.get(opts, :ignore_comments, false),
        do: AshAgentTools.Laws.Comments.blank(source, diff?: Keyword.get(opts, :diff?, false)),
        else: source

    min_tier = Keyword.get(opts, :min_tier, :likely)
    label = Keyword.get(opts, :file, "inline")
    path = source_path(label)
    selected = select_laws(opts[:laws], laws(opts))
    lines = String.split(source, ["\r\n", "\n"])
    diff? = Keyword.get(opts, :diff?, false)
    meta = %{file: path, lines: lines, diff?: diff?}

    {checked, raw_violations} =
      if diff? do
        # Each added line is judged under the file its hunk belongs to, so a
        # law scoped with `paths` applies hunk by hunk.
        files = diff_files(lines)

        by_file =
          files
          |> Map.values()
          |> Enum.uniq()
          |> Map.new(fn file -> {file, Enum.filter(selected, &applies?(&1, file))} end)

        file_for = fn no -> Map.get(files, no) end
        laws_for = fn no -> Map.get(by_file, file_for.(no), []) end

        {selected,
         line_violations(added_diff_lines(lines), lines, laws_for, file_for) ++
           custom_violations(source, selected, meta)}
      else
        applicable = Enum.filter(selected, &applies?(&1, path))
        indexed = Enum.with_index(lines, 1)

        {applicable,
         line_violations(indexed, lines, fn _no -> applicable end, fn _no -> path end) ++
           mount_violations(lines, applicable, path) ++
           window_violations(lines, applicable, path) ++
           file_violations(source, lines, applicable, path) ++
           custom_violations(source, applicable, meta)}
      end

    violations =
      raw_violations
      |> Enum.filter(&(tier_rank(&1.tier) <= tier_rank(min_tier)))
      |> Enum.sort_by(&{&1.line, tier_rank(&1.tier), &1.law})

    counts =
      Map.new(@tiers, fn tier -> {tier, Enum.count(raw_violations, &(&1.tier == tier))} end)

    %{
      source: Keyword.get(opts, :file, "inline"),
      laws_checked: length(checked),
      violations: violations,
      counts: counts,
      clean?: violations == [],
      laws_without_detectors:
        selected |> Enum.filter(&(&1.detectors == [])) |> Enum.map(&%{id: &1.id, name: &1.name})
    }
  end

  # ── detector kinds ──────────────────────────────────────────────────────

  defp line_violations(pairs, all_lines, laws_for, file_for) do
    for {line, no} <- pairs,
        law <- laws_for.(no),
        det <- law.detectors,
        det.kind == :line,
        Regex.match?(det.pattern, line),
        not next_line_suppressed?(det, all_lines, no) do
      violation(law, det, no, line, file_for.(no))
    end
  end

  defp next_line_suppressed?(%{unless_next: pattern}, lines, no) do
    case Enum.at(lines, no) do
      nil -> false
      next -> Regex.match?(pattern, next)
    end
  end

  defp next_line_suppressed?(_, _, _), do: false

  defp added_diff_lines(lines) do
    Enum.with_index(lines, 1)
    |> Enum.filter(fn {line, _no} ->
      String.starts_with?(line, "+") and not String.starts_with?(line, "+++")
    end)
  end

  defp mount_violations(lines, laws, file) do
    blocks = mount_blocks(lines)

    for law <- laws,
        det <- law.detectors,
        det.kind == :mount,
        {line, no} <- blocks,
        Regex.match?(det.pattern, line),
        not mount_guarded?(det, blocks) do
      violation(law, det, no, line, file)
    end
  end

  defp mount_guarded?(%{guarded_by: pattern}, blocks) when is_struct(pattern, Regex),
    do: Enum.any?(blocks, fn {line, _no} -> Regex.match?(pattern, line) end)

  defp mount_guarded?(_, _), do: false

  # Every line inside any `def mount` body, as {line, absolute_line_no}.
  # Depth starts at 1 (the def's own end closes it); each `do` (excluding the
  # keyword-list `do:` form) adds one, each `end` removes one. Grep-tier by
  # design — strings containing do/end fool it, and the tiers say so.
  defp mount_blocks(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _no} -> Regex.match?(@mount_def, line) end)
    |> Enum.flat_map(fn {def_line, no} -> block_lines(lines, no, def_line) end)
  end

  defp block_lines(lines, def_no, def_line) do
    if Regex.match?(@keyword_do, def_line) do
      []
    else
      lines
      |> Enum.drop(def_no)
      |> Enum.take(@block_cap)
      |> Enum.with_index(def_no + 1)
      |> Enum.reduce_while({[], 1}, fn {line, no}, {acc, depth} ->
        depth = depth + block_opens(line) - block_closes(line)

        if depth <= 0 do
          {:halt, {acc, 0}}
        else
          {:cont, {[{line, no} | acc], depth}}
        end
      end)
      |> elem(0)
      |> Enum.reverse()
    end
  end

  defp block_opens(line), do: length(Regex.scan(@block_opener, line))
  defp block_closes(line), do: length(Regex.scan(@block_closer, line))

  defp window_violations(lines, laws, file) do
    indexed = Enum.with_index(lines, 1)

    for law <- laws,
        det <- law.detectors,
        det.kind == :window,
        {line, no} <- indexed,
        Regex.match?(det.pattern, line),
        not window_clean?(det, lines, no) do
      violation(law, det, no, line, file)
    end
  end

  defp window_clean?(det, lines, no) do
    # `no` is 1-based; slice from the anchor line itself (`no - 1` 0-based) so
    # an anchor line that already carries the option (`use Oban.Worker, ...,
    # unique: [...]`) counts as clean, and keep the full `window` lines of
    # reach past it.
    lines
    |> Enum.slice(no - 1, det.window + 1)
    |> Enum.any?(fn line -> Enum.any?(det.none, &Regex.match?(&1, line)) end)
  end

  defp file_violations(source, lines, laws, file) do
    for law <- laws,
        det <- law.detectors,
        det.kind == :file,
        Enum.all?(det.all, &Regex.match?(&1, source)),
        not Enum.any?(det.none, &Regex.match?(&1, source)) do
      anchor = hd(det.all)
      no = (Enum.find_index(lines, &Regex.match?(anchor, &1)) || 0) + 1
      line = Enum.at(lines, no - 1) || ""
      violation(law, det, no, line, file)
    end
  end

  # A `:custom` detector is the project's own function. `check.(source, meta)`
  # returns the lines it objects to: a line number (the line's text and the
  # detector's hint are used), or a map with `line` and, optionally, `text`
  # and `hint`. Anything else is the project's bug, named as such.
  defp custom_violations(source, laws, meta) do
    for law <- laws,
        det <- law.detectors,
        det.kind == :custom,
        hit <- custom_hits!(law, det, source, meta) do
      {no, text, hint} = custom_hit!(law, hit)
      line = text || Enum.at(meta.lines, no - 1) || ""
      violation(law, %{det | hint: hint || det.hint}, no, line, meta.file)
    end
  end

  defp custom_hits!(law, det, source, meta) do
    case det.check.(source, meta) do
      hits when is_list(hits) ->
        hits

      other ->
        raise ArgumentError,
              "extra_laws: the :custom detector of law #{inspect(law.id)} returned " <>
                "#{inspect(other)}; expected a list of hits"
    end
  end

  defp custom_hit!(_law, no) when is_integer(no) and no > 0, do: {no, nil, nil}

  defp custom_hit!(law, %{line: no} = hit) when is_integer(no) and no > 0 do
    text = Map.get(hit, :text)
    hint = Map.get(hit, :hint)

    if (is_nil(text) or is_binary(text)) and (is_nil(hint) or is_binary(hint)) do
      {no, text, hint}
    else
      bad_custom_hit!(law, hit)
    end
  end

  defp custom_hit!(law, hit), do: bad_custom_hit!(law, hit)

  defp bad_custom_hit!(law, hit) do
    raise ArgumentError,
          "extra_laws: the :custom detector of law #{inspect(law.id)} returned the hit " <>
            "#{inspect(hit)}; expected a positive line number, or a map with :line and " <>
            "optional string :text and :hint"
  end

  defp violation(law, det, no, line, file) do
    %{
      law: law.id,
      name: law.name,
      category: law.category,
      tier: det.tier,
      file: file,
      line: no,
      text: line |> String.slice(0, 200) |> String.trim(),
      hint: det.hint
    }
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp tier_rank(tier), do: Enum.find_index(@tiers, &(&1 == tier))

  # The path a `:file` label names; a snippet or plain stdin has none.
  defp source_path(label) when label in [nil, "inline", "-"], do: nil
  defp source_path(label) when is_binary(label), do: String.replace_prefix(label, "./", "")
  defp source_path(_), do: nil

  # The file each line of a unified diff belongs to, from its `+++` headers
  # (`b/` stripped; `/dev/null` is a deleted file, judged under no path).
  defp diff_files(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.reduce({%{}, nil}, fn {line, no}, {map, current} ->
      current =
        case Regex.run(~r{^\+\+\+ (?:b/)?(\S+)}, line) do
          [_, "/dev/null"] -> nil
          [_, path] -> source_path(path)
          nil -> current
        end

      {Map.put(map, no, current), current}
    end)
    |> elem(0)
  end

  # A law with `paths` applies only to a known path matching one of them;
  # `exclude` keeps it off matching paths. Without a path, scoped laws are
  # skipped and `exclude` cannot fire. Core laws carry neither.
  defp applies?(law, path) do
    paths = Map.get(law, :paths) || []
    exclude = Map.get(law, :exclude) || []

    cond do
      is_nil(path) -> paths == []
      paths != [] and not Enum.any?(paths, &glob_match?(&1, path)) -> false
      Enum.any?(exclude, &glob_match?(&1, path)) -> false
      true -> true
    end
  end

  # Globs as `Path.wildcard/1` spells them: `**` crosses directories, `*`
  # and `?` stay within one, `{a,b}` is alternatives.
  defp glob_match?(glob, path), do: Regex.match?(glob_regex(glob), path)

  defp glob_regex(glob) do
    pattern =
      glob
      |> String.split(~r/\*\*\/|\*\*|\*|\?|\{[^}]*\}/, include_captures: true, trim: true)
      |> Enum.map_join(fn
        "**/" ->
          "(?:.*/)?"

        "**" ->
          ".*"

        "*" ->
          "[^/]*"

        "?" ->
          "[^/]"

        "{" <> rest ->
          "(?:" <>
            (rest
             |> String.trim_trailing("}")
             |> String.split(",")
             |> Enum.map_join("|", &Regex.escape/1)) <> ")"

        literal ->
          Regex.escape(literal)
      end)

    Regex.compile!("^" <> pattern <> "$")
  end

  defp select_laws(nil, laws), do: laws

  defp select_laws(ids, laws) when is_list(ids) do
    known_ids = Enum.map(laws, & &1.id)
    unknown = Enum.reject(ids, &(&1 in known_ids))

    if unknown == [] do
      Enum.filter(laws, &(&1.id in ids))
    else
      raise ArgumentError,
            "unknown law id(s) #{inspect(unknown)} — valid ids: #{Enum.join(known_ids, ", ")}"
    end
  end

  # ── project laws ────────────────────────────────────────────────────────

  defp source_laws(%{} = law), do: [law]

  defp source_laws(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :laws, 0) do
      List.wrap(module.laws())
    else
      raise ArgumentError,
            "extra_laws: #{inspect(module)} is not a loaded module exporting laws/0 " <>
              "(implement AshAgentTools.Laws.Source)"
    end
  end

  defp source_laws(other) do
    raise ArgumentError,
          "extra_laws: expected a module or a law map, got #{inspect(other)}"
  end

  defp validate_project_laws!(laws) do
    Enum.each(laws, &validate_law!/1)

    duplicates =
      laws
      |> Enum.frequencies_by(& &1.id)
      |> Enum.filter(fn {_, n} -> n > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates != [] do
      raise ArgumentError, "extra_laws: duplicate project law id(s) #{inspect(duplicates)}"
    end

    laws
  end

  defp validate_law!(%{id: id} = law) when is_binary(id) do
    validate_id!(id)
    validate_fields!(id, law)

    case Map.get(law, :detectors) do
      detectors when is_list(detectors) -> Enum.each(detectors, &validate_detector!(id, &1))
      _ -> raise ArgumentError, "extra_laws: law #{inspect(id)} needs a :detectors list"
    end
  end

  defp validate_law!(law) do
    raise ArgumentError, "extra_laws: a law needs a string :id, got #{inspect(law)}"
  end

  defp validate_id!(""), do: raise(ArgumentError, "extra_laws: a law id must not be empty")

  defp validate_id!(id) when id in @core_ids do
    raise ArgumentError,
          "extra_laws: law id #{inspect(id)} is a core iron law; " <>
            "give project laws their own ids (e.g. \"ui-01\")"
  end

  defp validate_id!(id) do
    if id =~ ~r/^\d+$/ do
      raise ArgumentError,
            "extra_laws: law id #{inspect(id)} is reserved — numeric ids are the core " <>
              "numbering; use a prefix (e.g. \"ui-01\")"
    end
  end

  defp validate_fields!(id, law) do
    for key <- [:name, :title, :summary],
        not (is_binary(Map.get(law, key)) and Map.get(law, key) != "") do
      raise ArgumentError,
            "extra_laws: law #{inspect(id)} needs a non-empty string #{inspect(key)}"
    end

    category = Map.get(law, :category)

    unless is_atom(category) and not is_nil(category) do
      raise ArgumentError, "extra_laws: law #{inspect(id)} needs an atom :category"
    end

    for key <- [:paths, :exclude], Map.has_key?(law, key) do
      value = Map.get(law, key)

      unless is_list(value) and Enum.all?(value, &(is_binary(&1) and &1 != "")) do
        raise ArgumentError,
              "extra_laws: law #{inspect(id)} needs #{inspect(key)} to be a list of glob strings"
      end
    end
  end

  defp validate_detector!(id, %{kind: kind, tier: tier, hint: hint} = det)
       when kind in @detector_kinds and tier in @tiers and is_binary(hint) do
    missing =
      case kind do
        :line -> regex_keys(det, [:pattern]) ++ optional_regex(det, :unless_next)
        :mount -> regex_keys(det, [:pattern]) ++ optional_regex(det, :guarded_by)
        :window -> regex_keys(det, [:pattern]) ++ regex_list(det, :none) ++ window(det)
        :file -> regex_list(det, :all, non_empty: true) ++ regex_list(det, :none)
        :custom -> custom_check(det)
      end

    if missing != [] do
      raise ArgumentError,
            "extra_laws: a #{inspect(kind)} detector of law #{inspect(id)} needs #{Enum.join(missing, ", ")}"
    end
  end

  defp validate_detector!(id, det) do
    raise ArgumentError,
          "extra_laws: law #{inspect(id)} has an invalid detector #{inspect(det)} — needs " <>
            ":kind (one of #{inspect(@detector_kinds)}), :tier (one of #{inspect(@tiers)}) " <>
            "and a string :hint"
  end

  defp regex_keys(det, keys),
    do: for(key <- keys, not is_struct(Map.get(det, key), Regex), do: "#{inspect(key)} (a regex)")

  defp optional_regex(det, key) do
    case Map.fetch(det, key) do
      {:ok, value} when not is_struct(value, Regex) -> ["#{inspect(key)} to be a regex"]
      _ -> []
    end
  end

  defp regex_list(det, key, opts \\ []) do
    value = Map.get(det, key)

    valid? =
      is_list(value) and Enum.all?(value, &is_struct(&1, Regex)) and
        (value != [] or not Keyword.get(opts, :non_empty, false))

    if valid?, do: [], else: ["#{inspect(key)} (a list of regexes)"]
  end

  defp custom_check(%{check: check}) when is_function(check, 2), do: []
  defp custom_check(_), do: [":check (a function of (source, meta))"]

  defp window(%{window: n}) when is_integer(n) and n > 0, do: []
  defp window(_), do: [":window (a positive integer)"]
end
