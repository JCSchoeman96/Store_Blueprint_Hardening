defmodule Store.Pricing.Promotion do
  @moduledoc """
  Persisted promotion definition used as deterministic evaluator input.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Pricing

  attributes do
    uuid_v7_primary_key(:id)

    attribute :code, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :currency, :string do
      allow_nil?(false)
      constraints(min_length: 3, max_length: 3)
      public?(true)
    end

    attribute :discount_minor, :integer do
      allow_nil?(false)
      constraints(min: 1)
      public?(true)
    end

    attribute :starts_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :ends_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :active, :boolean do
      allow_nil?(false)
      default(true)
      public?(true)
    end

    attribute :exclusive, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    attribute :combinable, :boolean do
      allow_nil?(false)
      default(true)
      public?(true)
    end

    attribute :exclusive_priority, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :precedence_rank, :integer do
      allow_nil?(false)
      default(200)
      public?(true)
    end

    attribute :eligibility_key, :string do
      allow_nil?(true)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_code, [:code])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    create :create do
      accept([
        :code,
        :currency,
        :discount_minor,
        :starts_at,
        :ends_at,
        :active,
        :exclusive,
        :combinable,
        :exclusive_priority,
        :precedence_rank,
        :eligibility_key
      ])

      change(&normalize_code/2)
    end

    update :update do
      require_atomic?(false)

      accept([
        :code,
        :currency,
        :discount_minor,
        :starts_at,
        :ends_at,
        :active,
        :exclusive,
        :combinable,
        :exclusive_priority,
        :precedence_rank,
        :eligibility_key
      ])

      change(&normalize_code/2)
    end
  end

  postgres do
    table("promotions")
    repo(Store.Repo)

    custom_indexes do
      index([:active], name: "promotions_active_index")
      index([:starts_at, :ends_at], name: "promotions_window_index")
      index([:exclusive, :exclusive_priority], name: "promotions_exclusive_priority_index")
    end
  end

  policies do
    policy action(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action(:create) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:update) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy always() do
      forbid_if(always())
    end
  end

  defp normalize_code(changeset, _context) do
    case Ash.Changeset.get_attribute(changeset, :code) do
      code when is_binary(code) ->
        code
        |> String.trim()
        |> String.upcase()
        |> then(&Ash.Changeset.change_attribute(changeset, :code, &1))

      _other ->
        changeset
    end
  end
end
