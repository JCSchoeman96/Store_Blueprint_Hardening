defmodule StoreWeb.Telemetry do
  @moduledoc false

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("store.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("store.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("store.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("store.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("store.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),
      summary("store.carts.step.duration",
        tags: [:step, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.carts.step.query_count",
        tags: [:step, :result]
      ),
      summary("store.carts.step.queue_time",
        tags: [:step, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.carts.step.query_time",
        tags: [:step, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.carts.step.decode_time",
        tags: [:step, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.checkout.step.duration",
        tags: [:step, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.checkout.step.query_count",
        tags: [:step, :result]
      ),
      summary("store.checkout.step.queue_time",
        tags: [:step, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.checkout.step.query_time",
        tags: [:step, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.checkout.step.decode_time",
        tags: [:step, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.checkout.trace.duration",
        tags: [:step, :substep, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.checkout.provider_setup.duration",
        tags: [:phase, :provider, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.checkout.provider_setup_task.duration",
        tags: [:provider, :result, :completion_source],
        unit: {:native, :millisecond}
      ),
      counter("store.checkout.provider_setup_task.count",
        tags: [:provider, :result, :completion_source]
      ),
      counter("store.checkout.pending_provider_setup.resume.count",
        tags: [:provider]
      ),
      counter("store.checkout.pending_provider_setup.state.count",
        tags: [:classification, :phase, :provider, :source]
      ),
      counter("store.checkout.pending_provider_setup.recovery.count",
        tags: [:provider, :result, :source]
      ),
      last_value("store.checkout.pending_provider_setup.backlog.count",
        tags: [:source]
      ),
      last_value("store.checkout.pending_provider_setup.backlog.oldest_age_seconds",
        tags: [:source]
      ),
      last_value("store.checkout.pending_provider_setup.backlog.reserved_variant_count",
        tags: [:source]
      ),
      last_value("store.checkout.pending_provider_setup.backlog.without_provider_refs_count",
        tags: [:source]
      ),
      last_value("store.checkout.pending_provider_setup.backlog.recoverable_created_intent_count",
        tags: [:source]
      ),
      summary("store.checkout.pending_provider_setup.sweep.duration",
        tags: [:result],
        unit: {:native, :millisecond}
      ),
      summary("store.checkout.pending_provider_setup.sweep.recovered_count",
        tags: [:result]
      ),
      summary("store.checkout.pending_provider_setup.sweep.swept_count",
        tags: [:result]
      ),
      summary("store.checkout.pending_provider_setup.sweep.released_count",
        tags: [:result]
      ),
      counter("store.waiting_room.http.count",
        tags: [:decision, :scope, :mode]
      ),
      counter("store.waiting_room.socket.count",
        tags: [:decision, :scope, :mode]
      ),
      summary("store.ops.redis_aggregate_flush.duration",
        tags: [:result],
        unit: {:native, :millisecond}
      ),
      summary("store.ops.redis_aggregate_flush.bucket_count",
        tags: [:result]
      ),
      summary("store.ops.redis_aggregate_flush.row_count",
        tags: [:result]
      ),
      summary("store.catalog.product_detail.public.duration",
        tags: [:result],
        unit: {:native, :millisecond}
      ),
      summary("store.catalog.product_detail.public.query_count",
        tags: [:result]
      ),
      summary("store.catalog.product_detail.public.queue_time",
        tags: [:result],
        unit: {:native, :millisecond}
      ),
      summary("store.catalog.product_detail.public.query_time",
        tags: [:result],
        unit: {:native, :millisecond}
      ),
      summary("store.catalog.product_detail.public.decode_time",
        tags: [:result],
        unit: {:native, :millisecond}
      ),
      summary("store.catalog.product_detail.public.encoded_payload_bytes",
        tags: [:result],
        unit: {:byte, :kilobyte}
      ),
      summary("store.catalog.product_detail.public.option_count",
        tags: [:result]
      ),
      summary("store.catalog.product_detail.public.option_value_count",
        tags: [:result]
      ),
      summary("store.catalog.product_detail.public.variant_row_count",
        tags: [:result]
      ),
      summary("store.catalog.product_detail.public.availability_cell_count",
        tags: [:result]
      ),
      summary("store.catalog.product_detail.public.availability_value_count",
        tags: [:result]
      ),
      summary("store.catalog.product_list.duration",
        tags: [:cache, :layer, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.catalog.product_list.result_count",
        tags: [:cache, :layer, :result]
      ),
      summary("store.catalog.product_detail.duration",
        tags: [:cache, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.shop_live.product_detail.duration",
        tags: [:phase, :connected, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.shop_live.product_detail.reductions_delta",
        tags: [:phase, :connected, :result]
      ),
      summary("store.shop_live.product_detail.memory_delta",
        tags: [:phase, :connected, :result],
        unit: {:byte, :kilobyte}
      ),
      summary("store.shop_live.index.mount.duration",
        tags: [:phase, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.shop_live.index.mount.query_count",
        tags: [:phase, :result]
      ),
      summary("store.shop_live.index.mount.queue_time",
        tags: [:phase, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.shop_live.index.mount.jitter_delay_ms",
        tags: [:phase, :result],
        unit: {:millisecond, :millisecond}
      ),
      summary("store.shop_live.show.mount.duration",
        tags: [:phase, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.shop_live.show.mount.query_count",
        tags: [:phase, :result]
      ),
      summary("store.shop_live.show.mount.queue_time",
        tags: [:phase, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.shop_live.show.mount.jitter_delay_ms",
        tags: [:phase, :result],
        unit: {:millisecond, :millisecond}
      ),
      summary("store.cart_live.mount.duration",
        tags: [:phase, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.cart_live.mount.query_count",
        tags: [:phase, :result]
      ),
      summary("store.cart_live.mount.queue_time",
        tags: [:phase, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.cart_live.mount.jitter_delay_ms",
        tags: [:phase, :result],
        unit: {:millisecond, :millisecond}
      ),
      summary("store.checkout_live.mount.duration",
        tags: [:phase, :result, :live_action],
        unit: {:native, :millisecond}
      ),
      summary("store.checkout_live.mount.query_count",
        tags: [:phase, :result, :live_action]
      ),
      summary("store.checkout_live.mount.queue_time",
        tags: [:phase, :result, :live_action],
        unit: {:native, :millisecond}
      ),
      summary("store.checkout_live.mount.jitter_delay_ms",
        tags: [:phase, :result, :live_action],
        unit: {:millisecond, :millisecond}
      ),
      summary("store.payments.ingress.verify.duration",
        tags: [:route, :provider, :result, :error_code],
        unit: {:native, :millisecond}
      ),
      summary("store.payments.ingress.persist.duration",
        tags: [:route, :provider, :result, :error_code],
        unit: {:native, :millisecond}
      ),
      summary("store.payments.ingress.persist.query_count",
        tags: [:route, :provider, :result, :error_code]
      ),
      summary("store.payments.ingress.persist.queue_time",
        tags: [:route, :provider, :result, :error_code],
        unit: {:native, :millisecond}
      ),
      summary("store.payments.ingress.persist.query_time",
        tags: [:route, :provider, :result, :error_code],
        unit: {:native, :millisecond}
      ),
      summary("store.payments.ingress.persist.decode_time",
        tags: [:route, :provider, :result, :error_code],
        unit: {:native, :millisecond}
      ),
      summary("store.payments.ingress.enqueue.duration",
        tags: [:route, :provider, :result, :error_code],
        unit: {:native, :millisecond}
      ),
      summary("store.payments.ingress.enqueue.query_count",
        tags: [:route, :provider, :result, :error_code]
      ),
      summary("store.payments.ingress.enqueue.queue_time",
        tags: [:route, :provider, :result, :error_code],
        unit: {:native, :millisecond}
      ),
      summary("store.payments.ingress.enqueue.query_time",
        tags: [:route, :provider, :result, :error_code],
        unit: {:native, :millisecond}
      ),
      summary("store.payments.ingress.enqueue.decode_time",
        tags: [:route, :provider, :result, :error_code],
        unit: {:native, :millisecond}
      ),
      summary("store.payments.ingress.response.duration",
        tags: [:route, :provider, :result, :status_bucket, :error_code],
        unit: {:native, :millisecond}
      ),
      summary("store.shipping.quote.duration",
        tags: [:cache, :layer, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.shipping.quote.result_count",
        tags: [:cache, :layer, :result]
      ),
      summary("store.payments.webhook_received.duration",
        tags: [:route, :provider, :event_type, :verified],
        unit: {:native, :millisecond}
      ),
      summary("store.payments.webhook_enqueued.duration",
        tags: [:route, :provider, :event_type, :result],
        unit: {:native, :millisecond}
      ),
      summary("store.payments.webhook_processed.duration",
        tags: [:provider, :outcome],
        unit: {:native, :millisecond}
      ),
      summary("store.payments.refund_webhook_processed.duration",
        tags: [:provider, :outcome],
        unit: {:native, :millisecond}
      ),
      summary("store.payments.interlock_apply_payment_success_once.duration",
        tags: [:replay, :outcome],
        unit: {:native, :millisecond}
      ),
      counter("store.comms.outbox_insert.count",
        tags: [:kind, :provider]
      ),
      last_value("store.ops.queues.webhook_backlog_age_seconds"),
      last_value("store.ops.queues.webhook_failed_count"),
      last_value("store.ops.queues.outbox_backlog_age_seconds"),
      last_value("store.ops.queues.outbox_pending_count"),
      last_value("store.ops.queues.outbox_failed_count"),
      last_value("store.ops.queues.renewal_backlog_age_seconds"),
      counter("store.digital.grant_issued.count"),
      summary("store.digital.signed_url.duration",
        tags: [:outcome],
        unit: {:native, :millisecond}
      ),
      summary("store.subscriptions.tick.duration",
        unit: {:native, :millisecond}
      ),
      summary("store.subscriptions.tick.due_count"),
      summary("store.subscriptions.tick.success_count"),
      summary("store.subscriptions.tick.failed_count"),
      summary("store.subscriptions.renewal_attempt.duration",
        tags: [:outcome],
        unit: {:native, :millisecond}
      ),
      counter("store.subscriptions.dunning.count",
        tags: [:status]
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    if Application.get_env(:store, :enable_ops_telemetry_poller, true) do
      [{Store.Operations.TelemetryPoller, :emit_queue_metrics, []}]
    else
      []
    end
  end
end
