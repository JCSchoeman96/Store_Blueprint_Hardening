defmodule Store.Shipping.Types.QuoteEvidence do
  @moduledoc """
  Immutable shipping quote evidence persisted on the order before finalize.
  """

  @enforce_keys [
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
    :effective_to
  ]

  @type t :: %__MODULE__{
          quote_hash: String.t() | nil,
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
          effective_to: DateTime.t() | nil
        }

  @spec from_quote_option(Store.Shipping.Types.QuoteOption.t()) :: t()
  def from_quote_option(%Store.Shipping.Types.QuoteOption{} = option) do
    %__MODULE__{
      quote_hash: option.quote_hash,
      currency_code: option.currency_code,
      amount_minor: option.amount_minor,
      shipping_weight_grams: option.shipping_weight_grams,
      destination_country_code: option.destination_country_code,
      destination_region_code: option.destination_region_code,
      destination_postal_code: option.destination_postal_code,
      shipping_method_code: option.shipping_method_code,
      shipping_rule_id: option.shipping_rule_id,
      zone_id: option.zone_id,
      effective_from: option.effective_from,
      effective_to: option.effective_to
    }
  end

  @spec hash_payload(t()) :: map()
  def hash_payload(%__MODULE__{} = evidence) do
    %{
      currency_code: evidence.currency_code,
      amount_minor: evidence.amount_minor,
      shipping_weight_grams: evidence.shipping_weight_grams,
      destination_country_code: evidence.destination_country_code,
      destination_region_code: evidence.destination_region_code,
      destination_postal_code: evidence.destination_postal_code,
      shipping_method_code: evidence.shipping_method_code,
      shipping_rule_id: evidence.shipping_rule_id,
      zone_id: evidence.zone_id,
      effective_from: evidence.effective_from,
      effective_to: evidence.effective_to
    }
  end
end
