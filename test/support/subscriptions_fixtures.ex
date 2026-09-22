defmodule Store.SubscriptionsFixtures do
  @moduledoc false

  import Ash.Expr
  require Ash.Query

  alias Store.Catalog.{Product, Variant}
  alias Store.Orders.{Order, OrderLineItem}
  alias Store.Payments.PaymentIntent

  alias Store.Subscriptions.{
    Scheduler,
    StoredPaymentMethod,
    Subscription,
    SubscriptionItem,
    SubscriptionPlan,
    VariantSubscriptionPlan
  }

  alias Store.TestFixtures

  @spec create_customer!(String.t()) :: Store.Accounts.User.t()
  def create_customer!(prefix \\ "phase26_sub_customer") do
    TestFixtures.register_user!(email: TestFixtures.unique_email(prefix))
  end

  @spec create_subscription_sellable!(map()) :: %{product: Product.t(), variant: Variant.t()}
  def create_subscription_sellable!(overrides \\ %{}) when is_map(overrides) do
    unique = System.unique_integer([:positive])
    publish? = Map.get(overrides, :published?, true)

    attrs =
      %{
        slug: "phase26-sub-product-#{unique}",
        title: "Phase 26 Subscription Product #{unique}",
        product_kind: :subscription,
        base_variant_sku: "P26-SUB-SKU-#{unique}",
        base_variant_currency_code: "USD",
        base_variant_price_minor: 1_000,
        base_variant_stock_on_hand: 100
      }
      |> Map.merge(Map.drop(overrides, [:published?]))

    created_product =
      Product
      |> Ash.Changeset.for_create(:create_draft, attrs)
      |> Ash.create!(domain: Store.Catalog, authorize?: false)

    product =
      if publish? do
        created_product
        |> Ash.Changeset.for_update(:publish, %{})
        |> Ash.update!(domain: Store.Catalog, authorize?: false)
      else
        created_product
      end

    variant =
      Variant
      |> Ash.Query.filter(expr(id == ^product.default_variant_id))
      |> Ash.read!(domain: Store.Catalog, authorize?: false)
      |> List.first()

    %{product: product, variant: variant}
  end

  @spec create_subscription_plan!(map()) :: SubscriptionPlan.t()
  def create_subscription_plan!(overrides \\ %{}) when is_map(overrides) do
    unique = System.unique_integer([:positive])

    attrs =
      %{
        key: "PLAN_#{unique}",
        name: "Plan #{unique}",
        status: :active,
        interval_unit: :month,
        interval_count: 1,
        currency: "USD",
        amount_minor: 1_999,
        anchor_mode: :start_anniversary,
        billing_timezone: "Etc/UTC",
        term_mode: :until_canceled,
        access_on_past_due: :keep_during_grace,
        access_on_cancel: :keep_until_period_end,
        grace_period_days: 7,
        max_retry_attempts: 3,
        retry_schedule_hours: [0, 24, 72]
      }
      |> Map.merge(overrides)

    SubscriptionPlan
    |> Ash.Changeset.for_create(:create, attrs, context: %{system?: true})
    |> Ash.create(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> case do
      {:ok, plan} -> plan
      {:error, error} -> raise "unable to create subscription plan fixture: #{inspect(error)}"
    end
  end

  @spec attach_variant_plan!(Ecto.UUID.t(), Ecto.UUID.t(), boolean()) ::
          VariantSubscriptionPlan.t()
  def attach_variant_plan!(variant_id, plan_id, active \\ true)
      when is_binary(variant_id) and is_binary(plan_id) do
    VariantSubscriptionPlan
    |> Ash.Changeset.for_create(
      :attach,
      %{variant_id: variant_id, subscription_plan_id: plan_id, active: active},
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  @spec create_paid_order_with_subscription_line!(
          Ecto.UUID.t(),
          Variant.t(),
          SubscriptionPlan.t(),
          map()
        ) ::
          %{order: Order.t(), line_item: OrderLineItem.t()}
  def create_paid_order_with_subscription_line!(
        user_id,
        %Variant{} = variant,
        %SubscriptionPlan{} = plan,
        overrides \\ %{}
      )
      when is_binary(user_id) and is_map(overrides) do
    order = create_paid_order!(user_id, Map.get(overrides, :currency, plan.currency))
    line_item = create_subscription_order_line!(order, variant, plan, overrides)
    _ = maybe_create_paid_payment_intent!(order, plan, overrides)
    %{order: order, line_item: line_item}
  end

  @spec create_subscription_fixture!(Ecto.UUID.t(), Variant.t(), SubscriptionPlan.t(), map()) ::
          %{
            subscription: Subscription.t(),
            item: SubscriptionItem.t(),
            order: Order.t(),
            line_item: OrderLineItem.t()
          }
  def create_subscription_fixture!(
        user_id,
        %Variant{} = variant,
        %SubscriptionPlan{} = plan,
        overrides \\ %{}
      )
      when is_binary(user_id) and is_map(overrides) do
    %{order: order, line_item: line_item} =
      create_paid_order_with_subscription_line!(user_id, variant, plan, overrides)

    started_at =
      Map.get_lazy(overrides, :started_at, fn ->
        DateTime.utc_now() |> DateTime.truncate(:microsecond)
      end)

    period = Scheduler.initial_period(started_at, plan)
    provider = Map.get(overrides, :provider, :stripe)
    stored_payment_method = maybe_create_stored_payment_method!(user_id, provider, overrides)

    subscription_attrs =
      %{
        user_id: user_id,
        subscription_plan_id: plan.id,
        variant_id: variant.id,
        status: Map.get(overrides, :status, :active),
        provider: provider,
        billing_mode: Map.get(overrides, :billing_mode, :merchant_managed),
        quantity: Map.get(overrides, :quantity, 1),
        renewal_amount_minor: Map.get(overrides, :renewal_amount_minor, plan.amount_minor),
        renewal_currency: Map.get(overrides, :renewal_currency, plan.currency),
        membership_key: Map.get(overrides, :membership_key, membership_key_for_plan(plan)),
        started_at: period.current_period_start_at,
        current_period_start_at: period.current_period_start_at,
        current_period_end_at: period.current_period_end_at,
        next_renewal_at: Map.get(overrides, :next_renewal_at, period.next_renewal_at),
        pending_variant_id: Map.get(overrides, :pending_variant_id),
        pending_subscription_plan_id: Map.get(overrides, :pending_subscription_plan_id),
        pending_renewal_amount_minor: Map.get(overrides, :pending_renewal_amount_minor),
        pending_renewal_currency: Map.get(overrides, :pending_renewal_currency),
        change_effective_at: Map.get(overrides, :change_effective_at),
        dunning_attempt_count: Map.get(overrides, :dunning_attempt_count, 0),
        next_retry_at: Map.get(overrides, :next_retry_at),
        retry_suppressed_at: Map.get(overrides, :retry_suppressed_at),
        source_order_id: order.id,
        source_order_line_item_id: line_item.id,
        provider_customer_ref:
          Map.get(overrides, :provider_customer_ref) ||
            (stored_payment_method && stored_payment_method.provider_customer_ref),
        provider_billing_ref:
          Map.get(overrides, :provider_billing_ref) ||
            (stored_payment_method && stored_payment_method.provider_payment_method_ref),
        stored_payment_method_id:
          Map.get(overrides, :stored_payment_method_id) ||
            (stored_payment_method && stored_payment_method.id)
      }

    subscription =
      Subscription
      |> Ash.Changeset.for_create(:create_from_order_line, subscription_attrs,
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    item =
      SubscriptionItem
      |> Ash.Changeset.for_create(
        :create_from_order_line,
        %{
          subscription_id: subscription.id,
          variant_id: variant.id,
          quantity: 1,
          plan_key_snapshot: plan.key,
          amount_minor_snapshot: plan.amount_minor,
          currency_snapshot: plan.currency,
          interval_unit_snapshot: plan.interval_unit,
          interval_count_snapshot: plan.interval_count,
          source_order_line_item_id: line_item.id
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    %{subscription: subscription, item: item, order: order, line_item: line_item}
  end

  defp maybe_create_paid_payment_intent!(order, plan, overrides) do
    if Map.get(overrides, :create_payment_intent?, true) do
      provider = Map.get(overrides, :provider, :stripe)
      amount_minor = Map.get(overrides, :amount_minor, plan.amount_minor)
      currency = String.upcase(Map.get(overrides, :currency, plan.currency))

      payment_intent =
        PaymentIntent
        |> Ash.Changeset.for_create(
          :create_or_reuse,
          %{
            order_id: order.id,
            amount_received_minor: amount_minor,
            currency: currency,
            provider: provider,
            provider_customer_ref: Map.get(overrides, :provider_customer_ref),
            provider_payment_method_ref: Map.get(overrides, :provider_billing_ref),
            payment_intent_key: "phase26:pi:#{order.id}:#{provider}"
          },
          context: %{system?: true}
        )
        |> Ash.create!(domain: Store.Payments, authorize?: false, context: %{system?: true})

      payment_intent
      |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
      |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
      |> Ash.Changeset.for_update(:mark_succeeded, %{}, context: %{system?: true})
      |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
    else
      :ok
    end
  end

  defp create_paid_order!(user_id, currency) do
    order_ref = "ORDP26#{System.unique_integer([:positive])}"

    order =
      Order
      |> Ash.Changeset.for_create(:create, %{order_ref: order_ref, user_id: user_id})
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    order
    |> Ash.Changeset.for_update(
      :finalize_checkout_totals,
      %{
        currency_code: String.upcase(currency || "USD"),
        grand_total_minor: 0,
        items_subtotal_minor: 0,
        shipping_total_minor: 0
      },
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
    |> then(fn finalized ->
      finalized
      |> Ash.Changeset.for_update(:mark_paid, %{}, context: %{system?: true})
      |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
    end)
  end

  defp create_subscription_order_line!(order, variant, plan, overrides) do
    quantity = Map.get(overrides, :quantity, 1)
    amount_minor = Map.get(overrides, :amount_minor, plan.amount_minor)
    currency = String.upcase(Map.get(overrides, :currency, plan.currency))
    line_no = Map.get(overrides, :line_no, 1)

    OrderLineItem
    |> Ash.Changeset.for_create(:create, %{
      order_id: order.id,
      line_no: line_no,
      currency: currency,
      quantity: quantity,
      unit_price_minor: amount_minor,
      line_total_minor: amount_minor * quantity,
      sku_snapshot: variant.sku || "P26-SUB-LINE",
      product_title_snapshot: "Phase 26 Subscription Product",
      variant_title_snapshot: variant.title || "Default",
      variant_id_snapshot: variant.id,
      subscription_plan_id_snapshot: plan.id,
      subscription_plan_key_snapshot: plan.key,
      subscription_interval_unit_snapshot: Atom.to_string(plan.interval_unit),
      subscription_interval_count_snapshot: plan.interval_count,
      discount_allocated_minor: 0,
      net_line_total_minor: amount_minor * quantity,
      tax_category_snapshot: "STANDARD",
      tax_minor: 0
    })
    |> Ash.create!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp maybe_create_stored_payment_method!(user_id, provider, overrides) do
    cond do
      is_binary(Map.get(overrides, :stored_payment_method_id)) ->
        fetch_stored_payment_method!(Map.get(overrides, :stored_payment_method_id))

      is_binary(Map.get(overrides, :provider_billing_ref)) ->
        StoredPaymentMethod
        |> Ash.Changeset.for_create(
          :create_or_reuse,
          %{
            user_id: user_id,
            provider: provider,
            provider_customer_ref:
              Map.get(overrides, :provider_customer_ref, "cust_#{String.slice(user_id, 0, 8)}"),
            provider_payment_method_ref: Map.get(overrides, :provider_billing_ref),
            status: Map.get(overrides, :stored_payment_method_status, :active),
            fingerprint:
              Map.get(
                overrides,
                :stored_payment_method_fingerprint,
                "fp_#{System.unique_integer([:positive])}"
              )
          },
          context: %{system?: true}
        )
        |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

      true ->
        nil
    end
  end

  defp fetch_stored_payment_method!(id) do
    StoredPaymentMethod
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp membership_key_for_plan(plan) do
    case {Map.get(plan, :entitlement_kind), Map.get(plan, :entitlement_scope_key)} do
      {:membership_access, scope_key} when is_binary(scope_key) and scope_key != "" ->
        scope_key

      _ ->
        nil
    end
  end
end
