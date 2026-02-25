defmodule Store.Orders.PaymentApplication do
  @moduledoc """
  Immutable evidence that paid side effects were applied for an order exactly once.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Orders

  attributes do
    uuid_v7_primary_key(:id)

    attribute :application_key, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :applied_at, :utc_datetime_usec do
      allow_nil?(false)
      default(&DateTime.utc_now/0)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :order, Store.Orders.Order do
      allow_nil?(false)
      public?(true)
      attribute_writable?(true)
    end

    belongs_to :payment_intent, Store.Payments.PaymentIntent do
      allow_nil?(false)
      public?(true)
      attribute_writable?(true)
    end
  end

  identities do
    identity(:unique_application_key, [:application_key])
  end

  actions do
    defaults([:read])

    create :apply_once do
      accept([:order_id, :payment_intent_id, :application_key, :applied_at])

      upsert?(true)
      upsert_identity(:unique_application_key)
      upsert_fields([])
      return_skipped_upsert?(true)
    end
  end

  postgres do
    table("payment_applications")
    repo(Store.Repo)

    custom_indexes do
      index([:order_id], name: "payment_applications_order_id_index")
      index([:payment_intent_id], name: "payment_applications_payment_intent_id_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action(:apply_once) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy always() do
      forbid_if(always())
    end
  end
end
