defmodule Store.Pricing.Contract do
  @moduledoc """
  DB-agnostic, deterministic pricing evaluator input/output contract.

  The evaluator contract is intentionally pure data. It must not contain
  Ash resources, Ecto structs, or query-bound data.
  """

  defmodule Line do
    @moduledoc """
    Snapshot-like line input for deterministic evaluation.
    """

    @enforce_keys [
      :id,
      :line_no,
      :sku_snapshot,
      :product_title_snapshot,
      :quantity,
      :unit_price_minor,
      :line_total_minor
    ]
    defstruct [
      :id,
      :line_no,
      :sku_snapshot,
      :product_title_snapshot,
      :quantity,
      :unit_price_minor,
      :line_total_minor,
      variant_title_snapshot: nil,
      eligible?: true
    ]

    @type t :: %__MODULE__{
            id: String.t() | binary(),
            line_no: pos_integer(),
            sku_snapshot: String.t(),
            product_title_snapshot: String.t(),
            variant_title_snapshot: String.t() | nil,
            quantity: pos_integer(),
            unit_price_minor: integer(),
            line_total_minor: integer(),
            eligible?: boolean()
          }
  end

  defmodule Candidate do
    @moduledoc """
    Candidate discount read-model consumed by deterministic evaluation.
    """

    @enforce_keys [:id, :source_kind, :discount_minor, :inserted_at]
    defstruct [
      :id,
      :source_kind,
      :discount_minor,
      :inserted_at,
      code: nil,
      starts_at: nil,
      ends_at: nil,
      active?: true,
      exclusive?: false,
      combinable?: true,
      allow_with_exclusive?: false,
      exclusive_priority: 0,
      precedence_rank: 0,
      eligibility_key: nil
    ]

    @type source_kind :: :coupon | :promotion | :manual_adjustment

    @type t :: %__MODULE__{
            id: String.t() | binary(),
            source_kind: source_kind(),
            code: String.t() | nil,
            discount_minor: pos_integer(),
            starts_at: DateTime.t() | nil,
            ends_at: DateTime.t() | nil,
            active?: boolean(),
            exclusive?: boolean(),
            combinable?: boolean(),
            allow_with_exclusive?: boolean(),
            exclusive_priority: integer(),
            precedence_rank: integer(),
            inserted_at: DateTime.t(),
            eligibility_key: atom() | String.t() | nil
          }
  end

  defmodule Input do
    @moduledoc """
    Pure evaluator input.
    """

    @enforce_keys [:as_of, :currency, :lines]
    defstruct [:as_of, :currency, :lines, coupon: nil, promotions: [], eligibility: %{}]

    @type t :: %__MODULE__{
            as_of: DateTime.t(),
            currency: String.t(),
            lines: [Line.t()],
            coupon: Candidate.t() | nil,
            promotions: [Candidate.t()],
            eligibility: map()
          }
  end

  defmodule AppliedAdjustment do
    @moduledoc """
    Deterministically ordered applied discount evidence.
    """

    @enforce_keys [:source_kind, :source_id, :discount_minor, :precedence_rank, :inserted_at]
    defstruct [
      :source_kind,
      :source_id,
      :discount_minor,
      :precedence_rank,
      :inserted_at,
      source_code: nil
    ]

    @type t :: %__MODULE__{
            source_kind: Candidate.source_kind(),
            source_id: String.t() | binary(),
            source_code: String.t() | nil,
            discount_minor: integer(),
            precedence_rank: integer(),
            inserted_at: DateTime.t()
          }
  end

  defmodule LineAllocation do
    @moduledoc """
    Deterministic discount allocation for a line.
    """

    @enforce_keys [:line_id, :discount_minor]
    defstruct [:line_id, :discount_minor]

    @type t :: %__MODULE__{line_id: String.t() | binary(), discount_minor: non_neg_integer()}
  end

  defmodule LineEvaluation do
    @moduledoc """
    Evaluated line evidence for immutable snapshot writes.
    """

    @enforce_keys [
      :line_id,
      :line_no,
      :sku_snapshot,
      :product_title_snapshot,
      :quantity,
      :unit_price_minor,
      :line_total_minor,
      :discount_allocated_minor,
      :net_line_total_minor
    ]
    defstruct [
      :line_id,
      :line_no,
      :sku_snapshot,
      :product_title_snapshot,
      :quantity,
      :unit_price_minor,
      :line_total_minor,
      :discount_allocated_minor,
      :net_line_total_minor,
      variant_title_snapshot: nil
    ]

    @type t :: %__MODULE__{
            line_id: String.t() | binary(),
            line_no: pos_integer(),
            sku_snapshot: String.t(),
            product_title_snapshot: String.t(),
            variant_title_snapshot: String.t() | nil,
            quantity: pos_integer(),
            unit_price_minor: integer(),
            line_total_minor: integer(),
            discount_allocated_minor: non_neg_integer(),
            net_line_total_minor: integer()
          }
  end

  defmodule Output do
    @moduledoc """
    Pure evaluator output.
    """

    @enforce_keys [
      :currency,
      :subtotal_minor,
      :discount_total_minor,
      :total_minor,
      :lines,
      :line_allocations,
      :applied_adjustments
    ]
    defstruct [
      :currency,
      :subtotal_minor,
      :discount_total_minor,
      :total_minor,
      :lines,
      :line_allocations,
      :applied_adjustments
    ]

    @type t :: %__MODULE__{
            currency: String.t(),
            subtotal_minor: non_neg_integer(),
            discount_total_minor: non_neg_integer(),
            total_minor: non_neg_integer(),
            lines: [LineEvaluation.t()],
            line_allocations: [LineAllocation.t()],
            applied_adjustments: [AppliedAdjustment.t()]
          }
  end

  @spec to_input!(Input.t() | map()) :: Input.t()
  def to_input!(%Input{} = input), do: input

  def to_input!(attrs) when is_map(attrs) do
    %Input{
      as_of: Map.fetch!(attrs, :as_of),
      currency: Map.fetch!(attrs, :currency),
      lines: attrs |> Map.fetch!(:lines) |> Enum.map(&to_line!/1),
      coupon: attrs |> Map.get(:coupon) |> maybe_to_candidate(),
      promotions: attrs |> Map.get(:promotions, []) |> Enum.map(&to_candidate!/1),
      eligibility: Map.get(attrs, :eligibility, %{})
    }
  end

  @spec to_candidate!(Candidate.t() | map()) :: Candidate.t()
  def to_candidate!(%Candidate{} = candidate), do: candidate

  def to_candidate!(attrs) when is_map(attrs) do
    %Candidate{
      id: Map.fetch!(attrs, :id),
      source_kind: Map.fetch!(attrs, :source_kind),
      code: Map.get(attrs, :code),
      discount_minor: Map.fetch!(attrs, :discount_minor),
      starts_at: Map.get(attrs, :starts_at),
      ends_at: Map.get(attrs, :ends_at),
      active?: Map.get(attrs, :active?, true),
      exclusive?: Map.get(attrs, :exclusive?, false),
      combinable?: Map.get(attrs, :combinable?, true),
      allow_with_exclusive?: Map.get(attrs, :allow_with_exclusive?, false),
      exclusive_priority: Map.get(attrs, :exclusive_priority, 0),
      precedence_rank: Map.get(attrs, :precedence_rank, 0),
      inserted_at: Map.fetch!(attrs, :inserted_at),
      eligibility_key: Map.get(attrs, :eligibility_key)
    }
  end

  @spec to_line!(Line.t() | map()) :: Line.t()
  def to_line!(%Line{} = line), do: line

  def to_line!(attrs) when is_map(attrs) do
    %Line{
      id: Map.fetch!(attrs, :id),
      line_no: Map.fetch!(attrs, :line_no),
      sku_snapshot: Map.fetch!(attrs, :sku_snapshot),
      product_title_snapshot: Map.fetch!(attrs, :product_title_snapshot),
      variant_title_snapshot: Map.get(attrs, :variant_title_snapshot),
      quantity: Map.fetch!(attrs, :quantity),
      unit_price_minor: Map.fetch!(attrs, :unit_price_minor),
      line_total_minor: Map.fetch!(attrs, :line_total_minor),
      eligible?: Map.get(attrs, :eligible?, true)
    }
  end

  defp maybe_to_candidate(nil), do: nil
  defp maybe_to_candidate(candidate), do: to_candidate!(candidate)
end
