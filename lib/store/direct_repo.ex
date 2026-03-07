defmodule Store.DirectRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :store,
    adapter: Ecto.Adapters.Postgres
end
