defmodule Store.Orders do
  @moduledoc """
  Orders domain for lifecycle state-machine resources and inventory reservations.
  """

  use Ash.Domain, extensions: [AshJsonApi.Domain]

  import Ash.Expr
  require Ash.Query

  alias Store.Orders.{
    InventoryReservation,
    InventoryReservations,
    Order,
    SnapshotWriter,
    TaxShippingSnapshotWriter
  }

  alias Store.Pricing.Contract
  alias Store.Support.Errors.Error
  alias Store.Support.Governance.Idempotency
  alias Store.Support.ID.OrderRef
  alias Store.Support.ID.UUIDv7

  @max_order_ref_attempts 5

  resources do
    resource(Store.Orders.Order)
    resource(Store.Orders.OrderLineItem)
    resource(Store.Orders.OrderAdjustment)
    resource(Store.Orders.RefundAdjustment)
    resource(Store.Orders.InventoryReservation)
    resource(Store.Orders.PaymentApplication)
  end

  json_api do
    prefix("/api/v1")
    show_raised_errors?(false)

    routes do
      base_route("/orders", Order) do
        index(:read_for_user, derive_filter?: false, derive_sort?: false)
        get(:get_for_user, derive_filter?: false, derive_sort?: false)
      end

      base_route("/admin/orders", Order) do
        index(:read_for_admin, derive_filter?: false, derive_sort?: false)
        get(:get_for_admin, derive_filter?: false, derive_sort?: false)
      end
    end
  end

  @type begin_checkout_attrs :: %{
          required(:line_items) => [map()],
          required(:currency) => String.t(),
          required(:as_of) => DateTime.t() | String.t(),
          optional(:user_id) => String.t(),
          optional(:pricing_contract_version) => String.t(),
          optional(:tax_shipping_inputs) => map()
        }

  @spec create_order(map(), keyword()) :: {:ok, Order.t()} | {:error, term()}
  def create_order(attrs \\ %{}, opts \\ []) when is_map(attrs) and is_list(opts) do
    generator = Keyword.get(opts, :order_ref_generator, &OrderRef.generate/0)
    max_attempts = Keyword.get(opts, :max_attempts, @max_order_ref_attempts)
    ash_opts = Keyword.drop(opts, [:order_ref_generator, :max_attempts])

    do_create_order(attrs, generator, ash_opts, max_attempts)
  end

  @spec begin_checkout(begin_checkout_attrs(), keyword()) ::
          {:ok,
           %{
             order: Order.t(),
             checkout_key: String.t(),
             cart_fingerprint: String.t(),
             duplicate?: boolean(),
             notifications: [Ash.Notifier.Notification.t()]
           }}
          | {:error, Error.t() | term()}
  def begin_checkout(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    return_notifications? = Keyword.get(opts, :return_notifications?, false)
    ash_opts = Keyword.drop(opts, [:pricing_contract_version, :return_notifications?])

    with {:ok, request} <- normalize_begin_checkout_request(attrs, opts),
         cart_fingerprint <-
           Idempotency.cart_fingerprint(
             request.line_items,
             request.currency,
             request.as_of,
             request.pricing_contract_version,
             request.tax_shipping_inputs
           ),
         checkout_key <- Idempotency.checkout_key(request.user_id, cart_fingerprint),
         {:ok, order, duplicate?, notifications} <-
           create_or_reuse_checkout_order(request, checkout_key, ash_opts, return_notifications?) do
      {:ok,
       %{
         order: order,
         checkout_key: checkout_key,
         cart_fingerprint: cart_fingerprint,
         duplicate?: duplicate?,
         notifications: notifications
       }}
    end
  rescue
    error in ArgumentError ->
      {:error, Error.new("VALIDATION_ERROR", Exception.message(error))}
  end

  @spec write_priced_snapshot(String.t(), Contract.Output.t() | map(), keyword()) ::
          {:ok,
           %{
             line_items: [Store.Orders.OrderLineItem.t()],
             adjustments: [Store.Orders.OrderAdjustment.t()]
           }}
          | {:error, term()}
  def write_priced_snapshot(order_id, output, opts \\ [])
      when is_binary(order_id) and is_list(opts) do
    SnapshotWriter.write_priced_snapshot(order_id, output, opts)
  end

  @spec write_tax_shipping_snapshot(
          String.t(),
          Store.Pricing.TaxShippingContract.Output.t() | map(),
          keyword()
        ) ::
          {:ok, %{order: Store.Orders.Order.t(), idempotent?: boolean()}} | {:error, term()}
  def write_tax_shipping_snapshot(order_id, output, opts \\ [])
      when is_binary(order_id) and is_list(opts) do
    TaxShippingSnapshotWriter.write_tax_shipping_snapshot(order_id, output, opts)
  end

  @spec reserve_inventory(String.t(), [map()], keyword()) ::
          {:ok,
           %{
             reservations: [InventoryReservation.t()],
             inventory_items: [Store.Catalog.InventoryItem.t()]
           }}
          | {:error, term()}
  def reserve_inventory(order_id, items, opts \\ [])
      when is_binary(order_id) and is_list(items) and is_list(opts) do
    InventoryReservations.reserve_inventory(order_id, items, opts)
  end

  @spec reserve_inventory_for_checkout(String.t(), [map()], keyword()) ::
          {:ok, %{reserved_rows: [map()]}} | {:error, term()}
  def reserve_inventory_for_checkout(order_id, items, opts \\ [])
      when is_binary(order_id) and is_list(items) and is_list(opts) do
    InventoryReservations.reserve_inventory_for_checkout(order_id, items, opts)
  end

  @spec consume_reservations_for_order(String.t(), keyword()) ::
          {:ok, %{consumed_count: non_neg_integer(), reservations: [InventoryReservation.t()]}}
          | {:error, term()}
  def consume_reservations_for_order(order_id, opts \\ [])
      when is_binary(order_id) and is_list(opts) do
    InventoryReservations.consume_reservations_for_order(order_id, opts)
  end

  @spec release_reservations_for_order(String.t(), keyword()) ::
          {:ok, %{released_count: non_neg_integer(), reservations: [InventoryReservation.t()]}}
          | {:error, term()}
  def release_reservations_for_order(order_id, opts \\ [])
      when is_binary(order_id) and is_list(opts) do
    InventoryReservations.release_reservations_for_order(order_id, opts)
  end

  @spec expire_reservations(DateTime.t(), keyword()) ::
          {:ok, %{expired_count: non_neg_integer(), reservations: [InventoryReservation.t()]}}
          | {:error, term()}
  def expire_reservations(now \\ DateTime.utc_now(), opts \\ [])
      when is_struct(now, DateTime) and is_list(opts) do
    InventoryReservations.expire_reservations(now, opts)
  end

  defp do_create_order(_attrs, _generator, _ash_opts, attempts) when attempts <= 0 do
    {:error, "unable to generate unique order_ref after retry limit"}
  end

  defp do_create_order(attrs, generator, ash_opts, attempts) do
    attrs_with_order_ref =
      if explicit_order_ref?(attrs) do
        attrs
      else
        Map.put(attrs, :order_ref, generator.())
      end

    result =
      Order
      |> Ash.Changeset.for_create(:create, attrs_with_order_ref)
      |> Ash.create(Keyword.merge([domain: __MODULE__, authorize?: false], ash_opts))

    cond do
      retryable_order_ref_conflict?(result, attrs) and attempts > 1 ->
        do_create_order(attrs, generator, ash_opts, attempts - 1)

      retryable_order_ref_conflict?(result, attrs) ->
        {:error, "unable to generate unique order_ref after retry limit"}

      true ->
        result
    end
  end

  defp retryable_order_ref_conflict?({:error, error}, attrs) do
    not explicit_order_ref?(attrs) and order_ref_conflict?(error)
  end

  defp retryable_order_ref_conflict?(_, _attrs), do: false

  defp explicit_order_ref?(attrs),
    do: Map.has_key?(attrs, :order_ref) or Map.has_key?(attrs, "order_ref")

  defp normalize_begin_checkout_request(attrs, opts) do
    request = %{
      user_id: attr(attrs, :user_id),
      line_items: attr(attrs, :line_items, []),
      currency: attr(attrs, :currency),
      as_of: attr(attrs, :as_of),
      pricing_contract_version:
        attr(attrs, :pricing_contract_version, Keyword.get(opts, :pricing_contract_version, "v1")),
      tax_shipping_inputs: attr(attrs, :tax_shipping_inputs, %{})
    }

    with :ok <- validate_user_id(request.user_id),
         :ok <- validate_line_items(request.line_items),
         :ok <- require_binary(request.currency, "currency is required"),
         :ok <- validate_as_of(request.as_of),
         :ok <-
           require_binary(
             request.pricing_contract_version,
             "pricing_contract_version must be a string"
           ),
         :ok <- require_map(request.tax_shipping_inputs, "tax_shipping_inputs must be a map") do
      {:ok, request}
    end
  end

  defp create_or_reuse_checkout_order(request, checkout_key, ash_opts, return_notifications?) do
    with {:ok, existing_order} <- find_order_by_checkout_key(checkout_key, ash_opts) do
      case existing_order do
        %Order{state: :pending_payment} = order ->
          {:ok, order, true, []}

        %Order{} ->
          {:error,
           Error.new(
             "CHECKOUT_DUPLICATE",
             "checkout key already used for a non-pending order"
           )}

        nil ->
          create_checkout_order(request.user_id, checkout_key, ash_opts, return_notifications?)
      end
    end
  end

  defp create_checkout_order(user_id, checkout_key, ash_opts, return_notifications?) do
    create_attrs = %{user_id: user_id, checkout_key: checkout_key}

    create_ash_opts =
      if return_notifications? do
        Keyword.put(ash_opts, :return_notifications?, true)
      else
        ash_opts
      end

    Order
    |> Ash.Changeset.for_create(:begin_checkout, create_attrs, context: %{system?: true})
    |> Ash.create(checkout_ash_opts(create_ash_opts))
    |> case do
      {:ok, %Order{state: :pending_payment} = order} ->
        {:ok, order, false, []}

      {:ok, %Order{state: :pending_payment} = order, notifications} when is_list(notifications) ->
        {:ok, order, false, notifications}

      {:ok, %Order{}} ->
        {:error,
         Error.new("CHECKOUT_DUPLICATE", "checkout key did not resolve to pending_payment state")}

      {:ok, %Order{}, _notifications} ->
        {:error,
         Error.new("CHECKOUT_DUPLICATE", "checkout key did not resolve to pending_payment state")}

      {:error, error} ->
        {:error, error}
    end
  end

  defp find_order_by_checkout_key(checkout_key, ash_opts) do
    query = Order |> Ash.Query.filter(expr(checkout_key == ^checkout_key))

    case Ash.read(query, checkout_ash_opts(ash_opts)) do
      {:ok, [order | _]} -> {:ok, order}
      {:ok, []} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end

  defp checkout_ash_opts(ash_opts) do
    context =
      ash_opts
      |> Keyword.get(:context, %{})
      |> Map.put_new(:system?, true)

    ash_opts
    |> Keyword.put(:domain, __MODULE__)
    |> Keyword.put(:authorize?, false)
    |> Keyword.put(:context, context)
  end

  defp validate_user_id(nil), do: :ok

  defp validate_user_id(user_id) when is_binary(user_id) do
    if UUIDv7.valid?(user_id) do
      :ok
    else
      {:error, Error.new("VALIDATION_ERROR", "user_id must be a valid UUID")}
    end
  end

  defp validate_user_id(_user_id),
    do: {:error, Error.new("VALIDATION_ERROR", "user_id must be a UUID string")}

  defp validate_line_items(line_items) when is_list(line_items) do
    if line_items == [] do
      {:error, Error.new("VALIDATION_ERROR", "line_items must not be empty")}
    else
      validate_line_items_list(line_items)
    end
  end

  defp validate_line_items(_line_items),
    do: {:error, Error.new("VALIDATION_ERROR", "line_items must be a list")}

  defp validate_line_items_list(line_items) do
    Enum.reduce_while(line_items, :ok, &validate_line_item_step/2)
  end

  defp validate_line_item_step(line_item, :ok) do
    case validate_line_item_fields(line_item) do
      :ok -> {:cont, :ok}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp validate_line_item_fields(line_item) do
    case validate_line_item_id(line_item) do
      :ok -> validate_line_item_quantity(line_item)
      {:error, _} = error -> error
    end
  end

  defp validate_line_item_id(line_item) when is_map(line_item) do
    id =
      Map.get(line_item, :variant_id) ||
        Map.get(line_item, "variant_id") ||
        Map.get(line_item, :sku_id) ||
        Map.get(line_item, "sku_id")

    if is_binary(id) and UUIDv7.valid?(id) do
      :ok
    else
      {:error,
       Error.new("VALIDATION_ERROR", "each line item requires valid UUID variant_id or sku_id")}
    end
  end

  defp validate_line_item_id(_line_item) do
    {:error, Error.new("VALIDATION_ERROR", "each line item must be a map")}
  end

  defp validate_line_item_quantity(line_item) when is_map(line_item) do
    quantity = Map.get(line_item, :quantity) || Map.get(line_item, "quantity")

    if is_integer(quantity) and quantity > 0 do
      :ok
    else
      {:error, Error.new("VALIDATION_ERROR", "line item quantity must be a positive integer")}
    end
  end

  defp validate_line_item_quantity(_line_item) do
    {:error, Error.new("VALIDATION_ERROR", "line item quantity must be a positive integer")}
  end

  defp validate_as_of(%DateTime{}), do: :ok
  defp validate_as_of(as_of) when is_binary(as_of), do: :ok
  defp validate_as_of(_as_of), do: {:error, Error.new("VALIDATION_ERROR", "as_of is required")}

  defp require_binary(value, _message) when is_binary(value), do: :ok
  defp require_binary(_value, message), do: {:error, Error.new("VALIDATION_ERROR", message)}

  defp require_map(value, _message) when is_map(value), do: :ok
  defp require_map(_value, message), do: {:error, Error.new("VALIDATION_ERROR", message)}

  defp attr(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp order_ref_conflict?(error) do
    message = Exception.message(error)
    String.contains?(message, "order_ref") and String.contains?(message, "already been taken")
  end
end
