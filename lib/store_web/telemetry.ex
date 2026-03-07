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

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {StoreWeb, :count_users, []}
    ]
  end
end
