# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.DomainMap do
  @moduledoc """
  The domain map's pure half: validation of the editorial JSON and the
  renderers for the generated regions. The mix task (`mix ash_agent.domain_map`)
  is the I/O shell around this module — argument parsing, file paths, seeding —
  so the same code backs a host's CI gate, a test, and the task itself.

  The map renders an application's bounded contexts, their planes, substrates
  and relationships from two inputs: the host's editorial JSON (planes,
  contexts, missions, terms, edges, package roles) and what the registered
  domains introspect (`config :my_app, ash_domains`, each domain's resources,
  their relationships, the declared signal graph).

  Host policy is JSON data, not code: `"first_party_orgs"` says which git
  origins count as first-party (lock-claim completeness), `"vendor_tokens"`
  names the strings whose resource rows are omitted from the artifact, an
  in-repo substrate carries the `"path"` of its directory, and `"draft": true`
  holds validation down to referential integrity while a seed is still being
  written.

  This is introspection, not operation: the renderers read compile-time info
  only, so a resource description (`Ash.Resource.Info.description/1`) is
  rendered when the author wrote one and nothing invented when they did not —
  generated cells never carry prose the declarations do not themselves carry.
  """

  alias AshAgentTools.Registry

  # Density fallback: past this many edges the relationship-count edges come out of the
  # diagram and render as a matrix table under Context relationships instead. Decided up
  # front so the diagram's legibility does not depend on someone noticing the clutter.
  @edge_budget 45

  @region_regex ~r/<!-- domain-map:([a-z0-9:-]+):start -->.*?<!-- domain-map:\1:end -->/s

  @top_level_keys [
    "planes",
    "contexts",
    "substrates",
    "adopted",
    "first_party_orgs",
    "vendor_tokens",
    "draft"
  ]
  @plane_keys ["id", "name", "purpose"]
  @context_keys ["id", "name", "domain", "plane", "mission", "packages", "adrs", "terms", "edges"]
  @term_keys ["term", "definition"]
  @edge_keys ["to", "pattern", "note"]
  @substrate_keys ["package", "repo", "kind", "context", "role", "path"]
  @substrate_kinds ["first-party", "first-party dev", "fork", "transitive", "in-repo"]
  @adopted_keys ["package", "role"]

  @lock "mix.lock"
  @default_adr_dir "docs/adr"

  # Unknown keys and unknown ids fail loudly: a typo in a JSON key would otherwise
  # silently render as an empty cell, the quiet wrongness the generator exists
  # to prevent.
  @doc """
  Validates the decoded editorial JSON. Raises `Mix.Error` on any structural
  problem: unknown keys, duplicate ids, dangling references, substrates and
  adopted entries missing from the host's `mix.lock`, an in-repo substrate
  without a `"path"`, a context without a mission or with fewer than three
  terms — the last two held off while `"draft"` is true, so a seed can grow.
  Returns `:ok` when the data is sound.
  """
  def validate!(data) do
    reject_unknown_keys!(data, @top_level_keys, "top level")

    planes = data["planes"]
    contexts = data["contexts"]

    validate_top_level_types!(data)

    Enum.each(planes, &reject_unknown_keys!(&1, @plane_keys, "plane"))
    Enum.each(contexts, &reject_unknown_keys!(&1, @context_keys, "context"))
    Enum.each(data["substrates"], &reject_unknown_keys!(&1, @substrate_keys, "substrate"))
    Enum.each(data["adopted"], &reject_unknown_keys!(&1, @adopted_keys, "adopted entry"))

    plane_ids = refuse_duplicates!(planes, "plane id", & &1["id"])
    context_ids = refuse_duplicates!(contexts, "context id", & &1["id"])

    for plane <- planes, plane["purpose"] in [nil, ""] do
      Mix.raise("Plane #{inspect(plane["id"])} needs a purpose.")
    end

    draft? = data["draft"] == true

    Enum.each(contexts, &validate_context!(&1, plane_ids, context_ids, draft?))

    lock = read_lock!()

    Enum.each(data["substrates"], &validate_substrate!(&1, context_ids, lock))

    Enum.each(data["adopted"], fn adopted ->
      unless Map.has_key?(lock, adopted["package"]) do
        Mix.raise("Adopted package #{inspect(adopted["package"])} is not in #{@lock}.")
      end
    end)

    :ok
  end

  @doc false
  def build_model(data, domains) do
    domains = Enum.map(domains, &Code.ensure_loaded!/1)
    lock = read_lock!()
    resources = resources(domains)

    ctx_by_domain =
      for context <- data["contexts"],
          domain = context["domain"],
          is_binary(domain),
          into: %{},
          do: {domain, context["id"]}

    # Membership, not `Ash.Resource.Info.domain/1`: package-owned resources
    # (compliance, projections, bpmn machinery) carry their package's domain,
    # while the host domain registered in :ash_domains is the context they
    # belong to.
    ctx_by_resource =
      domains
      |> Enum.flat_map(fn domain ->
        case ctx_by_domain[Registry.module_name(domain)] do
          nil -> []
          ctx -> Enum.map(Ash.Domain.Info.resources(domain), &{&1, ctx})
        end
      end)
      |> Enum.reverse()
      |> Map.new()

    contexts =
      for context <- data["contexts"] do
        ctx_resources = Enum.filter(resources, &(Map.get(ctx_by_resource, &1) == context["id"]))

        Map.put(context, :resources, ctx_resources)
        |> Map.put(:resource_count, length(ctx_resources))
      end

    rel_edges = relationship_edges(resources, ctx_by_resource, ctx_by_domain)

    signals =
      Ash.Signals.Graph.build(resources: resources)
      |> Enum.filter(fn entry ->
        # The graph builder's listener search reaches loaded modules outside
        # `resources:` (consolidation off), so an unrelated fixture's signal
        # would otherwise render into a map that never declared it. The map
        # speaks for the registered domains only.
        emitters = Enum.map(entry.emitters, &record_resource/1)
        listeners = Enum.map(entry.listeners, &record_resource/1)

        Enum.all?(emitters ++ listeners, &(&1 in resources)) and emitters != [] and
          listeners != []
      end)

    model = %{
      data: data,
      domains: domains,
      contexts: contexts,
      lock: lock,
      signals: signals,
      rel_edges: rel_edges,
      tokens: data["vendor_tokens"] || [],
      first_party_orgs: data["first_party_orgs"] || [],
      fallback?: false,
      ctx_by_domain: ctx_by_domain,
      ctx_by_resource: ctx_by_resource
    }

    model = Map.put(model, :fallback?, over_budget?(model))
    check_completeness!(data, model)
    model
  end

  @doc false
  def regions(model, adr_dir \\ @default_adr_dir, adr_link_prefix \\ "adr") do
    %{
      "graph" => graph(model),
      "contexts" => contexts_catalogue(model),
      "substrates" => substrates(model),
      "signals" => signals_region(model),
      "adopted" => adopted(model)
    }
    |> Map.merge(
      Map.new(model.contexts, fn context ->
        {"context:#{context["id"]}", context_section(model, context, adr_dir, adr_link_prefix)}
      end)
    )
  end

  @doc false
  def ensure_target_regions!(target, regions) do
    unless File.exists?(target) do
      Mix.raise("#{target} does not exist. Create it with the region markers before generating.")
    end

    found =
      ~r/<!-- domain-map:([a-z0-9:-]+):start -->/
      |> Regex.scan(File.read!(target), capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    unknown = found -- Map.keys(regions)

    unless unknown == [] do
      Mix.raise(
        "#{target} contains a <!-- domain-map:#{hd(unknown)} --> region, but there is no " <>
          "renderer by that name. Known regions: #{Map.keys(regions) |> Enum.sort() |> Enum.join(", ")}."
      )
    end

    missing =
      for {"context:" <> id, _} <- Map.to_list(regions),
          "context:#{id}" not in found,
          do: id

    unless missing == [] do
      Mix.raise(
        "#{target} is missing the region for these contexts: #{Enum.join(missing, ", ")}. " <>
          "Every context in the JSON needs a `### ` heading with a domain-map:context:<id> region under it."
      )
    end
  end

  @doc false
  def rewrite(path, regions) do
    original = File.read!(path)

    rendered =
      Regex.replace(@region_regex, original, fn _whole, name ->
        # Blank lines around the body: GitHub's parser will not start a table
        # on the line after an HTML comment, so flush markers render the
        # generated tables as plain text there.
        "<!-- domain-map:#{name}:start -->\n\n" <>
          Map.fetch!(regions, name) <> "\n\n<!-- domain-map:#{name}:end -->"
      end)

    if rendered == original, do: {:unchanged, rendered}, else: {:changed, rendered}
  end

  # -- validation helpers ---------------------------------------------------

  defp validate_top_level_types!(data) do
    validate_string_list!(data["first_party_orgs"], "\"first_party_orgs\"")
    validate_string_list!(data["vendor_tokens"], "\"vendor_tokens\"")

    unless data["draft"] in [nil, true, false] do
      Mix.raise("\"draft\" must be true or false when present.")
    end

    :ok
  end

  defp validate_string_list!(nil, _what), do: :ok

  defp validate_string_list!(value, what) do
    legal? = is_list(value) and Enum.all?(value, &(is_binary(&1) and &1 != ""))

    unless legal? do
      Mix.raise("#{what} must be a list of non-empty strings.")
    end

    :ok
  end

  defp validate_context!(context, plane_ids, context_ids, draft?) do
    id = context["id"]

    unless context["plane"] in plane_ids do
      Mix.raise(
        "Context #{inspect(id)} names plane #{inspect(context["plane"])}, which is not defined."
      )
    end

    unless draft? or context_has_mission?(context) do
      Mix.raise("Context #{inspect(id)} needs a mission.")
    end

    domain = context["domain"]

    if !(is_binary(domain) or is_nil(domain)) do
      Mix.raise("Context #{inspect(id)}: \"domain\" must be the domain module string or null.")
    end

    len = length(context["terms"])

    if not draft? and (len < 3 or len > 8) do
      Mix.raise(
        "Context #{inspect(id)} has #{len} terms; the ubiquitous language wants three to eight per context."
      )
    end

    Enum.each(context["terms"], &validate_term!(&1, id))
    Enum.each(context["edges"], &validate_edge!(&1, id, context_ids))
  end

  defp context_has_mission?(context) do
    is_binary(context["mission"]) and context["mission"] != ""
  end

  defp validate_term!(term, id) do
    reject_unknown_keys!(term, @term_keys, "term of #{inspect(id)}")

    if term["term"] in [nil, ""] or term["definition"] in [nil, ""] do
      Mix.raise("A term of #{inspect(id)} needs both a term and a definition.")
    end
  end

  defp validate_edge!(edge, id, context_ids) do
    reject_unknown_keys!(edge, @edge_keys, "edge of #{inspect(id)}")

    unless edge["to"] in context_ids do
      Mix.raise(
        "Edge of #{inspect(id)} points at context #{inspect(edge["to"])}, which is not defined."
      )
    end
  end

  defp validate_substrate!(substrate, context_ids, lock) do
    package = substrate["package"]

    unless substrate["kind"] in @substrate_kinds do
      Mix.raise(
        "Substrate #{inspect(package)}: unknown kind #{inspect(substrate["kind"])}. " <>
          "Legal kinds: #{@substrate_kinds |> Enum.join(", ")}."
      )
    end

    Enum.each(normalize_ctx(substrate["context"]), fn id ->
      unless id in context_ids do
        Mix.raise(
          "Substrate #{inspect(package)} names context #{inspect(id)}, which is not defined."
        )
      end
    end)

    validate_substrate_source!(substrate, lock)
  end

  defp validate_substrate_source!(%{"kind" => "in-repo"} = substrate, _lock) do
    path = substrate["path"]

    unless is_binary(path) and path != "" do
      Mix.raise(
        "Substrate #{inspect(substrate["package"])} is in-repo, so it needs a non-empty " <>
          "\"path\" naming the directory it lives in."
      )
    end

    unless File.dir?(path) do
      Mix.raise(
        "Substrate #{inspect(substrate["package"])} is in-repo at #{inspect(path)}, " <>
          "but that directory does not exist."
      )
    end
  end

  defp validate_substrate_source!(%{"package" => package}, lock) do
    unless Map.has_key?(lock, package) do
      Mix.raise("Substrate #{inspect(package)} is not in #{@lock}.")
    end
  end

  defp reject_unknown_keys!(entry, legal, where) when is_map(entry) do
    unknown = Map.keys(entry) -- legal

    unless unknown == [] do
      Mix.raise(
        "Unknown key(s) #{Enum.map_join(unknown, ", ", &inspect/1)} at #{where}. " <>
          "Legal keys: #{Enum.map_join(legal, ", ", &inspect/1)}."
      )
    end
  end

  defp refuse_duplicates!(entries, what, key_fun) do
    ids = Enum.map(entries, key_fun)

    case ids -- Enum.uniq(ids) do
      [] -> ids
      [dup | _] -> Mix.raise("Duplicate #{what}: #{inspect(dup)}")
    end
  end

  defp normalize_ctx(ctx) when is_list(ctx), do: ctx
  defp normalize_ctx(ctx) when is_binary(ctx), do: [ctx]

  # -- completeness ---------------------------------------------------------

  # The registry ⊆ JSON direction is what the generator can force. The reverse
  # direction — a JSON context nobody registered — is legitimate (several
  # contexts own no Ash domain), so it is not an error here.
  defp check_completeness!(data, model) do
    registered =
      for context <- model.contexts,
          domain = context["domain"],
          is_binary(domain),
          do: {domain, context["id"]}

    missing_domains =
      for domain <- model.domains,
          module = Registry.module_name(domain),
          module not in Enum.map(registered, &elem(&1, 0)) do
        module
      end

    unless missing_domains == [] do
      Mix.raise(
        "These registered domains have no context in the domain map: " <>
          Enum.map_join(missing_domains, ", ", &inspect/1) <>
          ". Add a context with \"domain\" set, or remove the domain from :ash_domains."
      )
    end

    first_party = first_party_lock_packages(model.lock, model.first_party_orgs)

    claimed =
      MapSet.union(
        MapSet.new(data["substrates"], & &1["package"]),
        MapSet.new(Enum.flat_map(data["contexts"], & &1["packages"]))
      )

    unclaimed = Enum.filter(first_party, &(&1 not in claimed))

    unless unclaimed == [] do
      Mix.raise(
        "These first-party entries in #{@lock} are claimed by no substrate or context package: " <>
          Enum.map_join(unclaimed, ", ", &inspect/1) <> "."
      )
    end
  end

  # -- model helpers ---------------------------------------------------------

  defp resources(domains) do
    domains
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp relationship_edges(resources, ctx_by_resource, ctx_by_domain) do
    for resource <- resources,
        from = ctx_of(resource, ctx_by_resource, ctx_by_domain),
        from,
        rel <- Ash.Resource.Info.relationships(resource),
        to = rel_ctx(rel, ctx_by_resource, ctx_by_domain),
        to && to != from do
      {from, to}
    end
    |> Enum.frequencies()
    |> Enum.sort()
  end

  defp rel_ctx(rel, ctx_by_resource, ctx_by_domain) do
    dest = rel.destination
    dest_domain = Map.get(rel, :domain) || Ash.Resource.Info.domain(dest)

    ctx_of(dest, ctx_by_resource, ctx_by_domain) ||
      ctx_by_domain[Registry.module_name(dest_domain)]
  end

  defp ctx_of(resource, ctx_by_resource, ctx_by_domain) do
    Map.get(ctx_by_resource, resource) ||
      ctx_by_domain[Registry.module_name(Ash.Resource.Info.domain(resource))]
  end

  defp first_party_lock_packages(lock, orgs) do
    for {package, {:git, url, _rev}} <- lock,
        org <- orgs,
        String.contains?(url, org) do
      package
    end
    |> Enum.sort()
    |> Enum.uniq()
  end

  # Parsed with two anchored scans rather than `Code.eval_string/1`: the eval
  # works but re-compiles the lock literal, spraying a quoted-keyword warning
  # per dependency into every run, and CI checks run this task.
  defp read_lock! do
    unless File.exists?(@lock) do
      Mix.raise("#{@lock} does not exist.")
    end

    content = File.read!(@lock)

    hexes =
      Regex.scan(~r/^\s*"([^"]+)": \{:hex, :[^,]+, "([^"]+)"/m, content, capture: :all_but_first)

    gits =
      Regex.scan(~r/^\s*"([^"]+)": \{:git, "([^"]+)", "([0-9a-f]+)"/m, content,
        capture: :all_but_first
      )

    hexes
    |> Map.new(fn [package, version] -> {package, {:hex, version}} end)
    |> Map.merge(Map.new(gits, fn [package, url, rev] -> {package, {:git, url, rev}} end))
    |> tap(fn lock ->
      # Every entry line in the lock must have resolved to a key: a shape this
      # parser does not recognize is a silently missing package, never an
      # empty cell.
      entry_names =
        Regex.scan(~r/^\s*"([^"]+)": \{:(hex|git),/m, content, capture: :all_but_first)
        |> MapSet.new(fn [package, _kind] -> package end)

      if map_size(lock) != MapSet.size(entry_names) do
        Mix.raise(
          "Parsed #{map_size(lock)} of #{MapSet.size(entry_names)} entries from #{@lock}; " <>
            "an entry does not match the known hex/git shapes and its package would be silently missing."
        )
      end

      if lock == %{} do
        Mix.raise("No hex or git entries parsed from #{@lock}; its format may have changed.")
      end
    end)
  end

  defp over_budget?(model) do
    length(json_edges(model)) + length(model.rel_edges) + length(signal_pairs(model)) >
      @edge_budget
  end

  defp json_edges(model),
    do: Enum.flat_map(model.data["contexts"], &Enum.map(&1["edges"], fn e -> {&1["id"], e} end))

  defp signal_pairs(model) do
    model.signals
    |> Enum.flat_map(fn entry ->
      froms = ctxs(entry.emitters, model)
      tos = ctxs(entry.listeners, model)

      for from <- froms, to <- tos, from != to, do: {from, to}
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp ctxs(records, model) do
    records
    |> Enum.map(fn record ->
      ctx_of_resource(record.resource, model)
    end)
    |> Enum.uniq()
  end

  # -- graph ----------------------------------------------------------------

  defp context_label(%{resource_count: count} = context) when count > 0,
    do: "#{context["name"]}<br/>#{count} resources"

  defp context_label(context), do: context["name"]

  defp graph(model) do
    subgraphs =
      for plane <- model.data["planes"] do
        body =
          model.contexts
          |> Enum.filter(&(&1["plane"] == plane["id"]))
          |> Enum.map_join("\n", &~s(    ctx_#{&1["id"]}[#{mermaid_label(context_label(&1))}]))

        "  subgraph #{plane["id"]}[#{mermaid_label(plane["name"])}]\n#{body}\n  end"
      end
      |> Enum.join("\n")

    json_edge_lines =
      for context <- model.data["contexts"], edge <- context["edges"] do
        ~s(  ctx_#{context["id"]} -->|#{mermaid_label(edge["pattern"])}| ctx_#{edge["to"]})
      end
      |> Enum.sort()

    rel_lines =
      if model.fallback? do
        []
      else
        for {{from, to}, n} <- model.rel_edges do
          ~s(  ctx_#{from} -->|#{mermaid_label("#{n} rel#{plural(n)}")}| ctx_#{to})
        end
      end

    signal_lines =
      for {from, to, label} <- signal_edge_rows(model) do
        ~s(  ctx_#{from} -.->|#{mermaid_label(label)}| ctx_#{to})
      end
      |> Enum.sort()

    "```mermaid\nflowchart LR\n\n" <>
      subgraphs <>
      "\n\n" <>
      Enum.join(json_edge_lines ++ rel_lines ++ signal_lines, "\n") <> "\n```"
  end

  defp signal_edge_rows(model) do
    model.signals
    |> Enum.flat_map(fn entry ->
      froms = ctxs(entry.emitters, model)
      tos = ctxs(entry.listeners, model)

      for from <- froms, to <- tos, from != to do
        {from, to, entry.signal.name}
      end
    end)
    |> Enum.group_by(fn {from, to, _name} -> {from, to} end, fn {_from, _to, name} -> name end)
    |> Enum.map(fn {{from, to}, names} ->
      n = names |> Enum.uniq() |> length()
      {from, to, "#{n} signal#{plural(n)}"}
    end)
    |> Enum.sort()
  end

  defp mermaid_label(text) do
    ~s("#{text |> String.replace("|", "&#124;") |> String.replace("\"", "#quot;")}")
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"

  # -- contexts catalogue ---------------------------------------------------

  defp contexts_catalogue(model) do
    header = "| Context | Plane | Domain | Mission |\n|---|---|---|---|\n"

    rows =
      for context <- model.data["contexts"] do
        plane = Enum.find(model.data["planes"], &(&1["id"] == context["plane"]))
        domain = context["domain"] && "`#{context["domain"]}`"

        "| [#{context["name"]}](##{context["id"]}) | #{plane["name"]} | #{domain || "—"} | #{context["mission"]} |"
      end
      |> Enum.join("\n")

    header <> rows
  end

  # -- context section ------------------------------------------------------

  defp context_section(model, context, adr_dir, adr_link_prefix) do
    meta =
      [
        "Plane: **#{plane_name(model, context["plane"])}**",
        context["domain"] && "Domain: `#{context["domain"]}`",
        context["packages"] != [] &&
          "Packages: #{Enum.map_join(context["packages"], ", ", &"`#{&1}`")}",
        context["adrs"] != [] &&
          "ADRs: #{Enum.map_join(context["adrs"], ", ", &adr_link(&1, adr_dir, adr_link_prefix))}"
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" · ")

    """
    #{meta}

    #{context["mission"]}
    """ <>
      terms_section(context) <>
      resources_section(model, context) <>
      signals_section(model, context)
  end

  defp blank?(nil), do: true
  defp blank?(false), do: true
  defp blank?(_), do: false

  defp plane_name(model, plane_id) do
    case Enum.find(model.data["planes"], &(&1["id"] == plane_id)) do
      %{"name" => name} -> name
      _ -> plane_id
    end
  end

  defp terms_section(context) do
    rows =
      for term <- context["terms"] do
        "| **#{term["term"]}** | #{term["definition"]} |"
      end
      |> Enum.join("\n")

    """

    **Ubiquitous language**

    | Term | Meaning |
    |---|---|
    """ <> rows <> "\n"
  end

  defp resources_section(_model, %{"domain" => nil}), do: ""

  # Provider products the integration edge syncs name their own resources in
  # the code (`Integration.Gmail`, `Integration.Slack`...). The artifact names
  # no vendor, so those rows are omitted here and counted instead. The tokens
  # are the host's `vendor_tokens` JSON — product names, not generic words:
  # `Canonical.CalendarEvent` stays, it is corpus vocabulary, not a vendor.
  defp resources_section(model, context) do
    {shown, hidden} =
      Enum.split_with(context[:resources], fn resource ->
        name = Registry.module_name(resource)
        not Enum.any?(model.tokens, &String.contains?(name, &1))
      end)

    rows =
      for resource <- shown do
        description = Ash.Resource.Info.description(resource)
        aggs = length(Ash.Resource.Info.aggregates(resource))
        calcs = length(Ash.Resource.Info.calculations(resource))

        "| `#{Registry.module_name(resource)}` | #{description || "—"} | #{aggs} | #{calcs} |"
      end
      |> Enum.join("\n")

    omitted =
      if hidden == [] do
        ""
      else
        "\n\n*#{length(hidden)} provider-named resources omitted from this table.*"
      end

    n = context[:resource_count]

    """

    **Resources** — #{n} introspected

    | Resource | Description | Aggregates | Calculations |
    |---|---|---|---|
    """ <> rows <> omitted <> "\n"
  end

  defp signals_section(model, context) do
    id = context["id"]

    inbound =
      for entry <- model.signals,
          listener <- entry.listeners,
          ctx_of_resource(listener.resource, model) == id do
        {entry, listener, "listens"}
      end

    outbound =
      for entry <- model.signals,
          emitter <- entry.emitters,
          ctx_of_resource(emitter.resource, model) == id do
        {entry, emitter, "emits"}
      end

    if inbound == [] and outbound == [] do
      ""

      # A context with no declared signal involvement stays quiet: the section
      # would otherwise be forty identical "(none)" rows.
    else
      """
      \n**Signals**

      | Direction | Signal | Counterpart |
      |---|---|---|
      """ <>
        Enum.map_join(outbound ++ inbound, "\n", fn {entry, _record, dir} ->
          counterpart = counterpart_ctxs(entry, dir, model)

          "| #{dir} | `#{Registry.module_name(entry.signal_module)}.#{entry.signal.name}` | #{counterpart} |"
        end) <> "\n"
    end
  end

  # Signal-graph records differ by shape: `signals_in` listeners arrive as
  # `Ash.Resource.SignalListener` structs, `emit` declarations as plain maps —
  # both carry the resource under :resource. Extract it here, not at the call
  # sites, so a registry with a real signal graph renders instead of feeding
  # the record itself into `Ash.Resource.Info.domain/1`.
  defp record_resource(record) when is_map(record), do: Map.get(record, :resource)
  defp record_resource(_), do: nil

  defp counterpart_ctxs(entry, "emits", model) do
    entry.listeners |> Enum.map(&record_resource/1) |> ctx_names(model) |> join_names()
  end

  defp counterpart_ctxs(entry, "listens", model) do
    entry.emitters |> Enum.map(&record_resource/1) |> ctx_names(model) |> join_names()
  end

  defp ctx_names(resources, model) do
    resources
    |> Enum.map(&ctx_of_resource(&1, model))
    |> Enum.uniq()
  end

  defp ctx_of_resource(nil, _model), do: "(generic action)"

  defp ctx_of_resource(resource, model) do
    Map.get(model.ctx_by_resource, resource) ||
      domain_ctx(resource, model) ||
      Registry.module_name(resource)
  end

  # A resource may declare no `domain:` (a bare `signals_in` listener fixture,
  # for one); it then attributes to itself instead of crashing the render.
  defp domain_ctx(resource, model) do
    case Ash.Resource.Info.domain(resource) do
      nil -> nil
      domain -> model.ctx_by_domain[Registry.module_name(domain)]
    end
  end

  defp join_names([]), do: "—"
  defp join_names(names), do: Enum.join(names, ", ")

  # -- substrates -----------------------------------------------------------

  defp substrates(model) do
    header = "| Package | Kind | Locked as | Context | Role |\n|---|---|---|---|\n"

    rows =
      for substrate <- model.data["substrates"] do
        context =
          substrate["context"]
          |> normalize_ctx()
          |> Enum.map_join(", ", fn id ->
            name = context_name(model, id)
            "[#{name}](##{id})"
          end)

        "| `#{substrate["package"]}` | #{substrate["kind"]} | #{locked_as(substrate, model)} | #{context} | #{substrate["role"]} |"
      end
      |> Enum.join("\n")

    header <> rows
  end

  defp context_name(model, id) do
    case Enum.find(model.data["contexts"], &(&1["id"] == id)) do
      %{"name" => name} -> name
      _ -> id
    end
  end

  defp locked_as(%{"kind" => "in-repo", "path" => path}, _model), do: "in-repo (`#{path}/`)"

  defp locked_as(%{"package" => package}, model) do
    case model.lock[package] do
      {:git, _url, rev} -> "git @ #{String.slice(rev, 0, 8)}"
      {:hex, version} -> "hex #{version}"
      nil -> Mix.raise("Substrate #{inspect(package)} is not in #{@lock}.")
    end
  end

  # -- signals region -------------------------------------------------------

  defp signals_region(model) do
    flow_table =
      if model.signals == [] do
        "No declared signals cross the registered domains: no resource in `:ash_domains` declares\n" <>
          "an `emit` on an action, and none declares a `signals_in` listener. The map renders the\n" <>
          "table the day one does."
      else
        header = "| Signal | Emitted by | Listened by |\n|---|---|---|\n"

        rows =
          for entry <- model.signals do
            emitters = ctx_names(Enum.map(entry.emitters, & &1.resource), model) |> join_names()
            listeners = ctx_names(Enum.map(entry.listeners, & &1.resource), model) |> join_names()

            "| `#{Registry.module_name(entry.signal_module)}.#{entry.signal.name}` | #{emitters} | #{listeners} |"
          end
          |> Enum.join("\n")

        header <> rows
      end

    edge_header = "\n**Bounded-context edges**\n\n"

    edge_table =
      "| From | Pattern | To | Note |\n|---|---|---|---|\n" <>
        (model.data["contexts"]
         |> Enum.flat_map(fn context ->
           Enum.map(context["edges"], fn edge ->
             "| [#{context_name(model, context["id"])}](##{context["id"]}) | #{edge["pattern"]} | " <>
               "[#{context_name(model, edge["to"])}](##{edge["to"]}) | #{edge["note"]} |"
           end)
         end)
         |> Enum.join("\n"))

    matrix =
      if model.fallback? do
        "\n**Relationship counts**\n\n" <> relationship_matrix(model)
      else
        ""
      end

    flow_table <> edge_header <> edge_table <> matrix
  end

  defp relationship_matrix(model) do
    ctx_ids = Enum.map(model.data["contexts"], & &1["id"])
    pairs = Map.new(model.rel_edges)

    header =
      "| From \\ To | " <> Enum.map_join(ctx_ids, " | ", &context_name(model, &1)) <> " |\n"

    rule = "|---|" <> String.duplicate("---|", length(ctx_ids)) <> "\n"

    rows =
      for from <- ctx_ids do
        cells = Enum.map_join(ctx_ids, " | ", &matrix_cell(Map.get(pairs, {from, &1})))

        "| [#{context_name(model, from)}](##{from}) | " <> cells <> " |"
      end
      |> Enum.join("\n")

    header <> rule <> rows
  end

  defp matrix_cell(nil), do: " "
  defp matrix_cell(n), do: "#{n}"

  # -- adopted ---------------------------------------------------------------

  defp adopted(model) do
    header = "| Package | Role |\n|---|---|\n"

    rows =
      for adopted <- model.data["adopted"] do
        "| `#{adopted["package"]}` | #{adopted["role"]} |"
      end
      |> Enum.join("\n")

    header <> rows
  end

  # -- links ----------------------------------------------------------------

  defp adr_link(n, adr_dir, adr_link_prefix) do
    slug = String.pad_leading(Integer.to_string(n), 4, "0")

    case Path.wildcard(Path.join(adr_dir, "#{slug}-*.md")) do
      [path | _] -> "[ADR #{n}](#{adr_link_prefix}/#{Path.basename(path)})"
      [] -> "ADR #{n}"
    end
  end
end
