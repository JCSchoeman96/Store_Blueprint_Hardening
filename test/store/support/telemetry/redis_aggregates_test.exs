defmodule Store.Support.Telemetry.RedisAggregatesTest do
  use Store.DataCase, async: false

  alias Store.Support.Redis
  alias Store.Support.Telemetry.RedisAggregates

  setup do
    assert :ok = Redis.flush_db()
    :ok
  end

  test "redis aggregate sink records counters, uniques, and queue helpers" do
    bucket_id = RedisAggregates.current_bucket_id()

    :telemetry.execute(
      [:store, :payments, :webhook_received],
      %{duration: System.convert_time_unit(25, :millisecond, :native)},
      %{
        route: :webhook,
        provider: "stripe",
        event_type: "payment_intent.succeeded",
        verified: true,
        provider_event_id: "evt_phase29_1",
        receipt_id: Ecto.UUID.generate(),
        duplicate: false
      }
    )

    :telemetry.execute(
      [:store, :payments, :webhook_processed],
      %{duration: System.convert_time_unit(10, :millisecond, :native)},
      %{
        provider: "stripe",
        outcome: :ok,
        receipt_id: "receipt_phase29_1",
        provider_event_id: "evt_phase29_processed_1"
      }
    )

    :telemetry.execute(
      [:store, :comms, :outbox_insert],
      %{count: 1},
      %{kind: :order_receipt, provider: :sendgrid, outbox_id: "outbox_phase29_1"}
    )

    :telemetry.execute(
      [:store, :comms, :delivery_attempt],
      %{duration: System.convert_time_unit(5, :millisecond, :native)},
      %{
        provider: :sendgrid,
        template: :order_receipt,
        outcome: :sent,
        outbox_id: "outbox_phase29_1"
      }
    )

    :telemetry.execute(
      [:store, :catalog, :product_list],
      %{duration: System.convert_time_unit(8, :millisecond, :native), result_count: 2},
      %{cache: :hit, layer: :hot, result: :ok, cache_key: "catalog_query_1"}
    )

    :telemetry.execute(
      [:store, :shipping, :quote],
      %{duration: System.convert_time_unit(12, :millisecond, :native), result_count: 1},
      %{cache: :miss, layer: :cold, result: :ok, request_key: "shipping_request_1"}
    )

    assert_eventually(fn ->
      assert {:ok, webhook_counters} =
               Redis.hash_get_all(
                 "metrics:counter_buckets:#{bucket_id}:store.payments.webhook_received"
               )

      assert webhook_counters != %{}

      assert {:ok, catalog_uniques} =
               Redis.pfcount("metrics:unique_buckets:#{bucket_id}:catalog_product_list")

      assert catalog_uniques == 1

      assert {:ok, shipping_uniques} =
               Redis.pfcount("metrics:unique_buckets:#{bucket_id}:shipping_quote")

      assert shipping_uniques == 1

      assert {:ok, webhook_uniques} =
               Redis.pfcount("metrics:unique_buckets:#{bucket_id}:webhook_events")

      assert webhook_uniques == 1

      assert {:ok, pending_webhooks} = Redis.zmembers("queues:webhook:pending")
      assert pending_webhooks != []

      assert {:ok, pending_outbox_before_cleanup} = Redis.zmembers("queues:outbox:pending")
      assert pending_outbox_before_cleanup == []
    end)
  end

  test "processed webhook and sent outbox remove pending queue members" do
    receipt_id = "receipt_phase29_cleanup"
    outbox_id = "outbox_phase29_cleanup"

    :telemetry.execute(
      [:store, :payments, :webhook_received],
      %{duration: System.convert_time_unit(10, :millisecond, :native)},
      %{
        route: :webhook,
        provider: "stripe",
        event_type: "payment_intent.succeeded",
        verified: true,
        provider_event_id: "evt_phase29_cleanup",
        receipt_id: receipt_id,
        duplicate: false
      }
    )

    :telemetry.execute(
      [:store, :comms, :outbox_insert],
      %{count: 1},
      %{kind: :order_receipt, provider: :sendgrid, outbox_id: outbox_id}
    )

    assert_eventually(fn ->
      assert {:ok, pending_webhooks} = Redis.zmembers("queues:webhook:pending")
      assert receipt_id in pending_webhooks

      assert {:ok, pending_outbox} = Redis.zmembers("queues:outbox:pending")
      assert outbox_id in pending_outbox
    end)

    :telemetry.execute(
      [:store, :payments, :refund_webhook_processed],
      %{duration: System.convert_time_unit(4, :millisecond, :native)},
      %{
        provider: "stripe",
        outcome: :ok,
        receipt_id: receipt_id,
        provider_event_id: "evt_phase29_cleanup"
      }
    )

    :telemetry.execute(
      [:store, :comms, :delivery_attempt],
      %{duration: System.convert_time_unit(4, :millisecond, :native)},
      %{provider: :sendgrid, template: :order_receipt, outcome: :sent, outbox_id: outbox_id}
    )

    assert_eventually(fn ->
      assert {:ok, pending_webhooks} = Redis.zmembers("queues:webhook:pending")
      refute receipt_id in pending_webhooks

      assert {:ok, pending_outbox} = Redis.zmembers("queues:outbox:pending")
      refute outbox_id in pending_outbox
    end)
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    error in [ExUnit.AssertionError] ->
      if attempts == 1 do
        reraise error, __STACKTRACE__
      else
        Process.sleep(50)
        assert_eventually(fun, attempts - 1)
      end
  end
end
