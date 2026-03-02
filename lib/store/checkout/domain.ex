defmodule Store.Checkout do
  @moduledoc """
  Checkout draft orchestration domain for Phase 20 handoff.
  """

  use Ash.Domain

  import Ecto.Query

  alias Ecto.Changeset
  alias Store.Carts.Cart
  alias Store.Carts.CartItem
  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Catalog.{Product, Variant}
  alias Store.Checkout.CheckoutDraft
  alias Store.Checkout.Inputs.CheckoutStartInput
  alias Store.Repo
  alias Store.Support.Errors.{Error, Normalize}
  alias Store.Support.ID.UUIDv7

  resources do
    resource(Store.Checkout.CheckoutDraft)
  end

  @spec start_from_cart(map() | nil, String.t(), CheckoutStartInput.t()) ::
          {:ok,
           %{
             checkout_key: String.t(),
             draft_id: Ecto.UUID.t(),
             cart_id: Ecto.UUID.t(),
             cart_version: pos_integer(),
             duplicate?: boolean()
           }}
          | {:error, Error.t()}
  def start_from_cart(actor, token, %CheckoutStartInput{} = _input) when is_binary(token) do
    started_at = System.monotonic_time()

    result =
      with {:ok, cart} <- CartsFacade.get_cart_for_user(actor, token),
           {:ok, draft, duplicate?} <- get_or_create_draft(cart) do
        {:ok,
         %{
           checkout_key: draft.checkout_key,
           draft_id: draft.id,
           cart_id: draft.cart_id,
           cart_version: draft.cart_version,
           duplicate?: duplicate?
         }}
      end

    :telemetry.execute(
      [:store, :checkout, :start_from_cart],
      %{duration: System.monotonic_time() - started_at},
      %{result: telemetry_result(result)}
    )

    normalize_result(result)
  end

  def start_from_cart(_actor, _token, _input) do
    {:error, Error.new("VALIDATION_ERROR", "token must be a string")}
  end

  @spec get_draft_for_user(map() | nil, String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_draft_for_user(actor, checkout_key) when is_binary(checkout_key) do
    with {:ok, draft} <- read_draft_by_checkout_key(checkout_key),
         :ok <- authorize_draft_access(actor, draft) do
      build_draft_summary(draft)
    end
    |> normalize_result()
  end

  def get_draft_for_user(_actor, _checkout_key) do
    {:error, Error.new("VALIDATION_ERROR", "checkout_key must be a string")}
  end

  defp get_or_create_draft(%Cart{} = cart) do
    cart_id = cart.id

    Repo.transaction(fn ->
      locked_cart = lock_active_cart!(cart_id)
      locked_items = lock_cart_items(locked_cart.id)

      :ok = ensure_cart_not_empty!(locked_items)
      :ok = ensure_published_sellables!(locked_items)

      case Repo.get_by(CheckoutDraft, cart_id: locked_cart.id, cart_version: locked_cart.version) do
        %CheckoutDraft{} = draft ->
          {draft, true}

        nil ->
          create_or_reuse_checkout_draft!(locked_cart)
      end
    end)
    |> case do
      {:ok, {draft, duplicate?}} -> {:ok, draft, duplicate?}
      {:error, %Error{} = error} -> {:error, error}
      {:error, other} -> {:error, normalize_db_error(other)}
    end
  end

  defp create_or_reuse_checkout_draft!(%Cart{} = cart) do
    attrs = %{
      checkout_key: UUIDv7.generate(),
      cart_id: cart.id,
      cart_version: cart.version,
      user_id: cart.user_id,
      status: :open
    }

    %CheckoutDraft{}
    |> Changeset.change(attrs)
    |> Repo.insert()
    |> case do
      {:ok, draft} ->
        {maybe_reload_checkout_draft(draft, cart), false}

      {:error, %Ecto.Changeset{} = changeset} ->
        handle_checkout_draft_insert_error!(changeset, cart)
    end
  end

  defp handle_checkout_draft_insert_error!(%Ecto.Changeset{} = changeset, %Cart{} = cart) do
    if unique_cart_version_conflict?(changeset) do
      get_existing_checkout_draft!(cart.id, cart.version)
    else
      Repo.rollback(normalize_db_error(changeset))
    end
  end

  defp get_existing_checkout_draft!(cart_id, cart_version) do
    case Repo.get_by(CheckoutDraft, cart_id: cart_id, cart_version: cart_version) do
      %CheckoutDraft{} = draft ->
        {draft, true}

      nil ->
        Repo.rollback(Error.new("STALE_RECORD", "checkout draft conflict retry failed"))
    end
  end

  defp read_draft_by_checkout_key(checkout_key) do
    case Repo.get_by(CheckoutDraft, checkout_key: checkout_key) do
      %CheckoutDraft{} = draft -> {:ok, draft}
      nil -> {:error, Error.new("NOT_FOUND", "checkout draft not found")}
    end
  end

  defp maybe_reload_checkout_draft(%CheckoutDraft{id: nil}, %Cart{} = cart) do
    case Repo.get_by(CheckoutDraft, cart_id: cart.id, cart_version: cart.version) do
      %CheckoutDraft{} = draft ->
        draft

      nil ->
        Repo.rollback(Error.new("INTERNAL_ERROR", "unable to load checkout draft after create"))
    end
  end

  defp maybe_reload_checkout_draft(%CheckoutDraft{} = draft, _cart), do: draft

  defp authorize_draft_access(%{cart_token: token}, %CheckoutDraft{user_id: nil, cart_id: cart_id})
       when is_binary(token) do
    case active_cart_id_by_token(token) do
      ^cart_id -> :ok
      _ -> {:error, Error.new("NOT_FOUND", "checkout draft not found")}
    end
  end

  defp authorize_draft_access(%{id: actor_id}, %CheckoutDraft{user_id: user_id})
       when is_binary(actor_id) and is_binary(user_id) do
    if actor_id == user_id do
      :ok
    else
      {:error, Error.new("NOT_FOUND", "checkout draft not found")}
    end
  end

  defp authorize_draft_access(_actor, %CheckoutDraft{user_id: user_id}) when is_binary(user_id),
    do: {:error, Error.new("NOT_FOUND", "checkout draft not found")}

  defp authorize_draft_access(_actor, %CheckoutDraft{user_id: nil}),
    do: {:error, Error.new("NOT_FOUND", "checkout draft not found")}

  defp build_draft_summary(%CheckoutDraft{} = draft) do
    cart = Repo.get!(Cart, draft.cart_id)
    items = list_cart_items(draft.cart_id)
    {variants_by_id, products_by_id} = catalog_maps(items)

    line_items =
      Enum.map(items, fn item ->
        variant = Map.get(variants_by_id, item.variant_id)
        product = variant && Map.get(products_by_id, variant.product_id)

        %{
          variant_id: item.variant_id,
          qty: item.qty,
          sku: variant && variant.sku,
          product_title: product && product.title,
          product_slug: product && product.slug,
          variant_title: variant && variant.title,
          price_minor: variant && variant.price_minor,
          currency_code: variant && variant.currency_code,
          line_total_minor: if(variant, do: variant.price_minor * item.qty, else: 0)
        }
      end)

    subtotal_minor = Enum.reduce(line_items, 0, &(&1.line_total_minor + &2))

    {:ok,
     %{
       draft_id: draft.id,
       checkout_key: draft.checkout_key,
       cart_id: draft.cart_id,
       cart_version: draft.cart_version,
       status: draft.status,
       user_id: draft.user_id,
       cart_status: cart.status,
       item_count: Enum.reduce(line_items, 0, &(&1.qty + &2)),
       subtotal_minor: subtotal_minor,
       items: line_items
     }}
  end

  defp lock_active_cart!(nil), do: Repo.rollback(Error.new("NOT_FOUND", "active cart not found"))

  defp lock_active_cart!(cart_id) do
    case Cart
         |> where([c], c.id == ^cart_id and c.status == :active)
         |> lock("FOR UPDATE")
         |> Repo.one() do
      %Cart{} = cart -> cart
      nil -> Repo.rollback(Error.new("NOT_FOUND", "active cart not found"))
    end
  end

  defp lock_cart_items(cart_id) do
    list_cart_items(cart_id, lock?: true)
  end

  defp ensure_cart_not_empty!([]),
    do: Repo.rollback(Error.new("VALIDATION_ERROR", "cart must not be empty"))

  defp ensure_cart_not_empty!(_items), do: :ok

  defp ensure_published_sellables!(items) when is_list(items) do
    {variants_by_id, products_by_id} = catalog_maps(items)

    Enum.each(items, fn item ->
      variant = Map.get(variants_by_id, item.variant_id)
      product = variant && Map.get(products_by_id, variant.product_id)

      cond do
        is_nil(variant) ->
          Repo.rollback(Error.new("NOT_FOUND", "variant not found for cart item"))

        variant.status != :active ->
          Repo.rollback(Error.new("VALIDATION_ERROR", "cart contains inactive variant"))

        is_nil(product) ->
          Repo.rollback(Error.new("NOT_FOUND", "product not found for cart item"))

        product.status != :published or is_nil(product.published_at) ->
          Repo.rollback(Error.new("VALIDATION_ERROR", "cart contains unpublished product"))

        true ->
          :ok
      end
    end)

    :ok
  end

  defp list_cart_items(cart_id, opts \\ []) do
    base_query =
      CartItem
      |> where([i], i.cart_id == ^cart_id)
      |> order_by([i], asc: i.inserted_at, asc: i.id)

    query =
      if Keyword.get(opts, :lock?, false) do
        lock(base_query, "FOR UPDATE")
      else
        base_query
      end

    Repo.all(query)
  end

  defp active_cart_id_by_token(token) do
    Cart
    |> where([c], c.token == ^token and c.status == :active)
    |> select([c], c.id)
    |> limit(1)
    |> Repo.one()
  end

  defp catalog_maps(items) do
    variant_ids =
      items
      |> Enum.map(& &1.variant_id)
      |> Enum.uniq()

    variants =
      if variant_ids == [] do
        []
      else
        Variant
        |> where([v], v.id in ^variant_ids)
        |> Repo.all()
      end

    products =
      variants
      |> Enum.map(& &1.product_id)
      |> Enum.uniq()
      |> case do
        [] ->
          []

        product_ids ->
          Product
          |> where([p], p.id in ^product_ids)
          |> Repo.all()
      end

    {Map.new(variants, &{&1.id, &1}), Map.new(products, &{&1.id, &1})}
  end

  defp unique_cart_version_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_message, opts}} ->
        to_string(opts[:constraint_name] || "") ==
          "checkout_drafts_unique_cart_id_cart_version_index"

      _ ->
        false
    end)
  end

  defp normalize_result({:ok, _} = result), do: result
  defp normalize_result({:error, error}), do: {:error, Normalize.normalize(error)}

  defp normalize_db_error(%Ecto.Changeset{} = changeset) do
    if unique_cart_version_conflict?(changeset) do
      Error.new("STALE_RECORD", "checkout draft already exists")
    else
      Error.new("VALIDATION_ERROR", "invalid checkout draft data")
    end
  end

  defp normalize_db_error(_), do: Error.new("INTERNAL_ERROR", "checkout operation failed")

  defp telemetry_result({:ok, %{duplicate?: true}}), do: :duplicate
  defp telemetry_result({:ok, _}), do: :ok
  defp telemetry_result({:error, _}), do: :error
end
