defmodule Store.Subscriptions.AccessEffectCurrentnessFenceTest do
  use Store.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Entitlements.Inputs.SubscriptionSourceConvergenceInput
  alias Store.DirectRepo
  alias Store.Repo
  alias Store.Subscriptions.AccessEffect
  alias Store.Subscriptions.AccessEffectCurrentnessFence
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.Subscriptions.Subscription
  alias Store.SubscriptionsFixtures
  alias Store.Support.Errors.Error
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "refuses calls outside a caller transaction without querying" do
    effect_id = Ecto.UUID.generate()

    {result, queries} =
      capture_repo_queries(fn ->
        Sandbox.unboxed_run(Repo, fn -> AccessEffectCurrentnessFence.prove(effect_id) end)
      end)

    assert {:error, %Error{code: "VALIDATION_ERROR"}} = result
    assert queries == []
  end

  test "returns NOT_FOUND for an unknown exact AccessEffect id" do
    assert {:error, %Error{code: "NOT_FOUND"}} =
             prove_in_caller_transaction(Ecto.UUID.generate())
  end

  test "proves the exact candidate current at the aggregate version with four ordered selects" do
    fixture = create_subscription_fixture!()
    effect = establish_effect!(fixture)

    {result, queries} =
      capture_repo_queries(fn ->
        prove_in_caller_transaction(effect.id, fn {:ok, evidence} ->
          assert_locked_source_and_build_input(evidence, fixture.subscription)
        end)
      end)

    assert {:ok, evidence} = result
    assert evidence.status == :current
    assert evidence.access_effect.id == effect.id
    assert evidence.latest_access_effect_id == effect.id
    assert effect.source_version == fixture.subscription.aggregate_version
    assert_success_query_sequence(queries)
  end

  test "accepts a source-version gap below the locked aggregate version" do
    fixture = create_subscription_fixture!()
    effect = establish_effect!(fixture)
    advance_subscription_aggregate!(fixture, 2)
    aggregate_version = subscription_aggregate_version!(fixture.subscription.id)

    {result, queries} =
      capture_repo_queries(fn ->
        prove_in_caller_transaction(effect.id, fn {:ok, evidence} ->
          assert_locked_source_and_build_input(evidence, fixture.subscription)
        end)
      end)

    assert {:ok, evidence} = result
    assert evidence.status == :current
    assert aggregate_version >= effect.source_version + 2
    assert_success_query_sequence(queries)
  end

  test "classifies a valid candidate as stale when another exact-source effect is latest" do
    fixture = create_subscription_fixture!()
    candidate = establish_effect!(fixture)
    advance_subscription_aggregate!(fixture)
    latest_version = subscription_aggregate_version!(fixture.subscription.id)
    latest = establish_effect!(fixture, %{source_version: latest_version})

    {result, queries} =
      capture_repo_queries(fn ->
        prove_in_caller_transaction(candidate.id, fn {:ok, evidence} ->
          assert_locked_source_and_build_input(evidence, fixture.subscription)
        end)
      end)

    assert {:ok, evidence} = result
    assert evidence.status == :stale
    assert evidence.access_effect.id == candidate.id
    assert evidence.latest_access_effect_id == latest.id
    assert_success_query_sequence(queries)
  end

  test "rejects a candidate version greater than the locked aggregate" do
    fixture = create_subscription_fixture!()
    effect = establish_effect!(fixture)
    too_high = fixture.subscription.aggregate_version + 1

    Repo.query!(
      "UPDATE access_effects SET source_version = $2 WHERE id = $1",
      [Ecto.UUID.dump!(effect.id), too_high]
    )

    assert {:error, %Error{code: "INTERNAL_ERROR"}} =
             prove_in_caller_transaction(effect.id)
  end

  test "rejects a candidate whose subscription identity changes before its locked reread" do
    {source_fixture, effect} = create_committed_effect_fixture!()
    other_fixture = create_committed_subscription_fixture!()

    {result, queries} =
      capture_repo_queries_with_candidate_reassignment(
        effect.id,
        other_fixture.subscription.id
      )

    restore_candidate_subscription!(effect.id, source_fixture.subscription.id)

    assert {:error, %Error{code: "INTERNAL_ERROR"}} = result
    assert Enum.count(queries, &select_query?/1) == 3
    assert Enum.any?(queries, &String.contains?(String.downcase(&1), "for update"))
    assert source_fixture.subscription.id != other_fixture.subscription.id
  end

  test "rejects an EFFECTIVE pair with a nil start despite a valid legacy fingerprint" do
    fixture = create_subscription_fixture!()
    effect = establish_effect!(fixture)
    id = Ecto.UUID.dump!(effect.id)
    Repo.query!("UPDATE access_effects SET valid_from_at = NULL WHERE id = $1", [id])
    no_start = reload_effect!(effect.id)
    legacy_fingerprint = AccessEffect.legacy_target_fingerprint_v1(no_start)

    refute AccessEffect.target_fingerprint(no_start) == legacy_fingerprint
    write_fingerprint!(effect.id, legacy_fingerprint)

    {result, queries} = capture_repo_queries(fn -> prove_in_caller_transaction(effect.id) end)

    assert {:error, %Error{code: "VALIDATION_ERROR"}} = result
    assert Enum.count(queries, &select_query?/1) == 3
  end

  test "rejects a plausible fingerprint mismatch before classifying an otherwise stale candidate" do
    fixture = create_subscription_fixture!()
    candidate = establish_effect!(fixture)
    advance_subscription_aggregate!(fixture)
    latest_version = subscription_aggregate_version!(fixture.subscription.id)
    latest = establish_effect!(fixture, %{source_version: latest_version})
    write_fingerprint!(candidate.id, unrelated_fingerprint(candidate))

    {result, queries} =
      capture_repo_queries(fn -> prove_in_caller_transaction(candidate.id) end)

    assert {:error, %Error{code: "INTERNAL_ERROR"}} = result
    assert latest.id != candidate.id
    assert Enum.count(queries, &select_query?/1) == 3
    refute Enum.any?(queries, &latest_effect_query?/1)
  end

  test "rejects a half-pair before latest-effect classification" do
    fixture = create_subscription_fixture!()
    effect = establish_effect!(fixture)

    Repo.query!(
      "ALTER TABLE access_effects DROP CONSTRAINT access_effects_entitlement_pair_complete_check"
    )

    Repo.query!("UPDATE access_effects SET entitlement_kind = NULL WHERE id = $1", [
      Ecto.UUID.dump!(effect.id)
    ])

    recompute_v2_fingerprint!(effect.id)

    {result, queries} = capture_repo_queries(fn -> prove_in_caller_transaction(effect.id) end)

    assert {:error, %Error{code: "VALIDATION_ERROR"}} = result
    assert Enum.count(queries, &select_query?/1) == 3
    refute Enum.any?(queries, &latest_effect_query?/1)
  end

  test "accepts an EFFECTIVE pair with an open-ended interval" do
    fixture = create_subscription_fixture!()
    effect = establish_effect!(fixture, %{valid_until_at: nil})

    assert {:ok, evidence} = prove_in_caller_transaction(effect.id)
    assert evidence.status == :current
    assert evidence.access_effect.valid_from_at != nil
    assert evidence.access_effect.valid_until_at == nil
  end

  test "accepts an EFFECTIVE empty target" do
    fixture = create_subscription_fixture!(%{})

    assert fixture.revision.entitlement_kind == nil
    assert fixture.revision.entitlement_scope_key == nil

    effect =
      establish_effect!(fixture, %{valid_from_at: nil})

    assert {:ok, evidence} = prove_in_caller_transaction(effect.id)
    assert evidence.status == :current
    assert evidence.access_effect.entitlement_kind == nil
    assert evidence.access_effect.entitlement_scope_key == nil
    assert evidence.access_effect.valid_from_at == nil
  end

  test "accepts a NON_EFFECTIVE empty target" do
    fixture = create_subscription_fixture!()

    effect =
      establish_effect!(fixture, %{
        disposition: :non_effective,
        entitlement_kind: nil,
        entitlement_scope_key: nil,
        valid_from_at: nil
      })

    assert {:ok, evidence} = prove_in_caller_transaction(effect.id)
    assert evidence.status == :current
    assert evidence.access_effect.disposition == :non_effective
    assert evidence.access_effect.entitlement_kind == nil
    assert evidence.access_effect.entitlement_scope_key == nil
    assert evidence.access_effect.valid_from_at == nil
  end

  test "rejects an empty target with a populated start" do
    fixture = create_subscription_fixture!()
    effect = establish_effect!(fixture)

    Repo.query!(
      "UPDATE access_effects SET entitlement_kind = NULL, entitlement_scope_key = NULL WHERE id = $1",
      [Ecto.UUID.dump!(effect.id)]
    )

    recompute_v2_fingerprint!(effect.id)

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             prove_in_caller_transaction(effect.id)
  end

  test "rejects a NON_EFFECTIVE pair" do
    fixture = create_subscription_fixture!()

    effect =
      establish_effect!(fixture, %{
        disposition: :non_effective,
        entitlement_kind: nil,
        entitlement_scope_key: nil,
        valid_from_at: nil
      })

    Repo.query!(
      "UPDATE access_effects SET entitlement_kind = 'membership_access', entitlement_scope_key = 'members' WHERE id = $1",
      [Ecto.UUID.dump!(effect.id)]
    )

    recompute_v2_fingerprint!(effect.id)

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             prove_in_caller_transaction(effect.id)
  end

  test "rejects a finite pair whose start equals its end" do
    fixture = create_subscription_fixture!()
    effect = establish_effect!(fixture)

    Repo.query!(
      "UPDATE access_effects SET valid_until_at = valid_from_at WHERE id = $1",
      [Ecto.UUID.dump!(effect.id)]
    )

    recompute_v2_fingerprint!(effect.id)

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             prove_in_caller_transaction(effect.id)
  end

  test "rejects an empty persisted scope with a valid fingerprint" do
    assert_corrupt_scope_rejected("")
  end

  test "rejects a whitespace-only persisted scope with a valid fingerprint" do
    assert_corrupt_scope_rejected("   ")
  end

  test "rejects an oversized persisted scope with a valid fingerprint" do
    assert_corrupt_scope_rejected(String.duplicate("s", 256))
  end

  defp assert_corrupt_scope_rejected(scope) do
    fixture = create_subscription_fixture!()
    effect = establish_effect!(fixture)

    Repo.query!(
      "UPDATE access_effects SET entitlement_scope_key = $2 WHERE id = $1",
      [Ecto.UUID.dump!(effect.id), scope]
    )

    recompute_v2_fingerprint!(effect.id)
    corrupted_effect = reload_effect!(effect.id)

    assert AccessEffect.persisted_fingerprint_status(corrupted_effect) == :v2_match

    {result, queries} =
      capture_repo_queries(fn -> prove_in_caller_transaction(effect.id) end)

    assert {:error, %Error{code: "VALIDATION_ERROR"}} = result
    assert Enum.count(queries, &select_query?/1) == 3
    refute Enum.any?(queries, &latest_effect_query?/1)
  end

  defp assert_locked_source_and_build_input(evidence, subscription) do
    assert evidence.source.subscription_id == subscription.id
    assert evidence.source.user_id == subscription.user_id

    attrs = %{
      subscription_id: evidence.source.subscription_id,
      user_id: evidence.source.user_id,
      disposition: evidence.access_effect.disposition,
      entitlement_kind: evidence.access_effect.entitlement_kind,
      entitlement_scope_key: evidence.access_effect.entitlement_scope_key,
      valid_from_at: evidence.access_effect.valid_from_at,
      valid_until_at: evidence.access_effect.valid_until_at,
      reason: "test currentness evidence",
      access_effect_id: evidence.access_effect.id,
      source_version: evidence.access_effect.source_version,
      target_fingerprint: evidence.access_effect.target_fingerprint
    }

    {input_result, queries} =
      capture_repo_queries(fn -> SubscriptionSourceConvergenceInput.new(attrs) end)

    assert {:ok, _input} = input_result
    assert queries == []
  end

  defp prove_in_caller_transaction(effect_id) do
    prove_in_caller_transaction(effect_id, fn _result -> :ok end)
  end

  defp prove_in_caller_transaction(effect_id, after_prove) do
    case Repo.transaction(fn ->
           result = AccessEffectCurrentnessFence.prove(effect_id)
           after_prove.(result)
           Repo.rollback(result)
         end) do
      {:error, result} -> result
      {:ok, result} -> result
    end
  end

  defp assert_success_query_sequence(queries) do
    selects = Enum.filter(queries, &select_query?/1)
    dml = Enum.filter(queries, &dml_query?/1)

    assert length(selects) == 4
    assert dml == []

    assert Enum.map(selects, &classify_select/1) == [
             :unlocked_exact_effect,
             :locked_subscription,
             :locked_exact_effect,
             :latest_effect
           ]

    [lookup, source_lock, candidate_lock, latest] = Enum.map(selects, &String.downcase/1)

    assert Regex.match?(~r/select\s+\w+\."subscription_id"\s+from/, lookup)
    assert String.contains?(lookup, "where") and String.contains?(lookup, ".\"id\"")
    assert String.contains?(source_lock, "from \"subscriptions\"")
    assert String.contains?(source_lock, "for update")
    assert String.contains?(source_lock, "where") and String.contains?(source_lock, ".\"id\"")
    assert String.contains?(candidate_lock, "from \"access_effects\"")
    assert String.contains?(candidate_lock, "for update")

    assert String.contains?(candidate_lock, "where") and
             String.contains?(candidate_lock, ".\"id\"")

    for field <- [
          "subscription_id",
          "source_version",
          "disposition",
          "entitlement_kind",
          "entitlement_scope_key",
          "valid_from_at",
          "valid_until_at",
          "target_fingerprint",
          "source_order_line_item_id",
          "contract_change_id",
          "plan_revision_id"
        ] do
      assert String.contains?(candidate_lock, field)
    end

    assert String.contains?(latest, "order by")
    assert String.contains?(latest, "source_version")
    assert String.contains?(latest, "desc")
    assert String.contains?(latest, "limit")
    assert String.contains?(latest, "where") and String.contains?(latest, "subscription_id")

    refute Enum.any?(queries, fn sql ->
             String.contains?(String.downcase(sql), "plan_revisions") or
               String.contains?(String.downcase(sql), "subscription_plans")
           end)
  end

  defp classify_select(sql) do
    normalized = String.downcase(sql)

    cond do
      String.contains?(normalized, "from \"subscriptions\"") and
          String.contains?(normalized, "for update") ->
        :locked_subscription

      String.contains?(normalized, "from \"access_effects\"") and
          String.contains?(normalized, "order by") ->
        :latest_effect

      String.contains?(normalized, "from \"access_effects\"") and
          String.contains?(normalized, "for update") ->
        :locked_exact_effect

      String.contains?(normalized, "from \"access_effects\"") and
          String.contains?(normalized, "subscription_id") ->
        :unlocked_exact_effect

      true ->
        :other
    end
  end

  defp select_query?(sql), do: String.starts_with?(String.downcase(String.trim(sql)), "select")

  defp dml_query?(sql) do
    String.starts_with?(String.downcase(String.trim(sql)), ["insert", "update", "delete"])
  end

  defp latest_effect_query?(sql) do
    normalized = String.downcase(sql)

    String.contains?(normalized, "from \"access_effects\"") and
      String.contains?(normalized, "order by")
  end

  defp unrelated_fingerprint(effect) do
    candidates =
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(fn number ->
        :crypto.hash(:sha256, "currentness mismatch #{number}")
        |> Base.encode16(case: :lower)
      end)

    Enum.find(candidates, fn candidate ->
      candidate != AccessEffect.target_fingerprint(effect) and
        candidate != AccessEffect.legacy_target_fingerprint_v1(effect)
    end)
  end

  defp recompute_v2_fingerprint!(effect_id) do
    write_fingerprint!(effect_id, AccessEffect.target_fingerprint(reload_effect!(effect_id)))
  end

  defp write_fingerprint!(effect_id, fingerprint) do
    Repo.query!("UPDATE access_effects SET target_fingerprint = $2 WHERE id = $1", [
      Ecto.UUID.dump!(effect_id),
      fingerprint
    ])
  end

  defp reload_effect!(effect_id) do
    Repo.one(from effect in AccessEffect, where: effect.id == ^effect_id)
  end

  defp capture_repo_queries(fun) do
    handler_id = {__MODULE__, :currentness_queries, make_ref()}
    message_ref = make_ref()

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :repo, :query],
        fn _event, _measurements, metadata, {pid, ref} ->
          send(pid, {ref, metadata.query})
        end,
        {self(), message_ref}
      )

    try do
      result = fun.()
      {result, receive_repo_queries(message_ref, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp capture_repo_queries_with_candidate_reassignment(effect_id, new_subscription_id) do
    handler_id = {__MODULE__, :candidate_reassignment, make_ref()}
    message_ref = make_ref()
    mutation_key = {__MODULE__, :candidate_reassignment_done, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :repo, :query],
        fn _event, _measurements, metadata, {pid, ref, key, candidate_id, subscription_id} ->
          send(pid, {ref, metadata.query})

          if self() == pid and Process.get(key) != true and effect_lookup_query?(metadata.query) do
            Process.put(key, true)

            task =
              Task.async(fn ->
                Sandbox.unboxed_run(DirectRepo, fn ->
                  {:ok, result} =
                    DirectRepo.transaction(fn ->
                      DirectRepo.query!("SET LOCAL lock_timeout = '5s'")

                      DirectRepo.query!(
                        "UPDATE access_effects SET subscription_id = $2 WHERE id = $1",
                        [Ecto.UUID.dump!(candidate_id), Ecto.UUID.dump!(subscription_id)]
                      )
                    end)

                  result
                end)
              end)

            case Task.yield(task, 6_000) do
              {:ok, _result} ->
                :ok

              {:exit, reason} ->
                exit(reason)

              nil ->
                _ = Task.shutdown(task, :brutal_kill)
                raise "candidate identity mutation did not finish within six seconds"
            end
          end
        end,
        {self(), message_ref, mutation_key, effect_id, new_subscription_id}
      )

    try do
      result = prove_in_caller_transaction(effect_id)
      {result, receive_repo_queries(message_ref, [])}
    after
      Process.delete(mutation_key)
      :telemetry.detach(handler_id)
    end
  end

  defp effect_lookup_query?(sql) do
    normalized = String.downcase(String.trim(sql))

    String.starts_with?(normalized, "select") and
      String.contains?(normalized, "from \"access_effects\"") and
      String.contains?(normalized, "subscription_id") and
      not String.contains?(normalized, "for update")
  end

  defp receive_repo_queries(ref, queries) do
    receive do
      {^ref, query} -> receive_repo_queries(ref, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp create_subscription_fixture!(
         plan_overrides \\ %{
           entitlement_kind: :membership_access,
           entitlement_scope_key: "members"
         }
       ) do
    customer =
      SubscriptionsFixtures.create_customer!("f0_currentness_#{Ecto.UUID.generate()}")

    %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan = SubscriptionsFixtures.create_subscription_plan!(plan_overrides)

    variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    fixture = SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    Map.merge(fixture, %{
      customer: customer,
      product: product,
      variant: variant,
      plan: plan,
      variant_plan: variant_plan
    })
  end

  defp create_committed_subscription_fixture! do
    fixture = Sandbox.unboxed_run(Repo, fn -> create_subscription_fixture!() end)
    on_exit(fn -> cleanup_committed_subscription_fixture!(fixture) end)
    fixture
  end

  defp create_committed_effect_fixture! do
    fixture = create_committed_subscription_fixture!()
    effect = Sandbox.unboxed_run(Repo, fn -> establish_effect!(fixture) end)
    {fixture, effect}
  end

  defp restore_candidate_subscription!(effect_id, subscription_id) do
    Sandbox.unboxed_run(DirectRepo, fn ->
      DirectRepo.query!(
        "UPDATE access_effects SET subscription_id = $2 WHERE id = $1",
        [Ecto.UUID.dump!(effect_id), Ecto.UUID.dump!(subscription_id)]
      )
    end)
  end

  defp cleanup_committed_subscription_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      subscription_id = Ecto.UUID.dump!(fixture.subscription.id)
      line_item_id = Ecto.UUID.dump!(fixture.line_item.id)
      order_id = Ecto.UUID.dump!(fixture.order.id)
      variant_id = Ecto.UUID.dump!(fixture.variant.id)
      product_id = Ecto.UUID.dump!(fixture.product.id)
      plan_id = Ecto.UUID.dump!(fixture.plan.id)

      Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [subscription_id])
      Repo.query!("DELETE FROM renewal_attempts WHERE subscription_id = $1", [subscription_id])
      Repo.query!("DELETE FROM subscription_items WHERE subscription_id = $1", [subscription_id])
      Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])
      Repo.query!("DELETE FROM order_line_items WHERE id = $1", [line_item_id])
      Repo.query!("DELETE FROM order_adjustments WHERE order_id = $1", [order_id])
      Repo.query!("DELETE FROM fulfillment_orders WHERE order_id = $1", [order_id])
      Repo.query!("DELETE FROM payment_intents WHERE order_id = $1", [order_id])
      Repo.query!("DELETE FROM orders WHERE id = $1", [order_id])

      Repo.query!("DELETE FROM variant_subscription_plans WHERE variant_id = $1", [variant_id])
      Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [plan_id])
      Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
      Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")
      Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
    end)
  end

  defp access_effect_input(fixture, overrides) do
    subscription = fixture.subscription
    revision = fixture.revision
    disposition = Map.get(overrides, :disposition, :effective)

    default_valid_from_at =
      if disposition == :effective, do: subscription.current_period_start_at, else: nil

    attrs =
      %{
        subscription_id: subscription.id,
        source_version: subscription_aggregate_version!(subscription.id),
        disposition: disposition,
        entitlement_kind: revision.entitlement_kind,
        entitlement_scope_key: revision.entitlement_scope_key,
        valid_from_at: default_valid_from_at,
        valid_until_at: subscription.current_period_end_at,
        source_order_line_item_id: fixture.line_item.id,
        contract_change_id: subscription.current_contract_change_id,
        plan_revision_id: revision.id
      }
      |> Map.merge(overrides)

    case EstablishAccessEffectInput.new(attrs) do
      {:ok, input} -> input
      {:error, reason} -> raise "invalid AccessEffect test input: #{inspect(reason)}"
    end
  end

  defp establish_effect!(fixture, overrides \\ %{}) do
    assert {:ok, effect} =
             fixture
             |> access_effect_input(overrides)
             |> Facade.establish_access_effect_for_system()

    effect
  end

  defp advance_subscription_aggregate!(fixture, count \\ 1) do
    Repo.query!(
      "UPDATE subscriptions SET aggregate_version = aggregate_version + $2 WHERE id = $1",
      [Ecto.UUID.dump!(fixture.subscription.id), count]
    )
  end

  defp subscription_aggregate_version!(subscription_id) do
    Repo.one(
      from subscription in Subscription,
        where: subscription.id == ^subscription_id,
        select: subscription.aggregate_version
    )
  end
end
