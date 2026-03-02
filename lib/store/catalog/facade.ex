defmodule Store.Catalog.Facade do
  @moduledoc """
  Consumer-scoped read surfaces for catalog storefront and admin consumers.
  """

  alias Store.Catalog
  alias Store.Catalog.Inputs.CartLineInput
  alias Store.Catalog.Product
  alias Store.Catalog.Queries.{ProductAdminIndexQuery, ProductIndexQuery}
  alias Store.Support.Errors.Error
  alias Store.Support.Errors.Normalize

  @spec list_products_for_public(map() | nil, ProductIndexQuery.t()) ::
          {:ok, [Product.t()]} | {:error, term()}
  def list_products_for_public(actor, %ProductIndexQuery{} = query) do
    ash_query =
      Product
      |> Ash.Query.for_read(:read_for_public, %{}, actor: actor)
      |> Ash.Query.load([:images, :default_variant, :category])

    case Ash.read(ash_query, domain: Catalog, actor: actor) do
      {:ok, products} ->
        products
        |> apply_public_filters(query)
        |> apply_public_sort(query.sort)
        |> apply_pagination(ProductIndexQuery.offset(query), query.page_size)
        |> then(&{:ok, &1})

      {:error, error} ->
        {:error, Normalize.normalize(error)}
    end
  end

  @spec get_product_for_public(map() | nil, String.t()) ::
          {:ok, Product.t() | nil} | {:error, term()}
  def get_product_for_public(actor, slug) when is_binary(slug) do
    ash_query =
      Product
      |> Ash.Query.for_read(:get_for_public, %{slug: slug}, actor: actor)
      |> Ash.Query.load([:images, :default_variant, :category])

    case Ash.read_one(ash_query, domain: Catalog, actor: actor) do
      {:ok, product} -> {:ok, product}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec list_products_for_admin(map(), ProductAdminIndexQuery.t()) ::
          {:ok, [Product.t()]} | {:error, term()}
  def list_products_for_admin(actor, %ProductAdminIndexQuery{} = query) when is_map(actor) do
    ash_query =
      Product
      |> Ash.Query.for_read(:read_for_admin, %{}, actor: actor)
      |> Ash.Query.load([:images, :default_variant, :category])

    case Ash.read(ash_query, domain: Catalog, actor: actor) do
      {:ok, products} ->
        products
        |> apply_admin_filters(query)
        |> apply_admin_sort(query.sort)
        |> apply_pagination(ProductAdminIndexQuery.offset(query), query.page_size)
        |> then(&{:ok, &1})

      {:error, error} ->
        {:error, Normalize.normalize(error)}
    end
  end

  @spec get_product_for_admin(map(), Ecto.UUID.t()) :: {:ok, Product.t() | nil} | {:error, term()}
  def get_product_for_admin(actor, id) when is_map(actor) and is_binary(id) do
    ash_query =
      Product
      |> Ash.Query.for_read(:get_for_admin, %{id: id}, actor: actor)
      |> Ash.Query.load([:images, :default_variant, :category])

    case Ash.read_one(ash_query, domain: Catalog, actor: actor) do
      {:ok, product} -> {:ok, product}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec normalize_cart_line_for_public(map()) ::
          {:ok, CartLineInput.t()} | {:error, Error.t() | term()}
  def normalize_cart_line_for_public(params) when is_map(params), do: CartLineInput.new(params)

  def normalize_cart_line_for_public(_params) do
    {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
  end

  @spec publish_product_for_admin(map(), Ecto.UUID.t()) :: {:ok, Product.t()} | {:error, term()}
  def publish_product_for_admin(actor, product_id) when is_map(actor) and is_binary(product_id) do
    case get_product_for_admin(actor, product_id) do
      {:ok, %Product{} = product} ->
        product
        |> Ash.Changeset.for_update(:publish, %{})
        |> Ash.update(domain: Catalog, actor: actor)
        |> normalize_result()

      {:ok, nil} ->
        {:error, Error.new("NOT_FOUND", "product not found")}

      {:error, _} = error ->
        error
    end
  end

  @spec unpublish_product_for_admin(map(), Ecto.UUID.t()) ::
          {:ok, Product.t()} | {:error, term()}
  def unpublish_product_for_admin(actor, product_id)
      when is_map(actor) and is_binary(product_id) do
    case get_product_for_admin(actor, product_id) do
      {:ok, %Product{} = product} ->
        product
        |> Ash.Changeset.for_update(:unpublish, %{})
        |> Ash.update(domain: Catalog, actor: actor)
        |> normalize_result()

      {:ok, nil} ->
        {:error, Error.new("NOT_FOUND", "product not found")}

      {:error, _} = error ->
        error
    end
  end

  @spec archive_product_for_admin(map(), Ecto.UUID.t()) :: {:ok, Product.t()} | {:error, term()}
  def archive_product_for_admin(actor, product_id) when is_map(actor) and is_binary(product_id) do
    case get_product_for_admin(actor, product_id) do
      {:ok, %Product{} = product} ->
        product
        |> Ash.Changeset.for_update(:archive, %{})
        |> Ash.update(domain: Catalog, actor: actor)
        |> normalize_result()

      {:ok, nil} ->
        {:error, Error.new("NOT_FOUND", "product not found")}

      {:error, _} = error ->
        error
    end
  end

  defp apply_public_filters(products, query) do
    products
    |> maybe_filter_query(query.q)
    |> maybe_filter_category(query.category)
  end

  defp apply_admin_filters(products, query) do
    products
    |> maybe_filter_query(query.q)
    |> maybe_filter_status(query.status)
  end

  defp maybe_filter_query(products, nil), do: products
  defp maybe_filter_query(products, ""), do: products

  defp maybe_filter_query(products, q) do
    needle = String.downcase(String.trim(q))

    Enum.filter(products, fn product ->
      String.contains?(String.downcase(product.title || ""), needle) ||
        String.contains?(String.downcase(product.subtitle || ""), needle)
    end)
  end

  defp maybe_filter_category(products, nil), do: products
  defp maybe_filter_category(products, ""), do: products

  defp maybe_filter_category(products, category_slug) do
    Enum.filter(products, fn product ->
      category = Map.get(product, :category)
      category && category.slug == category_slug
    end)
  end

  defp maybe_filter_status(products, nil), do: products

  defp maybe_filter_status(products, status) do
    Enum.filter(products, &(&1.status == status))
  end

  defp apply_public_sort(products, :newest),
    do: Enum.sort_by(products, &{to_unix_usec(&1.inserted_at), &1.id}, :desc)

  defp apply_public_sort(products, :price_asc),
    do: Enum.sort_by(products, &{price_of(&1), &1.id}, :asc)

  defp apply_public_sort(products, :price_desc),
    do: Enum.sort_by(products, &{price_of(&1), &1.id}, :desc)

  defp apply_admin_sort(products, :newest),
    do: Enum.sort_by(products, &{to_unix_usec(&1.inserted_at), &1.id}, :desc)

  defp apply_admin_sort(products, :oldest),
    do: Enum.sort_by(products, &{to_unix_usec(&1.inserted_at), &1.id}, :asc)

  defp apply_admin_sort(products, :title_asc),
    do: Enum.sort_by(products, &{String.downcase(&1.title || ""), &1.id}, :asc)

  defp apply_admin_sort(products, :title_desc),
    do: Enum.sort_by(products, &{String.downcase(&1.title || ""), &1.id}, :desc)

  defp apply_pagination(products, offset, limit),
    do: products |> Enum.drop(offset) |> Enum.take(limit)

  defp price_of(product) do
    product
    |> Map.get(:default_variant)
    |> case do
      %{price_minor: price} when is_integer(price) -> price
      _ -> 0
    end
  end

  defp to_unix_usec(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp to_unix_usec(_), do: 0

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, error}), do: {:error, Normalize.normalize(error)}
end
