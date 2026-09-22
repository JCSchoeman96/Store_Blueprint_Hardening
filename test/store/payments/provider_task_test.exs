defmodule Store.Payments.ProviderTaskTest do
  use ExUnit.Case, async: false

  require Logger

  alias Store.Payments.ProviderConfig
  alias Store.Payments.ProviderTask
  alias Store.Support.Errors.Error

  setup do
    previous_payments_config = Application.get_env(:store, :payments)

    on_exit(fn ->
      if previous_payments_config do
        Application.put_env(:store, :payments, previous_payments_config)
      else
        Application.delete_env(:store, :payments)
      end
    end)

    :ok
  end

  test "returns provider payload on success and preserves logger metadata inside task" do
    previous = Logger.metadata()
    Logger.metadata(request_id: "provider-task-test")

    try do
      assert {:ok, %{request_id: "provider-task-test"}} =
               ProviderTask.execute(
                 fn ->
                   {:ok, %{request_id: Logger.metadata()[:request_id]}}
                 end,
                 provider: :stripe,
                 order_id: "order-1",
                 checkout_key: "checkout-1",
                 payment_intent_key: "pi-key-1",
                 timeout_ms: 100
               )
    after
      Logger.reset_metadata(previous)
    end
  end

  test "normalizes returned transport errors without crashing caller" do
    assert {:error, %Error{code: "PAYMENT_PROVIDER_DOWN"}} =
             ProviderTask.execute(
               fn -> {:error, RuntimeError.exception("network down")} end,
               provider: :stripe,
               timeout_ms: 100
             )
  end

  test "returns provider down when worker exits under async_nolink" do
    assert {:error, %Error{code: "PAYMENT_PROVIDER_DOWN", meta: %{reason: reason}}} =
             ProviderTask.execute(
               fn -> exit(:boom) end,
               provider: :stripe,
               timeout_ms: 100
             )

    assert reason =~ ":boom"
    assert Process.alive?(self())
  end

  test "treats timeout plus shutdown payload as success" do
    assert {:ok, %{provider_session_id: "late-session"}} =
             ProviderTask.execute(
               fn -> {:ok, %{provider_session_id: "ignored"}} end,
               provider: :stripe,
               timeout_ms: 50,
               spawn_fun: fn _supervisor, _fun -> :task end,
               yield_fun: fn :task, 50 -> nil end,
               shutdown_fun: fn :task, :brutal_kill ->
                 {:ok, {:ok, %{provider_session_id: "late-session"}}}
               end
             )
  end

  test "returns timeout when shutdown kills unfinished worker" do
    assert {:error, %Error{code: "PAYMENT_PROVIDER_TIMEOUT"}} =
             ProviderTask.execute(
               fn -> {:ok, %{provider_session_id: "ignored"}} end,
               provider: :stripe,
               timeout_ms: 50,
               spawn_fun: fn _supervisor, _fun -> :task end,
               yield_fun: fn :task, 50 -> nil end,
               shutdown_fun: fn :task, :brutal_kill -> nil end
             )
  end

  test "normalizes provider error returned during shutdown race" do
    assert {:error, %Error{code: "PAYMENT_PROVIDER_DOWN"}} =
             ProviderTask.execute(
               fn -> {:ok, %{provider_session_id: "ignored"}} end,
               provider: :stripe,
               timeout_ms: 50,
               spawn_fun: fn _supervisor, _fun -> :task end,
               yield_fun: fn :task, 50 -> nil end,
               shutdown_fun: fn :task, :brutal_kill ->
                 {:ok, {:error, RuntimeError.exception("transport failed")}}
               end
             )
  end

  test "provider config uses finch and enforces timeout hierarchy" do
    assert :ok = ProviderConfig.validate_timeout_hierarchy()
    assert Process.whereis(Store.Payments.Finch)
    assert ProviderConfig.task_timeout_ms() < ProviderConfig.http_receive_timeout_ms()
    assert ProviderConfig.task_timeout_ms() < ProviderConfig.http_pool_timeout_ms()

    finch_opts = Keyword.fetch!(ProviderConfig.request_options(), :finch)
    assert Keyword.fetch!(finch_opts, :name) == Store.Payments.Finch
    assert Keyword.fetch!(finch_opts, :pool_timeout) == ProviderConfig.http_pool_timeout_ms()
    refute Keyword.has_key?(ProviderConfig.request_options(), :pool_timeout)
  end

  test "provider config preserves custom Finch options and timeout" do
    set_stripe_request_options!(finch: [name: :custom_finch, pool_timeout: 1_234])

    finch_opts = Keyword.fetch!(ProviderConfig.request_options(), :finch)

    assert Keyword.fetch!(finch_opts, :name) == :custom_finch
    assert Keyword.fetch!(finch_opts, :pool_timeout) == 1_234
    refute Keyword.has_key?(ProviderConfig.request_options(), :connect_options)
  end

  test "provider config rejects Finch and connect options together" do
    set_stripe_request_options!(connect_options: [timeout: 100])

    assert_raise ArgumentError, ~r/cannot set both :finch and :connect_options/, fn ->
      ProviderConfig.request_options()
    end
  end

  defp set_stripe_request_options!(request_options) do
    payments = Application.get_env(:store, :payments, [])
    stripe = Keyword.get(payments, :stripe, [])

    Application.put_env(
      :store,
      :payments,
      Keyword.put(payments, :stripe, Keyword.put(stripe, :request_options, request_options))
    )
  end
end
