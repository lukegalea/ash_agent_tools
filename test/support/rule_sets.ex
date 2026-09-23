# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ast-forks/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Test.RuleSets.KYC do
  @moduledoc """
  A fixture rule set for `AshAgentTools.Rules`, following the minimal
  `use AshRules` pattern: one `fact_schema`, two rules — one that fires on
  the classic finding, one that exercises absence semantics (`:unknown`).
  """

  use AshRules

  combining(:deny_overrides)

  fact_schema do
    fact(:status, :atom,
      one_of: [:active, :suspended],
      description: "Customer lifecycle status"
    )

    fact(:jurisdiction, :atom)

    fact(:has_valid_kyc, :boolean,
      missing: :unknown,
      description: "KYC verification result; no data means we cannot know"
    )

    fact(:balance, :integer)
    fact(:owner, :atom)
  end

  rule "suspended customer with non-zero balance is a finding",
    id: "acct.balance_frozen",
    severity: :low,
    message: "account %{account} holds a non-zero balance while suspended" do
    when_requires(
      has(:customer, :status, :suspended),
      has(var(:account), :owner, :customer)
    )

    fails_when(neg(var(:account), :balance, 0))
    outcome(:noncompliant, gap: "acct.balance")
  end

  rule "active regulated customer requires valid KYC",
    id: "kyc.valid_required",
    severity: :medium do
    when_requires(
      has(:customer, :status, :active),
      has(:customer, :jurisdiction, :regulated)
    )

    fails_when(neg(:customer, :has_valid_kyc, true))
    outcome(:noncompliant, gap: "kyc.valid_required")
  end
end
