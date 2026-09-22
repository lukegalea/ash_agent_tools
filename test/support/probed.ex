# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Test.Probed do
  @moduledoc """
  A resource carrying the custom `AshAgentTools.Test.ProbeDsl` extension,
  so the generic section probe has foreign-DSL entities to project: named
  widgets, an `:id`-identified gear in a nested section, a `:tag`-only
  badge, and identifier-less seals.
  """

  use Ash.Resource,
    domain: AshAgentTools.Test.Domain,
    extensions: [AshAgentTools.Test.ProbeDsl]

  attributes do
    uuid_primary_key :id
  end

  widgets do
    widget :stethoscope do
      size(:large)
    end

    widget(:syringe)

    gears do
      gear(:main)
    end
  end

  badges do
    badge(:critical)
    seal(level: 3)
    seal()
  end
end
