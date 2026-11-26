# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Test.Signals do
  @moduledoc """
  The test signal module: one signal, emitted by `AshAgentTools.Test.SignalSource`,
  listened to by `AshAgentTools.Test.SignalSink`, so the domain map's signal
  rendering runs against a real declared graph.
  """

  use Ash.Signals

  signals do
    signal :thing_happened do
      argument :source_id, :uuid, allow_nil?: false
    end
  end
end

defmodule AshAgentTools.Test.SignalSource do
  @moduledoc "Emits the test signal from its create action."

  use Ash.Resource,
    domain: AshAgentTools.Test.SignalDomain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    create :create do
      accept []
      emit AshAgentTools.Test.Signals, :thing_happened, fields: [source_id: :id]
    end
  end
end

defmodule AshAgentTools.Test.SignalSink do
  @moduledoc "Listens to the test signal through `signals_in`."

  use Ash.Resource,
    domain: AshAgentTools.Test.SignalSinkDomain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :source_id, :uuid
  end

  actions do
    create :react do
      accept [:source_id]
    end
  end

  signals_in do
    from AshAgentTools.Test.Signals do
      on :thing_happened, :react
    end
  end
end

defmodule AshAgentTools.Test.SignalSinkDomain do
  @moduledoc """
  A second domain for the sink, so the domain map's counterpart extraction has
  to cross a context boundary to name the right side of the flow.
  """

  use Ash.Domain

  resources do
    resource AshAgentTools.Test.SignalSink
  end
end

defmodule AshAgentTools.Test.SignalDomain do
  @moduledoc """
  The domain hosting the signal fixtures, kept out of
  `AshAgentTools.Test.Domain` so ordinary introspection tests stay signal-free.
  """

  use Ash.Domain

  resources do
    resource AshAgentTools.Test.SignalSource
  end
end
