# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.AshAiAdapterTest do
  use ExUnit.Case, async: true
  import Plug.Test

  # The ash_ai adapter: the framework tools as an ash_ai tool domain.
  # Every tool runs through ash_ai's own execution path and must answer
  # exactly what the daemon's dispatch answers, from the same cards.

  alias AshAgentTools.AshAi.Run
  alias AshAgentTools.Mcp.Cards
  alias AshAgentTools.Mcp.Tools

  @tool_names ~w(ash_describe ash_validate ash_can ash_forbidden ash_context ash_search ash_laws)

  defp exposed do
    AshAi.exposed_tools(
      actions: [{AshAgentTools.AshAi.Tools, :*}],
      otp_app: :ash_agent_tools
    )
  end

  defp tool(name), do: Enum.find(exposed(), &(to_string(&1.name) == name))

  defp execute(name, input) do
    AshAi.Tools.execute(tool(name), %{"input" => input}, %{})
  end

  # What a daemon client parses: the report, JSON-encoded and decoded.
  defp daemon(name, args) do
    case Tools.call(name, args) do
      {:ok, report} -> {:ok, report |> Jason.encode!() |> Jason.decode!()}
      {:error, error} -> {:error, error |> Jason.encode!() |> Jason.decode!()}
    end
  end

  describe "exposed tools" do
    test "lists the seven, named as on the daemon" do
      assert exposed() |> Enum.map(&to_string(&1.name)) |> Enum.sort() == Enum.sort(@tool_names)
    end

    test "descriptions are the daemon cards' descriptions" do
      for name <- @tool_names do
        assert AshAi.Tools.description(tool(name)) == Cards.description(name)
      end
    end

    test "the adapter stays out of discovery" do
      refute AshAgentTools.AshAi in AshAgentTools.list_domains()
      refute AshAgentTools.AshAi.Tools in AshAgentTools.list_resources()
    end
  end

  describe "derived input schemas" do
    # ash_ai wraps generic-action arguments under "input"; inside it, the
    # schema must say what the daemon card says. additionalProperties is
    # dropped on both sides (ash_ai strips it in non-strict mode).
    test "match the cards for every tool" do
      for name <- @tool_names do
        derived =
          tool(name)
          |> AshAi.Tools.parameter_schema(strict: false)
          |> get_in(["properties", "input"])
          |> normalize()

        card = name |> Cards.input_schema() |> Jason.encode!() |> Jason.decode!() |> normalize()

        assert derived == card, "#{name}: #{inspect(derived)} != #{inspect(card)}"
      end
    end

    # ash_ai repeats an array argument's description on its items; that
    # repetition is the only difference allowed.
    defp normalize(%{} = schema) do
      schema
      |> Map.delete("additionalProperties")
      |> Map.update("items", nil, &Map.delete(&1, "description"))
      |> Map.update("required", nil, &Enum.sort/1)
      |> Map.update("enum", nil, &Enum.sort/1)
      |> Map.new(fn {key, value} -> {key, normalize(value)} end)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    end

    defp normalize(other), do: other
  end

  describe "execution through ash_ai" do
    @cases [
      {"ash_describe", %{}},
      {"ash_describe", %{"resource" => "AshAgentTools.Test.Post"}},
      {"ash_describe", %{"resource" => "AshAgentTools.Test.Post", "action" => "create"}},
      {"ash_validate",
       %{
         "resource" => "AshAgentTools.Test.Post",
         "action" => "create",
         "params" => %{"title" => "Hi", "score" => "7"}
       }},
      {"ash_can", %{"resource" => "AshAgentTools.Test.Guarded", "action" => "create"}},
      {"ash_forbidden", %{"resource" => "AshAgentTools.Test.Guarded"}},
      {"ash_context", %{"file" => "test/support/post.ex", "line" => 20}},
      {"ash_search", %{"term" => "title", "kinds" => ["attribute"]}},
      {"ash_search", %{"term" => "e", "kinds" => ["probe_widgets"]}},
      {"ash_laws", %{"source" => "def boom(x), do: String.to_atom(x)"}},
      {"ash_laws", %{"source" => "x", "laws" => ["10"], "min_tier" => "review"}}
    ]

    test "every tool answers what the daemon answers" do
      for {name, input} <- @cases do
        assert {:ok, text, _raw} = execute(name, input)
        assert {:ok, Jason.decode!(text)} == daemon(name, input), "#{name} #{inspect(input)}"
      end
    end

    test "reports keep their meaning" do
      {:ok, text, _} = execute("ash_describe", %{})
      summary = Jason.decode!(text)
      assert "AshAgentTools.Test.Post" in summary["resources"]

      {:ok, text, _} =
        execute("ash_validate", %{
          "resource" => "AshAgentTools.Test.Post",
          "action" => "create",
          "params" => %{"title" => "Hi", "score" => "7"}
        })

      assert %{"valid?" => true, "normalized_inputs" => %{"score" => 7}} = Jason.decode!(text)

      {:ok, text, _} =
        execute("ash_can", %{"resource" => "AshAgentTools.Test.Guarded", "action" => "create"})

      assert %{"allowed" => false, "verdict" => "forbidden"} = Jason.decode!(text)
    end

    test "the object actor spelling reaches ash_can" do
      {:ok, user} =
        AshAgentTools.Test.User
        |> Ash.Changeset.for_create(:create, %{email: "adapter-#{System.unique_integer()}@x.io"})
        |> Ash.create(authorize?: false)

      input = %{
        "resource" => "AshAgentTools.Test.User",
        "action" => "update",
        "actor" => %{"resource" => "AshAgentTools.Test.User", "id" => user.id}
      }

      assert {:ok, text, _} = execute("ash_can", input)
      assert {:ok, Jason.decode!(text)} == daemon("ash_can", input)
    end

    test "structured errors come back as the daemon's error JSON" do
      input = %{"resource" => "Post", "action" => "create"}

      assert {:error, text} = execute("ash_validate", input)
      assert {:error, Jason.decode!(text)} == daemon("ash_validate", input)
      assert Jason.decode!(text)["did_you_mean"] == ["AshAgentTools.Test.Post"]
    end

    test "missing required arguments are refused by ash_ai before the tool runs" do
      assert {:error, text} = execute("ash_validate", %{"resource" => "AshAgentTools.Test.Post"})
      assert text =~ "action"
    end
  end

  describe "inside a running app" do
    test "the router's otp_app reaches the action, and its domains get loaded" do
      Application.put_env(:ash_agent_tools_adapter_probe, :ash_domains, [
        AshAgentTools.Test.Domain,
        NotADomain
      ])

      tool = tool("ash_describe")

      assert {:ok, text, _} =
               AshAi.Tools.execute(tool, %{"input" => %{}}, %{
                 context: %{otp_app: :ash_agent_tools_adapter_probe}
               })

      assert "AshAgentTools.Test.Post" in Jason.decode!(text)["resources"]
    after
      Application.delete_env(:ash_agent_tools_adapter_probe, :ash_domains)
    end
  end

  describe "the dev-only guard" do
    test "allows a VM with Mix loaded" do
      assert Run.guard(true) == :ok
      assert Run.guard() == :ok
    end

    test "refuses without Mix" do
      assert {:error, error} = Run.guard(false)
      assert error.details["error"] =~ "dev-only"
      assert AshAi.ToToolError.to_tool_error(error) =~ "Mix is not loaded"
    end
  end

  describe "served by AshAi.Mcp.Router" do
    @router_opts AshAi.Mcp.Router.init(
                   otp_app: :ash_agent_tools,
                   protocol_version_statement: "2024-11-05",
                   actions: [{AshAgentTools.AshAi.Tools, :*}],
                   tools: [
                     :ash_describe,
                     :ash_validate,
                     :ash_can,
                     :ash_forbidden,
                     :ash_context,
                     :ash_search,
                     :ash_laws
                   ]
                 )

    defp rpc(body, session \\ nil) do
      conn =
        :post
        |> conn("/", Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")

      conn = if session, do: Plug.Conn.put_req_header(conn, "mcp-session-id", session), else: conn

      AshAi.Mcp.Router.call(conn, @router_opts)
    end

    test "tools/list and tools/call over the real router" do
      init =
        rpc(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2024-11-05",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "test", "version" => "1"}
          }
        })

      assert init.status == 200
      session = init |> Plug.Conn.get_resp_header("mcp-session-id") |> List.first()

      list = rpc(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}, session)
      names = Jason.decode!(list.resp_body)["result"]["tools"] |> Enum.map(& &1["name"])
      assert Enum.sort(names) == Enum.sort(@tool_names)

      call =
        rpc(
          %{
            "jsonrpc" => "2.0",
            "id" => 3,
            "method" => "tools/call",
            "params" => %{
              "name" => "ash_validate",
              "arguments" => %{
                "input" => %{
                  "resource" => "AshAgentTools.Test.Post",
                  "action" => "create",
                  "params" => %{"title" => "Hi"}
                }
              }
            }
          },
          session
        )

      result = Jason.decode!(call.resp_body)["result"]
      assert result["isError"] == false
      [%{"text" => text}] = result["content"]
      assert %{"valid?" => true} = Jason.decode!(text)
    end
  end
end
