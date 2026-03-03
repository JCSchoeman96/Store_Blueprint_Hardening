defmodule Store.Shipping.Types.QuoteOption do
  @moduledoc """
  Deterministic shipping quote option returned to checkout flows.
  """

  @enforce_keys [
    :quote_hash,
    :currency_code,
    :amount_minor,
    :shipping_weight_grams,
    :destination_country_code,
    :shipping_method_code
  ]
  defstruct [
    :quote_hash,
    :currency_code,
    :amount_minor,
    :shipping_weight_grams,
    :destination_country_code,
    :destination_region_code,
    :destination_postal_code,
    :shipping_method_code,
    :shipping_rule_id,
    :zone_id,
    :effective_from,
    :effective_to,
    :label
  ]

  @type t :: %__MODULE__{
          quote_hash: String.t(),
          currency_code: String.t(),
          amount_minor: non_neg_integer(),
          shipping_weight_grams: non_neg_integer(),
          destination_country_code: String.t(),
          destination_region_code: String.t() | nil,
          destination_postal_code: String.t() | nil,
          shipping_method_code: String.t(),
          shipping_rule_id: Ecto.UUID.t() | nil,
          zone_id: Ecto.UUID.t() | nil,
          effective_from: DateTime.t() | nil,
          effective_to: DateTime.t() | nil,
          label: String.t() | nil
        }
end
