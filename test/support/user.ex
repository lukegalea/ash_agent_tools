# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ast-forks/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Test.User do
  @moduledoc """
  An actor resource for `AshAgentTools.Can`: an ETS-backed record store (the
  actor spec is resolved with `Ash.get!/2`, so this is the fixture that can
  actually fetch one) plus an actor-scoped policy — updates require
  `admin`, everything else is deny-by-default (no applicable policy).
  """

  use Ash.Resource,
    domain: AshAgentTools.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_primary_key :id

    attribute :email, :string, public?: true

    attribute :admin, :boolean do
      default false
      public? true
    end
  end

  actions do
    # fixtures need writable inputs; the Ash 3 default accept is []
    default_accept :*
    defaults [:read, :create, :update]
  end

  policies do
    policy action_type(:update) do
      authorize_if actor_attribute_equals(:admin, true)
    end
  end
end
