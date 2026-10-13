defmodule Store.Governance.CheckoutInterlocksTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Catalog.{InventoryItem, Product}
  alias Store.OrderFixtures
  alias Store.Orders.{InventoryReservation, Order, OrderLineItem, PaymentApplication}
  alias Store.Payments.{Facade, ObservationEvidence, PaymentIntent}
  alias Store.Payments.Types.ProviderObservation
  alias Store.Repo
  alias Store.Support.Errors.Error
  alias Store.Support.ID.UUIDv7
  alias Store.TestFixtures

  setup do
    previous = Application.get_env(:store, :payments, [])

    on_exit(fn ->
      Application.put_env(:store, :payments, previous)
    end)

    :ok
  end

  test "begin_checkout is idempotent for same canonical input" do
    as_of = ~U[2026-02-25 18:00:00Z]
    line_a = %{variant_id: UUIDv7.generate(), quantity: 2}
    line_b = %{variant_id: UUIDv7.generate(), quantity: 1}

    attrs = %{
      user_id: UUIDv7.generate(),
      currency: "usd",
      as_of: as_of,
      pricing_contract_version: "phase-13-v1",
      tax_shipping_inputs: %{
        shipping_country_code: "US",
        shipping_region_code: "CA",
        shipping_postal_code: "94105"
      },
      line_items: [line_b, line_a]
    }

    assert {:ok, first} = Store.Orders.begin_checkout(attrs)
    assert {:ok, second} = Store.Orders.begin_checkout(%{attrs | line_items: [line_a, line_b]})

    assert first.order.id == second.order.id
    assert first.checkout_key == second.checkout_key
    assert first.cart_fingerprint == second.cart_fingerprint
    assert first.duplicate? == false
    assert second.duplicate? == true
    assert second.order.state == :pending_payment
  end

  test "begin_checkout key changes when deterministic pricing inputs differ" do
    line = %{variant_id: UUIDv7.generate(), quantity: 1}

    base_attrs = %{
      user_id: UUIDv7.generate(),
      currency: "USD",
      as_of: ~U[2026-02-25 18:00:00Z],
      pricing_contract_version: "phase-13-v1",
      tax_shipping_inputs: %{shipping_country_code: "US", shipping_region_code: "CA"},
      line_items: [line]
    }

    assert {:ok, first} = Store.Orders.begin_checkout(base_attrs)

    assert {:ok, second} =
             Store.Orders.begin_checkout(%{
               base_attrs
               | tax_shipping_inputs: %{shipping_country_code: "US", shipping_region_code: "TX"}
             })

    refute first.checkout_key == second.checkout_key
    refute first.order.id == second.order.id
  end

  test "begin_checkout guest checkout_scope isolates otherwise identical checkouts" do
    attrs = %{
      user_id: nil,
      currency: "USD",
      as_of: ~U[2026-02-25 18:00:00Z],
      pricing_contract_version: "phase-13-v1",
      tax_shipping_inputs: %{},
      line_items: [%{variant_id: UUIDv7.generate(), quantity: 1}]
    }

    assert {:ok, first} =
             Store.Orders.begin_checkout(Map.put(attrs, :checkout_scope, "guest_cart:one"))

    assert {:ok, duplicate} =
             Store.Orders.begin_checkout(Map.put(attrs, :checkout_scope, "guest_cart:one"))

    assert {:ok, second} =
             Store.Orders.begin_checkout(Map.put(attrs, :checkout_scope, "guest_cart:two"))

    assert first.checkout_key == duplicate.checkout_key
    assert duplicate.duplicate? == true
    refute first.checkout_key == second.checkout_key
    refute first.order.id == second.order.id
  end

  test "begin_checkout retries generated order_ref collisions and succeeds" do
    duplicate_ref = "ORDREF_CHECKOUT_RETRY_DUP"
    unique_ref = "ORDREF_CHECKOUT_RETRY_OK"

    assert {:ok, _existing} =
             Order
             |> Ash.Changeset.for_create(:create, %{order_ref: duplicate_ref})
             |> Ash.create(domain: Store.Orders, authorize?: false)

    attrs = %{
      user_id: UUIDv7.generate(),
      currency: "USD",
      as_of: ~U[2026-02-25 18:00:00Z],
      pricing_contract_version: "phase-13-v1",
      tax_shipping_inputs: %{},
      line_items: [%{variant_id: UUIDv7.generate(), quantity: 1}]
    }

    generator = sequence_generator([duplicate_ref, unique_ref])

    assert {:ok, result} =
             Store.Orders.begin_checkout(
               attrs,
               order_ref_generator: generator,
               max_attempts: 3
             )

    assert result.order.order_ref == unique_ref
    assert result.duplicate? == false
  end

  test "create_or_reuse_payment_intent is idempotent for same key payload" do
    order = create_order!()

    attrs = %{
      order_id: order.id,
      amount_received_minor: 10_000,
      currency: "usd",
      provider: "stripe"
    }

    assert {:ok, first} = Store.Payments.create_or_reuse_payment_intent(attrs)
    assert {:ok, second} = Store.Payments.create_or_reuse_payment_intent(attrs)

    assert first.payment_intent.id == second.payment_intent.id
    assert first.payment_intent_key == second.payment_intent_key
    assert first.duplicate? == false
    assert second.duplicate? == true
  end

  test "cannot create new payment intent while another is in-flight" do
    order = create_order!()

    assert {:ok, first} =
             Store.Payments.create_or_reuse_payment_intent(%{
               order_id: order.id,
               amount_received_minor: 10_000,
               currency: "USD",
               provider: "stripe"
             })

    _submitted = submit_payment_intent!(first.payment_intent)

    assert {:error, %Error{code: "PAYMENT_INTENT_DUPLICATE"}} =
             Store.Payments.create_or_reuse_payment_intent(%{
               order_id: order.id,
               amount_received_minor: 12_000,
               currency: "USD",
               provider: "stripe"
             })
  end

  test "cannot create new payment intent after succeeded payment exists" do
    order = create_order!()

    assert {:ok, first} =
             Store.Payments.create_or_reuse_payment_intent(%{
               order_id: order.id,
               amount_received_minor: 10_000,
               currency: "USD",
               provider: "stripe"
             })

    first.payment_intent
    |> submit_payment_intent!()
    |> mark_succeeded_payment_intent!()

    assert {:error, %Error{code: "PAYMENT_ALREADY_SUCCEEDED"}} =
             Store.Payments.create_or_reuse_payment_intent(%{
               order_id: order.id,
               amount_received_minor: 12_000,
               currency: "USD",
               provider: "stripe"
             })
  end

  test "apply_payment_success_once is replay-safe and inserts one payment_application" do
    order = create_customer_order!()
    payment_intent = create_submitted_payment_intent!(order.id)
    parent = self()
    handler_id = {__MODULE__, :apply_payment_success_once, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:store, :payments, :interlock_apply_payment_success_once],
      fn _event, measurements, metadata, pid ->
        send(pid, {:apply_payment_success_once, measurements, metadata})
      end,
      parent
    )

    try do
      assert {:ok, first_result} = Store.Payments.apply_payment_success_once(payment_intent.id)
      assert first_result.applied? == true

      assert_receive {:apply_payment_success_once, first_measurements, first_metadata}
      assert first_measurements.duration > 0
      assert first_metadata.replay == false
      assert first_metadata.outcome == :ok

      assert {:ok, second_result} = Store.Payments.apply_payment_success_once(payment_intent.id)
      assert second_result.applied? == false

      assert_receive {:apply_payment_success_once, second_measurements, second_metadata}
      assert second_measurements.duration > 0
      assert second_metadata.replay == true
      assert second_metadata.outcome == :ok

      assert 1 ==
               PaymentApplication
               |> Ash.Query.filter(expr(order_id == ^order.id))
               |> Ash.count!(domain: Store.Orders, authorize?: false)

      assert :paid == fetch_order!(order.id).state
      assert :succeeded == fetch_payment_intent!(payment_intent.id).state
    after
      :telemetry.detach(handler_id)
    end
  end

  @tag :jc281_cancelled_reservation_scope
  test "ordinary checkout payment fails closed after its physical reservation is cancelled" do
    order = create_customer_order!()
    variant_id = create_physical_variant!()
    create_physical_order_line_item!(order.id, variant_id)
    payment_intent = create_submitted_payment_intent!(order.id)

    assert {:ok, %{reserved_rows: [_reservation]}} =
             Store.Orders.reserve_inventory_for_checkout(
               order.id,
               [%{variant_id: variant_id, quantity: 1}],
               context: %{system?: true}
             )

    inventory_before_release = Repo.get_by!(InventoryItem, variant_id: variant_id)
    assert inventory_before_release.reserved_count == 1
    assert inventory_before_release.stock_on_hand == 4

    assert {:ok, %{released_count: 1}} =
             Store.Orders.release_reservations_for_order(order.id, context: %{system?: true})

    reservation = Repo.get_by!(InventoryReservation, order_id: order.id, variant_id: variant_id)
    assert reservation.state == :cancelled

    inventory_after_release = Repo.get_by!(InventoryItem, variant_id: variant_id)
    assert inventory_after_release.reserved_count == 0
    assert inventory_after_release.stock_on_hand == 4

    assert {:error, %Error{code: "RESERVATION_CONFLICT"}} =
             Store.Payments.apply_payment_success_once(payment_intent.id)

    assert fetch_order!(order.id).state == :pending_payment
    assert fetch_payment_intent!(payment_intent.id).state == :submitted

    assert 0 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.count!(domain: Store.Orders, authorize?: false)

    inventory_after_payment = Repo.get_by!(InventoryItem, variant_id: variant_id)
    assert inventory_after_payment.reserved_count == 0
    assert inventory_after_payment.stock_on_hand == 4
  end

  test "apply-once refuses to attribute an order application to a different payment intent" do
    order = create_customer_order!()
    first_intent = create_submitted_payment_intent!(order.id)

    second_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(
        :create,
        %{order_id: order.id, amount_received_minor: 1_000, provider: :stripe}
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    assert {:ok, %{applied?: true}} = Store.Payments.apply_payment_success_once(first_intent.id)
    assert {:error, _reason} = Store.Payments.apply_payment_success_once(second_intent.id)

    assert :succeeded == fetch_payment_intent!(first_intent.id).state
    assert :created == fetch_payment_intent!(second_intent.id).state
    assert :paid == fetch_order!(order.id).state

    assert {:ok, [application]} =
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.read(domain: Store.Orders, authorize?: false)

    assert application.payment_intent_id == first_intent.id
  end

  test "verified success can correct a failed payment intent through outcome application" do
    order = create_customer_order!()

    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(
        :create,
        %{
          order_id: order.id,
          amount_received_minor: 1_000,
          currency: "USD",
          provider: :stripe,
          provider_payment_id: "pi_corrected"
        }
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false)
      |> submit_payment_intent!()

    payment_intent
    |> Ash.Changeset.for_update(:mark_failed, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    nonterminal_failure =
      outcome_observation(payment_intent, :failure_observation, "requires_payment_method")

    assert {:ok, _failure_evidence} =
             ObservationEvidence.record(payment_intent, nonterminal_failure)

    assert {:error, _reason} =
             payment_intent
             |> Ash.Changeset.for_update(:mark_succeeded, %{}, context: %{system?: true})
             |> Ash.update(domain: Store.Payments, authorize?: false, context: %{system?: true})

    observation = %ProviderObservation{
      provider: :stripe,
      provider_reference: "pi_corrected",
      provider_reference_kind: :payment_intent,
      provider_transaction_id: "pi_corrected",
      local_payment_intent_id: payment_intent.id,
      observation_source: :verification,
      normalized_outcome: :authoritative_success,
      raw_provider_status: "succeeded",
      amount_minor: 1_000,
      currency: "USD",
      provider_environment: "test",
      observed_at: DateTime.utc_now()
    }

    assert {:ok, evidence} = ObservationEvidence.record(payment_intent, observation)

    assert {:ok, %{outcome: :authoritative_success}} =
             Facade.apply_observed_payment_outcome_for_system(%{
               payment_intent: payment_intent,
               observation: observation,
               evidence: evidence
             })

    assert :succeeded == fetch_payment_intent!(payment_intent.id).state
    assert :paid == fetch_order!(order.id).state

    assert 1 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.count!(domain: Store.Orders, authorize?: false)
  end

  test "Stripe cancellation evidence makes a later success require reconciliation" do
    order = create_customer_order!()
    payment_intent = create_submitted_payment_intent!(order.id, "pi_cancel_then_success")

    canceled = outcome_observation(payment_intent, :failure_observation, "canceled")
    assert {:ok, canceled_evidence} = ObservationEvidence.record(payment_intent, canceled)

    assert {:ok, %{outcome: :verified_terminal_non_success}} =
             Facade.apply_observed_payment_outcome_for_system(%{
               payment_intent: payment_intent,
               observation: canceled,
               evidence: canceled_evidence
             })

    succeeded = outcome_observation(payment_intent, :authoritative_success, "succeeded")
    assert {:ok, succeeded_evidence} = ObservationEvidence.record(payment_intent, succeeded)

    assert {:ok, %{outcome: :reconciliation_required}} =
             Facade.apply_observed_payment_outcome_for_system(%{
               payment_intent: payment_intent,
               observation: succeeded,
               evidence: succeeded_evidence
             })

    assert :failed == fetch_payment_intent!(payment_intent.id).state
    assert :pending_payment == fetch_order!(order.id).state
    assert 0 == Repo.aggregate(PaymentApplication, :count, :id)
  end

  test "cancel and success evidence resolve to reconciliation in either insertion order" do
    for evidence_order <- [[:canceled, :succeeded], [:succeeded, :canceled]] do
      order = create_customer_order!()

      payment_intent =
        create_submitted_payment_intent!(order.id, "pi_order_#{UUIDv7.generate()}")

      observations = %{
        canceled: outcome_observation(payment_intent, :failure_observation, "canceled"),
        succeeded: outcome_observation(payment_intent, :authoritative_success, "succeeded")
      }

      evidence =
        Map.new(evidence_order, fn key ->
          observation = Map.fetch!(observations, key)
          assert {:ok, record} = ObservationEvidence.record(payment_intent, observation)
          {key, record}
        end)

      results =
        Enum.map([:canceled, :succeeded], fn key ->
          Facade.apply_observed_payment_outcome_for_system(%{
            payment_intent: payment_intent,
            observation: Map.fetch!(observations, key),
            evidence: Map.fetch!(evidence, key)
          })
        end)

      assert Enum.all?(results, &match?({:ok, %{outcome: :reconciliation_required}}, &1))
      assert :submitted == fetch_payment_intent!(payment_intent.id).state
      assert :pending_payment == fetch_order!(order.id).state
      assert 0 == Repo.aggregate(PaymentApplication, :count, :id)
    end
  end

  test "late certified terminal evidence requires reconciliation without undoing applied success" do
    order = create_customer_order!()
    payment_intent = create_submitted_payment_intent!(order.id, "pi_success_then_cancel")
    success = outcome_observation(payment_intent, :authoritative_success, "succeeded")
    assert {:ok, success_evidence} = ObservationEvidence.record(payment_intent, success)

    assert {:ok, %{outcome: :authoritative_success}} =
             Facade.apply_observed_payment_outcome_for_system(%{
               payment_intent: payment_intent,
               observation: success,
               evidence: success_evidence
             })

    canceled = outcome_observation(payment_intent, :failure_observation, "canceled")
    assert {:ok, canceled_evidence} = ObservationEvidence.record(payment_intent, canceled)

    assert {:ok, %{outcome: :reconciliation_required}} =
             Facade.apply_observed_payment_outcome_for_system(%{
               payment_intent: payment_intent,
               observation: canceled,
               evidence: canceled_evidence
             })

    assert :succeeded == fetch_payment_intent!(payment_intent.id).state
    assert :paid == fetch_order!(order.id).state
    assert 1 == Repo.aggregate(PaymentApplication, :count, :id)
  end

  test "a nonterminal failure after applied success leaves success monotonic without reconciliation" do
    order = create_customer_order!()
    payment_intent = create_submitted_payment_intent!(order.id, "pi_success_then_retryable")
    success = outcome_observation(payment_intent, :authoritative_success, "succeeded")
    assert {:ok, success_evidence} = ObservationEvidence.record(payment_intent, success)

    assert {:ok, %{outcome: :authoritative_success}} =
             Facade.apply_observed_payment_outcome_for_system(%{
               payment_intent: payment_intent,
               observation: success,
               evidence: success_evidence
             })

    retryable =
      outcome_observation(payment_intent, :failure_observation, "requires_payment_method")

    assert {:ok, retryable_evidence} = ObservationEvidence.record(payment_intent, retryable)

    assert {:ok, %{outcome: :already_applied_success}} =
             Facade.apply_observed_payment_outcome_for_system(%{
               payment_intent: payment_intent,
               observation: retryable,
               evidence: retryable_evidence
             })

    assert :succeeded == fetch_payment_intent!(payment_intent.id).state
    assert :paid == fetch_order!(order.id).state
    assert 1 == Repo.aggregate(PaymentApplication, :count, :id)
  end

  test "replayed success after application remains already applied" do
    order = create_customer_order!()
    payment_intent = create_submitted_payment_intent!(order.id, "pi_success_replayed")
    success = outcome_observation(payment_intent, :authoritative_success, "succeeded")
    assert {:ok, success_evidence} = ObservationEvidence.record(payment_intent, success)

    assert {:ok, %{outcome: :authoritative_success}} =
             Facade.apply_observed_payment_outcome_for_system(%{
               payment_intent: payment_intent,
               observation: success,
               evidence: success_evidence
             })

    assert {:ok, replay_evidence} = ObservationEvidence.record(payment_intent, success)

    assert {:ok, %{outcome: :already_applied_success}} =
             Facade.apply_observed_payment_outcome_for_system(%{
               payment_intent: payment_intent,
               observation: success,
               evidence: replay_evidence
             })

    assert :succeeded == fetch_payment_intent!(payment_intent.id).state
    assert :paid == fetch_order!(order.id).state
    assert 1 == Repo.aggregate(PaymentApplication, :count, :id)
  end

  test "a succeeded payment intent cannot transition back to failed" do
    order = create_customer_order!()
    payment_intent = create_submitted_payment_intent!(order.id)

    payment_intent
    |> Ash.Changeset.for_update(:mark_succeeded, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    assert {:error, _reason} =
             payment_intent
             |> Ash.Changeset.for_update(:mark_failed, %{}, context: %{system?: true})
             |> Ash.update(domain: Store.Payments, authorize?: false, context: %{system?: true})

    assert :succeeded == fetch_payment_intent!(payment_intent.id).state
  end

  test "concurrent success applications preserve one exact payment application" do
    order = create_customer_order!()
    payment_intent = create_submitted_payment_intent!(order.id)
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Sandbox.allow(Store.Repo, parent, self())
          Sandbox.allow(Store.DirectRepo, parent, self())
          Store.Payments.apply_payment_success_once(payment_intent.id)
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 15_000))
    assert Enum.all?(results, &match?({:ok, _}, &1))

    assert 1 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.count!(domain: Store.Orders, authorize?: false)

    assert :succeeded == fetch_payment_intent!(payment_intent.id).state
    assert :paid == fetch_order!(order.id).state
  end

  test "terminal failure and success evidence racing requires reconciliation" do
    order = create_customer_order!()

    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        order_id: order.id,
        amount_received_minor: 1_000,
        currency: "USD",
        provider: :stripe,
        provider_payment_id: "pi_terminal_race"
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)
      |> submit_payment_intent!()

    terminal_observation = outcome_observation(payment_intent, :failure_observation, "canceled")
    success_observation = outcome_observation(payment_intent, :authoritative_success, "succeeded")

    assert {:ok, terminal_evidence} =
             ObservationEvidence.record(payment_intent, terminal_observation)

    assert {:ok, success_evidence} =
             ObservationEvidence.record(payment_intent, success_observation)

    terminal_result = %{
      payment_intent: payment_intent,
      observation: terminal_observation,
      evidence: terminal_evidence
    }

    success_result = %{
      payment_intent: payment_intent,
      observation: success_observation,
      evidence: success_evidence
    }

    parent = self()
    start = make_ref()

    tasks =
      Enum.map([terminal_result, success_result], fn result ->
        Task.async(fn ->
          Sandbox.allow(Store.Repo, parent, self())
          Sandbox.allow(Store.DirectRepo, parent, self())
          send(parent, {:ready, start})
          receive do: ({:go, ^start} -> :ok)
          Facade.apply_observed_payment_outcome_for_system(result)
        end)
      end)

    assert_receive {:ready, ^start}
    assert_receive {:ready, ^start}
    send(Enum.at(tasks, 0).pid, {:go, start})
    send(Enum.at(tasks, 1).pid, {:go, start})
    Enum.each(tasks, &Task.await(&1, 15_000))

    assert :submitted == fetch_payment_intent!(payment_intent.id).state
    assert :pending_payment == fetch_order!(order.id).state
    assert 0 == Repo.aggregate(PaymentApplication, :count, :id)
    assert 2 == Repo.aggregate(Store.Payments.PaymentAttempt, :count, :id)
  end

  defp outcome_observation(payment_intent, outcome, status) do
    %ProviderObservation{
      provider: :stripe,
      provider_reference: payment_intent.provider_payment_id,
      provider_reference_kind: :payment_intent,
      provider_transaction_id: payment_intent.provider_payment_id,
      local_payment_intent_id: payment_intent.id,
      observation_source: :verification,
      normalized_outcome: outcome,
      raw_provider_status: status,
      amount_minor: 1_000,
      currency: "USD",
      provider_environment: "test",
      observed_at: DateTime.utc_now()
    }
  end

  test "create_or_reuse_payment_intent fails closed for missing or unsupported provider" do
    order = create_order!()

    assert {:error, %Error{code: "PAYMENT_PROVIDER_SELECTION_REQUIRED"}} =
             Store.Payments.create_or_reuse_payment_intent(%{
               order_id: order.id,
               amount_received_minor: 10_000,
               currency: "USD"
             })

    assert {:error, %Error{code: "PAYMENT_PROVIDER_UNSUPPORTED"}} =
             Store.Payments.create_or_reuse_payment_intent(%{
               order_id: order.id,
               amount_received_minor: 10_000,
               currency: "USD",
               provider: "nope"
             })

    assert 0 ==
             PaymentIntent
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.count!(domain: Store.Payments, authorize?: false)
  end

  test "create_or_reuse_payment_intent fails closed for disabled providers" do
    Application.put_env(:store, :payments,
      enabled_providers: [],
      stripe: [webhook_secret: "whsec_test_only_change_me"]
    )

    order = create_order!()

    assert {:error, %Error{code: "PAYMENT_PROVIDER_DISABLED"}} =
             Store.Payments.create_or_reuse_payment_intent(%{
               order_id: order.id,
               amount_received_minor: 10_000,
               currency: "USD",
               provider: "stripe"
             })

    assert 0 ==
             PaymentIntent
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.count!(domain: Store.Payments, authorize?: false)
  end

  defp create_order! do
    Order
    |> Ash.Changeset.for_create(:create, %{})
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp create_physical_variant! do
    unique = System.unique_integer([:positive])

    product =
      Product
      |> Ash.Changeset.for_create(:create_draft, %{
        slug: "jc281-physical-checkout-#{unique}",
        title: "JC281 physical checkout #{unique}",
        base_variant_sku: "JC281-PHYSICAL-#{unique}",
        base_variant_currency_code: "USD",
        base_variant_price_minor: 1_000,
        base_variant_stock_on_hand: 4
      })
      |> Ash.create!(domain: Store.Catalog, authorize?: false)

    product
    |> Ash.Changeset.for_update(:publish, %{})
    |> Ash.update!(domain: Store.Catalog, authorize?: false)
    |> Map.fetch!(:default_variant_id)
  end

  defp create_physical_order_line_item!(order_id, variant_id) do
    OrderLineItem
    |> Ash.Changeset.for_create(:create, %{
      order_id: order_id,
      line_no: 1,
      currency: "USD",
      quantity: 1,
      unit_price_minor: 1_000,
      line_total_minor: 1_000,
      sku_snapshot: "JC281-PHYSICAL-CHECKOUT",
      product_title_snapshot: "JC281 physical checkout",
      variant_title_snapshot: "Default",
      variant_id_snapshot: variant_id,
      discount_allocated_minor: 0,
      net_line_total_minor: 1_000
    })
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp create_customer_order! do
    %{order: order} =
      OrderFixtures.create_customer_order!(
        email: TestFixtures.unique_email("checkout_interlocks_customer")
      )

    order
  end

  defp create_submitted_payment_intent!(order_id) do
    PaymentIntent
    |> Ash.Changeset.for_create(
      :create,
      %{order_id: order_id, amount_received_minor: 1_000, provider: :stripe}
    )
    |> Ash.create!(domain: Store.Payments, authorize?: false)
    |> submit_payment_intent!()
  end

  defp create_submitted_payment_intent!(order_id, provider_payment_id) do
    PaymentIntent
    |> Ash.Changeset.for_create(:create, %{
      order_id: order_id,
      amount_received_minor: 1_000,
      currency: "USD",
      provider: :stripe,
      provider_payment_id: provider_payment_id
    })
    |> Ash.create!(domain: Store.Payments, authorize?: false)
    |> submit_payment_intent!()
  end

  defp submit_payment_intent!(payment_intent) do
    payment_intent
    |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp mark_succeeded_payment_intent!(payment_intent) do
    payment_intent
    |> Ash.Changeset.for_update(:mark_succeeded, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp fetch_order!(id) do
    assert {:ok, [order]} =
             Order
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Orders, authorize?: false)

    order
  end

  defp fetch_payment_intent!(id) do
    assert {:ok, [payment_intent]} =
             PaymentIntent
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    payment_intent
  end

  defp sequence_generator(sequence) do
    parent = self()
    ref = make_ref()
    send(parent, {ref, sequence})

    fn ->
      receive do
        {^ref, [next | rest]} ->
          send(parent, {ref, rest})
          next
      after
        0 ->
          raise "sequence exhausted for order_ref generator"
      end
    end
  end
end
