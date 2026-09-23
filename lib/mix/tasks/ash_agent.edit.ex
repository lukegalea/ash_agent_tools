# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Edit do
  @shortdoc "Semantic DSL-entity edits (dry-run by default) as JSON"

  @moduledoc """
  Edits an Ash DSL entity in its source file, addressed by name path —
  e.g. `MyApp.Accounts.User/actions/read` or `.../policies/policy[0]` (see
  `AshAgentTools.NamePath` for the grammar).

  Operations:

    * `create SECTION_PATH` — create a new entity inside a section, empty
      sections included: `SECTION_PATH` is `"Module/dsl_path"` (e.g.
      `MyApp.Post/actions`), and a missing `section do … end` block is
      synthesized inside the module body. Optional `--anchor NAME_PATH
      --position after|before` places the entity next to an existing one
    * `replace NAME_PATH` — swap the entity's source block for `--body`
    * `insert-before NAME_PATH` / `insert-after NAME_PATH` — anchor inserts
    * `delete NAME_PATH` — safe delete; refuses while anything references
      the entity

  Batch mode — `--batch FILE` (a JSON array of op maps, or `-` for stdin):

      [{"op": "create_entity", "section_path": "MyApp.Post/actions",
        "body": "update :check_in do accept [] end"},
       {"op": "insert_after_entity", "name_path": "MyApp.Post/actions/check_in",
        "body": "attribute :reviewed, :boolean"}]

  One digest handshake for the whole file, sequential in-memory application
  (later ops may anchor on entities created earlier in the batch), one
  atomic write, one gate — any failure at any step reverts everything.
  Op names: `create_entity`, `replace_entity_block`, `insert_before_entity`,
  `insert_after_entity`, `safe_delete_entity` (the CLI verbs are accepted as
  aliases).

  **Dry-run by default.** Without `--write` the task prints the planned
  diff plus the file's shape digest and changes nothing. To apply:

      mix ash_agent.edit replace User/actions/by_tag \
        --body-file new_action.ex --write --expected-digest <digest-from-dry-run>

  The `--expected-digest` handshake is the mechanical read-before-edit: it
  is the `current_digest` from your dry-run (or `AshAgentTools.Edit.shape/1`),
  and a mismatch refuses the write.

  Formatter contract: a format-clean file is reformatted whole after the
  edit; a file that was not clean is left exactly as spliced and the report
  carries `"format_hint":"run mix format"`.

  Every applied write passes the post-edit gate: the file is recompiled
  with diagnostics captured and the affected resource runs a per-action
  validate canary — a failed gate reverts the file and reports why.
  Transformer-injected declarations (no Spark annotation) are refused, not
  spliced.

  **Boot contract: compile, don't start** — the task needs compiled DSL
  state for name-path resolution, not a running application.

  **stdout is pure JSON, always** (`is_error?: true` marks error reports;
  the exit code is non-zero for errors).

  ## Usage

      mix ash_agent.edit OP NAME_PATH|SECTION_PATH
          [--body TEXT | --body-file FILE] [--anchor NAME_PATH] [--position after|before]
          [--write] [--expected-digest D] [--batch FILE|-] [--out FILE] [--pretty] [--verbose]

  `--body-file -` reads the body from stdin.

  ## Examples

      $ mix ash_agent.edit replace MyApp.Post/attributes/score \
          --body "attribute :score, :integer, public?: true"
      {"op":"replace_entity_block","name_path":"MyApp.Post/attributes/score",
       "file":"lib/my_app/post.ex","dry_run?":true,"diff":"@@ line 35 @@\\n- ...",
       "current_digest":"9f2c..."}

      $ mix ash_agent.edit create MyApp.Post/actions \
          --body "update :check_in do accept [] end" --write --expected-digest 9f2c...
      {"op":"create_entity","placement":"synthesized_section",
       "name_path":"MyApp.Post/actions/check_in",...}

      $ mix ash_agent.edit --batch ops.json --write --expected-digest 9f2c...
      {"op":"apply_batch","op_count":2,"ops":[...],"combined_diff":"...","applied?":true,...}

      $ mix ash_agent.edit delete MyApp.Post/actions/by_tag --write --expected-digest 9f2c...
      {"error":"has_references","references":[...],"reverted?":null,...}
  """

  use Mix.Task

  alias AshAgentTools.Edit

  # Compile-only boot: name-path resolution needs compiled DSL state, not
  # a running application.
  @requirements ["app.config"]

  @ops %{
    "replace" => :replace_entity_block,
    "insert-before" => :insert_before_entity,
    "insert-after" => :insert_after_entity,
    "delete" => :safe_delete_entity,
    "create" => :create_entity
  }

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          body: :string,
          body_file: :string,
          anchor: :string,
          position: :string,
          batch: :string,
          write: :boolean,
          expected_digest: :string,
          pretty: :boolean,
          out: :string,
          verbose: :boolean
        ]
      )

    AshAgentTools.TaskOutput.with_quiet_logger(opts, fn ->
      AshAgentTools.TaskOutput.ensure_compiled()
      AshAgentTools.TaskOutput.load_configured_domains()

      case dispatch(positional, opts) do
        {:ok, report} ->
          Jason.encode!(report, pretty: !!opts[:pretty])
          |> AshAgentTools.TaskOutput.write_json(opts)

        {:error, report} ->
          Jason.encode!(Map.put(report, :is_error?, true), pretty: !!opts[:pretty])
          |> AshAgentTools.TaskOutput.write_json(opts)

          exit({:shutdown, 1})
      end
    end)
  end

  defp dispatch(positional, opts) do
    if opts[:batch] do
      dispatch_batch(opts)
    else
      dispatch_op(positional, opts)
    end
  end

  defp dispatch_batch(opts) do
    ops = decode_batch!(opts[:batch])
    write_opts = [write: !!opts[:write], expected_digest: opts[:expected_digest]]
    Edit.apply_batch(ops, write_opts)
  end

  defp dispatch_op([op_name, target], opts) when is_map_key(@ops, op_name) do
    op = Map.fetch!(@ops, op_name)
    write? = !!opts[:write]
    body = body!(opts, op)

    write_opts =
      opts
      |> Keyword.take([:expected_digest])
      |> Keyword.put(:write, write?)
      |> Keyword.put(:anchor, opts[:anchor])
      |> Keyword.put(:position, position(opts[:position]))

    case op do
      :safe_delete_entity -> Edit.safe_delete_entity(target, write_opts)
      :create_entity -> Edit.create_entity(target, body, write_opts)
      op -> apply(Edit, op, [target, body, write_opts])
    end
  end

  defp dispatch_op([op_name | _], _opts) when not is_map_key(@ops, op_name) do
    {:error,
     %{
       error: "unknown_operation",
       message:
         "unknown operation #{inspect(op_name)}. Valid operations: #{inspect(Map.keys(@ops))}"
     }}
  end

  defp dispatch_op(_positional, _opts) do
    {:error,
     %{
       error: "usage",
       message:
         "Usage: mix ash_agent.edit create|replace|insert-before|insert-after|delete" <>
           " NAME_PATH|SECTION_PATH [--body TEXT | --body-file FILE]" <>
           " [--anchor NAME_PATH --position after|before] [--batch FILE|-]" <>
           " [--write] [--expected-digest D]"
     }}
  end

  defp decode_batch!("-") do
    case IO.read(:stdio, :eof) |> Jason.decode() do
      {:ok, ops} ->
        ops

      {:error, reason} ->
        raise ArgumentError, "invalid --batch JSON: #{Exception.message(reason)}"
    end
  end

  defp decode_batch!(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"ops" => ops}} ->
            ops

          {:ok, ops} when is_list(ops) ->
            ops

          {:ok, _} ->
            raise ArgumentError, "--batch JSON must be an array of ops"

          {:error, reason} ->
            raise ArgumentError, "invalid --batch JSON: #{Exception.message(reason)}"
        end

      {:error, reason} ->
        raise ArgumentError, "cannot read --batch file: #{inspect(reason)}"
    end
  end

  defp position(nil), do: nil
  defp position("after"), do: :after
  defp position("before"), do: :before

  defp position(other),
    do: raise(ArgumentError, "invalid --position #{inspect(other)}: use after or before")

  defp body!(_opts, :safe_delete_entity), do: nil

  defp body!(opts, _op) do
    cond do
      body = opts[:body] ->
        body

      path = opts[:body_file] ->
        if path == "-" do
          IO.read(:stdio, :eof)
        else
          case File.read(path) do
            {:ok, content} -> content
            {:error, reason} -> raise ArgumentError, "cannot read --body-file: #{inspect(reason)}"
          end
        end

      true ->
        raise ArgumentError,
              "missing body: pass --body TEXT or --body-file FILE (use - for stdin)"
    end
  end
end
