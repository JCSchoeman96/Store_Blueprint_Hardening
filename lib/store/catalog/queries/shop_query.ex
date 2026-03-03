defmodule Store.Catalog.Queries.ShopQuery do
  @moduledoc """
  Typed storefront query contract for shop listing reads.
  """

  alias Store.Catalog.Queries.ProductIndexQuery
  alias Store.Support.Errors.Error

  @enforce_keys [:q, :category, :sort, :page, :page_size]
  defstruct [:q, :category, :sort, :page, :page_size]

  @type t :: %__MODULE__{
          q: String.t() | nil,
          category: String.t() | nil,
          sort: ProductIndexQuery.sort_t(),
          page: pos_integer(),
          page_size: pos_integer()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with {:ok, %ProductIndexQuery{} = query} <- ProductIndexQuery.new(params) do
      {:ok,
       %__MODULE__{
         q: query.q,
         category: query.category,
         sort: query.sort,
         page: query.page,
         page_size: query.page_size
       }}
    end
  end

  def new(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}

  @spec offset(t()) :: non_neg_integer()
  def offset(%__MODULE__{page: page, page_size: page_size}), do: (page - 1) * page_size

  @spec to_product_index_query(t()) :: ProductIndexQuery.t()
  def to_product_index_query(%__MODULE__{} = query) do
    %ProductIndexQuery{
      q: query.q,
      category: query.category,
      sort: query.sort,
      page: query.page,
      page_size: query.page_size
    }
  end
end
