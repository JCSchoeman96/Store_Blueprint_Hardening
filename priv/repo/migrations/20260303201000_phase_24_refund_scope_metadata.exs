defmodule Store.Repo.Migrations.Phase24RefundScopeMetadata do
  @moduledoc """
  Persists explicit refund scope metadata used by digital grant revocation policy.
  """

  use Ecto.Migration

  def up do
    alter table(:refunds) do
      add :scope_kind, :text, null: false, default: "partial_refund"
      add :line_item_ids, {:array, :uuid}, null: false, default: []
    end

    create index(:refunds, [:scope_kind], name: "refunds_scope_kind_index")

    create constraint(:refunds, "refunds_scope_kind_check",
             check: "scope_kind IN ('full_refund', 'partial_refund', 'shipping_refund')"
           )
  end

  def down do
    drop constraint(:refunds, "refunds_scope_kind_check")
    drop_if_exists index(:refunds, [:scope_kind], name: "refunds_scope_kind_index")

    alter table(:refunds) do
      remove :line_item_ids
      remove :scope_kind
    end
  end
end
