defmodule Store.Workers.ExpirePendingProviderSetupOrdersWorkerTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Store.Catalog.InventoryItem
  alias Store.Orders.{InventoryReservation, Order}
  alias Store.Payments.PaymentIntent
  alias Store.Support.ID.UUIDv7
  alias Store.Workers.ExpirePendingProviderSetupOrdersWorker

  test "worker cancels stale pending provider setup orders and releases reservations" do
    variant_id = UUIDv7.generate()
    order = create_order!()
    create_inventory_item!(variant_id, 2)

    assert {:ok, _result} =
             Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 1}])

    stale_started_at =
      DateTime.add(DateTime.utc_now(), -1_800, :second)
      |> DateTime.truncate(:microsecond)

    assert {:ok, pending_order} =
             order
             |> Ash.Changeset.for_update(
               :begin_provider_setup,
               %{provider_setup_started_at: stale_started_at},
               context: %{system?: true}
             )
             |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})

    assert pending_order.state == :pending_provider_setup

    assert :ok = perform_job(ExpirePendingProviderSetupOrdersWorker, %{})

    swept_order = fetch_order!(order.id)
    assert swept_order.state == :cancelled
    assert is_nil(swept_order.provider_setup_started_at)

    reservation = Repo.get_by!(InventoryReservation, order_id: order.id, variant_id: variant_id)
    assert reservation.state == :cancelled

    inventory = Repo.get_by!(InventoryItem, variant_id: variant_id)
    assert inventory.reserved_count == 0
    assert inventory.stock_on_hand == 2
  end

  test "worker leaves fresh pending provider setup orders untouched" do
    order = create_order!()

    assert {:ok, pending_order} =
             order
             |> Ash.Changeset.for_update(
               :begin_provider_setup,
               %{
                 provider_setup_started_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
               },
               context: %{system?: true}
             )
             |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})

    assert pending_order.state == :pending_provider_setup
    assert :ok = perform_job(ExpirePendingProviderSetupOrdersWorker, %{})

    fresh_order = fetch_order!(order.id)
    assert fresh_order.state == :pending_provider_setup
    assert %DateTime{} = fresh_order.provider_setup_started_at
  end

  test "sweep is a no-op for an empty backlog" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, result} =
             ExpirePendingProviderSetupOrdersWorker.sweep(now,
               ttl_seconds: 30,
               batch_size: 50,
               source: :test
             )

    assert result.swept_count == 0
    assert result.released_count == 0
    assert result.order_ids == []
  end

  test "worker recovers fresh locally completable pending provider setup orders before stale sweep" do
    order = create_order!()
    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, pending_order} =
             order
             |> Ash.Changeset.for_update(
               :begin_provider_setup,
               %{provider_setup_started_at: started_at},
               context: %{system?: true}
             )
             |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})

    payment_intent = create_recoverable_payment_intent!(order.id)

    assert pending_order.state == :pending_provider_setup
    assert payment_intent.state == :created

    assert {:ok, result} =
             ExpirePendingProviderSetupOrdersWorker.sweep(started_at,
               ttl_seconds: 3_600,
               batch_size: 50,
               source: :test
             )

    assert result.recovered_count == 1
    assert result.recovered_order_ids == [order.id]
    assert result.swept_count == 0
    assert result.released_count == 0
    assert result.order_ids == []

    recovered_order = fetch_order!(order.id)
    recovered_payment_intent = fetch_payment_intent!(payment_intent.id)

    assert recovered_order.state == :pending_payment
    assert is_nil(recovered_order.provider_setup_started_at)
    assert recovered_payment_intent.state == :submitted
  end

  defp fetch_order!(order_id) do
    assert {:ok, [order]} =
             Order
             |> Ash.Query.filter(expr(id == ^order_id))
             |> Ash.read(domain: Store.Orders, authorize?: false)

    order
  end

  defp fetch_payment_intent!(payment_intent_id) do
    assert {:ok, [payment_intent]} =
             PaymentIntent
             |> Ash.Query.filter(expr(id == ^payment_intent_id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    payment_intent
  end

  defp create_order! do
    Order
    |> Ash.Changeset.for_create(:create, %{})
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp create_inventory_item!(variant_id, stock_on_hand) do
    InventoryItem
    |> Ash.Changeset.for_create(:create, %{
      variant_id: variant_id,
      stock_on_hand: stock_on_hand,
      reserved_count: 0
    })
    |> Ash.create!(domain: Store.Catalog, authorize?: false)
  end

  defp create_recoverable_payment_intent!(order_id) do
    PaymentIntent
    |> Ash.Changeset.for_create(
      :create,
      %{
        order_id: order_id,
        amount_received_minor: 2_500,
        currency: "USD",
        provider: :stripe,
        payment_intent_key: "pi-key-#{System.unique_integer([:positive])}",
        provider_session_id: "cs_test_#{System.unique_integer([:positive])}",
        provider_payment_id: "pi_test_#{System.unique_integer([:positive])}",
        provider_checkout_url: "https://checkout.stripe.test/session/recoverable"
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end
end
