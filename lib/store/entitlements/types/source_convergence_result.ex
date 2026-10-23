defmodule Store.Entitlements.Types.SourceConvergenceResult do
  @moduledoc """
  Result of converging one Subscription source into Entitlements.
  """

  @enforce_keys [
    :mode,
    :subscription_id,
    :target_grant_id,
    :revoked_grant_ids,
    :projection_user_ids
  ]
  defstruct [
    :mode,
    :subscription_id,
    :target_grant_id,
    :revoked_grant_ids,
    :projection_user_ids
  ]

  @type t :: %__MODULE__{
          mode: :pair | :empty,
          subscription_id: Ecto.UUID.t(),
          target_grant_id: Ecto.UUID.t() | nil,
          revoked_grant_ids: [Ecto.UUID.t()],
          projection_user_ids: [Ecto.UUID.t()]
        }
end
