# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Test.SimpleDataLayer do
  @moduledoc """
  `Ash.DataLayer.Simple` plus the aggregate capability clauses.

  The introspection API never runs actions, but Ash's
  `ValidateAggregatesSupported` verifier rejects the test Post's
  `comment_count` aggregate unless the resource's data layer claims to
  aggregate — and plain resources (Simple) do not. Everything here delegates
  to `Ash.DataLayer.Simple`; only `can?/2` grows the aggregate clauses the
  verifier asks about. The name keeps the word "Simple" because the describe
  tool reports the data layer and its tests assert on it.
  """

  use Spark.Dsl.Extension, transformers: [], sections: []

  @behaviour Ash.DataLayer

  @doc false
  def can?(_, {:aggregate_relationship, _}), do: true
  def can?(_, {:aggregate, :count}), do: true
  def can?(resource, other), do: Ash.DataLayer.Simple.can?(resource, other)

  defdelegate set_data(query, data), to: Ash.DataLayer.Simple
  defdelegate resource_to_query(resource, domain), to: Ash.DataLayer.Simple
  defdelegate run_query(query, resource), to: Ash.DataLayer.Simple
  defdelegate limit(query, limit, resource), to: Ash.DataLayer.Simple
  defdelegate offset(query, offset, resource), to: Ash.DataLayer.Simple
  defdelegate set_tenant(resource, query, tenant), to: Ash.DataLayer.Simple
  defdelegate filter(query, filter, resource), to: Ash.DataLayer.Simple
  defdelegate sort(query, sort, resource), to: Ash.DataLayer.Simple
  defdelegate set_context(resource, query, context), to: Ash.DataLayer.Simple
  defdelegate create(resource, changeset), to: Ash.DataLayer.Simple
  defdelegate bulk_create(resource, stream, options), to: Ash.DataLayer.Simple
  defdelegate update(resource, changeset), to: Ash.DataLayer.Simple
  defdelegate destroy(resource, changeset), to: Ash.DataLayer.Simple
end
