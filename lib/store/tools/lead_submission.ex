defmodule Store.Tools.LeadSubmission do
  @moduledoc """
  Persisted lead submission from a public tool (e.g. Risk Appetite Calculator).
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Tools

  attributes do
    uuid_v7_primary_key(:id)

    attribute :tool_slug, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :name, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :email, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :phone, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :consent_contact, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    attribute :consent_store_data, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    attribute :score, :integer do
      allow_nil?(false)
      public?(true)
    end

    attribute :category, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :answers, :map do
      allow_nil?(false)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :tool_slug,
        :name,
        :email,
        :phone,
        :consent_contact,
        :consent_store_data,
        :score,
        :category,
        :answers
      ])
    end
  end

  postgres do
    table("tool_lead_submissions")
    repo(Store.Repo)

    custom_indexes do
      index([:tool_slug], name: "tool_lead_submissions_tool_slug_index")
      index([:email], name: "tool_lead_submissions_email_index")
      index([:inserted_at], name: "tool_lead_submissions_inserted_at_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action_type(:create) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy always() do
      forbid_if(always())
    end
  end
end
