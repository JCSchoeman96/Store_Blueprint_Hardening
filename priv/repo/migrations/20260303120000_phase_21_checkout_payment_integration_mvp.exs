defmodule Store.Repo.Migrations.Phase21CheckoutPaymentIntegrationMvp do
  @moduledoc """
  Adds order-backed checkout fields, payment provider metadata, webhook verification states,
  and receipt-email outbox persistence for phase 21.
  """

  use Ecto.Migration

  def up do
    alter table(:checkout_drafts) do
      add(
        :order_id,
        references(:orders,
          column: :id,
          type: :uuid,
          name: "checkout_drafts_order_id_fkey",
          on_delete: :nilify_all
        )
      )
    end

    create(index(:checkout_drafts, [:order_id], name: "checkout_drafts_order_id_index"))

    create(
      unique_index(:checkout_drafts, [:order_id],
        where: "order_id IS NOT NULL",
        name: "checkout_drafts_unique_order_id_index"
      )
    )

    alter table(:orders) do
      add(:currency_code, :text)
      add(:items_subtotal_minor, :bigint, null: false, default: 0)
      add(:shipping_total_minor, :bigint, null: false, default: 0)
      add(:grand_total_minor, :bigint, null: false, default: 0)
      add(:totals_finalized_at, :utc_datetime_usec)
      add(:shipping_recipient_name, :text)
      add(:shipping_address_line1, :text)
      add(:shipping_address_line2, :text)
      add(:shipping_city, :text)
      add(:shipping_phone, :text)
    end

    create(index(:orders, [:currency_code], name: "orders_currency_code_index"))
    create(index(:orders, [:totals_finalized_at], name: "orders_totals_finalized_at_index"))

    create(
      constraint(:orders, "orders_items_subtotal_minor_non_negative",
        check: "items_subtotal_minor >= 0"
      )
    )

    create(
      constraint(:orders, "orders_shipping_total_minor_non_negative",
        check: "shipping_total_minor >= 0"
      )
    )

    create(
      constraint(:orders, "orders_grand_total_minor_non_negative",
        check: "grand_total_minor >= 0"
      )
    )

    alter table(:payment_intents) do
      add(:provider, :text, null: false, default: "stripe")
      add(:provider_payment_id, :text)
      add(:provider_session_id, :text)
      add(:provider_checkout_url, :text)
      add(:provider_client_secret, :text)
    end

    create(index(:payment_intents, [:provider], name: "payment_intents_provider_index"))

    create(
      index(:payment_intents, [:provider_payment_id],
        name: "payment_intents_provider_payment_id_index"
      )
    )

    create(
      index(:payment_intents, [:provider_session_id],
        name: "payment_intents_provider_session_id_index"
      )
    )

    create(
      unique_index(:payment_intents, [:provider, :provider_payment_id],
        where: "provider_payment_id IS NOT NULL",
        name: "payment_intents_unique_provider_payment_id_index"
      )
    )

    create(
      unique_index(:payment_intents, [:provider, :provider_session_id],
        where: "provider_session_id IS NOT NULL",
        name: "payment_intents_unique_provider_session_id_index"
      )
    )

    alter table(:webhook_receipts) do
      add(:verification_status, :text, null: false, default: "verified")
      add(:processing_status, :text, null: false, default: "new")
      add(:provider_event_id, :text)
      add(:event_type, :text)
      add(:error_code, :text)
      add(:error_detail, :text)
      add(:verified_at, :utc_datetime_usec)
      add(:processed_at, :utc_datetime_usec)
    end

    create(
      index(:webhook_receipts, [:verification_status],
        name: "webhook_receipts_verification_status_index"
      )
    )

    create(
      index(:webhook_receipts, [:processing_status],
        name: "webhook_receipts_processing_status_index"
      )
    )

    create(
      index(:webhook_receipts, [:provider_event_id],
        name: "webhook_receipts_provider_event_id_index"
      )
    )

    create(
      unique_index(:webhook_receipts, [:provider, :provider_event_id],
        where: "provider_event_id IS NOT NULL",
        name: "webhook_receipts_unique_provider_event_id_index"
      )
    )

    create(
      constraint(:webhook_receipts, "webhook_receipts_verification_status_check",
        check: "verification_status IN ('verified', 'rejected')"
      )
    )

    create(
      constraint(:webhook_receipts, "webhook_receipts_processing_status_check",
        check: "processing_status IN ('new', 'processing', 'processed', 'failed')"
      )
    )

    create table(:email_outboxes, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :order_id,
        references(:orders,
          column: :id,
          type: :uuid,
          name: "email_outboxes_order_id_fkey",
          on_delete: :delete_all
        ),
        null: false
      )

      add(:template_kind, :text, null: false)
      add(:to_email, :text, null: false)
      add(:subject, :text, null: false, default: "")
      add(:body_text, :text, null: false, default: "")
      add(:body_html, :text)
      add(:idempotency_key, :text, null: false)
      add(:state, :text, null: false, default: "pending")
      add(:attempt_count, :integer, null: false, default: 0)
      add(:last_error, :text)
      add(:sent_at, :utc_datetime_usec)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(index(:email_outboxes, [:order_id], name: "email_outboxes_order_id_index"))
    create(index(:email_outboxes, [:state], name: "email_outboxes_state_index"))

    create(index(:email_outboxes, [:template_kind], name: "email_outboxes_template_kind_index"))

    create(
      unique_index(:email_outboxes, [:idempotency_key],
        name: "email_outboxes_unique_idempotency_key_index"
      )
    )

    create(
      unique_index(:email_outboxes, [:order_id, :template_kind],
        name: "email_outboxes_unique_order_template_kind_index"
      )
    )

    create(
      constraint(:email_outboxes, "email_outboxes_state_check",
        check: "state IN ('pending', 'processing', 'sent', 'failed')"
      )
    )

    create(
      constraint(:email_outboxes, "email_outboxes_attempt_count_non_negative",
        check: "attempt_count >= 0"
      )
    )
  end

  def down do
    drop(constraint(:email_outboxes, "email_outboxes_attempt_count_non_negative"))
    drop(constraint(:email_outboxes, "email_outboxes_state_check"))

    drop_if_exists(
      unique_index(:email_outboxes, [:order_id, :template_kind],
        name: "email_outboxes_unique_order_template_kind_index"
      )
    )

    drop_if_exists(
      unique_index(:email_outboxes, [:idempotency_key],
        name: "email_outboxes_unique_idempotency_key_index"
      )
    )

    drop_if_exists(
      index(:email_outboxes, [:template_kind], name: "email_outboxes_template_kind_index")
    )

    drop_if_exists(index(:email_outboxes, [:state], name: "email_outboxes_state_index"))
    drop_if_exists(index(:email_outboxes, [:order_id], name: "email_outboxes_order_id_index"))

    drop(table(:email_outboxes))

    drop(constraint(:webhook_receipts, "webhook_receipts_processing_status_check"))
    drop(constraint(:webhook_receipts, "webhook_receipts_verification_status_check"))

    drop_if_exists(
      unique_index(:webhook_receipts, [:provider, :provider_event_id],
        where: "provider_event_id IS NOT NULL",
        name: "webhook_receipts_unique_provider_event_id_index"
      )
    )

    drop_if_exists(
      index(:webhook_receipts, [:provider_event_id],
        name: "webhook_receipts_provider_event_id_index"
      )
    )

    drop_if_exists(
      index(:webhook_receipts, [:processing_status],
        name: "webhook_receipts_processing_status_index"
      )
    )

    drop_if_exists(
      index(:webhook_receipts, [:verification_status],
        name: "webhook_receipts_verification_status_index"
      )
    )

    alter table(:webhook_receipts) do
      remove(:processed_at)
      remove(:verified_at)
      remove(:error_detail)
      remove(:error_code)
      remove(:event_type)
      remove(:provider_event_id)
      remove(:processing_status)
      remove(:verification_status)
    end

    drop_if_exists(
      unique_index(:payment_intents, [:provider, :provider_payment_id],
        where: "provider_payment_id IS NOT NULL",
        name: "payment_intents_unique_provider_payment_id_index"
      )
    )

    drop_if_exists(
      unique_index(:payment_intents, [:provider, :provider_session_id],
        where: "provider_session_id IS NOT NULL",
        name: "payment_intents_unique_provider_session_id_index"
      )
    )

    drop_if_exists(
      index(:payment_intents, [:provider_payment_id],
        name: "payment_intents_provider_payment_id_index"
      )
    )

    drop_if_exists(
      index(:payment_intents, [:provider_session_id],
        name: "payment_intents_provider_session_id_index"
      )
    )

    drop_if_exists(index(:payment_intents, [:provider], name: "payment_intents_provider_index"))

    alter table(:payment_intents) do
      remove(:provider_client_secret)
      remove(:provider_checkout_url)
      remove(:provider_session_id)
      remove(:provider_payment_id)
      remove(:provider)
    end

    drop(constraint(:orders, "orders_grand_total_minor_non_negative"))
    drop(constraint(:orders, "orders_shipping_total_minor_non_negative"))
    drop(constraint(:orders, "orders_items_subtotal_minor_non_negative"))

    drop_if_exists(
      index(:orders, [:totals_finalized_at], name: "orders_totals_finalized_at_index")
    )

    drop_if_exists(index(:orders, [:currency_code], name: "orders_currency_code_index"))

    alter table(:orders) do
      remove(:shipping_phone)
      remove(:shipping_city)
      remove(:shipping_address_line2)
      remove(:shipping_address_line1)
      remove(:shipping_recipient_name)
      remove(:totals_finalized_at)
      remove(:grand_total_minor)
      remove(:shipping_total_minor)
      remove(:items_subtotal_minor)
      remove(:currency_code)
    end

    drop_if_exists(
      unique_index(:checkout_drafts, [:order_id],
        where: "order_id IS NOT NULL",
        name: "checkout_drafts_unique_order_id_index"
      )
    )

    drop_if_exists(index(:checkout_drafts, [:order_id], name: "checkout_drafts_order_id_index"))

    alter table(:checkout_drafts) do
      remove(:order_id)
    end
  end
end
