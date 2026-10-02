defmodule Store.Orders.InventoryAdmissionTest do
  use ExUnit.Case, async: false

  alias Store.Orders.InventoryAdmission
  alias Store.Orders.InventoryAdmission.{Config, Redis, Reference, Request}
  alias Store.Support.Errors.Error
  alias Store.Support.ID.UUIDv7
  alias Store.Support.RateLimit.RedixClient
  alias Store.Support.Telemetry.RepoStats

  @hmac_key "ia03-test-only-trusted-key-material"
  @order_id "018ecb40-c457-73e6-a400-000398daddd7"
  @second_order_id "018ecb40-c457-73e6-a400-000398daddd8"
  @variant_id "018ecb40-c457-73e6-a400-000398daddd9"
  @second_variant_id "018ecb40-c457-73e6-a400-000398dadda0"
  @operation_id "018ecb40-c457-73e6-a400-000398daddaa"

  setup do
    scope =
      "ia03_orchestration_#{System.system_time(:nanosecond)}_#{System.unique_integer([:positive])}"

    {:ok, scope: scope}
  end

  test "valid generic reserve returns admitted coordination state", %{scope: scope} do
    request = params()

    assert {:ok, result} = InventoryAdmission.reserve(request, opts(scope, b_total: 2))
    assert result.state == :admitted
    assert result.status == :admitted
    assert is_binary(result.operation_id)
    assert result.operation_epoch == 1
    assert result.reference.operation_id == result.operation_id
    assert result.reference.operation_epoch == result.operation_epoch
    assert result.reference.reservation_key == "order:#{@order_id}:sku:#{@variant_id}"
    refute Map.has_key?(result, :lease_token)
    refute Map.has_key?(result, :owner_epoch)
    refute Map.has_key?(result, :member)
  end

  test "same-variant capacity queues immediately and another variant uses global headroom", %{
    scope: scope
  } do
    options = opts(scope, b_total: 2)

    assert {:ok, first} = InventoryAdmission.reserve(params(), options)

    assert {:ok, queued} =
             InventoryAdmission.reserve(params(@second_order_id, @variant_id), options)

    assert queued.state == :queued
    assert queued.status == :queued
    assert queued.operation_id != first.operation_id

    assert {:ok, other_variant} =
             InventoryAdmission.reserve(params(@second_order_id, @second_variant_id), options)

    assert other_variant.state == :admitted
    assert other_variant.operation_epoch == 3
  end

  test "exact live replay returns the same operation identity and epoch", %{scope: scope} do
    options = opts(scope, b_total: 2)

    assert {:ok, first} = InventoryAdmission.reserve(params(), options)
    assert {:ok, replay} = InventoryAdmission.reserve(params(), options)

    assert replay.state == :admitted
    assert replay.operation_id == first.operation_id
    assert replay.operation_epoch == first.operation_epoch
    assert replay.reference == first.reference
  end

  test "changed live fingerprint fails with the idempotency mismatch code", %{scope: scope} do
    options = opts(scope, b_total: 2)
    assert {:ok, _first} = InventoryAdmission.reserve(params(), options)

    assert {:error, %Error{code: "IDEMPOTENCY_KEY_REUSE_MISMATCH"}} =
             InventoryAdmission.reserve(params(@order_id, @variant_id, 2), options)
  end

  test "definite capacity backpressure maps to governed busy", %{scope: scope} do
    options = opts(scope, b_total: 1, q_variant_max: 0)
    assert {:ok, _first} = InventoryAdmission.reserve(params(), options)

    assert {:error, %Error{code: "INVENTORY_ADMISSION_BUSY"}} =
             InventoryAdmission.reserve(params(@second_order_id, @variant_id), options)
  end

  test "Redis uncertainty maps to admission unavailable", %{scope: scope} do
    assert {:error, %Error{code: "INVENTORY_ADMISSION_UNAVAILABLE"}} =
             InventoryAdmission.reserve(params(), Keyword.delete(opts(scope), :hmac_key))
  end

  test "status on a missing reference does not create or admit state", %{scope: scope} do
    request = request(@second_order_id, @second_variant_id)
    reference = reference_for(request, nil)

    {result, stats} =
      RepoStats.capture(fn ->
        InventoryAdmission.status(reference, lookup_opts(scope))
      end)

    assert {:error, %Error{code: "INVENTORY_ADMISSION_UNAVAILABLE"}} = result
    assert stats.query_count == 0

    keys = keys_for(request, scope)
    assert {:ok, 0} = redis(["EXISTS", keys.global_sequence])
    assert {:ok, 0} = redis(["EXISTS", keys.request_meta, keys.reservation_fence])
  end

  test "queued and admitted status report current coordination without Repo work", %{
    scope: scope
  } do
    options = opts(scope, b_total: 1)
    assert {:ok, admitted} = InventoryAdmission.reserve(params(), options)

    assert {:ok, queued} =
             InventoryAdmission.reserve(params(@second_order_id, @variant_id), options)

    {queued_result, queued_stats} =
      RepoStats.capture(fn -> InventoryAdmission.status(queued.reference, lookup_opts(scope)) end)

    assert {:ok, queued_status} = queued_result
    assert queued_status.state == :queued
    assert queued_status.operation_id == queued.operation_id
    assert queued_stats.query_count == 0
    refute Map.has_key?(queued_status, :lease_token)
    refute Map.has_key?(queued_status, :owner_epoch)
    refute Map.has_key?(queued_status, :member)

    {admitted_result, admitted_stats} =
      RepoStats.capture(fn ->
        InventoryAdmission.status(admitted.reference, lookup_opts(scope))
      end)

    assert {:ok, admitted_status} = admitted_result
    assert admitted_status.state == :admitted
    assert admitted_status.operation_id == admitted.operation_id
    assert admitted_stats.query_count == 0
  end

  test "queued abandon is idempotent and does not promote the next waiter", %{scope: scope} do
    options = opts(scope, b_total: 1)
    assert {:ok, _holder} = InventoryAdmission.reserve(params(), options)

    assert {:ok, abandoned} =
             InventoryAdmission.reserve(params(@second_order_id, @variant_id), options)

    assert {:ok, tail} =
             InventoryAdmission.reserve(params(UUIDv7.generate(), @variant_id), options)

    {result, stats} =
      RepoStats.capture(fn ->
        InventoryAdmission.abandon(abandoned.reference, lookup_opts(scope))
      end)

    assert {:ok, abandoned_result} = result
    assert abandoned_result.state == :abandoned
    assert abandoned_result.operation_id == abandoned.operation_id
    assert stats.query_count == 0
    refute Map.has_key?(abandoned_result, :lease_token)
    refute Map.has_key?(abandoned_result, :owner_epoch)
    refute Map.has_key?(abandoned_result, :member)

    assert {:ok, tail_status} = InventoryAdmission.status(tail.reference, lookup_opts(scope))
    assert tail_status.state == :queued
  end

  test "abandon of admitted state fails closed and preserves its permit", %{scope: scope} do
    options = opts(scope, b_total: 1)
    assert {:ok, admitted} = InventoryAdmission.reserve(params(), options)

    assert {:error, %Error{code: "INVENTORY_ADMISSION_UNSUPPORTED"}} =
             InventoryAdmission.abandon(admitted.reference, lookup_opts(scope))

    assert {:ok, queued} =
             InventoryAdmission.reserve(params(@second_order_id, @variant_id), options)

    assert queued.state == :queued
  end

  test "invalid generic input is rejected without bypassing Request validation", %{scope: scope} do
    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             InventoryAdmission.reserve(%{order_id: "not-a-uuid"}, opts(scope))
  end

  test "server-owned admission evidence cannot be supplied by the caller", %{scope: scope} do
    input = Map.merge(params(), %{member: String.duplicate("f", 64), operation_epoch: 99})

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             InventoryAdmission.reserve(input, opts(scope))
  end

  describe "typed configuration" do
    @describetag :inventory_admission_config
    setup do
      previous = Application.get_env(:store, :inventory_admission)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:store, :inventory_admission)
        else
          Application.put_env(:store, :inventory_admission, previous)
        end
      end)

      :ok
    end

    test "default configured mode is disabled" do
      assert {:ok, %Config{mode: :disabled}} = Config.load()
    end

    test "explicit disabled configuration does not require capacity or HMAC" do
      Application.put_env(:store, :inventory_admission, mode: :disabled, scope: "test_scope")

      assert {:ok, %Config{mode: :disabled, hmac_key: nil}} = Config.load()
    end

    test "valid enforced configuration loads" do
      Application.put_env(:store, :inventory_admission, enforced_config())

      assert {:ok, %Config{mode: :enforced} = config} = Config.load()
      assert Config.enforced?(config)
    end

    test "invalid mode fails" do
      assert_config_error(mode: :invalid)
    end

    test "missing enforced HMAC fails" do
      Application.put_env(
        :store,
        :inventory_admission,
        Keyword.delete(enforced_config(), :hmac_key)
      )

      assert {:error, {:invalid_configuration, :hmac_key}} = Config.load()
    end

    test "empty HMAC fails" do
      assert_config_error(hmac_key: "")
    end

    test "invalid HMAC key version fails" do
      assert_config_error(hmac_key_version: "version-1")
    end

    test "invalid scope fails" do
      assert_config_error(scope: "invalid scope")
    end

    test "non-positive repository capacity fails" do
      assert_config_error(repo_pool_capacity: 0)
    end

    test "non-positive repository headroom fails" do
      assert_config_error(repo_headroom: 0)
    end

    test "repository headroom at or above capacity fails" do
      assert_config_error(repo_headroom: 100)
    end

    test "non-positive total budget fails" do
      assert_config_error(b_total: 0)
    end

    test "budget above reviewed capacity fails" do
      assert_config_error(b_total: 91)
    end

    test "budget equal to reviewed capacity after headroom is accepted" do
      Application.put_env(
        :store,
        :inventory_admission,
        Keyword.put(enforced_config(), :b_total, 80)
      )

      assert {:ok, %Config{b_total: 80}} = Config.load()
    end

    test "non-positive queue bounds fail" do
      assert_config_error(q_variant_max: 0)
      assert_config_error(q_global_max: 0)
    end

    test "non-positive queue, DB, or lease windows fail" do
      assert_config_error(queue_window_ms: 0)
      assert_config_error(db_window_ms: 0)
      assert_config_error(lease_window_ms: 0)
    end

    test "negative safety margin fails" do
      assert_config_error(safety_margin_ms: -1)
    end

    test "lease window below DB window plus safety margin fails" do
      assert_config_error(lease_window_ms: 2_499)
    end

    test "lease window equal to DB window plus safety margin is accepted" do
      Application.put_env(
        :store,
        :inventory_admission,
        Keyword.put(enforced_config(), :lease_window_ms, 2_500)
      )

      assert {:ok, %Config{lease_window_ms: 2_500}} = Config.load()
    end

    test "non-positive cleanup limit fails" do
      assert_config_error(cleanup_limit: 0)
    end

    test "non-positive metadata retention fails" do
      assert_config_error(metadata_retention_ms: 0)
    end

    test "positive database safety window is accepted" do
      Application.put_env(
        :store,
        :inventory_admission,
        Keyword.put(enforced_config(), :database_safety_window_ms, 1_000)
      )

      assert {:ok, config} = Config.load()
      assert Map.get(config, :database_safety_window_ms) == 1_000
    end

    test "zero and negative database safety windows fail" do
      assert_config_error(database_safety_window_ms: 0)
      assert_config_error(database_safety_window_ms: -1)
    end

    test "positive recovery retry budget is accepted" do
      Application.put_env(
        :store,
        :inventory_admission,
        Keyword.put(enforced_config(), :recovery_retry_budget, 1)
      )

      assert {:ok, config} = Config.load()
      assert Map.get(config, :recovery_retry_budget) == 1
    end

    test "zero and negative recovery retry budgets fail" do
      assert_config_error(recovery_retry_budget: 0)
      assert_config_error(recovery_retry_budget: -1)
    end

    test "recovery deadline must exceed the database safety window" do
      assert_config_error(recovery_deadline_ms: 1_000)
      assert_config_error(recovery_deadline_ms: 999)
    end

    test "recovery deadline one millisecond above the safety window is accepted" do
      Application.put_env(
        :store,
        :inventory_admission,
        Keyword.merge(enforced_config(),
          database_safety_window_ms: 1_000,
          recovery_deadline_ms: 1_001
        )
      )

      assert {:ok, config} = Config.load()
      assert Map.get(config, :database_safety_window_ms) == 1_000
      assert Map.get(config, :recovery_deadline_ms) == 1_001
    end

    test "zero and negative Redis restart quarantine windows fail" do
      assert_config_error(redis_restart_quarantine_ms: 0)
      assert_config_error(redis_restart_quarantine_ms: -1)
    end

    test "redis options contain only the IA-03 option set" do
      Application.put_env(:store, :inventory_admission, enforced_config())
      assert {:ok, config} = Config.load()

      options = Config.redis_options(config)

      assert Keyword.keys(options) == [
               :hmac_key,
               :scope,
               :b_total,
               :q_variant_max,
               :q_global_max,
               :queue_window_ms,
               :db_window_ms,
               :lease_window_ms,
               :safety_margin_ms,
               :cleanup_limit,
               :metadata_retention_ms
             ]

      refute Keyword.has_key?(options, :mode)
      refute Keyword.has_key?(options, :repo_pool_capacity)
      refute Keyword.has_key?(options, :repo_headroom)
      refute Keyword.has_key?(options, :hmac_key_version)
      refute Keyword.has_key?(options, :database_safety_window_ms)
      refute Keyword.has_key?(options, :recovery_retry_budget)
      refute Keyword.has_key?(options, :recovery_deadline_ms)
      refute Keyword.has_key?(options, :redis_restart_quarantine_ms)
    end

    test "validation failures do not expose the HMAC secret" do
      secret = "do-not-expose-this-secret"
      config = Keyword.merge(enforced_config(), hmac_key: secret, b_total: 0)
      Application.put_env(:store, :inventory_admission, config)

      assert {:error, reason} = Config.load()
      assert :nomatch == :binary.match(:erlang.term_to_binary(reason), secret)
      refute String.contains?(inspect(reason), secret)
    end
  end

  describe "startup validation" do
    @describetag :startup_validation

    setup do
      previous = Application.get_env(:store, :inventory_admission)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:store, :inventory_admission)
        else
          Application.put_env(:store, :inventory_admission, previous)
        end
      end)

      :ok
    end

    test "disabled validation does not require Redis readiness" do
      Application.put_env(:store, :inventory_admission,
        mode: :disabled,
        scope: "test"
      )

      assert :ok =
               Store.Application.validate_inventory_admission_startup(:disabled, fn ->
                 flunk()
               end)
    end

    test "invalid enforced static configuration fails before Redis readiness" do
      Application.put_env(
        :store,
        :inventory_admission,
        Keyword.put(enforced_config(), :b_total, 0)
      )

      assert {:error, :invalid_enforced_config} =
               Store.Application.validate_inventory_admission_startup(:enforced, fn -> flunk() end)
    end

    test "valid enforced configuration succeeds when existing Redis is available" do
      Application.put_env(:store, :inventory_admission, enforced_config())
      test_pid = self()

      assert :ok =
               Store.Application.validate_inventory_admission_startup(:enforced, fn ->
                 send(test_pid, :redis_readiness_checked)
                 :ok
               end)

      assert_received :redis_readiness_checked
    end

    test "valid enforced configuration fails closed when Redis is unavailable" do
      secret = "redis-password-never-return-this"
      Application.put_env(:store, :inventory_admission, enforced_config())

      result =
        Store.Application.validate_inventory_admission_startup(:enforced, fn ->
          {:error, {:connection_failed, secret}}
        end)

      assert {:error, :redis_unavailable} = result
      refute String.contains?(inspect(result), secret)
    end

    test "Redis unavailability does not switch enforced mode to disabled" do
      Application.put_env(:store, :inventory_admission, enforced_config())

      assert {:error, :redis_unavailable} =
               Store.Application.validate_inventory_admission_startup(:enforced, fn ->
                 {:error, :connection_failed}
               end)

      assert Application.get_env(:store, :inventory_admission)[:mode] == :enforced
    end

    test "startup readiness validation creates no admission Redis state", %{scope: scope} do
      config = Keyword.put(enforced_config(), :scope, scope)
      Application.put_env(:store, :inventory_admission, config)

      request = request(@order_id, @variant_id)
      keys = keys_for(request, scope)

      admission_keys = [
        keys.global_sequence,
        keys.variant_queue_order,
        keys.global_queue_dispatch,
        keys.global_queue_expiry,
        keys.variant_active,
        keys.global_active_expiry,
        keys.request_meta,
        keys.reservation_fence
      ]

      assert {:ok, 0} = redis(["EXISTS" | admission_keys])
      assert :ok = Store.Application.validate_inventory_admission_startup(:enforced)
      assert {:ok, 0} = redis(["EXISTS" | admission_keys])
    end

    test "startup validation errors do not expose HMAC material" do
      secret = "startup-hmac-never-return-this"

      Application.put_env(
        :store,
        :inventory_admission,
        Keyword.merge(enforced_config(), hmac_key: secret, b_total: 0)
      )

      result =
        Store.Application.validate_inventory_admission_startup(:enforced, fn -> flunk() end)

      assert {:error, :invalid_enforced_config} = result
      refute String.contains?(inspect(result), secret)
    end
  end

  defp params(order_id \\ @order_id, variant_id \\ @variant_id, quantity \\ 1) do
    %{order_id: order_id, variant_id: variant_id, quantity: quantity}
  end

  defp request(order_id, variant_id), do: request(order_id, variant_id, 1)

  defp request(order_id, variant_id, quantity) do
    assert {:ok, request} = Request.new(params(order_id, variant_id, quantity))
    request
  end

  defp opts(scope, overrides \\ []) do
    Keyword.merge(
      [
        hmac_key: @hmac_key,
        scope: scope,
        b_total: 1,
        q_variant_max: 10,
        q_global_max: 20,
        queue_window_ms: 10_000,
        db_window_ms: 2_000,
        lease_window_ms: 3_000,
        safety_margin_ms: 500,
        cleanup_limit: 2
      ],
      overrides
    )
  end

  defp lookup_opts(scope), do: [hmac_key: @hmac_key, scope: scope]

  defp enforced_config do
    [
      mode: :enforced,
      scope: "ia04_test",
      repo_pool_capacity: 100,
      repo_headroom: 20,
      b_total: 80,
      q_variant_max: 10,
      q_global_max: 20,
      queue_window_ms: 10_000,
      db_window_ms: 2_000,
      lease_window_ms: 3_000,
      safety_margin_ms: 500,
      cleanup_limit: 2,
      metadata_retention_ms: 60_000,
      database_safety_window_ms: 1_000,
      recovery_retry_budget: 3,
      recovery_deadline_ms: 5_000,
      redis_restart_quarantine_ms: 2_000,
      hmac_key: "ia04-test-only-trusted-key-material",
      hmac_key_version: "v1"
    ]
  end

  defp assert_config_error(overrides) when is_list(overrides) do
    Application.put_env(:store, :inventory_admission, Keyword.merge(enforced_config(), overrides))
    assert {:error, {:invalid_configuration, _field}} = Config.load()
  end

  defp assert_config_error(overrides), do: assert_config_error([overrides])

  defp reference_for(request, admission) do
    %Reference{
      reservation_key: request.reservation_key,
      variant_id: request.variant_id,
      identity_digest: request.identity_digest,
      request_fingerprint: request.request_fingerprint,
      member:
        if(is_map(admission),
          do: admission.member,
          else: Redis.admission_member(request.identity_digest, @hmac_key)
        ),
      operation_id: if(is_map(admission), do: admission.operation_id, else: @operation_id),
      operation_epoch: if(is_map(admission), do: admission.operation_epoch, else: 1)
    }
  end

  defp keys_for(request, scope) do
    member = Redis.admission_member(request.identity_digest, @hmac_key)

    assert {:ok, keys} =
             Redis.key_set(request.variant_id, member, request.identity_digest, scope: scope)

    keys
  end

  defp redis(command), do: Redix.command(RedixClient.connection_name(), command)
end
