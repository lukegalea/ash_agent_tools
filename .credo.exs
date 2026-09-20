# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

%{
  configs: [
    %{
      name: "default",
      strict: true,
      merge_with_default_config: true,
      checks: %{
        extra: [
          # The default nesting limit (2) flags the package's Info-module
          # read paths, which legitimately nest a for/with around a domain or
          # resource walk; 3 keeps the check meaningful without that noise.
          {Credo.Check.Refactor.Nesting, max_nesting: 3}
        ],
        disabled: [
          # The package's style favors fully-qualified calls into Ash's Info
          # modules (Ash.Resource.Info.*, Ash.Domain.Info.*, ...) and
          # cross-module helpers (AshAgentTools.Registry.*) — they are
          # grep-friendly and keep the called surface obvious at each site,
          # so single-use "alias this nested module" suggestions are noise.
          {Credo.Check.Design.AliasUsage, []}
        ]
      }
    }
  ]
}
