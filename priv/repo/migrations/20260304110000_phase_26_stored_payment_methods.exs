defmodule Store.Repo.Migrations.Phase26StoredPaymentMethods do
  use Ecto.Migration

  @known_providers "'stripe', 'payfast', 'paystack', 'yoco', 'peach_payments'"

  def up do
    create table(:stored_payment_methods, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :user_id,
        references(:users,
          column: :id,
          type: :uuid,
          name: "stored_payment_methods_user_id_fkey",
          on_delete: :delete_all
        ),
        null: false
      )

      add(:provider, :text, null: false)
      add(:provider_customer_ref, :text, null: false)
      add(:provider_payment_method_ref, :text, null: false)
      add(:status, :text, null: false, default: "active")
      add(:fingerprint, :text)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(
        :stored_payment_methods,
        [:provider, :provider_customer_ref, :provider_payment_method_ref],
        name: "stored_payment_methods_unique_provider_customer_pm_index"
      )
    )

    create(
      index(:stored_payment_methods, [:user_id, :status],
        name: "stored_payment_methods_user_id_status_index"
      )
    )

    create(
      index(:stored_payment_methods, [:provider, :status],
        name: "stored_payment_methods_provider_status_index"
      )
    )

    create(
      constraint(
        :stored_payment_methods,
        "stored_payment_methods_provider_value_check",
        check: "provider IN (#{@known_providers})"
      )
    )

    create(
      constraint(
        :stored_payment_methods,
        "stored_payment_methods_status_value_check",
        check: "status IN ('active', 'inactive', 'revoked')"
      )
    )

    alter table(:subscriptions) do
      add(
        :stored_payment_method_id,
        references(:stored_payment_methods,
          column: :id,
          type: :uuid,
          name: "subscriptions_stored_payment_method_id_fkey",
          on_delete: :nilify_all
        )
      )
    end

    create(
      index(:subscriptions, [:stored_payment_method_id],
        name: "subscriptions_stored_payment_method_id_index"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:subscriptions, [:stored_payment_method_id],
        name: "subscriptions_stored_payment_method_id_index"
      )
    )

    alter table(:subscriptions) do
      remove(:stored_payment_method_id)
    end

    drop_if_exists(
      constraint(:stored_payment_methods, "stored_payment_methods_status_value_check")
    )

    drop_if_exists(
      constraint(:stored_payment_methods, "stored_payment_methods_provider_value_check")
    )

    drop_if_exists(
      index(:stored_payment_methods, [:provider, :status],
        name: "stored_payment_methods_provider_status_index"
      )
    )

    drop_if_exists(
      index(:stored_payment_methods, [:user_id, :status],
        name: "stored_payment_methods_user_id_status_index"
      )
    )

    drop_if_exists(
      unique_index(
        :stored_payment_methods,
        [:provider, :provider_customer_ref, :provider_payment_method_ref],
        name: "stored_payment_methods_unique_provider_customer_pm_index"
      )
    )

    drop(table(:stored_payment_methods))
  end
end
