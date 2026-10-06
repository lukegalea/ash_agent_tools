# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Edit.Single do
  @moduledoc false

  import AshAgentTools.Edit.Support
  import AshAgentTools.Edit.Writer

  def run(op, name_path, body, opts) when is_list(opts) do
    with {:ok, resolved} <- resolve(name_path),
         :ok <- check_body(op, body),
         :ok <- check_provenance(resolved),
         {:ok, file, content} <- read_target(resolved),
         {:ok, current_shape} <- shape!(file),
         {:ok, range} <- locate_block(file, content, resolved),
         :ok <- check_references(op, resolved) do
      {spliced, diff} =
        splice(op, content, range, prepare_body(op, body, content, range))

      {new_content, formatted?} = format_pass(file, content, spliced)
      diff = format_note(diff, formatted?)

      if opts[:write] do
        finish_write(%{
          op: Atom.to_string(op),
          name_path: resolved.name_path,
          file: file,
          original: content,
          new_content: new_content,
          diff: diff,
          current_digest: current_shape.digest,
          expected_digest: opts[:expected_digest],
          modules: [resolved.module.module],
          formatted?: formatted?
        })
      else
        {:ok,
         %{
           op: Atom.to_string(op),
           name_path: resolved.name_path,
           file: file,
           dry_run?: true,
           write?: false,
           diff: diff,
           formatted?: formatted?,
           current_digest: current_shape.digest
         }
         |> maybe_format_hint(formatted?)}
      end
    end
  end

  def run(_op, name_path, _body, _opts) do
    {:error,
     %{
       error: "invalid_name_path",
       message: "name_path must be a string, got: #{inspect(name_path)}"
     }}
  end

  # -- steps -----------------------------------------------------------------
end
