defmodule Store.Repo do
  @moduledoc false

  use AshPostgres.Repo, otp_app: :store

  @impl true
  def min_pg_version do
    %Version{major: 13, minor: 0, patch: 0}
  end

  @impl true
  def installed_extensions do
    ["ash-functions", "citext"]
  end
end
