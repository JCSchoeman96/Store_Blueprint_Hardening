defmodule Store.Subscriptions.AccessEffect do
  @moduledoc """
  Durable desired access outcome and lifecycle obligation for one Subscription source version.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Subscriptions

  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput

  @fingerprint_domain :store_subscriptions_access_effect_target
  @fingerprint_version 1

  attributes do
    uuid_v7_primary_key(:id)

    attribute :status, Store.Subscriptions.Types.AccessEffectStatus do
      allow_nil?(false)
      default(:required)
      public?(false)
    end

    attribute :source_version, :integer do
      allow_nil?(false)
      constraints(min: 1)
      public?(false)
    end

    attribute :disposition, Store.Subscriptions.Types.AccessDisposition do
      allow_nil?(false)
      public?(false)
    end

    attribute :entitlement_kind, Store.Entitlements.Types.EntitlementKind do
      allow_nil?(true)
      public?(false)
    end

    attribute :entitlement_scope_key, :string do
      allow_nil?(true)
      constraints(min_length: 1, max_length: 255)
      public?(false)
    end

    attribute :valid_until_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(false)
    end

    attribute :target_fingerprint, :string do
      allow_nil?(false)
      constraints(min_length: 64, max_length: 64)
      public?(false)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :subscription, Store.Subscriptions.Subscription do
      allow_nil?(false)
      attribute_writable?(true)
      public?(false)
    end

    belongs_to :source_order_line_item, Store.Orders.OrderLineItem do
      allow_nil?(false)
      attribute_writable?(true)
      public?(false)
    end

    belongs_to :contract_change, Store.Subscriptions.ContractChange do
      allow_nil?(true)
      attribute_writable?(true)
      public?(false)
    end

    belongs_to :plan_revision, Store.Subscriptions.PlanRevision do
      allow_nil?(false)
      attribute_writable?(true)
      public?(false)
    end
  end

  identities do
    identity(:unique_subscription_source_version, [:subscription_id, :source_version])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    read :read_for_subscription_source_version do
      argument :subscription_id, :uuid do
        allow_nil?(false)
      end

      argument :source_version, :integer do
        allow_nil?(false)
      end

      filter(
        expr(
          subscription_id == ^arg(:subscription_id) and
            source_version == ^arg(:source_version)
        )
      )
    end

    read :read_current_for_subscription do
      argument :subscription_id, :uuid do
        allow_nil?(false)
      end

      filter(expr(subscription_id == ^arg(:subscription_id)))
      prepare(build(sort: [source_version: :desc]))
    end

    create :establish do
      public?(false)

      accept([
        :subscription_id,
        :source_order_line_item_id,
        :contract_change_id,
        :plan_revision_id,
        :source_version,
        :disposition,
        :entitlement_kind,
        :entitlement_scope_key,
        :valid_until_at
      ])

      change(set_attribute(:status, :required))
      change(&set_target_fingerprint/2)
    end

    update :mark_pending_from_required do
      public?(false)
      require_atomic?(false)
      accept([])
      change(filter(expr(status == :required)))
      change(set_attribute(:status, :pending))
    end

    update :mark_applied do
      public?(false)
      require_atomic?(false)
      accept([])
      change(filter(expr(status == :pending)))
      change(set_attribute(:status, :applied))
    end

    update :mark_failed_retryable do
      public?(false)
      require_atomic?(false)
      accept([])
      change(filter(expr(status == :pending)))
      change(set_attribute(:status, :failed_retryable))
    end

    update :retry_to_pending do
      public?(false)
      require_atomic?(false)
      accept([])
      change(filter(expr(status == :failed_retryable)))
      change(set_attribute(:status, :pending))
    end

    update :supersede do
      public?(false)
      require_atomic?(false)
      accept([])
      change(filter(expr(status == :pending)))
      change(set_attribute(:status, :superseded))
    end
  end

  postgres do
    table("access_effects")
    repo(Store.Repo)

    check_constraints do
      check_constraint(:status, "access_effects_status_value_check",
        check: "status IN ('required', 'pending', 'applied', 'failed_retryable', 'superseded')"
      )

      check_constraint(:source_version, "access_effects_source_version_check",
        check: "source_version >= 1"
      )

      check_constraint(:disposition, "access_effects_disposition_value_check",
        check: "disposition IN ('effective', 'non_effective')"
      )

      check_constraint(:entitlement_scope_key, "access_effects_scope_requires_kind_check",
        check: "entitlement_kind IS NOT NULL OR entitlement_scope_key IS NULL"
      )

      check_constraint(:target_fingerprint, "access_effects_fingerprint_length_check",
        check: "length(target_fingerprint) = 64"
      )
    end

    custom_indexes do
      index([:subscription_id, {:desc, :source_version}],
        name: "access_effects_subscription_source_version_index"
      )
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy action_type([:create, :update]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end
  end

  @doc false
  @spec target_fingerprint(EstablishAccessEffectInput.t() | map()) :: String.t()
  def target_fingerprint(%EstablishAccessEffectInput{} = input) do
    fingerprint_fields(Map.from_struct(input))
  end

  def target_fingerprint(fields) when is_map(fields), do: fingerprint_fields(fields)

  defp fingerprint_fields(fields) do
    descriptor =
      {@fingerprint_domain, @fingerprint_version,
       uuid_bytes!(Map.fetch!(fields, :subscription_id)), Map.fetch!(fields, :source_version),
       Map.fetch!(fields, :disposition), Map.fetch!(fields, :entitlement_kind),
       Map.fetch!(fields, :entitlement_scope_key),
       datetime_micros(Map.fetch!(fields, :valid_until_at)),
       uuid_bytes!(Map.fetch!(fields, :source_order_line_item_id)),
       optional_uuid_bytes(Map.fetch!(fields, :contract_change_id)),
       uuid_bytes!(Map.fetch!(fields, :plan_revision_id))}

    :crypto.hash(:sha256, :erlang.term_to_binary(descriptor, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp uuid_bytes!(uuid) do
    {:ok, bytes} = Ecto.UUID.dump(uuid)
    bytes
  end

  defp optional_uuid_bytes(nil), do: nil
  defp optional_uuid_bytes(uuid), do: uuid_bytes!(uuid)

  defp datetime_micros(nil), do: nil
  defp datetime_micros(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)

  defp set_target_fingerprint(changeset, _context) do
    fields =
      Map.new(
        [
          :subscription_id,
          :source_version,
          :disposition,
          :entitlement_kind,
          :entitlement_scope_key,
          :valid_until_at,
          :source_order_line_item_id,
          :contract_change_id,
          :plan_revision_id
        ],
        fn field -> {field, Ash.Changeset.get_attribute(changeset, field)} end
      )

    if valid_fingerprint_fields?(fields) do
      Ash.Changeset.change_attribute(changeset, :target_fingerprint, target_fingerprint(fields))
    else
      Ash.Changeset.add_error(changeset,
        field: :target_fingerprint,
        message: "cannot fingerprint incomplete AccessEffect target evidence"
      )
    end
  end

  defp valid_fingerprint_fields?(fields) do
    Enum.all?(
      [:subscription_id, :source_order_line_item_id, :plan_revision_id],
      &(is_binary(Map.get(fields, &1)) and Map.get(fields, &1) != "")
    ) and is_integer(fields.source_version) and fields.source_version > 0 and
      not is_nil(fields.disposition)
  end
end
