defmodule Store.Catalog.Types.ProductDetail do
  @moduledoc """
  Stable public storefront product detail contract.
  """

  alias Store.Catalog.Product
  alias Store.Catalog.Variant

  @enforce_keys [
    :product,
    :options,
    :selected,
    :resolution,
    :availability_matrix,
    :subscription_plan_options,
    :selected_subscription_plan_id,
    :selected_subscription_plan_key,
    :subscription_plan_required?
  ]
  defstruct [
    :product,
    :options,
    :selected,
    :resolution,
    :availability_matrix,
    :subscription_plan_options,
    :selected_subscription_plan_id,
    :selected_subscription_plan_key,
    :subscription_plan_required?
  ]

  @type t :: %__MODULE__{
          product: Product.t(),
          options: [Option.t()],
          selected: %{optional(String.t()) => String.t()},
          resolution: Resolution.t(),
          availability_matrix: [AvailabilityCell.t()],
          subscription_plan_options: [PlanOption.t()],
          selected_subscription_plan_id: String.t() | nil,
          selected_subscription_plan_key: String.t() | nil,
          subscription_plan_required?: boolean()
        }

  defmodule Option do
    @moduledoc """
    Public storefront option axis.
    """

    @enforce_keys [:id, :slug, :name, :position, :selection_required, :values]
    defstruct [:id, :slug, :name, :position, :selection_required, :values]

    @type t :: %__MODULE__{
            id: String.t(),
            slug: String.t(),
            name: String.t(),
            position: integer(),
            selection_required: boolean(),
            values: [Store.Catalog.Types.ProductDetail.OptionValue.t()]
          }
  end

  defmodule OptionValue do
    @moduledoc """
    Public storefront option value.
    """

    @enforce_keys [:id, :slug, :name, :position]
    defstruct [:id, :slug, :name, :position]

    @type t :: %__MODULE__{
            id: String.t(),
            slug: String.t(),
            name: String.t(),
            position: integer()
          }
  end

  defmodule Resolution do
    @moduledoc """
    Product detail resolution outcome for the currently selected options.
    """

    @enforce_keys [:status, :variant_id, :variant, :reason]
    defstruct [:status, :variant_id, :variant, :reason]

    @type status :: :ok | :error
    @type reason :: nil | :invalid_selection | :selection_ambiguous | :out_of_stock

    @type t :: %__MODULE__{
            status: status(),
            variant_id: String.t() | nil,
            variant: Variant.t() | nil,
            reason: reason()
          }
  end

  defmodule AvailabilityValue do
    @moduledoc """
    Public storefront availability state for a selectable value.
    """

    @enforce_keys [:value_id, :value_slug, :selectable, :in_stock]
    defstruct [:value_id, :value_slug, :selectable, :in_stock]

    @type t :: %__MODULE__{
            value_id: String.t(),
            value_slug: String.t(),
            selectable: boolean(),
            in_stock: boolean()
          }
  end

  defmodule AvailabilityCell do
    @moduledoc """
    Public storefront availability state for one option axis.
    """

    @enforce_keys [:option_id, :option_slug, :selected_value_id, :values]
    defstruct [:option_id, :option_slug, :selected_value_id, :values]

    @type t :: %__MODULE__{
            option_id: String.t(),
            option_slug: String.t(),
            selected_value_id: String.t() | nil,
            values: [Store.Catalog.Types.ProductDetail.AvailabilityValue.t()]
          }
  end

  defmodule PlanOption do
    @moduledoc """
    Public storefront subscription plan option for the resolved variant.
    """

    @enforce_keys [:id, :key, :name, :amount_minor, :currency]
    defstruct [:id, :key, :name, :amount_minor, :currency]

    @type t :: %__MODULE__{
            id: String.t(),
            key: String.t(),
            name: String.t(),
            amount_minor: integer(),
            currency: String.t()
          }
  end
end
