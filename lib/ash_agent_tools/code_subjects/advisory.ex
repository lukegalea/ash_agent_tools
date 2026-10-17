# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.CodeSubjects.Advisory do
  @moduledoc """
  The advisory review of a change: the deterministic iron-laws report and
  the model-backed findings, kept in separate sections that never feed
  each other.

  ADR 0045 makes System One signals in tooling advisory: deterministic
  reports stay byte-identical, and deterministic gates stay deterministic,
  unless a versioned promotion threshold says otherwise. This module is
  where a review comment is assembled, so that rule is enforced here: the
  `laws` section is `AshAgentTools.Laws.judge/2`'s output, untouched, and
  the `advisory` section is built only from the findings passed in. No
  finding can add, drop or re-tier a law violation, and nothing here
  changes an exit status.

  A finding is a plain map:

      %{
        subject: %{id: ..., location: "lib/x.ex:42", ...},
        standard: "std-policy-checks-never-query",
        question_id: "judgment:v0:...",
        status: :in | :out | {:unknown, reason},   # from the facts, or
        probability: 0.91,                          # an unadmitted observation
        admitted?: false
      }
  """

  alias AshAgentTools.Laws

  @doc """
  The review of `diff` (a unified diff) with the given findings.

  Returns `%{laws: report, advisory: [finding], markdown: text}`. `laws` is
  `AshAgentTools.Laws.judge(diff, diff?: true)` exactly; pass `:laws_opts`
  to add judge options.
  """
  @spec review(String.t(), [map()], keyword()) :: map()
  def review(diff, findings, opts \\ []) when is_binary(diff) and is_list(findings) do
    laws = Laws.judge(diff, Keyword.merge([diff?: true], Keyword.get(opts, :laws_opts, [])))
    advisory = Enum.map(findings, &normalize/1)

    %{laws: laws, advisory: advisory, markdown: markdown(laws, advisory)}
  end

  defp normalize(finding) do
    subject = Map.fetch!(finding, :subject)

    %{
      subject_id: subject.id,
      location: subject.location,
      standard: Map.fetch!(finding, :standard),
      question_id: Map.get(finding, :question_id),
      status: Map.get(finding, :status),
      probability: Map.get(finding, :probability),
      admitted?: Map.get(finding, :admitted?, false),
      rung: :system_one
    }
  end

  defp markdown(laws, advisory) do
    [
      "### Iron laws (deterministic)",
      "",
      laws_lines(laws),
      "",
      "### Standards (System One, advisory: not a gate)",
      "",
      advisory_lines(advisory)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp laws_lines(%{violations: []}), do: ["No violations."]

  defp laws_lines(%{violations: violations}) do
    Enum.map(violations, fn v ->
      "- `#{v.tier}` law ##{v.law} #{v.name}, line #{v.line}: #{v.hint}"
    end)
  end

  defp advisory_lines([]), do: ["No findings."]

  defp advisory_lines(advisory) do
    Enum.map(advisory, fn finding ->
      "- `#{finding.location}` #{finding.standard}: #{reading(finding)}"
    end)
  end

  defp reading(%{admitted?: true, status: status}), do: "admitted fact, #{format_status(status)}"

  defp reading(%{probability: p}) when is_number(p),
    do: "observation, p = #{:erlang.float_to_binary(p * 1.0, decimals: 2)}, not admitted"

  defp reading(%{status: status}), do: format_status(status)

  defp format_status({:in, _}), do: "in"
  defp format_status({:out, _}), do: "out"
  defp format_status({:unknown, reason}), do: "unknown (#{inspect(reason)})"
  defp format_status(status), do: inspect(status)
end
