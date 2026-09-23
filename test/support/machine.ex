# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ast-forks/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Test.Machine do
  @moduledoc """
  An `AshStateMachine` resource, so the `transitions` tool has a real
  compiled `state_machine` section to project: a review lifecycle with a
  two-way branch (reject → rejected/cancelled) and an archive sink. Each
  named transition gets its update action, as the extension's verifier
  requires.
  """

  use Ash.Resource,
    domain: AshAgentTools.Test.Domain,
    extensions: [AshStateMachine]

  state_machine do
    initial_states([:pending])
    default_initial_state(:pending)

    transitions do
      transition(:confirm, from: :pending, to: :confirmed)
      transition(:reject, from: :pending, to: [:rejected, :cancelled])
      transition(:archive, from: [:confirmed, :rejected], to: :archived)
    end
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:create, :read]

    update :confirm do
      accept []
      change transition_state(:confirmed)
    end

    update :reject do
      accept []
      change transition_state(:rejected)
    end

    update :cancel do
      accept []
      change transition_state(:cancelled)
    end

    update :archive do
      accept []
      change transition_state(:archived)
    end
  end
end
