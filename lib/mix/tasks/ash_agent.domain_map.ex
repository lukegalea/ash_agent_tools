# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.DomainMap do
  @shortdoc "Render the domain map regions in a markdown file from an editorial JSON + Ash introspection"

  @moduledoc """
  Renders the domain map — an application's bounded contexts, their planes,
  substrates and relationships — from one machine-readable source plus what the
  registered domains declare.

      mix ash_agent.domain_map [--check] [--init]
          [--source PATH] [--target PATH] [--adr-dir PATH]

  `docs/domain-map.json` is the editorial source (planes, contexts, missions,
  terms, edges, package roles — plus the host policy as JSON data:
  `"first_party_orgs"`, `"vendor_tokens"`, the in-repo substrate `"path"`, and
  `"draft": true` while a seed is still being written). Everything
  introspectable is not stored there: the generator reads
  `config :my_app, ash_domains`, each domain's resources, their relationships,
  and the declared signal graph (`Ash.Signals.Graph.build/1`), and renders the
  generated regions of `docs/DOMAIN-MAP.md`.

  Regions are delimited by HTML comments and rewritten between them:

      <!-- domain-map:context:security:start -->
      ...generated...
      <!-- domain-map:context:security:end -->

  A region naming an unknown renderer is an error rather than a silent no-op,
  and a context in the JSON without its `context:<id>` region in the target is
  an error too — the map must be complete or it must not render.

  `--init` seeds a first `docs/domain-map.json` (one plane, one context per
  registered domain, `"draft": true`) and a skeleton `docs/DOMAIN-MAP.md`, then
  prints what to edit next. It neither validates the seed nor rewrites an
  existing file.

  **Boot contract: compile, don't start.** The task runs under
  `@requirements ["app.config"]` and reads compile-time info only: a resource
  description is rendered when the author wrote one and nothing invented when
  they did not. Regeneration is manual by design — derived output arrives
  through review; CI gates drift with `--check`.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv,
        strict: [
          check: :boolean,
          init: :boolean,
          source: :string,
          target: :string,
          "adr-dir": :string
        ]
      )

    source = Keyword.get(opts, :source, "docs/domain-map.json")
    target = Keyword.get(opts, :target, "docs/DOMAIN-MAP.md")
    adr_dir = Keyword.get(opts, :"adr-dir", "docs/adr")

    AshAgentTools.TaskOutput.with_quiet_logger(opts, fn ->
      AshAgentTools.TaskOutput.ensure_compiled()
      AshAgentTools.TaskOutput.load_configured_domains()

      domains = Application.get_env(Mix.Project.config()[:app], :ash_domains, [])

      if opts[:init] do
        seed(source, target, domains)
      else
        generate(source, target, adr_dir, domains, check?: Keyword.get(opts, :check, false))
      end
    end)
  end

  # -- seed -----------------------------------------------------------------

  defp seed(source, target, domains) do
    cond do
      File.exists?(source) ->
        Mix.raise(
          "#{source} already exists; --init never rewrites an existing file. " <>
            "Run the task without --init to render it."
        )

      File.exists?(target) ->
        Mix.raise(
          "#{target} already exists; --init never rewrites an existing file. " <>
            "Run the task without --init to render it."
        )

      true ->
        :ok
    end

    File.mkdir_p!(Path.dirname(source))
    File.mkdir_p!(Path.dirname(target))
    File.write!(source, seed_json(domains))
    File.write!(target, skeleton(domains))

    Mix.shell().info("""

    Seeded #{source} and #{target}.

    Next steps:
      1. Edit #{source}: rename the plane, give every context its mission and
         three to eight ubiquitous-language terms, add substrates and adopted
         packages. Missions come from the declarations themselves — never
         invent prose the code does not carry.
      2. Remove the "draft" key when the editorial pass is done. While it is
         set, validation holds to the referential-integrity, lock-existence and
         completeness rules so the seed can grow.
      3. Run `mix ash_agent.domain_map` (without --init) to render the regions,
         and commit both files.
    """)
  end

  defp seed_json(domains) do
    %{
      "planes" => [
        %{
          "id" => "platform",
          "name" => "Platform",
          "purpose" => "Drafted by --init; edit me."
        }
      ],
      "contexts" => seed_contexts(domains),
      "substrates" => [],
      "adopted" => [],
      "first_party_orgs" => [],
      "vendor_tokens" => [],
      "draft" => true
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  # One context per registered domain: the id is the domain module's last
  # segment in kebab-case, falling back to the full module path when two
  # domains share a last segment. Missions come from the domain module's
  # `@moduledoc` first sentence — never invented prose.
  defp seed_contexts(domains) do
    {contexts, _taken} =
      Enum.map_reduce(domains, MapSet.new(), fn domain, taken ->
        name = AshAgentTools.Registry.module_name(domain)
        short = kebab(last_segment(name))
        id = if MapSet.member?(taken, short), do: kebab(name), else: short

        context = %{
          "id" => id,
          "name" => humanize(last_segment(name)),
          "domain" => name,
          "plane" => "platform",
          "mission" => moduledoc_mission(domain),
          "packages" => [],
          "adrs" => [],
          "terms" => [],
          "edges" => []
        }

        {context, MapSet.put(taken, id)}
      end)

    contexts
  end

  defp skeleton(domains) do
    context_sections =
      domains
      |> seed_contexts()
      |> Enum.map_join("\n", fn context ->
        id = context["id"]

        """

        ### #{context["name"]}

        <a name="#{id}"></a>

        <!-- domain-map:context:#{id}:start -->

        <!-- domain-map:context:#{id}:end -->
        """
      end)

    """
    # Domain map

    One generated artifact: the bounded contexts, their planes, substrates and
    relationships, rendered by `mix ash_agent.domain_map` from
    `docs/domain-map.json` and the registered domains. Everything between the
    region markers is generated — edit the JSON or the declarations and re-run
    the task, never the regions.

    ## The planes

    The planes are the capability groupings the contexts belong to; the graph
    below is generated from the JSON.

    <!-- domain-map:graph:start -->

    <!-- domain-map:graph:end -->

    ## Bounded contexts

    <!-- domain-map:contexts:start -->

    <!-- domain-map:contexts:end -->#{context_sections}
    ## Substrate packages

    <!-- domain-map:substrates:start -->

    <!-- domain-map:substrates:end -->

    ## Context relationships

    <!-- domain-map:signals:start -->

    <!-- domain-map:signals:end -->

    ## Adopted platform

    <!-- domain-map:adopted:start -->

    <!-- domain-map:adopted:end -->

    ## Staying current

    Run `mix ash_agent.domain_map` after changing `docs/domain-map.json` or the
    registered domains, and commit the result. CI runs the same task with
    `--check` and fails when the regions disagree with either.
    """
  end

  defp last_segment(name), do: name |> String.split(".") |> List.last()

  defp kebab(name),
    do:
      name
      |> String.split(~r/(?<=[a-z0-9])(?=[A-Z])/)
      |> Enum.map_join("-", &String.downcase/1)

  defp humanize(name),
    do: name |> String.split(~r/(?<=[a-z0-9])(?=[A-Z])/) |> Enum.join(" ")

  defp moduledoc_mission(domain) do
    case Code.fetch_docs(domain) do
      {:docs_v1, _anno, _lang, _format, %{"en" => doc}, _meta, _docs} when is_binary(doc) ->
        doc |> first_sentence() |> Kernel.||("Drafted by --init; edit me.")

      _ ->
        "Drafted by --init; edit me."
    end
  end

  defp first_sentence(doc) do
    doc
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> List.first()
    |> case do
      nil -> nil
      line -> line |> String.split(~r/(?<=\.)\s/) |> hd() |> String.trim()
    end
  end

  # -- generate / check -----------------------------------------------------

  defp generate(source, target, adr_dir, domains, check?: check?) do
    data = load_source!(source)
    model = AshAgentTools.DomainMap.build_model(data, domains)

    regions = AshAgentTools.DomainMap.regions(model, adr_dir, link_prefix(adr_dir, target))

    AshAgentTools.DomainMap.ensure_target_regions!(target, regions)

    case AshAgentTools.DomainMap.rewrite(target, regions) do
      {:changed, content} ->
        if check? do
          Mix.shell().error("""

          #{target} is out of date with #{source} and the registered domains.

          Run `mix ash_agent.domain_map` and commit the result.
          """)

          exit({:shutdown, 1})
        else
          File.write!(target, content)
          Mix.shell().info("Rewrote #{target}")
        end

      {:unchanged, _} ->
        if check? do
          Mix.shell().info("The domain map is up to date with #{source}.")
        else
          Mix.shell().info("Unchanged #{target}")
        end
    end
  end

  # The ADR links are relative to the markdown target's directory, so a target
  # outside the default layout still links correctly.
  defp link_prefix(adr_dir, target),
    do: Path.relative_to(adr_dir, Path.dirname(target)) |> String.replace_suffix("/", "")

  defp load_source!(source) do
    unless File.exists?(source) do
      Mix.raise(
        "#{source} does not exist. It is the editorial source of the domain map. " <>
          "Run `mix ash_agent.domain_map --init` to seed one."
      )
    end

    case source |> File.read!() |> Jason.decode() do
      {:ok, %{"planes" => _, "contexts" => _, "substrates" => _, "adopted" => _} = data} ->
        AshAgentTools.DomainMap.validate!(data)
        data

      {:ok, _} ->
        Mix.raise(
          ~s|#{source} must contain the "planes", "contexts", "substrates" and "adopted" keys.|
        )

      {:error, error} ->
        Mix.raise("#{source} is not valid JSON: #{Exception.message(error)}")
    end
  end
end
