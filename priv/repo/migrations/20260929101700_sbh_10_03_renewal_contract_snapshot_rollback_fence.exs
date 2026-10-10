defmodule Store.Repo.Migrations.Sbh1003RenewalContractSnapshotRollbackFence do
  @moduledoc """
  Rollback fence for SBH-10-03 renewal-contract evidence on `renewal_attempts`.

  Forward migration is intentionally non-destructive. Rollback is blocked before
  `20260924203729_sbh_10_03_renewal_contract_snapshot` can remove charged-contract
  columns when durable evidence rows exist.
  """

  use Ecto.Migration

  @evidence_fields [
    :charged_contract_version,
    :plan_revision_id,
    :variant_id,
    :quantity,
    :amount_minor,
    :currency,
    :contract_change_id,
    :expected_subscription_version,
    :charged_contract_snapshot
  ]

  def up do
    :ok
  end

  def down do
    ensure_no_durable_renewal_contract_evidence!()
  end

  defp ensure_no_durable_renewal_contract_evidence! do
    conditions =
      Enum.map_join(@evidence_fields, " OR ", fn field ->
        "#{field} IS NOT NULL"
      end)

    %{rows: [[durable_evidence?]]} =
      repo().query!("""
      SELECT EXISTS (
        SELECT 1
        FROM renewal_attempts
        WHERE #{conditions}
      )
      """)

    if durable_evidence? do
      raise Ecto.MigrationError,
        message:
          "cannot roll back SBH-10-03 renewal-contract snapshot while durable " <>
            "renewal contract evidence exists on renewal_attempts; " <>
            "rollback is blocked before schema mutation"
    end
  end
end
