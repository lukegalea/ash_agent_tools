# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.CanTest do
  use ExUnit.Case, async: true

  doctest AshAgentTools.Can

  alias AshAgentTools.Test.{Guarded, User}

  describe "can/5" do
    test "an actor-less create on a policy resource is denied, with the static listing" do
      report = AshAgentTools.can(Guarded, :create, :none)

      assert report.allowed == false
      assert report.verdict == :forbidden
      assert report.actor == %{kind: :none, resource: nil, id: nil}
      # Guarded's policies exist but none applies to :create — nothing is
      # "responsible" (that is exactly Ash's deny-by-default shape).
      assert report.responsible == nil
      assert length(report.policies) == 2
      assert report.input_valid? == true
    end

    test "an admin actor passes the update policy" do
      {:ok, admin} = create_user!(%{admin: true})

      report = AshAgentTools.can(User, :update, %{resource: User, id: admin.id})

      assert {report.allowed, report.verdict} == {true, :allowed}
      assert report.actor == %{kind: :record, resource: User, id: admin.id}
      assert report.action_type == :update
    end

    test "a non-admin update is denied by the actor-scoped policy, with the breakdown" do
      {:ok, user} = create_user!(%{email: "u@example.com"})

      report = AshAgentTools.can(User, :update, %{resource: User, id: user.id})

      assert {report.allowed, report.verdict} == {false, :forbidden}
      assert report.responsible.index == 0
      assert report.responsible.reason == :unknown
      assert report.responsible.condition == ["action.type == :update"]

      check = hd(report.responsible.checks)
      assert check.description == "actor.admin == true"
      assert check.fact == false

      # the fact-backed per-policy breakdown mirrors the responsible policy
      [policy] = report.per_policy
      assert policy.applies? == true
      assert policy.decision == :unknown
      assert [%{fact: false}] = policy.checks
    end

    test "an explicit record option targets a different record" do
      {:ok, admin} = create_user!(%{admin: true})
      {:ok, other} = create_user!(%{email: "other@example.com"})

      report =
        AshAgentTools.Can.can(User, :update, %{resource: User, id: admin.id}, %{},
          record: other.id
        )

      assert report.allowed == true

      assert Enum.any?(report.notes, &(&1 =~ "resolved by id"))
    end

    test "actions without policies are allowed (no authorizers apply)" do
      report = AshAgentTools.can(AshAgentTools.Test.Post, :create, :none)

      assert {report.allowed, report.verdict} == {true, :allowed}
      assert report.policies == []
      assert Enum.any?(report.notes, &(&1 =~ "No policies are declared"))
    end

    test "invalid input is reported honestly but does not block the policy verdict" do
      {:ok, admin} = create_user!(%{admin: true})

      report =
        AshAgentTools.can(User, :update, %{resource: User, id: admin.id}, %{"email" => 42})

      assert report.allowed == true
      assert report.input_valid? == false
      assert Enum.any?(report.notes, &(&1 =~ "validate_input/3"))
    end

    test "accepts an already-resolved actor record" do
      {:ok, user} = create_user!(%{})

      report = AshAgentTools.can(User, :update, user)

      assert report.allowed == false
      assert report.actor.resource == User
    end

    test "accepts string-keyed actor specs" do
      {:ok, user} = create_user!(%{})

      report =
        AshAgentTools.can(User, :update, %{
          "resource" => "AshAgentTools.Test.User",
          "id" => user.id
        })

      assert report.allowed == false
      assert report.actor.id == user.id
    end

    test "an unresolvable actor raises with candidates and emits the kaizen gap" do
      # The dev sink is idempotent; attach so this async test does not depend
      # on kaizen_test's attach having run first.
      AshAgentTools.Kaizen.attach()
      AshAgentTools.Kaizen.reset()

      assert_raise ArgumentError, ~r/could not resolve the actor record/, fn ->
        AshAgentTools.can(User, :update, %{resource: AshAgentTools.Test.Author, id: "nope"})
      end

      digest = AshAgentTools.Kaizen.digest()

      gap = Enum.find(digest.gaps, &(&1.tool == "can" and &1.gap_kind == "actor_resolve_miss"))
      assert gap != nil
      assert gap.count >= 1
    end

    test "unknown actions and non-resources raise the usual errors" do
      assert_raise ArgumentError, ~r/no action named/, fn ->
        AshAgentTools.can(User, :nonexistent, :none)
      end

      assert_raise ArgumentError, ~r/not a loaded Ash resource/, fn ->
        AshAgentTools.can(String, :read, :none)
      end
    end

    test "the report is JSON-encodable" do
      {:ok, user} = create_user!(%{})

      for report <- [
            AshAgentTools.can(User, :update, %{resource: User, id: user.id}),
            AshAgentTools.can(Guarded, :create, :none),
            AshAgentTools.can(AshAgentTools.Test.Post, :by_tag, :none, %{"tag" => "x"})
          ] do
        assert is_binary(Jason.encode!(report))
      end
    end

    test "read actions with filter policies stay decidable without data-layer access" do
      # The read policy's expr(public == true) is a filter check: filters
      # authorize with a scope, so the read stays :allowed even with
      # run_queries?: false — while the actor-present check already
      # authorized for a present actor.
      {:ok, user} = create_user!(%{})

      report = AshAgentTools.can(Guarded, :read, %{resource: User, id: user.id})

      assert report.verdict in [:allowed, :maybe]
    end

    defp create_user!(params) do
      User
      |> Ash.Changeset.for_create(:create, params)
      |> Ash.create(authorize?: false)
    end
  end
end
