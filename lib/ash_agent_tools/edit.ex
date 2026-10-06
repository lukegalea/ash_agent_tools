# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Edit do
  @moduledoc """
  Public facade for semantic edits on Ash DSL entities.

  The implementation is split across focused modules for source analysis,
  creation planning, write gates, and transactional batches.
  """

  alias AshAgentTools.Edit.Batch
  alias AshAgentTools.Edit.Creator
  alias AshAgentTools.Edit.Single
  alias AshAgentTools.Edit.Support

  defdelegate shape(file), to: Support

  defdelegate create_entity(section_path, body, opts \\ []), to: Creator

  def replace_entity_block(name_path, body, opts \\ []),
    do: Single.run(:replace_entity_block, name_path, body, opts)

  def insert_before_entity(name_path, body, opts \\ []),
    do: Single.run(:insert_before_entity, name_path, body, opts)

  def insert_after_entity(name_path, body, opts \\ []),
    do: Single.run(:insert_after_entity, name_path, body, opts)

  def safe_delete_entity(name_path, opts \\ []),
    do: Single.run(:safe_delete_entity, name_path, nil, opts)

  defdelegate apply_batch(ops, opts \\ []), to: Batch
end
