defmodule Store.Repo.Migrations.DepSec03cIdentityLinkEmailOutbox do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("ALTER TYPE email_template_kind ADD VALUE IF NOT EXISTS 'identity_link_confirmation'")

    drop constraint(:email_outboxes, "email_outboxes_template_kind_refund_coherence_check")

    create(
      constraint(:email_outboxes, "email_outboxes_template_kind_refund_coherence_check",
        check: """
        (
          order_id IS NOT NULL
          AND refund_id IS NULL
          AND subscription_id IS NULL
          AND template_kind IN (
            'order_receipt'::email_template_kind,
            'payment_authentication_required'::email_template_kind
          )
        ) OR (
          order_id IS NOT NULL
          AND refund_id IS NOT NULL
          AND subscription_id IS NULL
          AND template_kind IN (
            'refund_requested'::email_template_kind,
            'refund_processed'::email_template_kind
          )
        ) OR (
          order_id IS NULL
          AND refund_id IS NULL
          AND subscription_id IS NOT NULL
          AND template_kind IN (
            'renewal_reminder'::email_template_kind,
            'access_ended'::email_template_kind
          )
        ) OR (
          order_id IS NULL
          AND refund_id IS NULL
          AND subscription_id IS NULL
          AND template_kind = 'identity_link_confirmation'::email_template_kind
        )
        """
      )
    )
  end

  def down do
    drop constraint(:email_outboxes, "email_outboxes_template_kind_refund_coherence_check")

    create(
      constraint(:email_outboxes, "email_outboxes_template_kind_refund_coherence_check",
        check: """
        (
          order_id IS NOT NULL
          AND refund_id IS NULL
          AND subscription_id IS NULL
          AND template_kind IN (
            'order_receipt'::email_template_kind,
            'payment_authentication_required'::email_template_kind
          )
        ) OR (
          order_id IS NOT NULL
          AND refund_id IS NOT NULL
          AND subscription_id IS NULL
          AND template_kind IN (
            'refund_requested'::email_template_kind,
            'refund_processed'::email_template_kind
          )
        ) OR (
          order_id IS NULL
          AND refund_id IS NULL
          AND subscription_id IS NOT NULL
          AND template_kind IN (
            'renewal_reminder'::email_template_kind,
            'access_ended'::email_template_kind
          )
        )
        """
      )
    )
  end
end
