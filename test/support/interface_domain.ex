# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Test.InterfaceDomain do
  @moduledoc """
  A second test domain that *declares* a domain-level code interface, so
  the symbol index and name-path resolution have real `code_interfaces`
  entities to address (resource-declared interfaces do not attach to the
  domain's resource-reference entities).
  """

  use Ash.Domain

  resources do
    resource AshAgentTools.Test.Post do
      define :domain_feature, action: :feature
    end

    resource AshAgentTools.Test.Author
    resource AshAgentTools.Test.Comment
    resource AshAgentTools.Test.Guarded
    resource AshAgentTools.Test.ContextProbe
  end
end
