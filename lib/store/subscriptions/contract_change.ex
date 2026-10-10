defmodule Store.Subscriptions.ContractChange do
  @moduledoc """
  Durable future commercial instruction owned by one Subscription.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Subscriptions

  attributes do
    uuid_v7_primary_key(:id)

    attribute :status, Store.Subscriptions.Types.ContractChangeStatus do
      allow_nil?(false)
      default(:queued)
      public?(true)
    end

    attribute :instruction_kind, Store.Subscriptions.Types.ContractChangeKind do
      allow_nil?(false)
      public?(true)
    end

    attribute :ordering_version, :integer do
      allow_nil?(false)
      constraints(min: 1)
      public?(true)
    end

    attribute :effective_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    attribute :target_quantity, :integer do
      allow_nil?(false)
      constraints(min: 1)
      public?(true)
    end

    attribute :target_amount_minor, :integer do
      allow_nil?(false)
      constraints(min: 0)
      public?(true)
    end

    attribute :target_currency, :string do
      allow_nil?(false)
      constraints(min_length: 3, max_length: 3)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :subscription, Store.Subscriptions.Subscription do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :target_plan_revision, Store.Subscriptions.PlanRevision do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :target_variant, Store.Catalog.Variant do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :predecessor_contract_change, Store.Subscriptions.ContractChange do
      source_attribute(:predecessor_contract_change_id)
      allow_nil?(true)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :supersedes_contract_change, Store.Subscriptions.ContractChange do
      source_attribute(:supersedes_contract_change_id)
      allow_nil?(true)
      attribute_writable?(true)
      public?(true)
    end
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    read :read_for_subscription do
      argument :subscription_id, :uuid do
        allow_nil?(false)
      end

      filter(expr(subscription_id == ^arg(:subscription_id)))
      prepare(build(sort: [ordering_version: :asc]))
    end

    create :queue do
      public?(false)

      accept([
        :subscription_id,
        :target_plan_revision_id,
        :target_variant_id,
        :predecessor_contract_change_id,
        :supersedes_contract_change_id,
        :instruction_kind,
        :ordering_version,
        :effective_at,
        :target_quantity,
        :target_amount_minor,
        :target_currency
      ])

      change(set_attribute(:status, :queued))
      change(&normalize_target_currency/2)
    end

    update :supersede do
      public?(false)

      require_atomic?(false)
      accept([])
      change(filter(expr(status == :queued)))
      change(set_attribute(:status, :superseded))
    end

    update :cancel do
      public?(false)

      require_atomic?(false)
      accept([])
      change(filter(expr(status == :queued)))
      change(set_attribute(:status, :canceled))
    end

    update :bind_to_renewal do
      public?(false)

      require_atomic?(false)
      accept([])

      validate(fn changeset, _context ->
        if changeset.data.status == :queued do
          :ok
        else
          {:error, field: :status, message: "ContractChange is no longer queued"}
        end
      end)

      change(filter(expr(status == :queued)))
      change(set_attribute(:status, :bound_to_renewal))
    end
  end

  postgres do
    table("contract_changes")
    repo(Store.Repo)

    references do
      reference(:subscription, on_delete: :restrict)
      reference(:target_plan_revision, on_delete: :restrict)
      reference(:target_variant, on_delete: :restrict)
      reference(:predecessor_contract_change, on_delete: :restrict)
      reference(:supersedes_contract_change, on_delete: :restrict)
    end

    check_constraints do
      check_constraint(:status, "contract_changes_status_value_check",
        check: "status IN ('queued', 'superseded', 'canceled', 'bound_to_renewal', 'applied')"
      )

      check_constraint(:instruction_kind, "contract_changes_instruction_kind_value_check",
        check: "instruction_kind IN ('plan_change', 'variant_change', 'renew_unchanged')"
      )

      check_constraint(:ordering_version, "contract_changes_ordering_version_check",
        check: "ordering_version >= 1"
      )

      check_constraint(:target_quantity, "contract_changes_target_quantity_check",
        check: "target_quantity >= 1"
      )

      check_constraint(:target_amount_minor, "contract_changes_target_amount_minor_check",
        check: "target_amount_minor >= 0"
      )

      check_constraint(:target_currency, "contract_changes_target_currency_check",
        check: "length(target_currency) = 3 AND target_currency = upper(target_currency)"
      )
    end

    custom_indexes do
      index([:subscription_id], name: "contract_changes_subscription_id_index")

      index([:subscription_id, :ordering_version],
        unique: true,
        name: "contract_changes_subscription_ordering_version_index"
      )

      index([:subscription_id],
        unique: true,
        where: "status = 'queued'",
        name: "contract_changes_one_queued_per_subscription_index"
      )

      index([:target_plan_revision_id], name: "contract_changes_target_plan_revision_id_index")
      index([:target_variant_id], name: "contract_changes_target_variant_id_index")

      index([:predecessor_contract_change_id],
        name: "contract_changes_predecessor_id_index"
      )

      index([:supersedes_contract_change_id],
        name: "contract_changes_supersedes_id_index"
      )
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action_type([:create, :update]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end

  defp normalize_target_currency(changeset, _context) do
    case Ash.Changeset.get_attribute(changeset, :target_currency) do
      currency when is_binary(currency) ->
        Ash.Changeset.change_attribute(changeset, :target_currency, String.upcase(currency))

      _currency ->
        changeset
    end
  end
end
