# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Test.Comment do
  @moduledoc false

  use Ash.Resource, domain: AshAgentTools.Test.Domain

  attributes do
    uuid_primary_key :id
  end

  relationships do
    belongs_to :post, AshAgentTools.Test.Post, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, :create]
  end
end
