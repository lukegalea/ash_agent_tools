# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Test.Decisions do
  @moduledoc """
  A real `ash_decisions` domain for the decision tooling tests — the engine's
  own resource macros against the sandboxed `AshAgentTools.TestRepo` (see
  `AshAgentTools.Test.Bpmn` for why the macros imply a database).
  """

  defmodule Definition do
    @moduledoc false
    use AshDecisions.Resources.Definition,
      domain: AshAgentTools.Test.DecisionsDomain,
      repo: AshAgentTools.TestRepo
  end

  defmodule Evaluation do
    @moduledoc false
    use AshDecisions.Resources.Evaluation,
      domain: AshAgentTools.Test.DecisionsDomain,
      repo: AshAgentTools.TestRepo,
      definition: Definition
  end
end

defmodule AshAgentTools.Test.DecisionsDomain do
  @moduledoc """
  The decisions domain: definition catalogue + evaluation ledger.
  """

  use Ash.Domain

  resources do
    resource AshAgentTools.Test.Decisions.Definition
    resource AshAgentTools.Test.Decisions.Evaluation
  end
end
