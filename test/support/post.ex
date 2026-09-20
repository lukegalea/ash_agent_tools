# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Test.Post do
  @moduledoc """
  Minimal test resource exercising fields, relationships, actions with
  arguments, defaults, and a resource-level code interface. No data layer:
  the introspection API never runs actions, so nothing needs persisting.
  """

  use Ash.Resource, domain: AshAgentTools.Test.Domain

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :body, :string, public?: true

    attribute :status, :atom do
      constraints one_of: [:draft, :published, :archived]
      default :draft
      public? true
    end

    attribute :tags, {:array, :string} do
      default []
      public? true
    end

    attribute :score, :integer, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :author, AshAgentTools.Test.Author do
      public? true
    end

    has_many :comments, AshAgentTools.Test.Comment do
      destination_attribute :post_id
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:title, :body, :status, :tags, :score]
    end

    update :publish do
      accept []
      change set_attribute(:status, :published)
    end

    read :by_tag do
      argument :tag, :string, allow_nil?: false

      filter expr(^arg(:tag) in tags)
    end

    action :feature, :string do
      argument :level, :integer do
        default 1
      end

      run fn _input, _context ->
        {:ok, "featured"}
      end
    end
  end

  code_interface do
    domain AshAgentTools.Test.Domain
    define :feature, args: [:level]
  end
end
