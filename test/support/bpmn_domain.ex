# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Test.Bpmn do
  @moduledoc """
  A real `ash_bpmn` engine domain for the BPMN tooling tests.

  Built with the engine's own resource macros — the same ones a host uses —
  against the sandboxed `AshAgentTools.TestRepo`. That is deliberate: the
  tools read the engine's *code interfaces* and its `StateExport`, so a
  hand-rolled fixture could silently drift from what a host actually ships.
  The macros are AshPostgres by construction, which is why these tests need
  a database (see `AshAgentTools.BpmnCase`).
  """

  defmodule Definition do
    @moduledoc false
    use AshBpmn.Resources.Definition,
      domain: AshAgentTools.Test.BpmnDomain,
      repo: AshAgentTools.TestRepo
  end

  defmodule Instance do
    @moduledoc false
    use AshBpmn.Resources.Instance,
      domain: AshAgentTools.Test.BpmnDomain,
      repo: AshAgentTools.TestRepo,
      definition: Definition
  end

  defmodule Token do
    @moduledoc false
    use AshBpmn.Resources.Token,
      domain: AshAgentTools.Test.BpmnDomain,
      repo: AshAgentTools.TestRepo,
      instance: Instance
  end

  defmodule HumanTask do
    @moduledoc false
    use AshBpmn.Resources.HumanTask,
      domain: AshAgentTools.Test.BpmnDomain,
      repo: AshAgentTools.TestRepo,
      instance: Instance,
      token: Token
  end

  defmodule TaskCandidate do
    @moduledoc false
    use AshBpmn.Resources.TaskCandidate,
      domain: AshAgentTools.Test.BpmnDomain,
      repo: AshAgentTools.TestRepo,
      task: HumanTask
  end

  defmodule ProcessEvent do
    @moduledoc false
    use AshBpmn.Resources.ProcessEvent,
      domain: AshAgentTools.Test.BpmnDomain,
      repo: AshAgentTools.TestRepo,
      instance: Instance
  end
end

defmodule AshAgentTools.Test.BpmnDomain do
  @moduledoc """
  The engine domain: the core six BPMN resources, no triggers, no tenants —
  the smallest install `AshBpmn.Resources.for_domain/1` accepts.
  """

  use Ash.Domain

  resources do
    resource AshAgentTools.Test.Bpmn.Definition
    resource AshAgentTools.Test.Bpmn.Instance
    resource AshAgentTools.Test.Bpmn.Token
    resource AshAgentTools.Test.Bpmn.HumanTask
    resource AshAgentTools.Test.Bpmn.TaskCandidate
    resource AshAgentTools.Test.Bpmn.ProcessEvent
  end
end
