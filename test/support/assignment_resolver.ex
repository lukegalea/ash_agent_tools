# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Test.AssignmentResolver do
  @moduledoc """
  The `AshBpmn.AssignmentResolver` test double: resolves every candidate
  spec to one deterministic synthetic user, derived from the spec itself so
  a test can assert exactly which principal a task was offered to.
  """

  @behaviour AshBpmn.AssignmentResolver

  @impl true
  def candidates(specs, _ctx) do
    {:ok, Enum.map(specs, fn spec -> %{type: :user, id: principal_id(spec)} end)}
  end

  @impl true
  def exclusions(_specs, _ctx), do: {:ok, []}

  @doc "The deterministic principal id a spec resolves to."
  def principal_id(spec) do
    <<a::32, b::16, c::16, d::16, e::48>> =
      :sha256 |> :crypto.hash("candidate:" <> inspect(spec)) |> binary_part(0, 16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end
end
