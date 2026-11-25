# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Test.GateRung do
  @moduledoc """
  A System One rung for the gate tests, driven by the command it is asked
  about. Every call reports itself to the test process named, encoded, in
  the request's `session_id`.

  The command's first word picks the answer: `rung-yes` (destructive),
  `rung-no` (benign, certified), `rung-uncertified` (benign, not
  certified), `rung-unsure`, `rung-sleep`, `rung-raise`, `rung-error`,
  `rung-exit` and `rung-garbage` (not the contract).
  """

  @doc "The session id that routes the rung's reports to `pid`."
  def session(pid), do: pid |> :erlang.term_to_binary() |> Base.url_encode64()

  def judge(request, _opts) do
    report(request)
    word = request.command |> to_string() |> String.split(" ") |> hd()
    respond(word)
  end

  defp respond("rung-yes"), do: answer("yes", "no", true)
  defp respond("rung-no"), do: answer("no", "no", true)
  defp respond("rung-uncertified"), do: answer("no", "no", false)
  defp respond("rung-unsure"), do: answer("unsure", "no", true)
  defp respond("rung-sleep"), do: Process.sleep(:infinity)
  defp respond("rung-raise"), do: raise("the model is down")
  defp respond("rung-error"), do: {:error, :connection_refused}
  defp respond("rung-exit"), do: exit(:boom)
  defp respond("rung-garbage"), do: {:ok, %{band: "admit"}}
  defp respond(_other), do: answer("unsure", "unsure", true)

  defp answer(destructive, out_of_scope, certified) do
    {:ok,
     %{
       inputs: %{"destructive" => destructive, "out_of_scope" => out_of_scope},
       certified: certified,
       audit: %{model_version: "test-model", question_hashes: ["sha256:q1", "sha256:q2"]}
     }}
  end

  defp report(%{session_id: session}) when is_binary(session) do
    with {:ok, binary} <- Base.url_decode64(session),
         pid when is_pid(pid) <- :erlang.binary_to_term(binary, [:safe]) do
      send(pid, {:rung_called, self()})
    end
  end

  defp report(_request), do: :ok
end
