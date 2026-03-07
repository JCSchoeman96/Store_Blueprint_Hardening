defmodule Store.Catalog.Facade do
  @moduledoc """
  Consumer-scoped read surfaces for catalog storefront and admin consumers.
  """

  import Ecto.Query

  alias Store.Catalog
  alias Store.Catalog.Inputs.CartLineInput

  alias Store.Catalog.{
    AvailabilityCache,
    Category,
    Product,
    ProductOption,
    ProductOptionValue,
    StockFastPath,
    Variant,
    VariantOptionSelection,
    VariantResolver
  }

  alias Store.Catalog.Queries.{
    ProductAdminIndexQuery,
    ProductDetailQuery,
    ProductIndexQuery
  }

  alias Store.Repo
  alias Store.Support.Errors.Error
  alias Store.Support.Errors.Normalize

  @variant_delete_blocking_constraints [
    "products_default_variant_id_fkey",
    "cart_items_variant_id_fkey",
    "subscription_items_variant_id_fkey"
  ]

  @variant_delete_blocking_constraints_set MapSet.new(@variant_delete_blocking_constraints)

  @spec list_products_for_public(map() | nil, ProductIndexQuery.t()) ::
          {:ok, [Product.t()]} | {:error, term()}
  def list_products_for_public(actor, %ProductIndexQuery{} = query) do
    ash_query = Ash.Query.for_read(Product, :read_for_public, %{}, actor: actor)

    case Ash.read(ash_query, domain: Catalog, actor: actor) do
      {:ok, products} ->
        products
        |> attach_default_variants()
        |> attach_categories()
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
      |> Ash.Query.load([:images])

    case Ash.read_one(ash_query, domain: Catalog, actor: actor) do
      {:ok, product} -> {:ok, product}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec get_product_detail_for_public(map() | nil, ProductDetailQuery.t()) ::
          {:ok, map()} | {:error, term()}
  def get_product_detail_for_public(actor, %ProductDetailQuery{} = query) do
    with {:ok, %Product{} = product} <- get_product_for_public(actor, query.slug),
         {:ok, detail} <- VariantResolver.build_product_detail(product, query.selection) do
      {:ok, detail}
    else
      {:ok, nil} -> {:error, Error.new("NOT_FOUND", "product not found")}
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
    transition_product_for_admin(actor, product_id, :publish)
  end

  @spec unpublish_product_for_admin(map(), Ecto.UUID.t()) ::
          {:ok, Product.t()} | {:error, term()}
  def unpublish_product_for_admin(actor, product_id)
      when is_map(actor) and is_binary(product_id) do
    transition_product_for_admin(actor, product_id, :unpublish)
  end

  @spec archive_product_for_admin(map(), Ecto.UUID.t()) :: {:ok, Product.t()} | {:error, term()}
  def archive_product_for_admin(actor, product_id) when is_map(actor) and is_binary(product_id) do
    transition_product_for_admin(actor, product_id, :archive)
  end

  @spec list_product_options_for_admin(map(), Ecto.UUID.t()) ::
          {:ok, [%{option: ProductOption.t(), values: [ProductOptionValue.t()]}]}
          | {:error, term()}
  def list_product_options_for_admin(actor, product_id)
      when is_map(actor) and is_binary(product_id) do
    case get_product_for_admin(actor, product_id) do
      {:ok, %Product{}} ->
        options =
          ProductOption
          |> where([option], option.product_id == ^product_id)
          |> order_by([option], asc: option.position, asc: option.id)
          |> Repo.all()

        values_by_option_id =
          ProductOptionValue
          |> where([value], value.product_option_id in ^Enum.map(options, & &1.id))
          |> order_by([value], asc: value.position, asc: value.id)
          |> Repo.all()
          |> Enum.group_by(& &1.product_option_id)

        {:ok,
         Enum.map(options, fn option ->
           %{option: option, values: Map.get(values_by_option_id, option.id, [])}
         end)}

      {:ok, nil} ->
        {:error, Error.new("NOT_FOUND", "product not found")}

      {:error, _} = error ->
        error
    end
  end

  @spec create_product_option_for_admin(map(), Ecto.UUID.t(), map()) ::
          {:ok, ProductOption.t()} | {:error, term()}
  def create_product_option_for_admin(actor, product_id, attrs)
      when is_map(actor) and is_binary(product_id) and is_map(attrs) do
    attrs = Map.put(attrs, :product_id, product_id)

    ProductOption
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(domain: Catalog, actor: actor)
    |> normalize_result()
    |> maybe_invalidate_product_cache(product_id)
  end

  def create_product_option_for_admin(_actor, _product_id, _attrs),
    do: {:error, Error.new("VALIDATION_ERROR", "actor, product_id, and attrs are required")}

  @spec update_product_option_for_admin(map(), Ecto.UUID.t(), map()) ::
          {:ok, ProductOption.t()} | {:error, term()}
  def update_product_option_for_admin(actor, option_id, attrs)
      when is_map(actor) and is_binary(option_id) and is_map(attrs) do
    with %ProductOption{} = option <- Repo.get(ProductOption, option_id),
         {:ok, updated} <-
           option
           |> Ash.Changeset.for_update(:update, attrs)
           |> Ash.update(domain: Catalog, actor: actor)
           |> normalize_result() do
      maybe_invalidate_product_cache({:ok, updated}, option.product_id)
    else
      nil -> {:error, Error.new("NOT_FOUND", "product option not found")}
      {:error, _} = error -> error
    end
  end

  def update_product_option_for_admin(_actor, _option_id, _attrs),
    do: {:error, Error.new("VALIDATION_ERROR", "actor, option_id, and attrs are required")}

  @spec delete_product_option_for_admin(map(), Ecto.UUID.t()) :: :ok | {:error, term()}
  def delete_product_option_for_admin(actor, option_id)
      when is_map(actor) and is_binary(option_id) do
    with %ProductOption{} = option <- Repo.get(ProductOption, option_id),
         {:ok, _destroyed} <-
           option
           |> Ash.Changeset.for_destroy(:destroy, %{})
           |> Ash.destroy(domain: Catalog, actor: actor)
           |> normalize_result() do
      _ = AvailabilityCache.invalidate_product(option.product_id)
      :ok
    else
      nil -> {:error, Error.new("NOT_FOUND", "product option not found")}
      {:error, _} = error -> error
    end
  end

  def delete_product_option_for_admin(_actor, _option_id),
    do: {:error, Error.new("VALIDATION_ERROR", "actor and option_id are required")}

  @spec create_product_option_value_for_admin(map(), Ecto.UUID.t(), map()) ::
          {:ok, ProductOptionValue.t()} | {:error, term()}
  def create_product_option_value_for_admin(actor, option_id, attrs)
      when is_map(actor) and is_binary(option_id) and is_map(attrs) do
    case Repo.get(ProductOption, option_id) do
      %ProductOption{} = option ->
        attrs = Map.put(attrs, :product_option_id, option_id)

        ProductOptionValue
        |> Ash.Changeset.for_create(:create, attrs)
        |> Ash.create(domain: Catalog, actor: actor)
        |> normalize_result()
        |> maybe_invalidate_product_cache(option.product_id)

      nil ->
        {:error, Error.new("NOT_FOUND", "product option not found")}
    end
  end

  def create_product_option_value_for_admin(_actor, _option_id, _attrs),
    do: {:error, Error.new("VALIDATION_ERROR", "actor, option_id, and attrs are required")}

  @spec update_product_option_value_for_admin(map(), Ecto.UUID.t(), map()) ::
          {:ok, ProductOptionValue.t()} | {:error, term()}
  def update_product_option_value_for_admin(actor, value_id, attrs)
      when is_map(actor) and is_binary(value_id) and is_map(attrs) do
    with %ProductOptionValue{} = value <- Repo.get(ProductOptionValue, value_id),
         %ProductOption{} = option <- Repo.get(ProductOption, value.product_option_id),
         {:ok, updated} <-
           value
           |> Ash.Changeset.for_update(:update, attrs)
           |> Ash.update(domain: Catalog, actor: actor)
           |> normalize_result() do
      maybe_invalidate_product_cache({:ok, updated}, option.product_id)
    else
      nil -> {:error, Error.new("NOT_FOUND", "product option value not found")}
      {:error, _} = error -> error
    end
  end

  def update_product_option_value_for_admin(_actor, _value_id, _attrs),
    do: {:error, Error.new("VALIDATION_ERROR", "actor, value_id, and attrs are required")}

  @spec delete_product_option_value_for_admin(map(), Ecto.UUID.t()) :: :ok | {:error, term()}
  def delete_product_option_value_for_admin(actor, value_id)
      when is_map(actor) and is_binary(value_id) do
    with %ProductOptionValue{} = value <- Repo.get(ProductOptionValue, value_id),
         %ProductOption{} = option <- Repo.get(ProductOption, value.product_option_id),
         {:ok, _destroyed} <-
           value
           |> Ash.Changeset.for_destroy(:destroy, %{})
           |> Ash.destroy(domain: Catalog, actor: actor)
           |> normalize_result() do
      _ = AvailabilityCache.invalidate_product(option.product_id)
      :ok
    else
      nil -> {:error, Error.new("NOT_FOUND", "product option value not found")}
      {:error, _} = error -> error
    end
  end

  def delete_product_option_value_for_admin(_actor, _value_id),
    do: {:error, Error.new("VALIDATION_ERROR", "actor and value_id are required")}

  @spec list_variants_for_admin(map(), Ecto.UUID.t()) :: {:ok, [Variant.t()]} | {:error, term()}
  def list_variants_for_admin(actor, product_id) when is_map(actor) and is_binary(product_id) do
    case get_product_for_admin(actor, product_id) do
      {:ok, %Product{}} ->
        variants =
          Variant
          |> where([variant], variant.product_id == ^product_id)
          |> order_by([variant], asc: variant.inserted_at, asc: variant.id)
          |> Repo.all()

        {:ok, variants}

      {:ok, nil} ->
        {:error, Error.new("NOT_FOUND", "product not found")}

      {:error, _} = error ->
        error
    end
  end

  @spec list_variant_selections_for_admin(map(), Ecto.UUID.t()) ::
          {:ok, [VariantOptionSelection.t()]} | {:error, term()}
  def list_variant_selections_for_admin(actor, product_id)
      when is_map(actor) and is_binary(product_id) do
    with {:ok, _product} <- get_product_for_admin(actor, product_id),
         variant_ids <- variant_ids_for_product(product_id) do
      selections =
        VariantOptionSelection
        |> where([selection], selection.variant_id in ^variant_ids)
        |> order_by([selection], asc: selection.inserted_at, asc: selection.id)
        |> Repo.all()

      {:ok, selections}
    else
      {:ok, nil} -> {:error, Error.new("NOT_FOUND", "product not found")}
      {:error, _} = error -> error
    end
  end

  @spec create_variant_for_admin(map(), Ecto.UUID.t(), map()) ::
          {:ok, Variant.t()} | {:error, term()}
  def create_variant_for_admin(actor, product_id, attrs)
      when is_map(actor) and is_binary(product_id) and is_map(attrs) do
    attrs = Map.put(attrs, :product_id, product_id)

    Variant
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(domain: Catalog, actor: actor)
    |> normalize_result()
    |> maybe_invalidate_product_cache(product_id)
  end

  def create_variant_for_admin(_actor, _product_id, _attrs),
    do: {:error, Error.new("VALIDATION_ERROR", "actor, product_id, and attrs are required")}

  @spec update_variant_for_admin(map(), Ecto.UUID.t(), map()) ::
          {:ok, Variant.t()} | {:error, term()}
  def update_variant_for_admin(actor, variant_id, attrs)
      when is_map(actor) and is_binary(variant_id) and is_map(attrs) do
    with %Variant{} = variant <- Repo.get(Variant, variant_id),
         {:ok, updated} <-
           variant
           |> Ash.Changeset.for_update(:update, attrs)
           |> Ash.update(domain: Catalog, actor: actor)
           |> normalize_result() do
      maybe_invalidate_product_cache({:ok, updated}, variant.product_id)
    else
      nil -> {:error, Error.new("NOT_FOUND", "variant not found")}
      {:error, _} = error -> error
    end
  end

  def update_variant_for_admin(_actor, _variant_id, _attrs),
    do: {:error, Error.new("VALIDATION_ERROR", "actor, variant_id, and attrs are required")}

  @spec archive_variant_for_admin(map(), Ecto.UUID.t()) :: {:ok, Variant.t()} | {:error, term()}
  def archive_variant_for_admin(actor, variant_id) when is_map(actor) and is_binary(variant_id) do
    with %Variant{} = variant <- Repo.get(Variant, variant_id),
         {:ok, archived} <-
           variant
           |> Ash.Changeset.for_update(:archive, %{})
           |> Ash.update(domain: Catalog, actor: actor)
           |> normalize_result() do
      maybe_invalidate_product_cache({:ok, archived}, variant.product_id)
    else
      nil -> {:error, Error.new("NOT_FOUND", "variant not found")}
      {:error, _} = error -> error
    end
  end

  @spec delete_variant_for_admin(map(), Ecto.UUID.t()) :: :ok | {:error, term()}
  def delete_variant_for_admin(actor, variant_id) when is_map(actor) and is_binary(variant_id) do
    with %Variant{} = variant <- Repo.get(Variant, variant_id),
         {:ok, _destroyed} <-
           variant
           |> Ash.Changeset.for_destroy(:destroy, %{})
           |> Ash.destroy(domain: Catalog, actor: actor)
           |> normalize_variant_delete_result() do
      _ = AvailabilityCache.invalidate_product(variant.product_id)
      _ = StockFastPath.invalidate_variant_ids([variant.id])
      :ok
    else
      nil -> {:error, Error.new("NOT_FOUND", "variant not found")}
      {:error, _} = error -> error
    end
  end

  def delete_variant_for_admin(_actor, _variant_id),
    do: {:error, Error.new("VALIDATION_ERROR", "actor and variant_id are required")}

  @spec set_variant_selection_for_admin(map(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, VariantOptionSelection.t()} | {:error, term()}
  def set_variant_selection_for_admin(actor, variant_id, option_id, value_id)
      when is_map(actor) and is_binary(variant_id) and is_binary(option_id) and
             is_binary(value_id) do
    existing =
      VariantOptionSelection
      |> where(
        [selection],
        selection.variant_id == ^variant_id and selection.product_option_id == ^option_id
      )
      |> limit(1)
      |> Repo.one()

    action_result =
      case existing do
        nil ->
          VariantOptionSelection
          |> Ash.Changeset.for_create(:create, %{
            variant_id: variant_id,
            product_option_id: option_id,
            product_option_value_id: value_id
          })
          |> Ash.create(domain: Catalog, actor: actor)

        %VariantOptionSelection{} = selection ->
          selection
          |> Ash.Changeset.for_update(:update, %{product_option_value_id: value_id})
          |> Ash.update(domain: Catalog, actor: actor)
      end

    action_result
    |> normalize_result()
    |> case do
      {:ok, %VariantOptionSelection{} = selection} ->
        _ = AvailabilityCache.invalidate_product(selection.product_id)
        {:ok, selection}

      {:error, _} = error ->
        error
    end
  end

  def set_variant_selection_for_admin(_actor, _variant_id, _option_id, _value_id),
    do:
      {:error,
       Error.new("VALIDATION_ERROR", "actor, variant_id, option_id, and value_id are required")}

  @spec delete_variant_selection_for_admin(map(), Ecto.UUID.t()) :: :ok | {:error, term()}
  def delete_variant_selection_for_admin(actor, selection_id)
      when is_map(actor) and is_binary(selection_id) do
    with %VariantOptionSelection{} = selection <- Repo.get(VariantOptionSelection, selection_id),
         {:ok, _destroyed} <-
           selection
           |> Ash.Changeset.for_destroy(:destroy, %{})
           |> Ash.destroy(domain: Catalog, actor: actor)
           |> normalize_result() do
      _ = AvailabilityCache.invalidate_product(selection.product_id)
      :ok
    else
      nil -> {:error, Error.new("NOT_FOUND", "variant selection not found")}
      {:error, _} = error -> error
    end
  end

  def delete_variant_selection_for_admin(_actor, _selection_id),
    do: {:error, Error.new("VALIDATION_ERROR", "actor and selection_id are required")}

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

  defp attach_default_variants([]), do: []

  defp attach_default_variants(products) do
    variant_ids =
      products
      |> Enum.map(& &1.default_variant_id)
      |> Enum.reject(&is_nil/1)

    variants_by_id =
      Variant
      |> where([variant], variant.id in ^variant_ids and variant.status == :active)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.map(products, fn product ->
      Map.put(product, :default_variant, Map.get(variants_by_id, product.default_variant_id))
    end)
  end

  defp attach_categories([]), do: []

  defp attach_categories(products) do
    category_ids =
      products
      |> Enum.map(& &1.category_id)
      |> Enum.reject(&is_nil/1)

    categories_by_id =
      Category
      |> where([category], category.id in ^category_ids and category.is_active == true)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.map(products, fn product ->
      Map.put(product, :category, Map.get(categories_by_id, product.category_id))
    end)
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

  defp transition_product_for_admin(actor, product_id, transition)
       when transition in [:publish, :unpublish, :archive] do
    case get_product_for_admin(actor, product_id) do
      {:ok, %Product{} = product} ->
        action =
          case transition do
            :publish -> :publish
            :unpublish -> :unpublish
            :archive -> :archive
          end

        product
        |> Ash.Changeset.for_update(action, %{})
        |> Ash.update(domain: Catalog, actor: actor)
        |> normalize_result()
        |> maybe_invalidate_product_cache(product.id)

      {:ok, nil} ->
        {:error, Error.new("NOT_FOUND", "product not found")}

      {:error, _} = error ->
        error
    end
  end

  defp maybe_invalidate_product_cache({:ok, result}, product_id) when is_binary(product_id) do
    _ = AvailabilityCache.invalidate_product(product_id)

    variant_ids =
      Variant
      |> where([variant], variant.product_id == ^product_id)
      |> select([variant], variant.id)
      |> Repo.all()

    _ = StockFastPath.invalidate_variant_ids(variant_ids)

    {:ok, result}
  end

  defp maybe_invalidate_product_cache({:error, _} = error, _product_id), do: error

  defp variant_ids_for_product(product_id) do
    Variant
    |> where([variant], variant.product_id == ^product_id)
    |> select([variant], variant.id)
    |> Repo.all()
  end

  defp normalize_variant_delete_result({:ok, result}), do: {:ok, result}

  defp normalize_variant_delete_result({:error, error}) do
    case find_variant_delete_blocking_constraint(error) do
      nil ->
        {:error, Normalize.normalize(error)}

      _constraint ->
        {:error,
         Error.new(
           "VARIANT_IN_USE",
           "variant is still referenced by existing cart or subscription records"
         )}
    end
  end

  defp find_variant_delete_blocking_constraint(error) do
    error
    |> collect_constraints(MapSet.new())
    |> Enum.find(&MapSet.member?(@variant_delete_blocking_constraints_set, &1))
  end

  defp collect_constraints(%Ecto.ConstraintError{constraint: constraint}, acc)
       when is_binary(constraint) do
    MapSet.put(acc, constraint)
  end

  defp collect_constraints(%Postgrex.Error{postgres: postgres}, acc) when is_map(postgres) do
    case {Map.get(postgres, :code), Map.get(postgres, :constraint)} do
      {code, constraint}
      when code in [:foreign_key_violation, "23503"] and is_binary(constraint) ->
        MapSet.put(acc, constraint)

      _ ->
        acc
    end
  end

  defp collect_constraints({key, constraint}, acc)
       when key in [:constraint_name, :constraint, "constraint_name", "constraint"] and
              is_binary(constraint) do
    MapSet.put(acc, constraint)
  end

  defp collect_constraints(value, acc) when is_binary(value) do
    Enum.reduce(@variant_delete_blocking_constraints, acc, fn constraint, reduced ->
      if String.contains?(value, constraint) do
        MapSet.put(reduced, constraint)
      else
        reduced
      end
    end)
  end

  defp collect_constraints(%{} = value, acc) do
    Enum.reduce(Map.values(value), acc, &collect_constraints/2)
  end

  defp collect_constraints(value, acc) when is_list(value) do
    Enum.reduce(value, acc, &collect_constraints/2)
  end

  defp collect_constraints(value, acc) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.reduce(acc, &collect_constraints/2)
  end

  defp collect_constraints(_value, acc), do: acc

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, error}), do: {:error, Normalize.normalize(error)}
end
