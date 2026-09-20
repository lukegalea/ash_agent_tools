# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Test.Guarded do
  @moduledoc """
  A policy-protected resource, so `explain_forbidden/2` has realistic
  policies to list: an admin bypass, a read policy, and a field policy.
  """

  use Ash.Resource,
    domain: AshAgentTools.Test.Domain,
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_primary_key :id

    attribute :name, :string, public?: true

    attribute :public, :boolean do
      default false
      public? true
    end
  end

  actions do
    defaults [:read, :create, :update, :destroy]
  end

  field_policies do
    field_policy :name do
      authorize_if actor_attribute_equals(:admin, true)
    end

    field_policy :* do
      authorize_if always()
    end
  end

  policies do
    bypass actor_attribute_equals(:admin, true) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if actor_present()
      authorize_if expr(public == true)
    end
  end
end
