defmodule Store.Repo.Migrations.Phase26ProviderHardeningNoImplicitDefaults do
  use Ecto.Migration

  @known_providers "'stripe', 'payfast', 'paystack', 'yoco', 'peach_payments'"

  def up do
    execute("UPDATE subscriptions SET provider = lower(provider)")
    execute("UPDATE payment_intents SET provider = lower(provider)")
    execute("UPDATE provider_events SET provider = lower(provider)")
    execute("UPDATE webhook_receipts SET provider = lower(provider)")
    execute("UPDATE payment_attempts SET provider = lower(provider)")
    execute("UPDATE refunds SET provider = lower(provider)")
    execute("UPDATE refund_attempts SET provider = lower(provider)")

    alter table(:subscriptions) do
      modify(:provider, :text, null: false, default: nil)
      modify(:billing_mode, :text, null: false, default: nil)
    end

    alter table(:payment_intents) do
      modify(:provider, :text, null: false, default: nil)
    end

    alter table(:payment_attempts) do
      modify(:provider, :text, null: false, default: nil)
    end

    alter table(:refunds) do
      modify(:provider, :text, null: false, default: nil)
    end

    alter table(:refund_attempts) do
      modify(:provider, :text, null: false, default: nil)
    end

    drop_if_exists(constraint(:subscriptions, "subscriptions_provider_value_check"))
    drop_if_exists(constraint(:payment_intents, "payment_intents_provider_value_check"))
    drop_if_exists(constraint(:provider_events, "provider_events_provider_value_check"))
    drop_if_exists(constraint(:webhook_receipts, "webhook_receipts_provider_value_check"))
    drop_if_exists(constraint(:payment_attempts, "payment_attempts_provider_value_check"))
    drop_if_exists(constraint(:refunds, "refunds_provider_value_check"))
    drop_if_exists(constraint(:refund_attempts, "refund_attempts_provider_value_check"))

    create(
      constraint(
        :subscriptions,
        "subscriptions_provider_value_check",
        check: "provider IN (#{@known_providers})"
      )
    )

    create(
      constraint(
        :payment_intents,
        "payment_intents_provider_value_check",
        check: "provider IN (#{@known_providers})"
      )
    )

    create(
      constraint(
        :provider_events,
        "provider_events_provider_value_check",
        check: "provider IN (#{@known_providers})"
      )
    )

    create(
      constraint(
        :webhook_receipts,
        "webhook_receipts_provider_value_check",
        check: "provider IN (#{@known_providers})"
      )
    )

    create(
      constraint(
        :payment_attempts,
        "payment_attempts_provider_value_check",
        check: "provider IN (#{@known_providers})"
      )
    )

    create(
      constraint(
        :refunds,
        "refunds_provider_value_check",
        check: "provider IN (#{@known_providers})"
      )
    )

    create(
      constraint(
        :refund_attempts,
        "refund_attempts_provider_value_check",
        check: "provider IN (#{@known_providers})"
      )
    )
  end

  def down do
    drop_if_exists(constraint(:refund_attempts, "refund_attempts_provider_value_check"))
    drop_if_exists(constraint(:refunds, "refunds_provider_value_check"))
    drop_if_exists(constraint(:payment_attempts, "payment_attempts_provider_value_check"))
    drop_if_exists(constraint(:webhook_receipts, "webhook_receipts_provider_value_check"))
    drop_if_exists(constraint(:provider_events, "provider_events_provider_value_check"))
    drop_if_exists(constraint(:payment_intents, "payment_intents_provider_value_check"))
    drop_if_exists(constraint(:subscriptions, "subscriptions_provider_value_check"))

    alter table(:refund_attempts) do
      modify(:provider, :text, null: false, default: "stripe")
    end

    alter table(:refunds) do
      modify(:provider, :text, null: false, default: "stripe")
    end

    alter table(:payment_attempts) do
      modify(:provider, :text, null: false, default: "stripe")
    end

    alter table(:payment_intents) do
      modify(:provider, :text, null: false, default: "stripe")
    end

    alter table(:subscriptions) do
      modify(:provider, :text, null: false, default: "stripe")
      modify(:billing_mode, :text, null: false, default: "merchant_managed")
    end
  end
end
