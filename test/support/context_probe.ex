# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Test.ContextProbe do
  @moduledoc """
  A position fixture for `AshAgentTools.context/3`: a tiny resource whose
  declaration lines are pinned by that function's doctests and its tests.
  The `:excerpt` attribute block and the `:stamp` action must stay where
  they are (or the pinned examples must move with them) — `context/3`
  resolves a line inside the `:excerpt` do-block to `:excerpt` and a line
  inside the `:stamp` do-block to `:stamp`.
  """

  use Ash.Resource, domain: AshAgentTools.Test.Domain

  attributes do
    uuid_primary_key :id

    attribute :excerpt, :string do
      allow_nil? false
      public? true
    end

    attribute :memo, :string, public?: true
  end

  actions do
    defaults [:read]

    create :stamp do
      accept [:excerpt, :memo]
    end
  end
end
