defmodule Store.Subscriptions.Facade do
  @moduledoc """
  Subscription surfaces for user/admin reads and system orchestration.
  """

  import Ash.Expr
  require Ash.Query

  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Orders.Order
  alias Store.Orders.OrderLineItem
  alias Store.Payments.{PaymentIntent, Providers}
  alias Store.Repo
  alias Store.Subscriptions

  alias Store.Subscriptions.Queries.{
    AdminSubscriptionIndexQuery,
    UserSubscriptionIndexQuery
  }

  alias Store.Subscriptions.{
    RenewalAttempt,
    Scheduler,
    Subscription,
    SubscriptionItem,
    SubscriptionPlan,
    VariantSubscriptionPlan
  }

  alias Store.Support.Errors.{Error, Normalize}

  @default_due_limit 100

  @spec list_subscriptions_for_user(map(), UserSubscriptionIndexQuery.t()) ::
          {:ok, [Subscription.t()]} | {:error, Error.t() | term()}
  def list_subscriptions_for_user(actor, %UserSubscriptionIndexQuery{} = query)
      when is_map(actor) do
    ash_query =
      Subscription
      |> Ash.Query.for_read(:read_for_user, %{}, actor: actor)
      |> maybe_filter_subscription_status(query.status)
      |> Ash.Query.limit(query.limit)
      |> Ash.Query.offset(query.offset)

    case Ash.read(ash_query, domain: Subscriptions, actor: actor) do
      {:ok, subscriptions} ->
        case Ash.load(subscriptions, [:subscription_plan],
               domain: Subscriptions,
               authorize?: false,
               context: %{system?: true}
             ) do
          {:ok, loaded} ->
            loaded
            |> maybe_filter_subscription_plan_key(query.plan_key)
            |> then(&{:ok, &1})

          {:error, reason} ->
            {:error, Normalize.normalize(reason)}
        end

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def list_subscriptions_for_user(_actor, _query) do
    {:error, Error.new("VALIDATION_ERROR", "actor and user subscription query are required")}
  end

  @spec get_subscription_for_user(map(), Ecto.UUID.t()) ::
          {:ok, Subscription.t() | nil} | {:error, Error.t() | term()}
  def get_subscription_for_user(actor, subscription_id)
      when is_map(actor) and is_binary(subscription_id) do
    ash_query =
      Subscription
      |> Ash.Query.for_read(:get_for_user, %{id: subscription_id}, actor: actor)

    case Ash.read_one(ash_query, domain: Subscriptions, actor: actor) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, %Subscription{} = subscription} ->
        subscription
        |> Ash.load([:subscription_plan, :items],
          domain: Subscriptions,
          authorize?: false,
          context: %{system?: true}
        )
        |> case do
          {:ok, loaded} -> {:ok, loaded}
          {:error, reason} -> {:error, Normalize.normalize(reason)}
        end

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def get_subscription_for_user(_actor, _subscription_id) do
    {:error, Error.new("VALIDATION_ERROR", "actor and subscription_id are required")}
  end

  @spec list_subscriptions_for_admin(map(), AdminSubscriptionIndexQuery.t()) ::
          {:ok, [Subscription.t()]} | {:error, Error.t() | term()}
  def list_subscriptions_for_admin(actor, %AdminSubscriptionIndexQuery{} = query)
      when is_map(actor) do
    ash_query =
      Subscription
      |> Ash.Query.for_read(:read_for_admin, %{}, actor: actor)
      |> maybe_filter_subscription_status(query.status)
      |> maybe_filter_subscription_user(query.user_id)
      |> Ash.Query.limit(query.limit)
      |> Ash.Query.offset(query.offset)
      |> Ash.Query.load([:subscription_plan])

    case Ash.read(ash_query, domain: Subscriptions, actor: actor) do
      {:ok, subscriptions} ->
        subscriptions
        |> maybe_filter_subscription_plan_key(query.plan_key)
        |> then(&{:ok, &1})

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def list_subscriptions_for_admin(_actor, _query) do
    {:error, Error.new("VALIDATION_ERROR", "actor and admin subscription query are required")}
  end

  @spec get_subscription_for_admin(map(), Ecto.UUID.t()) ::
          {:ok, Subscription.t() | nil} | {:error, Error.t() | term()}
  def get_subscription_for_admin(actor, subscription_id)
      when is_map(actor) and is_binary(subscription_id) do
    ash_query =
      Subscription
      |> Ash.Query.for_read(:get_for_admin, %{id: subscription_id}, actor: actor)
      |> Ash.Query.load([:subscription_plan, :items])

    case Ash.read_one(ash_query, domain: Subscriptions, actor: actor) do
      {:ok, subscription} -> {:ok, subscription}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  def get_subscription_for_admin(_actor, _subscription_id) do
    {:error, Error.new("VALIDATION_ERROR", "actor and subscription_id are required")}
  end

  @spec resolve_variant_subscription_plan_for_system(Ecto.UUID.t(), Ecto.UUID.t() | nil) ::
          {:ok, SubscriptionPlan.t() | nil} | {:error, Error.t() | term()}
  def resolve_variant_subscription_plan_for_system(variant_id, explicit_plan_id \\ nil)

  def resolve_variant_subscription_plan_for_system(variant_id, explicit_plan_id)
      when is_binary(variant_id) do
    query =
      VariantSubscriptionPlan
      |> Ash.Query.for_read(:read_active_for_variant, %{variant_id: variant_id})
      |> Ash.Query.load([:subscription_plan])

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, []} ->
        {:ok, nil}

      {:ok, plans} when is_binary(explicit_plan_id) ->
        match =
          Enum.find(plans, fn plan ->
            plan.subscription_plan_id == explicit_plan_id
          end)

        if match do
          {:ok, match.subscription_plan}
        else
          {:error,
           Error.new(
             "VALIDATION_ERROR",
             "subscription_plan_id is not active for the selected variant"
           )}
        end

      {:ok, [single]} ->
        {:ok, single.subscription_plan}

      {:ok, _many} ->
        {:error,
         Error.new(
           "VALIDATION_ERROR",
           "variant has multiple active subscription plans; explicit subscription_plan_id is required"
         )}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def resolve_variant_subscription_plan_for_system(_variant_id, _explicit_plan_id) do
    {:error, Error.new("VALIDATION_ERROR", "variant_id must be a UUID")}
  end

  @spec order_has_subscription_lines_for_system(Ecto.UUID.t()) ::
          {:ok, boolean()} | {:error, Error.t() | term()}
  def order_has_subscription_lines_for_system(order_id) when is_binary(order_id) do
    with {:ok, line_items} <- fetch_subscription_order_line_items(order_id) do
      {:ok, line_items != []}
    end
  end

  def order_has_subscription_lines_for_system(_order_id) do
    {:error, Error.new("VALIDATION_ERROR", "order_id must be a UUID")}
  end

  @spec order_is_subscription_only_for_system(Ecto.UUID.t()) ::
          {:ok, boolean()} | {:error, Error.t() | term()}
  def order_is_subscription_only_for_system(order_id) when is_binary(order_id) do
    with {:ok, line_items} <- fetch_all_order_line_items(order_id) do
      subscription_line_count =
        Enum.count(line_items, fn line_item ->
          is_binary(Map.get(line_item, :subscription_plan_id_snapshot))
        end)

      {:ok, line_items != [] and subscription_line_count == length(line_items)}
    end
  end

  def order_is_subscription_only_for_system(_order_id) do
    {:error, Error.new("VALIDATION_ERROR", "order_id must be a UUID")}
  end

  @spec create_subscriptions_from_paid_order_for_system(Ecto.UUID.t()) ::
          {:ok,
           %{
             order_id: Ecto.UUID.t(),
             subscription_line_count: non_neg_integer(),
             created_count: non_neg_integer(),
             skipped_count: non_neg_integer(),
             entitlement_issued_count: non_neg_integer()
           }}
          | {:error, Error.t() | term()}
  def create_subscriptions_from_paid_order_for_system(order_id) when is_binary(order_id) do
    with {:ok, order} <- fetch_paid_order(order_id),
         :ok <- ensure_order_user(order),
         {:ok, line_items} <- fetch_subscription_order_line_items(order.id),
         {:ok, result} <- build_subscription_creation_result(order, line_items) do
      {:ok,
       %{
         order_id: order.id,
         subscription_line_count: length(line_items),
         created_count: result.created,
         skipped_count: result.skipped,
         entitlement_issued_count: result.entitlements
       }}
    end
  end

  def create_subscriptions_from_paid_order_for_system(_order_id) do
    {:error, Error.new("VALIDATION_ERROR", "order_id must be a UUID")}
  end

  defp build_subscription_creation_result(order, line_items) do
    Enum.reduce_while(
      line_items,
      {:ok, %{created: 0, skipped: 0, entitlements: 0}},
      fn line_item, {:ok, acc} ->
        case create_subscription_from_line(order, line_item) do
          {:ok, :created, entitlement_issued?} ->
            updated =
              %{
                created: acc.created + 1,
                skipped: acc.skipped,
                entitlements: acc.entitlements + if(entitlement_issued?, do: 1, else: 0)
              }

            {:cont, {:ok, updated}}

          {:ok, :skipped, _entitlement_issued?} ->
            {:cont, {:ok, %{acc | skipped: acc.skipped + 1}}}

          {:error, reason} ->
            {:halt, {:error, Normalize.normalize(reason)}}
        end
      end
    )
  end

  @spec cancel_subscription_for_user(map(), Ecto.UUID.t(), :now | :period_end) ::
          {:ok, Subscription.t()} | {:error, Error.t() | term()}
  def cancel_subscription_for_user(actor, subscription_id, mode \\ :period_end)

  def cancel_subscription_for_user(actor, subscription_id, mode)
      when is_map(actor) and is_binary(subscription_id) and mode in [:now, :period_end] do
    with {:ok, %Subscription{} = subscription} <-
           get_subscription_for_user(actor, subscription_id),
         {:ok, canceled} <- run_cancel(subscription, mode, actor) do
      {:ok, canceled}
    else
      {:ok, nil} ->
        {:error, Error.new("SUBSCRIPTION_NOT_FOUND", "subscription not found")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def cancel_subscription_for_user(_actor, _subscription_id, _mode) do
    {:error, Error.new("VALIDATION_ERROR", "invalid cancel subscription request")}
  end

  @spec cancel_subscription_for_admin(map(), Ecto.UUID.t(), :now | :period_end) ::
          {:ok, Subscription.t()} | {:error, Error.t() | term()}
  def cancel_subscription_for_admin(actor, subscription_id, mode \\ :period_end)

  def cancel_subscription_for_admin(actor, subscription_id, mode)
      when is_map(actor) and is_binary(subscription_id) and mode in [:now, :period_end] do
    with {:ok, %Subscription{} = subscription} <-
           get_subscription_for_admin(actor, subscription_id),
         {:ok, canceled} <- run_cancel(subscription, mode, actor) do
      {:ok, canceled}
    else
      {:ok, nil} ->
        {:error, Error.new("SUBSCRIPTION_NOT_FOUND", "subscription not found")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def cancel_subscription_for_admin(_actor, _subscription_id, _mode) do
    {:error, Error.new("VALIDATION_ERROR", "invalid cancel subscription request")}
  end

  @spec run_due_renewals_for_system(keyword()) ::
          {:ok,
           %{
             due_count: non_neg_integer(),
             success_count: non_neg_integer(),
             failed_count: non_neg_integer()
           }}
          | {:error, Error.t() | term()}
  def run_due_renewals_for_system(opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    limit = Keyword.get(opts, :limit, @default_due_limit)

    query = Subscription |> Ash.Query.for_read(:read_due_for_system, %{now: now, limit: limit})

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, due_subscriptions} ->
        result = count_due_renewal_results(due_subscriptions, now)

        {:ok,
         %{
           due_count: length(due_subscriptions),
           success_count: result.success,
           failed_count: result.failed
         }}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp count_due_renewal_results(due_subscriptions, now) do
    Enum.reduce(due_subscriptions, %{success: 0, failed: 0}, fn subscription, acc ->
      case run_single_due_renewal(subscription, now) do
        :ok -> %{success: acc.success + 1, failed: acc.failed}
        {:error, _reason} -> %{success: acc.success, failed: acc.failed + 1}
      end
    end)
  end

  defp run_single_due_renewal(%Subscription{} = subscription, now) do
    with {:ok, plan} <- fetch_plan(subscription.subscription_plan_id),
         :continue <- maybe_expire_past_due(subscription, plan, now),
         {:ok, renewal_period} <- renewal_period(subscription, plan, now),
         renewal_key <-
           Scheduler.renewal_key(subscription.id, renewal_period.current_period_end_at),
         {:ok, attempt} <-
           create_or_reuse_renewal_attempt(subscription, renewal_period, renewal_key) do
      result =
        case claim_renewal_attempt(attempt) do
          :ok ->
            run_claimed_due_renewal(subscription, plan, renewal_period, attempt)

          {:skip, :already_claimed} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      case result do
        :ok ->
          :ok

        {:error, %Error{} = error} ->
          mark_subscription_past_due(subscription, error)
          {:error, error}

        {:error, reason} ->
          mark_subscription_past_due(subscription, reason)
          {:error, reason}
      end
    else
      :expired ->
        :ok

      {:error, %Error{} = error} ->
        mark_subscription_past_due(subscription, error)
        {:error, error}

      {:error, reason} ->
        mark_subscription_past_due(subscription, reason)
        {:error, reason}
    end
  end

  defp run_claimed_due_renewal(subscription, plan, renewal_period, attempt) do
    with :ok <- ensure_renewal_chargeability(subscription, plan),
         {:ok, updated_subscription} <- extend_subscription_period(subscription, renewal_period),
         :ok <- maybe_sync_entitlement(updated_subscription, plan),
         {:ok, _updated_attempt} <- mark_attempt_succeeded(attempt) do
      :ok
    else
      {:error, reason} ->
        _ = mark_attempt_failed(attempt, reason)
        mark_subscription_past_due(subscription, reason)
        {:error, reason}
    end
  end

  defp fetch_paid_order(order_id) do
    query = Order |> Ash.Query.filter(expr(id == ^order_id))

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, [%Order{state: :paid} = order | _]} ->
        {:ok, order}

      {:ok, [%Order{}]} ->
        {:error,
         Error.new(
           "INVALID_STATE_TRANSITION",
           "order must be paid before subscription activation"
         )}

      {:ok, []} ->
        {:error, Error.new("ORDER_NOT_FOUND", "order not found")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_order_user(%Order{user_id: user_id}) when is_binary(user_id), do: :ok

  defp ensure_order_user(%Order{}) do
    {:error, Error.new("VALIDATION_ERROR", "subscriptions require an authenticated user")}
  end

  defp fetch_subscription_order_line_items(order_id) do
    query =
      OrderLineItem
      |> Ash.Query.filter(
        expr(order_id == ^order_id and not is_nil(subscription_plan_id_snapshot))
      )
      |> Ash.Query.sort(line_no: :asc)

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, line_items} -> {:ok, line_items}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_all_order_line_items(order_id) do
    query =
      OrderLineItem
      |> Ash.Query.filter(expr(order_id == ^order_id))
      |> Ash.Query.sort(line_no: :asc)

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, line_items} -> {:ok, line_items}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp create_subscription_from_line(%Order{} = order, %OrderLineItem{} = line_item) do
    with {:ok, nil} <- fetch_subscription_by_source_line(line_item.id),
         {:ok, plan} <- fetch_plan(Map.get(line_item, :subscription_plan_id_snapshot)),
         {:ok, provider_selection} <- resolve_provider_and_billing_mode(order, plan),
         period <-
           Scheduler.initial_period(DateTime.utc_now() |> DateTime.truncate(:microsecond), plan),
         {:ok, subscription} <-
           create_subscription_record(order, line_item, plan, period, provider_selection),
         {:ok, _item} <- create_subscription_item_record(subscription, line_item, plan),
         entitlement_result <- maybe_issue_entitlement(subscription, plan) do
      {:ok, :created, entitlement_result == :issued}
    else
      {:ok, %Subscription{}} ->
        {:ok, :skipped, false}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_subscription_by_source_line(source_order_line_item_id) do
    query =
      Subscription
      |> Ash.Query.filter(expr(source_order_line_item_id == ^source_order_line_item_id))

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [subscription | _]} -> {:ok, subscription}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_plan(plan_id) when is_binary(plan_id) do
    query = SubscriptionPlan |> Ash.Query.filter(expr(id == ^plan_id))

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [%SubscriptionPlan{} = plan | _]} -> {:ok, plan}
      {:ok, []} -> {:error, Error.new("NOT_FOUND", "subscription plan not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_plan(_plan_id), do: {:error, Error.new("VALIDATION_ERROR", "plan_id must be a UUID")}

  defp resolve_provider_and_billing_mode(%Order{} = order, _plan) do
    with {:ok, %PaymentIntent{} = payment_intent} <- fetch_succeeded_payment_intent(order.id),
         {:ok, provider} <- normalize_selected_provider(payment_intent.provider),
         {:ok, capabilities} <- fetch_provider_capabilities(provider),
         {:ok, billing_mode} <- choose_billing_mode(capabilities) do
      {:ok, %{provider: provider, billing_mode: billing_mode}}
    end
  end

  defp fetch_succeeded_payment_intent(order_id) when is_binary(order_id) do
    query =
      PaymentIntent
      |> Ash.Query.filter(expr(order_id == ^order_id and state == :succeeded))
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: Store.Payments, authorize?: false, context: %{system?: true}) do
      {:ok, [%PaymentIntent{} = payment_intent | _]} ->
        {:ok, payment_intent}

      {:ok, []} ->
        {:error,
         Error.new(
           "SUBSCRIPTION_PROVIDER_SELECTION_REQUIRED",
           "subscription provider selection is missing for paid order"
         )}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_succeeded_payment_intent(_order_id) do
    {:error, Error.new("VALIDATION_ERROR", "order_id must be a UUID")}
  end

  defp normalize_selected_provider(provider) do
    case Providers.normalize_provider(provider) do
      known when known in [:stripe, :payfast, :paystack, :yoco, :peach_payments] ->
        {:ok, known}

      :unknown ->
        {:error,
         Error.new("SUBSCRIPTION_PROVIDER_UNSUPPORTED", "subscription provider is unsupported")}
    end
  end

  defp fetch_provider_capabilities(provider) do
    case Providers.capabilities(provider) do
      capabilities when is_map(capabilities) ->
        {:ok, capabilities}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp choose_billing_mode(capabilities) when is_map(capabilities) do
    provider_managed_enabled? = subscription_feature_enabled?(:provider_managed_mode_enabled?)

    supports_provider_managed? =
      Map.get(capabilities, :supports_provider_managed_subscriptions?, false)

    supports_merchant_managed? =
      Map.get(capabilities, :supports_merchant_initiated_charges?, false)

    cond do
      provider_managed_enabled? and supports_provider_managed? ->
        {:ok, :provider_managed}

      supports_merchant_managed? ->
        {:ok, :merchant_managed}

      supports_provider_managed? and not provider_managed_enabled? ->
        {:error,
         Error.new(
           "SUBSCRIPTION_PROVIDER_MODE_DISABLED",
           "provider-managed subscriptions are disabled by feature flag"
         )}

      true ->
        {:error,
         Error.new(
           "SUBSCRIPTION_BILLING_MODE_UNSUPPORTED",
           "provider capabilities do not support subscription billing"
         )}
    end
  end

  defp subscription_feature_enabled?(key) when is_atom(key) do
    :store
    |> Application.get_env(:subscription_features, [])
    |> Keyword.get(key, false)
  end

  defp create_subscription_record(order, line_item, plan, period, provider_selection) do
    attrs = %{
      user_id: order.user_id,
      subscription_plan_id: plan.id,
      status: :active,
      provider: provider_selection.provider,
      billing_mode: provider_selection.billing_mode,
      started_at: period.current_period_start_at,
      current_period_start_at: period.current_period_start_at,
      current_period_end_at: period.current_period_end_at,
      next_renewal_at: period.next_renewal_at,
      source_order_id: order.id,
      source_order_line_item_id: line_item.id
    }

    Subscription
    |> Ash.Changeset.for_create(:create_from_order_line, attrs, context: %{system?: true})
    |> Ash.create(domain: Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp create_subscription_item_record(subscription, line_item, plan) do
    attrs = %{
      subscription_id: subscription.id,
      variant_id: line_item.variant_id_snapshot,
      quantity: line_item.quantity,
      plan_key_snapshot: plan.key,
      amount_minor_snapshot: plan.amount_minor,
      currency_snapshot: plan.currency,
      interval_unit_snapshot: plan.interval_unit,
      interval_count_snapshot: plan.interval_count,
      source_order_line_item_id: line_item.id
    }

    SubscriptionItem
    |> Ash.Changeset.for_create(:create_from_order_line, attrs, context: %{system?: true})
    |> Ash.create(domain: Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp maybe_issue_entitlement(subscription, plan) do
    if is_nil(plan.entitlement_kind) do
      :skipped
    else
      case EntitlementsFacade.issue_subscription_entitlement_for_system(subscription, plan) do
        {:ok, _grant} -> :issued
        {:error, _reason} -> :skipped
      end
    end
  end

  defp maybe_sync_entitlement(subscription, plan) do
    if is_nil(plan.entitlement_kind) do
      :ok
    else
      case EntitlementsFacade.issue_subscription_entitlement_for_system(subscription, plan) do
        {:ok, _grant} -> :ok
        {:error, reason} -> {:error, Normalize.normalize(reason)}
      end
    end
  end

  defp run_cancel(subscription, :period_end, actor) do
    subscription
    |> Ash.Changeset.for_update(:cancel_at_period_end_transition, %{})
    |> Ash.update(domain: Subscriptions, actor: actor)
    |> normalize_result()
  end

  defp run_cancel(subscription, :now, actor) do
    with {:ok, canceled} <-
           subscription
           |> Ash.Changeset.for_update(:cancel_now_transition, %{canceled_reason: "user_request"})
           |> Ash.update(domain: Subscriptions, actor: actor)
           |> normalize_result() do
      _ =
        EntitlementsFacade.revoke_subscription_entitlements_for_system(
          canceled.id,
          "canceled_now"
        )

      {:ok, canceled}
    end
  end

  defp renewal_period(subscription, plan, now) do
    period_start =
      subscription.current_period_end_at || subscription.current_period_start_at ||
        subscription.started_at || now

    if match?(%DateTime{}, period_start) do
      {:ok, Scheduler.next_period(period_start, plan)}
    else
      {:error, Error.new("VALIDATION_ERROR", "subscription period anchors are missing")}
    end
  end

  defp create_or_reuse_renewal_attempt(subscription, period, renewal_key) do
    attrs = %{
      subscription_id: subscription.id,
      period_start_at: period.current_period_start_at,
      period_end_at: period.current_period_end_at,
      renewal_key: renewal_key,
      status: :pending
    }

    RenewalAttempt
    |> Ash.Changeset.for_create(:create_or_reuse, attrs, context: %{system?: true})
    |> Ash.create(domain: Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp claim_renewal_attempt(%RenewalAttempt{id: attempt_id, updated_at: updated_at})
       when is_binary(attempt_id) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)

    with {:ok, attempt_uuid} <- Ecto.UUID.dump(attempt_id),
         {:ok, previous_updated_at} <- to_naive_datetime(updated_at) do
      case Repo.query(
             "UPDATE renewal_attempts SET updated_at = $2 WHERE id = $1 AND status IN ('pending', 'failed') AND updated_at = $3",
             [attempt_uuid, now, previous_updated_at]
           ) do
        {:ok, %{num_rows: 1}} ->
          :ok

        {:ok, _result} ->
          {:skip, :already_claimed}

        {:error, reason} ->
          {:error, Normalize.normalize(reason)}
      end
    else
      :error ->
        {:error, Error.new("VALIDATION_ERROR", "renewal attempt id must be a UUID")}

      {:error, _reason} ->
        {:error, Error.new("VALIDATION_ERROR", "renewal attempt updated_at is required")}
    end
  end

  defp to_naive_datetime(%DateTime{} = value), do: {:ok, DateTime.to_naive(value)}
  defp to_naive_datetime(%NaiveDateTime{} = value), do: {:ok, value}
  defp to_naive_datetime(_value), do: {:error, :invalid_datetime}

  defp mark_attempt_failed(%RenewalAttempt{} = attempt, reason) do
    {failure_code, failure_message} =
      case reason do
        %Error{code: code, message: message} ->
          {code, message}

        other ->
          {"INTERNAL_ERROR", inspect(other)}
      end

    attempt_no = max((attempt.attempt_no || 1) + 1, 1)

    attrs = %{
      failure_code: failure_code,
      failure_message: failure_message,
      attempt_no: attempt_no
    }

    case attempt
         |> Ash.Changeset.for_update(:mark_failed, attrs, context: %{system?: true})
         |> Ash.update(domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, _updated_attempt} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp ensure_renewal_chargeability(subscription, _plan) do
    if is_binary(subscription.provider_billing_ref) do
      :ok
    else
      {:error,
       Error.new(
         "SUBSCRIPTION_MISSING_BILLING_REFERENCE",
         "subscription cannot renew without provider_billing_ref"
       )}
    end
  end

  defp maybe_expire_past_due(%Subscription{status: :past_due} = subscription, plan, now) do
    case subscription.past_due_since_at do
      %DateTime{} = past_due_since_at ->
        grace_expires_at = Scheduler.grace_expires_at(past_due_since_at, plan)

        if DateTime.compare(now, grace_expires_at) in [:gt, :eq] do
          expire_past_due_subscription(subscription)
        else
          :continue
        end

      _ ->
        :continue
    end
  end

  defp maybe_expire_past_due(%Subscription{}, _plan, _now), do: :continue

  defp expire_past_due_subscription(subscription) do
    case subscription
         |> Ash.Changeset.for_update(
           :mark_expired_transition,
           %{canceled_reason: "grace_expired"},
           context: %{system?: true}
         )
         |> Ash.update(domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, expired} ->
        _ =
          EntitlementsFacade.revoke_subscription_entitlements_for_system(
            expired.id,
            "grace_expired"
          )

        :expired

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp extend_subscription_period(subscription, period) do
    attrs = %{
      current_period_start_at: period.current_period_start_at,
      current_period_end_at: period.current_period_end_at,
      next_renewal_at: period.next_renewal_at
    }

    subscription
    |> Ash.Changeset.for_update(:extend_period, attrs, context: %{system?: true})
    |> Ash.update(domain: Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp mark_attempt_succeeded(attempt) do
    attempt
    |> Ash.Changeset.for_update(:mark_succeeded, %{}, context: %{system?: true})
    |> Ash.update(domain: Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp mark_subscription_past_due(subscription, reason) do
    message =
      case reason do
        %Error{code: code} -> code
        other -> inspect(other)
      end

    _ =
      subscription
      |> Ash.Changeset.for_update(
        :mark_past_due_transition,
        %{billing_status_reason: message},
        context: %{system?: true}
      )
      |> Ash.update(domain: Subscriptions, authorize?: false, context: %{system?: true})

    :ok
  end

  defp maybe_filter_subscription_status(query, nil), do: query

  defp maybe_filter_subscription_status(query, status),
    do: Ash.Query.filter(query, expr(status == ^status))

  defp maybe_filter_subscription_user(query, nil), do: query

  defp maybe_filter_subscription_user(query, user_id),
    do: Ash.Query.filter(query, expr(user_id == ^user_id))

  defp maybe_filter_subscription_plan_key(subscriptions, nil), do: subscriptions

  defp maybe_filter_subscription_plan_key(subscriptions, plan_key) do
    Enum.filter(subscriptions, fn subscription ->
      case Map.get(subscription, :subscription_plan) do
        %{key: key} when is_binary(key) -> key == plan_key
        _ -> false
      end
    end)
  end

  defp normalize_result({:ok, _} = result), do: result
  defp normalize_result({:error, reason}), do: {:error, Normalize.normalize(reason)}
end
