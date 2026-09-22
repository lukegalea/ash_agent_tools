# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Test.Probe.Widget do
  @moduledoc """
  A probe entity shaped like the common case: identified by `:name`.
  """

  defstruct [:name, :size, :__spark_metadata__]
end

defmodule AshAgentTools.Test.Probe.Gear do
  @moduledoc """
  A probe entity identified through the second fallback, `:id`.
  """

  defstruct [:id, :__spark_metadata__]
end

defmodule AshAgentTools.Test.Probe.Badge do
  @moduledoc """
  A probe entity identified through the last fallback, `:tag` — no
  `:name` field at all.
  """

  defstruct [:tag, :__spark_metadata__]
end

defmodule AshAgentTools.Test.Probe.Seal do
  @moduledoc """
  A probe entity with no identifier-shaped field whatsoever: the
  degenerate shape the positional `<section>_<index>` fallback exists for.
  """

  defstruct [:level, :__spark_metadata__]
end

defmodule AshAgentTools.Test.ProbeDsl do
  @moduledoc """
  A minimal custom Spark extension for the generic section probe: two
  top-level sections (`widgets` with a nested `gears` section, `badges`)
  whose entities cover the identifier ladder — `:name`, `:id`, `:tag`,
  and none of them — plus a section shape with no entities at all
  (`options`).

  The short-name derivation under test: `ProbeDsl` → `probe`, so sections
  project as `probe_widgets`, `probe_widgets_gears`, `probe_badges`,
  `probe_options`.
  """

  use Spark.Dsl.Extension,
    sections: [
      %Spark.Dsl.Section{
        name: :widgets,
        entities: [
          %Spark.Dsl.Entity{
            name: :widget,
            target: AshAgentTools.Test.Probe.Widget,
            args: [:name],
            schema: [
              name: [type: :atom, required: true],
              size: [type: :atom]
            ]
          }
        ],
        sections: [
          %Spark.Dsl.Section{
            name: :gears,
            entities: [
              %Spark.Dsl.Entity{
                name: :gear,
                target: AshAgentTools.Test.Probe.Gear,
                args: [:id],
                schema: [
                  id: [type: :atom, required: true]
                ]
              }
            ],
            schema: []
          }
        ],
        schema: []
      },
      %Spark.Dsl.Section{
        name: :badges,
        entities: [
          %Spark.Dsl.Entity{
            name: :badge,
            target: AshAgentTools.Test.Probe.Badge,
            args: [:tag],
            schema: [
              tag: [type: :atom, required: true]
            ]
          },
          %Spark.Dsl.Entity{
            name: :seal,
            target: AshAgentTools.Test.Probe.Seal,
            schema: [
              level: [type: :integer]
            ]
          }
        ],
        schema: []
      },
      %Spark.Dsl.Section{
        name: :options,
        schema: [
          mode: [type: :atom]
        ]
      }
    ]
end
