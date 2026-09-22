# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Test.Domain do
  @moduledoc """
  Minimal Ash domain hosting the test resources, so discovery and
  code-interface introspection have realistic input.
  """

  use Ash.Domain

  resources do
    resource AshAgentTools.Test.Post
    resource AshAgentTools.Test.Author
    resource AshAgentTools.Test.Comment
    resource AshAgentTools.Test.Guarded
    resource AshAgentTools.Test.ContextProbe
    resource AshAgentTools.Test.Probed
  end
end
