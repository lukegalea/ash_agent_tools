# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Test.Injected.Extension do
  @moduledoc """
  A minimal Spark extension whose transformer injects an attribute, mirroring
  how real extensions (ash_archival, platform resources, ...) add shared
  columns: `Ash.Resource.Builder.build_attribute/3` +
  `Spark.Dsl.Transformer.add_entity/3`. Transformer-built entities carry no
  Spark source annotation — which is exactly the shape the describe tooling's
  `~extension` provenance marker detects.
  """

  use Spark.Dsl.Extension,
    transformers: [AshAgentTools.Test.Injected.Extension.AddAttribute]

  defmodule AddAttribute do
    @moduledoc false
    use Spark.Dsl.Transformer

    alias Spark.Dsl.Transformer

    @impl true
    def transform(dsl) do
      case Ash.Resource.Builder.build_attribute(:injected_flag, :boolean,
             allow_nil?: false,
             default: false,
             public?: true,
             description:
               "Injected by the test extension — provenance is not the resource's own source."
           ) do
        {:ok, attribute} ->
          {:ok, Transformer.add_entity(dsl, [:attributes], attribute)}

        {:error, error} ->
          {:error, "Injected.Extension could not build attribute: #{inspect(error)}"}
      end
    end
  end
end

defmodule AshAgentTools.Test.Injected do
  @moduledoc """
  Test resource carrying one in-file attribute and one extension-injected
  attribute, so the describe tooling's extension-provenance marker has both
  a positive and a negative case.
  """

  use Ash.Resource,
    domain: AshAgentTools.Test.Domain,
    data_layer: AshAgentTools.Test.SimpleDataLayer,
    extensions: [AshAgentTools.Test.Injected.Extension]

  attributes do
    uuid_primary_key :id

    attribute :declared_title, :string do
      allow_nil? false
      public? true
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [:declared_title]
    end
  end
end
