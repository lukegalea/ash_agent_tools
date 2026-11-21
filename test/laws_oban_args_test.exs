# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.LawsObanArgsTest do
  use ExUnit.Case, async: true

  alias AshAgentTools.Laws

  defp judge(source, opts), do: Laws.judge(source, Keyword.merge([min_tier: :review], opts))

  defp hits(source, law, opts \\ []) do
    for v <- judge(source, opts).violations, v.law == law, do: {v.line, v.tier}
  end

  describe "law #08, atom keys in Oban args" do
    test "an atom-keyed literal handed to a Worker constructor is likely" do
      assert hits("MyApp.MailWorker.new(%{user_id: 1})", "08") == [{1, :likely}]
      assert hits("MyApp.MailWorker.new(%{:user_id => 1})", "08") == [{1, :likely}]
      assert hits(~s|MyApp.MailWorker.new(%{"a" => 1, b: 2})|, "08") == [{1, :likely}]
    end

    test "Oban.Job.new, Oban.insert* arguments and pipes are likely whatever the module" do
      assert hits("Oban.Job.new(%{id: 1}, worker: W)", "08") == [{1, :likely}]
      assert hits("Oban.insert(Some.Thing.new(%{id: 1}))", "08") == [{1, :likely}]
      assert hits("Some.Thing.new(%{id: 1}) |> Oban.insert()", "08") == [{1, :likely}]
      assert hits("%{id: 1} |> MyApp.MailWorker.new() |> Oban.insert()", "08") == [{1, :likely}]

      assert hits("Oban.insert_all([A.new(%{id: 1}), B.new(%{\"id\" => 2})])", "08") == [
               {1, :likely}
             ]
    end

    test "a nested atom key is found, and a Job suffix is only review" do
      assert hits("MyApp.MailWorker.new(%{\"opts\" => %{deep: true}})", "08") == [{1, :likely}]
      assert hits("MyApp.SyncJob.new(%{id: 1})", "08") == [{1, :review}]
      assert hits("MyApp.SyncJob.new(%{id: 1})", "08", min_tier: :likely) == []
    end

    test "a variable bound once to an atom-keyed literal in the same function" do
      source = """
      def enqueue(id) do
        args = %{user_id: id}
        MyApp.MailWorker.new(args)
      end
      """

      assert hits(source, "08") == [{3, :likely}]
    end

    test "__MODULE__.new counts only in a source that uses Oban.Worker" do
      worker = """
      defmodule W do
        use Oban.Worker, unique: [period: 60]
        def again(id), do: __MODULE__.new(%{id: id})
      end
      """

      assert hits(worker, "08") == [{3, :likely}]
      assert hits("def again(id), do: __MODULE__.new(%{id: id})", "08") == []
    end

    test "near misses: string keys, ids, unrelated constructors, unknown variables" do
      for source <- [
            ~s|MyApp.MailWorker.new(%{"user_id" => 1})|,
            ~s|MyApp.MailWorker.new(%{"user_id" => user.id})|,
            "MyApp.MailWorker.new(args)",
            "MyApp.MailWorker.new()",
            "Map.new(%{id: 1})",
            "MapSet.new([id: 1])",
            "MyApp.Account.new(%{id: 1})",
            "Oban.insert(changeset)",
            "def f(args), do: MyApp.MailWorker.new(args)"
          ] do
        assert hits(source, "08") == [], source
      end

      rebound = """
      def enqueue(id) do
        args = %{user_id: id}
        args = Map.new(args, fn {k, v} -> {to_string(k), v} end)
        MyApp.MailWorker.new(args)
      end
      """

      assert hits(rebound, "08") == []
    end

    test "source that does not parse reports nothing" do
      assert hits("MyApp.MailWorker.new(%{id: 1}", "08") == []
    end
  end

  describe "law #09, structs in Oban args" do
    test "a struct literal, a __struct__ key, or a variable bound to a struct" do
      assert hits("MyApp.MailWorker.new(%{user: %User{id: 1}})", "09") == [{1, :likely}]
      assert hits(~s|MyApp.MailWorker.new(%{"user" => [%User{}]})|, "09") == [{1, :likely}]
      assert hits("MyApp.MailWorker.new(%{__struct__: User})", "09") == [{1, :likely}]
      assert hits("MyApp.MailWorker.new(%User{})", "09") == [{1, :likely}]

      bound = """
      def enqueue do
        user = %User{id: 1}
        MyApp.MailWorker.new(%{user: user})
      end
      """

      assert hits(bound, "09") == [{3, :likely}]

      matched = """
      def enqueue(%User{} = user) do
        Oban.insert(MyApp.MailWorker.new(%{"user" => user}))
      end
      """

      assert hits(matched, "09") == [{2, :likely}]
    end

    test "near misses: ids, fields, Map.from_struct, unknown variables, rebinding" do
      for source <- [
            "MyApp.MailWorker.new(%{user_id: user.id})",
            ~s|MyApp.MailWorker.new(%{"user" => Map.from_struct(%User{})})|,
            ~s|MyApp.MailWorker.new(%{"user" => user})|,
            "Struct.new(%{user: %User{}})",
            "def enqueue(user), do: MyApp.MailWorker.new(%{\"user\" => user})"
          ] do
        assert hits(source, "09") == [], source
      end

      rebound = """
      def enqueue do
        user = %User{id: 1}
        user = user.id
        MyApp.MailWorker.new(%{"user" => user})
      end
      """

      assert hits(rebound, "09") == []
    end

    test "an atom key and a struct in one call are reported by both laws" do
      source = "MyApp.MailWorker.new(%{user: %User{}})"
      assert hits(source, "08") == [{1, :likely}]
      assert hits(source, "09") == [{1, :likely}]
    end
  end

  describe "diff mode" do
    @diff """
    diff --git a/lib/enqueue.ex b/lib/enqueue.ex
    --- a/lib/enqueue.ex
    +++ b/lib/enqueue.ex
    @@ -3,3 +3,7 @@
     def enqueue(user) do
    -  MyApp.MailWorker.new(%{"user_id" => user.id})
    +  MyApp.MailWorker.new(%{user_id: user.id})
    +  |> Oban.insert()
    +  MyApp.MailWorker.new(%{user: %User{}})
     end
    """

    test "added lines are judged where they sit in the diff" do
      assert hits(@diff, "08", diff?: true) == [{7, :likely}, {9, :likely}]
      assert hits(@diff, "09", diff?: true) == [{9, :likely}]
    end

    test "a removed atom-keyed call is not a hit" do
      diff = """
      +++ b/lib/x.ex
      -MyApp.MailWorker.new(%{user_id: 1})
      +MyApp.MailWorker.new(%{"user_id" => 1})
      """

      assert hits(diff, "08", diff?: true) == []
    end

    test "an added run that does not parse alone falls back to its lines" do
      diff = """
      +++ b/lib/x.ex
      +end
      +MyApp.MailWorker.new(%{user_id: 1})
      """

      assert hits(diff, "08", diff?: true) == [{3, :likely}]
    end
  end

  describe "the registry" do
    test "#08 and #09 have :ast detectors; #06 #18 #20 #22 #26 do not, #18 and #22 say why" do
      by_id = Map.new(Laws.core_laws(), &{&1.id, &1})
      assert Enum.all?(~w(08 09), &match?([%{kind: :ast}], by_id[&1].detectors))

      without = Laws.judge("x").laws_without_detectors
      assert without |> Enum.map(& &1.id) |> Enum.sort() == ~w(06 18 20 22 26)

      assert Enum.filter(without, &Map.has_key?(&1, :detectable_from))
             |> Enum.map(&{&1.id, &1.detectable_from}) ==
               [{"18", :session}, {"22", :session}]
    end

    test "the package's own lib has no #08 or #09 hit" do
      for file <- Path.wildcard("lib/**/*.ex") do
        report = Laws.judge(File.read!(file), file: file, laws: ["08", "09"], min_tier: :review)
        assert report.violations == [], file
      end
    end
  end
end
