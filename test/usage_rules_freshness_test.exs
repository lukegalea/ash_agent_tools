# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.UsageRulesFreshnessTest do
  use ExUnit.Case, async: true

  @rules_path "usage-rules.md"
  @task_dir "lib/mix/tasks"

  # The mechanical proxy for "the usage rules match the shipped surface":
  # every mix task the package ships must have a @shortdoc, and that exact
  # sentence must appear in usage-rules.md. Other constellation packages can
  # adopt the same test against their own rules file.
  test "every shipped mix task's @shortdoc appears verbatim in usage-rules.md" do
    rules = File.read!(@rules_path)
    sources = task_sources()

    missing_shortdoc =
      for {path, source} <- sources,
          not Regex.match?(~r/@shortdoc "/, source),
          do: path

    assert missing_shortdoc == [],
           "these task modules carry no @shortdoc to document: #{inspect(missing_shortdoc)}"

    undocumented =
      for {path, source} <- sources,
          [shortdoc] <- [Regex.run(~r/@shortdoc "([^"]+)"/, source, capture: :all_but_first)],
          not String.contains?(rules, shortdoc),
          do: {path, shortdoc}

    assert undocumented == [],
           "usage-rules.md does not quote these @shortdocs verbatim (update the rules " <>
             "when the shipped surface changes): #{inspect(undocumented)}"
  end

  defp task_sources do
    Path.wildcard(Path.join(@task_dir, "*.ex"))
    |> Enum.map(&{&1, File.read!(&1)})
  end
end
