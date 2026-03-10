defmodule Store.Catalog.AvailabilityCache do
  @moduledoc """
  Product-scoped availability matrix cache.

  This cache is domain-driven and invalidated from catalog/inventory mutation paths.
  """

  @table :store_catalog_availability_cache
  @default_ttl_seconds 300

  @spec fetch(Ecto.UUID.t(), (-> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, term()} | {:error, term()}
  def fetch(product_id, builder_fun, opts \\ [])

  def fetch(product_id, builder_fun, opts)
      when is_binary(product_id) and is_function(builder_fun, 0) and is_list(opts) do
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

    case get(product_id) do
      {:ok, payload} ->
        {:ok, payload}

      :miss ->
        with {:ok, payload} <- builder_fun.() do
          _ = put(product_id, payload, ttl_seconds)
          {:ok, payload}
        end
    end
  end

  def fetch(_product_id, _builder_fun, _opts), do: {:error, :invalid_args}

  @spec get(Ecto.UUID.t()) :: {:ok, term()} | :miss
  def get(product_id) when is_binary(product_id) do
    table = ensure_table()
    now = System.system_time(:second)

    case :ets.lookup(table, product_id) do
      [{^product_id, expires_at, payload}] when expires_at > now ->
        {:ok, payload}

      [{^product_id, _expires_at, _payload}] ->
        :ets.delete(table, product_id)
        :miss

      _ ->
        :miss
    end
  end

  def get(_product_id), do: :miss

  @spec put(Ecto.UUID.t(), term(), pos_integer()) :: :ok
  def put(product_id, payload, ttl_seconds \\ @default_ttl_seconds)
      when is_binary(product_id) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    table = ensure_table()
    expires_at = System.system_time(:second) + ttl_seconds

    :ets.insert(table, {product_id, expires_at, payload})
    maybe_cleanup(table)
    :ok
  end

  @spec invalidate_product(Ecto.UUID.t()) :: :ok
  def invalidate_product(product_id) when is_binary(product_id) do
    table = ensure_table()
    :ets.delete(table, product_id)
    :ok
  end

  def invalidate_product(_product_id), do: :ok

  @spec invalidate_products([Ecto.UUID.t()]) :: :ok
  def invalidate_products(product_ids) when is_list(product_ids) do
    table = ensure_table()

    product_ids
    |> Enum.uniq()
    |> Enum.each(fn product_id ->
      if is_binary(product_id), do: :ets.delete(table, product_id)
    end)

    :ok
  end

  def invalidate_products(_product_ids), do: :ok

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> @table
        end

      table ->
        table
    end
  end

  defp maybe_cleanup(table) do
    now = System.system_time(:second)

    if rem(now, 60) == 0 do
      :ets.select_delete(
        table,
        [
          {{:"$1", :"$2", :"$3"}, [{:<, :"$2", now}], [true]}
        ]
      )
    end

    :ok
  end
end
