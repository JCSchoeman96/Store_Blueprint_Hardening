defmodule Store.Subscriptions.Types.SubscriptionDetail do
  @moduledoc """
  Composed subscription detail contract for account and admin surfaces.
  """

  @enforce_keys [
    :subscription,
    :renewal_attempts,
    :plan_targets,
    :variant_targets,
    :action_capabilities
  ]
  defstruct [
    :subscription,
    :renewal_attempts,
    :plan_targets,
    :variant_targets,
    :action_capabilities
  ]

  @type target_option :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          required(:price_minor) => integer(),
          required(:currency) => String.t(),
          optional(:key) => String.t(),
          optional(:selected?) => boolean()
        }

  @type action_capabilities :: %{
          required(:can_cancel_now?) => boolean(),
          required(:can_cancel_at_period_end?) => boolean(),
          required(:can_queue_plan_change?) => boolean(),
          required(:can_queue_variant_change?) => boolean(),
          required(:can_update_payment_method?) => boolean(),
          required(:payment_method_update_provider) => atom() | nil
        }

  @type t :: %__MODULE__{
          subscription: map(),
          renewal_attempts: [map()],
          plan_targets: [target_option()],
          variant_targets: [target_option()],
          action_capabilities: action_capabilities()
        }
end
