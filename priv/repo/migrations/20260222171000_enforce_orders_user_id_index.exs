defmodule Store.Repo.Migrations.EnforceOrdersUserIdIndex do
  use Ecto.Migration

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS orders_user_id_index ON orders (user_id);
    """)
  end

  def down do
    execute("""
    DROP INDEX IF EXISTS orders_user_id_index;
    """)
  end
end
