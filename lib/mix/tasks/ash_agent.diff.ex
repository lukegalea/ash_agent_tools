# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Diff do
  @shortdoc "Diffs two semantic-manifest JSON files as JSON"

  @moduledoc """
  Structurally diffs two semantic-manifest JSON documents and prints a JSON
  report of the added, removed, and changed symbols, keyed on stable symbol
  ids (`ash:v0:<Module>#<dsl_path>/<name>`, RFC §4.3 of the *Spark/Ash
  Semantic Manifest, v0* proposal).

  Wraps `AshAgentTools.diff_manifest/2`. A symbol counts as changed when its
  *content* differs (RFC §4.4): everything except `hashes`, `span`, and
  `property_spans` — so a moved declaration is unchanged, and documents with
  placeholder hashes (hand-authored fixtures) diff correctly. Works on
  hand-authored manifest documents today; the RFC's
  `mix ash.manifest.dump --semantic` exporter is future work.

  **stdout is pure JSON, always.** Your application is *not* booted — the
  task is pure file processing — and Logger output is suppressed for the
  duration, so the output pipes cleanly into a JSON parser; use `--verbose`
  if you want the logs back.

  ## Usage

      mix ash_agent.diff OLD NEW [--out FILE] [--pretty] [--verbose]

  ## Command line options

    * `--out FILE` - write the JSON to FILE instead of stdout
    * `--pretty` - pretty-print the JSON (default: compact)
    * `--verbose` - do not suppress Logger output (breaks pure-JSON stdout)

  ## Examples

      $ mix ash_agent.diff manifest-old.json manifest-new.json
      {"old_file":"manifest-old.json","new_file":"manifest-new.json",
       "summary":{"added":1,"removed":1,"changed":1,"unchanged":2},
       "added":[{"id":"ash:v0:MyApp.Post#actions/publish",...}],...}

  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, strict: [pretty: :boolean, out: :string, verbose: :boolean])

    AshAgentTools.TaskOutput.with_quiet_logger(opts, fn ->
      case positional do
        [old_path, new_path] ->
          AshAgentTools.diff_manifest(old_path, new_path)
          |> Jason.encode!(pretty: !!opts[:pretty])
          |> AshAgentTools.TaskOutput.write_json(opts)

        _ ->
          Mix.raise("Usage: mix ash_agent.diff OLD NEW [--out FILE] [--pretty]")
      end
    end)
  end
end
