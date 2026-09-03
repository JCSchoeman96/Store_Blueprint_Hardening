defmodule Store.Repo.Migrations.DepSec03cIdentityLinkEmailOutbox do
  @moduledoc """
  Adds the identity-link email outbox shape to the coherence constraint.

  Rollback is intentionally blocked once identity-link rows exist. The enum
  label remains physically present after a successful rollback because removing
  a PostgreSQL enum label would require destructive type reconstruction.
  """

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
    # Rollback state machine: eligible -> reverting -> reverted. If the
    # identity-link rows make the migration in_use, it transitions to blocked
    # here and performs no schema mutation.
    ensure_no_identity_link_outbox_rows!()

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

  defp ensure_no_identity_link_outbox_rows! do
    %{rows: [[identity_link_rows?]]} =
      repo().query!("""
      SELECT EXISTS (
        SELECT 1
        FROM email_outboxes
        WHERE template_kind::text = 'identity_link_confirmation'
      )
      """)

    if identity_link_rows? do
      raise Ecto.MigrationError,
        message:
          "cannot roll back DEP-SEC-03C while durable identity-link EmailOutbox rows exist; " <>
            "rollback is blocked before schema mutation"
    end
  end
end
