defmodule Store.Repo.Migrations.Phase21EmailOutboxUniqueOrderTemplateFix do
  @moduledoc """
  Repairs missing email outbox uniqueness index for databases that migrated through
  earlier phase 21 drafts.
  """

  use Ecto.Migration

  def up do
    execute(
      """
      CREATE UNIQUE INDEX IF NOT EXISTS email_outboxes_unique_order_template_kind_index
      ON email_outboxes (order_id, template_kind)
      """,
      """
      DROP INDEX IF EXISTS email_outboxes_unique_order_template_kind_index
      """
    )
  end

  def down do
    execute(
      """
      DROP INDEX IF EXISTS email_outboxes_unique_order_template_kind_index
      """,
      """
      CREATE UNIQUE INDEX IF NOT EXISTS email_outboxes_unique_order_template_kind_index
      ON email_outboxes (order_id, template_kind)
      """
    )
  end
end
