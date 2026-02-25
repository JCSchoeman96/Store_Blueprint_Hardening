defmodule Store.Pricing.TaxShippingContract do
  @moduledoc """
  Pure input/output contract for deterministic shipping and tax evaluation.
  """

  defmodule Line do
    @moduledoc """
    Priced line evidence input used as tax basis.
    """

    @enforce_keys [:line_id, :line_no, :net_line_total_minor]
    defstruct [:line_id, :line_no, :net_line_total_minor, tax_category_snapshot: "STANDARD"]

    @type t :: %__MODULE__{
            line_id: String.t() | binary(),
            line_no: pos_integer(),
            net_line_total_minor: non_neg_integer(),
            tax_category_snapshot: String.t()
          }
  end

  defmodule ShippingRateCandidate do
    @moduledoc """
    Shipping rate candidate read model used by deterministic selector.
    """

    @enforce_keys [:id, :code, :shipping_cost_minor]
    defstruct [
      :id,
      :code,
      :shipping_cost_minor,
      country_code: nil,
      region_code: nil,
      weight_min_grams: nil,
      weight_max_grams: nil,
      free_over_subtotal_minor: nil,
      allow_free_shipping_coupon: false,
      starts_at: nil,
      ends_at: nil,
      active?: true,
      precedence_rank: 100
    ]

    @type t :: %__MODULE__{
            id: String.t() | binary(),
            code: String.t(),
            shipping_cost_minor: non_neg_integer(),
            country_code: String.t() | nil,
            region_code: String.t() | nil,
            weight_min_grams: non_neg_integer() | nil,
            weight_max_grams: non_neg_integer() | nil,
            free_over_subtotal_minor: non_neg_integer() | nil,
            allow_free_shipping_coupon: boolean(),
            starts_at: DateTime.t() | nil,
            ends_at: DateTime.t() | nil,
            active?: boolean(),
            precedence_rank: integer()
          }
  end

  defmodule TaxRateCandidate do
    @moduledoc """
    Tax rate candidate read model used by deterministic per-line selection.
    """

    @enforce_keys [:id, :code, :country_code, :rate_basis_points]
    defstruct [
      :id,
      :code,
      :country_code,
      :rate_basis_points,
      region_code: nil,
      product_tax_category: nil,
      shipping_taxable: true,
      starts_at: nil,
      ends_at: nil,
      active?: true,
      precedence_rank: 100
    ]

    @type t :: %__MODULE__{
            id: String.t() | binary(),
            code: String.t(),
            country_code: String.t(),
            region_code: String.t() | nil,
            product_tax_category: String.t() | nil,
            rate_basis_points: non_neg_integer(),
            shipping_taxable: boolean(),
            starts_at: DateTime.t() | nil,
            ends_at: DateTime.t() | nil,
            active?: boolean(),
            precedence_rank: integer()
          }
  end

  defmodule Input do
    @moduledoc """
    Deterministic tax and shipping evaluation input.
    """

    @enforce_keys [
      :as_of,
      :currency,
      :destination_country_code,
      :subtotal_minor,
      :shipping_weight_grams,
      :lines,
      :shipping_rates,
      :tax_rates
    ]
    defstruct [
      :as_of,
      :currency,
      :destination_country_code,
      :subtotal_minor,
      :shipping_weight_grams,
      :lines,
      :shipping_rates,
      :tax_rates,
      destination_region_code: nil,
      destination_postal_code: nil,
      free_shipping_coupon?: false,
      shipping_enabled?: true,
      tax_enabled?: true
    ]

    @type t :: %__MODULE__{
            as_of: DateTime.t(),
            currency: String.t(),
            destination_country_code: String.t(),
            destination_region_code: String.t() | nil,
            destination_postal_code: String.t() | nil,
            subtotal_minor: non_neg_integer(),
            shipping_weight_grams: non_neg_integer(),
            lines: [Line.t()],
            shipping_rates: [ShippingRateCandidate.t()],
            tax_rates: [TaxRateCandidate.t()],
            free_shipping_coupon?: boolean(),
            shipping_enabled?: boolean(),
            tax_enabled?: boolean()
          }
  end

  defmodule LineTax do
    @moduledoc """
    Per-line tax output evidence.
    """

    @enforce_keys [
      :line_id,
      :line_no,
      :tax_minor,
      :tax_rate_id,
      :tax_rate_code,
      :tax_rate_bps,
      :tax_category_snapshot
    ]
    defstruct [
      :line_id,
      :line_no,
      :tax_minor,
      :tax_rate_id,
      :tax_rate_code,
      :tax_rate_bps,
      :tax_category_snapshot
    ]

    @type t :: %__MODULE__{
            line_id: String.t() | binary(),
            line_no: pos_integer(),
            tax_minor: non_neg_integer(),
            tax_rate_id: String.t() | binary(),
            tax_rate_code: String.t(),
            tax_rate_bps: non_neg_integer(),
            tax_category_snapshot: String.t()
          }
  end

  defmodule Output do
    @moduledoc """
    Deterministic tax and shipping output for order snapshot evidence.
    """

    @enforce_keys [
      :currency,
      :destination_country_code,
      :subtotal_minor,
      :shipping_cost_minor_original,
      :shipping_cost_minor_effective,
      :free_shipping_applied,
      :shipping_tax_minor,
      :tax_total_minor,
      :order_total_minor,
      :line_taxes,
      :tax_as_of
    ]
    defstruct [
      :currency,
      :destination_country_code,
      :subtotal_minor,
      :shipping_cost_minor_original,
      :shipping_cost_minor_effective,
      :free_shipping_applied,
      :shipping_tax_minor,
      :tax_total_minor,
      :order_total_minor,
      :line_taxes,
      :tax_as_of,
      destination_region_code: nil,
      destination_postal_code: nil,
      selected_shipping_rate_id: nil,
      selected_shipping_rate_code: nil,
      free_shipping_reason: nil,
      shipping_tax_rate_id: nil,
      shipping_tax_rate_code: nil,
      shipping_tax_rate_bps: nil
    ]

    @type t :: %__MODULE__{
            currency: String.t(),
            destination_country_code: String.t(),
            destination_region_code: String.t() | nil,
            destination_postal_code: String.t() | nil,
            subtotal_minor: non_neg_integer(),
            selected_shipping_rate_id: String.t() | binary() | nil,
            selected_shipping_rate_code: String.t() | nil,
            shipping_cost_minor_original: non_neg_integer(),
            shipping_cost_minor_effective: non_neg_integer(),
            free_shipping_applied: boolean(),
            free_shipping_reason: String.t() | nil,
            shipping_tax_rate_id: String.t() | binary() | nil,
            shipping_tax_rate_code: String.t() | nil,
            shipping_tax_rate_bps: non_neg_integer() | nil,
            shipping_tax_minor: non_neg_integer(),
            tax_total_minor: non_neg_integer(),
            order_total_minor: non_neg_integer(),
            line_taxes: [LineTax.t()],
            tax_as_of: DateTime.t()
          }
  end

  @spec to_input!(Input.t() | map()) :: Input.t()
  def to_input!(%Input{} = input), do: input

  def to_input!(attrs) when is_map(attrs) do
    %Input{
      as_of: Map.fetch!(attrs, :as_of),
      currency: Map.fetch!(attrs, :currency),
      destination_country_code: Map.fetch!(attrs, :destination_country_code),
      destination_region_code: Map.get(attrs, :destination_region_code),
      destination_postal_code: Map.get(attrs, :destination_postal_code),
      subtotal_minor: Map.fetch!(attrs, :subtotal_minor),
      shipping_weight_grams: Map.fetch!(attrs, :shipping_weight_grams),
      lines: attrs |> Map.fetch!(:lines) |> Enum.map(&to_line!/1),
      shipping_rates:
        attrs |> Map.fetch!(:shipping_rates) |> Enum.map(&to_shipping_rate_candidate!/1),
      tax_rates: attrs |> Map.fetch!(:tax_rates) |> Enum.map(&to_tax_rate_candidate!/1),
      free_shipping_coupon?: Map.get(attrs, :free_shipping_coupon?, false),
      shipping_enabled?: Map.get(attrs, :shipping_enabled?, true),
      tax_enabled?: Map.get(attrs, :tax_enabled?, true)
    }
  end

  @spec to_line!(Line.t() | map()) :: Line.t()
  def to_line!(%Line{} = line), do: line

  def to_line!(attrs) when is_map(attrs) do
    %Line{
      line_id: Map.fetch!(attrs, :line_id),
      line_no: Map.fetch!(attrs, :line_no),
      net_line_total_minor: Map.fetch!(attrs, :net_line_total_minor),
      tax_category_snapshot: Map.get(attrs, :tax_category_snapshot, "STANDARD")
    }
  end

  @spec to_shipping_rate_candidate!(ShippingRateCandidate.t() | map()) ::
          ShippingRateCandidate.t()
  def to_shipping_rate_candidate!(%ShippingRateCandidate{} = candidate), do: candidate

  def to_shipping_rate_candidate!(attrs) when is_map(attrs) do
    %ShippingRateCandidate{
      id: Map.fetch!(attrs, :id),
      code: Map.fetch!(attrs, :code),
      shipping_cost_minor: Map.fetch!(attrs, :shipping_cost_minor),
      country_code: Map.get(attrs, :country_code),
      region_code: Map.get(attrs, :region_code),
      weight_min_grams: Map.get(attrs, :weight_min_grams),
      weight_max_grams: Map.get(attrs, :weight_max_grams),
      free_over_subtotal_minor: Map.get(attrs, :free_over_subtotal_minor),
      allow_free_shipping_coupon: Map.get(attrs, :allow_free_shipping_coupon, false),
      starts_at: Map.get(attrs, :starts_at),
      ends_at: Map.get(attrs, :ends_at),
      active?: Map.get(attrs, :active?, true),
      precedence_rank: Map.get(attrs, :precedence_rank, 100)
    }
  end

  @spec to_tax_rate_candidate!(TaxRateCandidate.t() | map()) :: TaxRateCandidate.t()
  def to_tax_rate_candidate!(%TaxRateCandidate{} = candidate), do: candidate

  def to_tax_rate_candidate!(attrs) when is_map(attrs) do
    %TaxRateCandidate{
      id: Map.fetch!(attrs, :id),
      code: Map.fetch!(attrs, :code),
      country_code: Map.fetch!(attrs, :country_code),
      region_code: Map.get(attrs, :region_code),
      product_tax_category: Map.get(attrs, :product_tax_category),
      rate_basis_points: Map.fetch!(attrs, :rate_basis_points),
      shipping_taxable: Map.get(attrs, :shipping_taxable, true),
      starts_at: Map.get(attrs, :starts_at),
      ends_at: Map.get(attrs, :ends_at),
      active?: Map.get(attrs, :active?, true),
      precedence_rank: Map.get(attrs, :precedence_rank, 100)
    }
  end
end
