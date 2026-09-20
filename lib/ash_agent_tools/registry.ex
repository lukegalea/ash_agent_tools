# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Registry do
  @moduledoc """
  Discovery of loaded Ash domains and resources.

  Discovery is a pure function over the code server's list of loaded modules:
  a module counts as an Ash domain/resource when it exposes `spark_is/0`
  (the Spark DSL identity marker) and reports the matching kind. Nothing is
  loaded on your behalf — see `AshAgentTools.list_domains/0` for the caveat
  about compiled-but-never-loaded modules.
  """

  @doc """
  All currently loaded modules whose Spark DSL identity is `Ash.Domain`.
  """
  @spec list_domains() :: [module()]
  def list_domains, do: loaded_modules_matching(&(&1.spark_is() == Ash.Domain))

  @doc """
  All currently loaded modules whose Spark DSL identity is `Ash.Resource`.
  """
  @spec list_resources() :: [module()]
  def list_resources, do: loaded_modules_matching(&(&1.spark_is() == Ash.Resource))

  @doc """
  The loaded Ash domains that list the given resource.

  Used to attribute code interfaces defined on the domain side (`define`
  blocks in a domain's `resources` section).
  """
  @spec domains_for_resource(module()) :: [module()]
  def domains_for_resource(resource) do
    list_domains()
    |> Enum.filter(fn domain ->
      resource in Ash.Domain.Info.resources(domain)
    end)
  end

  @doc """
  Renders a module as a string without emitting the `Elixir.` prefix.
  """
  @spec module_name(module()) :: String.t()
  def module_name(module) when is_atom(module) do
    module |> Module.split() |> Enum.join(".")
  end

  defp loaded_modules_matching(predicate) do
    :code.all_loaded()
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.filter(fn module ->
      function_exported?(module, :spark_is, 0) and predicate.(module)
    end)
    |> Enum.sort()
  rescue
    _ -> []
  end
end
