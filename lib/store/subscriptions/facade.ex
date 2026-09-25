defmodule Store.Subscriptions.Facade do
  @moduledoc """
  Subscription surfaces for user/admin reads and system orchestration.
  """

  import Ash.Expr
  import Ecto.Query
  require Ash.Query

  alias Store.Carts.CartItem
  alias Store.Catalog.{Product, Variant}
  alias Store.Checkout.CheckoutDraft
  alias Store.Comms
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Orders
  alias Store.Orders.Order
  alias Store.Orders.OrderLineItem
  alias Store.Payments.{PaymentIntent, Providers}
  alias Store.Pricing.{Contract, TaxRate, TaxShippingContract, TaxShippingEvaluator}
  alias Store.Repo
  alias Store.Shipping.Facade, as: ShippingFacade
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.Types.{QuoteEvidence, QuoteOption}
  alias Store.Subscriptions
  alias Store.Subscriptions.Facade.StaleWrite

  alias Store.Subscriptions.Inputs.{
    QueueSubscriptionPlanChangeInput,
    QueueSubscriptionVariantChangeInput,
    StartSubscriptionPaymentMethodUpdateInput
  }

  alias Store.Subscriptions.Queries.{
    AdminSubscriptionIndexQuery,
    UserSubscriptionIndexQuery
  }

  alias Store.Subscriptions.{
    ContractChange,
    PlanRevision,
    RenewalAttempt,
    Scheduler,
    StoredPaymentMethod,
    Subscription,
    SubscriptionItem,
    SubscriptionPlan,
    Types.SubscriptionDetail,
    VariantSubscriptionPlan
  }

  alias Store.Support.AshNotifications
  alias Store.Support.Errors.{Error, Normalize}
  alias Store.Workers.ProcessSubscriptionRenewalWorker

  @default_due_limit 100
  @unresolved_contract_message "subscription commercial contract is unresolved"
  @shipping_surge_percent_bps 2_000
  @shipping_surge_absolute_minor 5_000
  @payment_retry_reasons MapSet.new([
                           "PAYMENT_METHOD_REQUIRED",
                           "PAYMENT_FAILED",
                           "PAYMENT_AUTHENTICATION_REQUIRED"
                         ])
  @hard_retry_suppressed_reasons MapSet.new([
                                   "VARIANT_UNAVAILABLE",
                                   "VARIANT_PLAN_UNAVAILABLE",
                                   "SHIPPING_PROFILE_MISSING",
                                   "SHIPPING_UNAVAILABLE",
                                   "SHIPPING_COST_SURGE"
                                 ])

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

  @spec get_subscription_detail_for_user(map(), Ecto.UUID.t()) ::
          {:ok, SubscriptionDetail.t() | nil} | {:error, Error.t() | term()}
  def get_subscription_detail_for_user(actor, subscription_id)
      when is_map(actor) and is_binary(subscription_id) do
    with {:ok, subscription} <- get_subscription_for_user(actor, subscription_id) do
      build_subscription_detail_result(subscription)
    end
  end

  def get_subscription_detail_for_user(_actor, _subscription_id) do
    {:error, Error.new("VALIDATION_ERROR", "actor and subscription_id are required")}
  end

  @spec get_subscription_detail_for_admin(map(), Ecto.UUID.t()) ::
          {:ok, SubscriptionDetail.t() | nil} | {:error, Error.t() | term()}
  def get_subscription_detail_for_admin(actor, subscription_id)
      when is_map(actor) and is_binary(subscription_id) do
    with {:ok, subscription} <- get_subscription_for_admin(actor, subscription_id) do
      build_subscription_detail_result(subscription)
    end
  end

  def get_subscription_detail_for_admin(_actor, _subscription_id) do
    {:error, Error.new("VALIDATION_ERROR", "actor and subscription_id are required")}
  end

  @spec queue_subscription_plan_change_for_user(
          map(),
          Ecto.UUID.t(),
          QueueSubscriptionPlanChangeInput.t()
        ) :: {:ok, Subscription.t()} | {:error, Error.t() | term()}
  def queue_subscription_plan_change_for_user(
        actor,
        subscription_id,
        %QueueSubscriptionPlanChangeInput{} = input
      )
      when is_map(actor) and is_binary(subscription_id) do
    with {:ok, %Subscription{} = subscription} <-
           get_subscription_for_user(actor, subscription_id),
         :ok <- ensure_input_subscription_id(input.subscription_id, subscription_id) do
      queue_plan_change_for_subscription(actor, subscription, input)
    end
  end

  def queue_subscription_plan_change_for_user(_actor, _subscription_id, _input) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "actor, subscription_id, and queue plan change input are required"
     )}
  end

  @spec queue_subscription_plan_change_for_admin(
          map(),
          Ecto.UUID.t(),
          QueueSubscriptionPlanChangeInput.t()
        ) :: {:ok, Subscription.t()} | {:error, Error.t() | term()}
  def queue_subscription_plan_change_for_admin(
        actor,
        subscription_id,
        %QueueSubscriptionPlanChangeInput{} = input
      )
      when is_map(actor) and is_binary(subscription_id) do
    with {:ok, %Subscription{} = subscription} <-
           get_subscription_for_admin(actor, subscription_id),
         :ok <- ensure_input_subscription_id(input.subscription_id, subscription_id) do
      queue_plan_change_for_subscription(actor, subscription, input)
    end
  end

  def queue_subscription_plan_change_for_admin(_actor, _subscription_id, _input) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "actor, subscription_id, and queue plan change input are required"
     )}
  end

  @spec queue_subscription_variant_change_for_user(
          map(),
          Ecto.UUID.t(),
          QueueSubscriptionVariantChangeInput.t()
        ) :: {:ok, Subscription.t()} | {:error, Error.t() | term()}
  def queue_subscription_variant_change_for_user(
        actor,
        subscription_id,
        %QueueSubscriptionVariantChangeInput{} = input
      )
      when is_map(actor) and is_binary(subscription_id) do
    with {:ok, %Subscription{} = subscription} <-
           get_subscription_for_user(actor, subscription_id),
         :ok <- ensure_input_subscription_id(input.subscription_id, subscription_id) do
      queue_variant_change_for_subscription(actor, subscription, input)
    end
  end

  def queue_subscription_variant_change_for_user(_actor, _subscription_id, _input) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "actor, subscription_id, and queue variant change input are required"
     )}
  end

  @spec queue_subscription_variant_change_for_admin(
          map(),
          Ecto.UUID.t(),
          QueueSubscriptionVariantChangeInput.t()
        ) :: {:ok, Subscription.t()} | {:error, Error.t() | term()}
  def queue_subscription_variant_change_for_admin(
        actor,
        subscription_id,
        %QueueSubscriptionVariantChangeInput{} = input
      )
      when is_map(actor) and is_binary(subscription_id) do
    with {:ok, %Subscription{} = subscription} <-
           get_subscription_for_admin(actor, subscription_id),
         :ok <- ensure_input_subscription_id(input.subscription_id, subscription_id) do
      queue_variant_change_for_subscription(actor, subscription, input)
    end
  end

  def queue_subscription_variant_change_for_admin(_actor, _subscription_id, _input) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "actor, subscription_id, and queue variant change input are required"
     )}
  end

  @doc false
  @spec queue_plan_change_for_subscription(
          map(),
          Subscription.t(),
          QueueSubscriptionPlanChangeInput.t()
        ) :: {:ok, Subscription.t()} | {:error, Error.t() | term()}
  defp queue_plan_change_for_subscription(
         actor,
         %Subscription{} = subscription,
         %QueueSubscriptionPlanChangeInput{} = input
       )
       when is_map(actor) do
    with :ok <- ensure_input_subscription_id(input.subscription_id, subscription.id) do
      queue_plan_change(subscription, input.subscription_plan_id, actor)
    end
  end

  defp queue_plan_change_for_subscription(_actor, _subscription, _input) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "actor, subscription, and queue plan change input are required"
     )}
  end

  @doc false
  @spec queue_variant_change_for_subscription(
          map(),
          Subscription.t(),
          QueueSubscriptionVariantChangeInput.t()
        ) :: {:ok, Subscription.t()} | {:error, Error.t() | term()}
  defp queue_variant_change_for_subscription(
         actor,
         %Subscription{} = subscription,
         %QueueSubscriptionVariantChangeInput{} = input
       )
       when is_map(actor) do
    with :ok <- ensure_input_subscription_id(input.subscription_id, subscription.id) do
      queue_variant_change(subscription, input.variant_id, actor)
    end
  end

  defp queue_variant_change_for_subscription(_actor, _subscription, _input) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "actor, subscription, and queue variant change input are required"
     )}
  end

  @spec start_subscription_payment_method_update_for_user(
          map(),
          Ecto.UUID.t(),
          StartSubscriptionPaymentMethodUpdateInput.t()
        ) :: {:ok, map()} | {:error, Error.t() | term()}
  def start_subscription_payment_method_update_for_user(
        actor,
        subscription_id,
        %StartSubscriptionPaymentMethodUpdateInput{} = input
      )
      when is_map(actor) and is_binary(subscription_id) do
    with {:ok, %Subscription{} = subscription} <-
           get_subscription_for_user(actor, subscription_id),
         :ok <- ensure_input_subscription_id(input.subscription_id, subscription_id) do
      start_payment_method_update(subscription)
    end
  end

  def start_subscription_payment_method_update_for_user(_actor, _subscription_id, _input) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "actor, subscription_id, and payment method update input are required"
     )}
  end

  @spec start_subscription_payment_method_update_for_admin(
          map(),
          Ecto.UUID.t(),
          StartSubscriptionPaymentMethodUpdateInput.t()
        ) :: {:ok, map()} | {:error, Error.t() | term()}
  def start_subscription_payment_method_update_for_admin(
        actor,
        subscription_id,
        %StartSubscriptionPaymentMethodUpdateInput{} = input
      )
      when is_map(actor) and is_binary(subscription_id) do
    with {:ok, %Subscription{} = subscription} <-
           get_subscription_for_admin(actor, subscription_id),
         :ok <- ensure_input_subscription_id(input.subscription_id, subscription_id) do
      start_payment_method_update(subscription)
    end
  end

  def start_subscription_payment_method_update_for_admin(_actor, _subscription_id, _input) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "actor, subscription_id, and payment method update input are required"
     )}
  end

  @spec handle_payment_method_update_succeeded_for_system(Ecto.UUID.t()) ::
          :ok | {:error, Error.t() | term()}
  def handle_payment_method_update_succeeded_for_system(payment_intent_id)
      when is_binary(payment_intent_id) do
    with {:ok, %PaymentIntent{} = payment_intent} <-
           fetch_payment_intent_for_system(payment_intent_id),
         :ok <- ensure_setup_payment_intent(payment_intent),
         {:ok, %Subscription{} = subscription} <-
           fetch_subscription_for_renewal(payment_intent.subscription_id),
         {:ok, result} <- persist_updated_payment_method(subscription, payment_intent) do
      maybe_enqueue_immediate_collection_retry(result.subscription, result.retry_now?)
    end
  end

  def handle_payment_method_update_succeeded_for_system(_payment_intent_id) do
    {:error, Error.new("VALIDATION_ERROR", "payment_intent_id must be a UUID")}
  end

  @spec list_variant_subscription_plan_options_for_system(Ecto.UUID.t(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t() | term()}
  def list_variant_subscription_plan_options_for_system(variant_id, opts \\ [])

  def list_variant_subscription_plan_options_for_system(variant_id, opts)
      when is_binary(variant_id) and is_list(opts) do
    selected_plan_key = Keyword.get(opts, :selected_plan_key)

    with {:ok, %Variant{} = variant} <- fetch_variant_for_renewal(variant_id),
         {:ok, plan_pairs} <- fetch_active_plans_for_variant(variant_id) do
      {:ok, build_plan_options_for_variant(variant, plan_pairs, selected_plan_key)}
    end
  end

  def list_variant_subscription_plan_options_for_system(_variant_id, _opts) do
    {:error, Error.new("VALIDATION_ERROR", "variant_id must be a UUID")}
  end

  defp build_subscription_detail_result(nil), do: {:ok, nil}

  defp build_subscription_detail_result(%Subscription{} = subscription) do
    with {:ok, loaded_subscription} <- load_subscription_detail_relationships(subscription),
         {:ok, renewal_attempts} <- list_recent_renewal_attempts(loaded_subscription.id),
         {:ok, plan_targets} <- build_plan_targets(loaded_subscription),
         {:ok, variant_targets} <- build_variant_targets(loaded_subscription) do
      {:ok,
       %SubscriptionDetail{
         subscription: loaded_subscription,
         renewal_attempts: renewal_attempts,
         plan_targets: plan_targets,
         variant_targets: variant_targets,
         action_capabilities: action_capabilities_for_subscription(loaded_subscription)
       }}
    end
  end

  defp load_subscription_detail_relationships(%Subscription{} = subscription) do
    subscription
    |> Ash.load(
      [
        :subscription_plan,
        :pending_subscription_plan,
        :variant,
        :pending_variant,
        :stored_payment_method,
        :items
      ],
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
    |> case do
      {:ok, loaded} -> {:ok, loaded}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp list_recent_renewal_attempts(subscription_id) when is_binary(subscription_id) do
    query =
      RenewalAttempt
      |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(5)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, attempts} -> {:ok, attempts}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp build_plan_targets(%Subscription{} = subscription) do
    variant_id = effective_variant_id(subscription)
    selected_plan_id = effective_plan_id(subscription)

    with {:ok, %Variant{} = variant} <- fetch_variant_for_renewal(variant_id),
         {:ok, plan_pairs} <- fetch_active_plans_for_variant(variant_id) do
      {:ok, build_plan_target_options(variant, plan_pairs, selected_plan_id)}
    end
  end

  defp build_variant_targets(%Subscription{} = subscription) do
    current_variant_id = effective_variant_id(subscription)
    selected_variant_id = effective_variant_id(subscription)
    plan_id = effective_plan_id(subscription)

    with {:ok, %Variant{} = current_variant} <- fetch_variant_for_renewal(current_variant_id),
         {:ok, variants} <-
           fetch_variant_targets_for_product_plan(current_variant.product_id, plan_id),
         {:ok, plan} <- fetch_plan(plan_id) do
      {:ok,
       Enum.map(variants, fn variant ->
         pricing = resolve_subscription_pricing(variant, plan)

         %{
           id: variant.id,
           label: variant.title || variant.sku || variant.id,
           price_minor: pricing.amount_minor,
           currency: pricing.currency,
           selected?: variant.id == selected_variant_id
         }
       end)}
    end
  end

  defp action_capabilities_for_subscription(%Subscription{} = subscription) do
    provider = Providers.normalize_provider(subscription.provider)

    can_queue_change? =
      subscription.status in [:active, :past_due] and not subscription.cancel_at_period_end

    %{
      can_cancel_now?: subscription.status in [:active, :past_due],
      can_cancel_at_period_end?: subscription.status in [:active, :past_due],
      can_queue_plan_change?: can_queue_change?,
      can_queue_variant_change?: can_queue_change?,
      can_update_payment_method?: payment_method_update_supported?(subscription),
      payment_method_update_provider: if(provider == :stripe, do: :stripe, else: nil)
    }
  end

  defp payment_method_update_supported?(%Subscription{} = subscription) do
    Providers.normalize_provider(subscription.provider) == :stripe and
      subscription.billing_mode == :merchant_managed and
      stripe_publishable_key() not in [nil, ""] and
      is_binary(subscription.provider_customer_ref)
  end

  defp queue_plan_change(subscription, target_plan_id, actor) do
    with :ok <- ensure_queueable_subscription(subscription),
         :ok <- ensure_subscription_contract_resolved(subscription),
         {:ok, base} <- future_target_base(subscription),
         {:ok, plan} <- fetch_plan(target_plan_id),
         :ok <- ensure_subscription_plan_active(plan),
         {:ok, %Variant{} = variant} <-
           fetch_variant_for_renewal(base.target_variant_id),
         :ok <- ensure_variant_subscription_plan_active(variant.id, plan.id),
         :ok <- ensure_variant_catalog_renewable(variant),
         {:ok, revision} <- fetch_effective_plan_revision(plan.id),
         :ok <- ensure_revision_belongs_to_plan(revision, plan.id),
         {:ok, effective_at} <- effective_at_for_target(subscription, base) do
      target = %{
        instruction_kind: :plan_change,
        target_plan_revision_id: revision.id,
        target_variant_id: base.target_variant_id,
        target_quantity: base.target_quantity,
        target_amount_minor: revision.amount_minor,
        target_currency: revision.currency,
        effective_at: effective_at
      }

      projection = contract_change_projection(subscription, target, plan.id)
      persist_contract_change(subscription, target, projection, actor, :queue_change)
    end
  end

  defp queue_variant_change(subscription, target_variant_id, actor) do
    with :ok <- ensure_queueable_subscription(subscription),
         :ok <- ensure_subscription_contract_resolved(subscription),
         {:ok, base} <- future_target_base(subscription),
         {:ok, %Variant{} = variant} <- fetch_variant_for_renewal(target_variant_id),
         {:ok, plan} <- fetch_plan(base.subscription_plan_id),
         :ok <- ensure_subscription_plan_active(plan),
         :ok <- ensure_variant_subscription_plan_active(variant.id, plan.id),
         :ok <- ensure_variant_catalog_renewable(variant),
         {:ok, revision} <- fetch_effective_plan_revision(plan.id),
         :ok <- ensure_revision_belongs_to_plan(revision, plan.id),
         {:ok, effective_at} <- effective_at_for_target(subscription, base) do
      target = %{
        instruction_kind: :variant_change,
        target_plan_revision_id: revision.id,
        target_variant_id: variant.id,
        target_quantity: base.target_quantity,
        target_amount_minor: revision.amount_minor,
        target_currency: revision.currency,
        effective_at: effective_at
      }

      projection = contract_change_projection(subscription, target, plan.id)
      persist_contract_change(subscription, target, projection, actor, :queue_change)
    end
  end

  defp future_target_base(%Subscription{} = subscription) do
    case current_contract_change(subscription) do
      {:ok, %ContractChange{} = contract_change} ->
        future_target_base_from_contract_change(contract_change)

      {:ok, nil} ->
        {:ok,
         %{
           subscription_plan_id: subscription.subscription_plan_id,
           target_variant_id: subscription.variant_id,
           target_quantity: subscription.quantity,
           effective_at: nil
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp future_target_base_from_contract_change(%ContractChange{} = contract_change) do
    with {:ok, revision} <- fetch_plan_revision(contract_change.target_plan_revision_id) do
      {:ok,
       %{
         subscription_plan_id: revision.subscription_plan_id,
         target_variant_id: contract_change.target_variant_id,
         target_quantity: contract_change.target_quantity,
         effective_at: contract_change.effective_at
       }}
    end
  end

  defp effective_at_for_target(%Subscription{}, %{effective_at: %DateTime{} = at}), do: {:ok, at}

  defp effective_at_for_target(%Subscription{} = subscription, _base),
    do: contract_change_effective_at(subscription)

  defp fetch_effective_plan_revision(plan_id) do
    case PlanRevision.get_effective_for_plan(plan_id,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, %PlanRevision{} = revision} ->
        {:ok, revision}

      {:ok, nil} ->
        {:error,
         Error.new(
           "VALIDATION_ERROR",
           "subscription plan has no eligible effective revision"
         )}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}

      _multiple_or_invalid ->
        {:error,
         Error.new(
           "VALIDATION_ERROR",
           "subscription plan has an ambiguous effective revision"
         )}
    end
  end

  defp ensure_queueable_subscription(%Subscription{
         status: status,
         cancel_at_period_end: false
       })
       when status in [:active, :past_due],
       do: :ok

  defp ensure_queueable_subscription(%Subscription{}) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "subscription cannot accept a future contract change in its current lifecycle state"
     )}
  end

  defp ensure_subscription_plan_active(%SubscriptionPlan{status: :active}), do: :ok

  defp ensure_subscription_plan_active(%SubscriptionPlan{}) do
    {:error, Error.new("VALIDATION_ERROR", "subscription plan is not active for a new change")}
  end

  defp contract_change_effective_at(%Subscription{
         next_renewal_at: %DateTime{} = effective_at
       }),
       do: {:ok, effective_at}

  defp contract_change_effective_at(%Subscription{
         current_period_end_at: %DateTime{} = effective_at
       }),
       do: {:ok, effective_at}

  defp contract_change_effective_at(%Subscription{}) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "subscription has no future commercial boundary"
     )}
  end

  defp contract_change_projection(subscription, target, target_plan_id) do
    %{
      pending_subscription_plan_id:
        if(target_plan_id == subscription.subscription_plan_id,
          do: nil,
          else: pending_or_nil(target_plan_id)
        ),
      pending_variant_id:
        if(target.target_variant_id == subscription.variant_id,
          do: nil,
          else: pending_or_nil(target.target_variant_id)
        ),
      pending_renewal_amount_minor: target.target_amount_minor,
      pending_renewal_currency: target.target_currency,
      change_effective_at: target.effective_at
    }
  end

  defp persist_contract_change(
         %Subscription{} = subscription,
         target,
         projection,
         actor,
         subscription_action
       ) do
    transaction_result =
      Repo.transaction(fn ->
        case lock_subscription_aggregate_version(subscription) do
          :ok ->
            persist_locked_contract_change(
              subscription,
              target,
              projection,
              actor,
              subscription_action
            )

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
      |> normalize_transaction_notifications()

    case transaction_result do
      {:ok, %{subscription: updated_subscription}, notifications} ->
        :ok =
          AshNotifications.notify_post_commit(
            notifications,
            context: %{
              flow: :persist_contract_change,
              subscription_id: subscription.id,
              contract_change_id: Map.get(updated_subscription, :current_contract_change_id)
            }
          )

        with :ok <-
               maybe_enqueue_immediate_collection_retry(
                 updated_subscription,
                 retry_now?(updated_subscription)
               ) do
          {:ok, updated_subscription}
        end

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp persist_locked_contract_change(
         subscription,
         target,
         projection,
         actor,
         subscription_action
       ) do
    with {:ok, current_target} <- current_contract_change(subscription),
         {:ok, predecessor} <- latest_contract_change(subscription.id) do
      if subscription_action == :queue_change and
           same_queued_contract_change?(current_target, target) do
        {:ok, %{subscription: subscription, notifications: []}}
      else
        persist_contract_change_tx(
          subscription,
          current_target,
          predecessor,
          target,
          projection,
          actor,
          subscription_action
        )
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp persist_contract_change_tx(
         subscription,
         current_target,
         predecessor,
         target,
         projection,
         actor,
         subscription_action
       ) do
    supersedes_id = current_target && current_target.id

    with :ok <- ensure_rescind_target_clear(subscription_action, current_target),
         {:ok, transition_notifications} <-
           maybe_transition_contract_change(current_target, :supersede),
         {:ok, contract_change, contract_change_notifications} <-
           create_contract_change(
             subscription,
             target,
             predecessor && predecessor.id,
             supersedes_id
           ),
         attrs <-
           projection
           |> Map.put(:current_contract_change_id, contract_change.id)
           |> then(&maybe_contract_correction_retry_attrs(subscription, &1)),
         {:ok, updated_subscription, subscription_notifications} <-
           update_subscription_contract_change(
             subscription,
             subscription_action,
             attrs,
             actor
           ) do
      {:ok,
       %{
         subscription: updated_subscription,
         notifications:
           transition_notifications ++ contract_change_notifications ++ subscription_notifications
       }}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_rescind_target_clear(:rescind_cancel_at_period_end_transition, nil), do: :ok

  defp ensure_rescind_target_clear(:rescind_cancel_at_period_end_transition, _current_target) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "scheduled cancellation has an unresolved current future target"
     )}
  end

  defp ensure_rescind_target_clear(_subscription_action, _current_target), do: :ok

  defp create_contract_change(
         subscription,
         target,
         predecessor_id,
         supersedes_id
       ) do
    attrs = %{
      subscription_id: subscription.id,
      target_plan_revision_id: target.target_plan_revision_id,
      target_variant_id: target.target_variant_id,
      predecessor_contract_change_id: predecessor_id,
      supersedes_contract_change_id: supersedes_id,
      instruction_kind: target.instruction_kind,
      ordering_version: subscription.aggregate_version + 1,
      effective_at: target.effective_at,
      target_quantity: target.target_quantity,
      target_amount_minor: target.target_amount_minor,
      target_currency: target.target_currency
    }

    ContractChange
    |> Ash.Changeset.for_create(:queue, attrs, context: %{system?: true})
    |> Ash.create(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> case do
      {:ok, contract_change, notifications} -> {:ok, contract_change, notifications}
      {:ok, contract_change} -> {:ok, contract_change, []}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp update_subscription_contract_change(subscription, action, attrs, actor) do
    subscription
    |> Ash.Changeset.for_update(action, attrs)
    |> Ash.update(domain: Subscriptions, actor: actor, return_notifications?: true)
    |> normalize_subscription_update_with_notifications(subscription)
  end

  defp maybe_transition_contract_change(nil, _transition), do: {:ok, []}

  defp maybe_transition_contract_change(%ContractChange{status: :queued} = change, transition) do
    change
    |> Ash.Changeset.for_update(transition, %{}, context: %{system?: true})
    |> Ash.update(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> case do
      {:ok, _updated, notifications} -> {:ok, notifications}
      {:ok, _updated} -> {:ok, []}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp maybe_transition_contract_change(%ContractChange{}, _transition) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "current subscription ContractChange is not queued"
     )}
  end

  defp current_contract_change(%Subscription{} = subscription) do
    case Map.get(subscription, :current_contract_change_id) do
      nil ->
        case fetch_queued_contract_change(subscription.id) do
          {:ok, nil} -> {:ok, nil}
          {:ok, _orphaned} -> {:error, inconsistent_current_contract_change_error()}
          {:error, reason} -> {:error, reason}
        end

      contract_change_id ->
        case fetch_contract_change_by_id(contract_change_id) do
          {:ok, %ContractChange{subscription_id: id, status: :queued} = target}
          when id == subscription.id ->
            {:ok, target}

          {:ok, _other} ->
            {:error, inconsistent_current_contract_change_error()}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp fetch_queued_contract_change(subscription_id) do
    query =
      ContractChange
      |> Ash.Query.filter(expr(subscription_id == ^subscription_id and status == :queued))
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [contract_change | _]} -> {:ok, contract_change}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp inconsistent_current_contract_change_error do
    Error.new("VALIDATION_ERROR", "current subscription ContractChange is inconsistent")
  end

  defp latest_contract_change(subscription_id) do
    query =
      ContractChange
      |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
      |> Ash.Query.sort(ordering_version: :desc)
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [latest | _]} -> {:ok, latest}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_contract_change_by_id(id) do
    query = ContractChange |> Ash.Query.filter(expr(id == ^id))

    case Ash.read_one(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, %ContractChange{} = contract_change} -> {:ok, contract_change}
      {:ok, nil} -> {:error, Error.new("VALIDATION_ERROR", "ContractChange was not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp same_queued_contract_change?(%ContractChange{} = current, target) do
    current.instruction_kind == target.instruction_kind and
      current.target_plan_revision_id == target.target_plan_revision_id and
      current.target_variant_id == target.target_variant_id and
      current.target_quantity == target.target_quantity and
      current.target_amount_minor == target.target_amount_minor and
      current.target_currency == target.target_currency and
      current.effective_at == target.effective_at
  end

  defp same_queued_contract_change?(nil, _target), do: false

  defp lock_subscription_aggregate_version(%Subscription{} = subscription) do
    case Ecto.UUID.dump(subscription.id) do
      {:ok, subscription_uuid} ->
        case Repo.query(
               "SELECT aggregate_version FROM subscriptions WHERE id = $1 FOR UPDATE",
               [subscription_uuid]
             ) do
          {:ok, %{rows: [[version]]}} when version == subscription.aggregate_version ->
            :ok

          {:ok, %{rows: [[_version]]}} ->
            _ = reload_subscription_after_stale_update(subscription.id)

            {:error,
             Error.new(
               "STALE_RECORD",
               "subscription changed while the command was in progress; reload and re-evaluate it"
             )}

          {:ok, %{rows: []}} ->
            {:error, Error.new("SUBSCRIPTION_NOT_FOUND", "subscription not found")}

          {:error, reason} ->
            {:error, Normalize.normalize(reason)}
        end

      :error ->
        {:error, Error.new("VALIDATION_ERROR", "subscription id must be a UUID")}
    end
  end

  defp maybe_contract_correction_retry_attrs(%Subscription{} = subscription, attrs) do
    if subscription.status == :past_due and is_struct(subscription.retry_suppressed_at, DateTime) do
      attrs
      |> Map.put(:retry_suppressed_at, nil)
      |> Map.put(:next_retry_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    else
      attrs
    end
  end

  defp retry_now?(%Subscription{status: :past_due, retry_suppressed_at: nil}), do: true
  defp retry_now?(%Subscription{}), do: false

  defp start_payment_method_update(%Subscription{} = subscription) do
    with :ok <- ensure_payment_method_update_supported(subscription),
         payment_intent_key <- payment_method_update_intent_key(subscription.id),
         {:ok, payment_intent} <-
           create_subscription_payment_method_update_intent(subscription, payment_intent_key),
         {:ok, provider_payload} <-
           create_subscription_payment_method_update_provider_intent(
             subscription,
             payment_intent,
             payment_intent_key
           ),
         {:ok, payment_intent} <-
           persist_setup_intent_provider_reference(payment_intent, provider_payload),
         {:ok, submitted_intent} <- maybe_submit_virtual_payment_intent(payment_intent) do
      {:ok,
       %{
         payment_intent_id: submitted_intent.id,
         client_secret: submitted_intent.provider_client_secret,
         publishable_key: stripe_publishable_key(),
         provider: :stripe
       }}
    end
  end

  defp create_subscription_payment_method_update_intent(subscription, payment_intent_key) do
    PaymentIntent
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider: subscription.provider,
        purpose: :subscription_payment_method_update,
        subscription_id: subscription.id,
        amount_received_minor: 0,
        currency: subscription.renewal_currency || "USD",
        provider_customer_ref: subscription.provider_customer_ref,
        payment_intent_key: payment_intent_key
      },
      context: %{system?: true}
    )
    |> Ash.create(domain: Store.Payments, authorize?: false, context: %{system?: true})
    |> case do
      {:ok, payment_intent} -> {:ok, payment_intent}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp create_subscription_payment_method_update_provider_intent(
         subscription,
         payment_intent,
         payment_intent_key
       ) do
    Providers.create_intent(
      subscription.provider,
      %{
        intent_purpose: :subscription_payment_method_update,
        payment_intent_key: payment_intent_key,
        local_intent_id: payment_intent.id,
        subscription_id: subscription.id,
        provider_customer_ref: subscription.provider_customer_ref,
        currency: subscription.renewal_currency || "USD"
      },
      []
    )
  end

  defp persist_setup_intent_provider_reference(
         %PaymentIntent{} = payment_intent,
         provider_payload
       ) do
    payment_intent
    |> Ash.Changeset.for_update(
      :set_provider_reference,
      %{
        provider: payment_intent.provider,
        provider_payment_id: Map.get(provider_payload, :provider_payment_id),
        provider_customer_ref: Map.get(provider_payload, :provider_customer_ref),
        provider_client_secret: Map.get(provider_payload, :provider_client_secret)
      },
      context: %{system?: true}
    )
    |> Ash.update(domain: Store.Payments, authorize?: false, context: %{system?: true})
    |> case do
      {:ok, updated_intent} -> {:ok, updated_intent}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_payment_method_update_supported(%Subscription{} = subscription) do
    if payment_method_update_supported?(subscription) do
      :ok
    else
      {:error,
       Error.new(
         "PAYMENT_METHOD_UPDATE_UNSUPPORTED",
         "payment method update is not supported for this subscription"
       )}
    end
  end

  defp ensure_input_subscription_id(expected, actual) when expected == actual, do: :ok

  defp ensure_input_subscription_id(_expected, _actual) do
    {:error,
     Error.new("VALIDATION_ERROR", "input subscription id must match the route subscription id")}
  end

  defp fetch_active_plans_for_variant(variant_id) when is_binary(variant_id) do
    query =
      VariantSubscriptionPlan
      |> Ash.Query.for_read(:read_active_for_variant, %{variant_id: variant_id})
      |> Ash.Query.load([:subscription_plan])

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, attachments} ->
        {:ok,
         attachments
         |> Enum.map(fn attachment ->
           {attachment.subscription_plan_id, attachment.subscription_plan}
         end)
         |> Enum.reject(fn {_id, plan} -> is_nil(plan) end)}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp build_plan_options_for_variant(%Variant{} = variant, plan_pairs, selected_plan_key) do
    Enum.map(plan_pairs, fn {_plan_id, plan} ->
      pricing = resolve_subscription_pricing(variant, plan)

      %{
        id: plan.id,
        key: plan.key,
        name: plan.name,
        label: plan.name || plan.key,
        price_minor: pricing.amount_minor,
        currency: pricing.currency,
        selected?: is_binary(selected_plan_key) and plan.key == selected_plan_key
      }
    end)
  end

  defp build_plan_target_options(%Variant{} = variant, plan_pairs, selected_plan_id) do
    Enum.map(plan_pairs, fn {_plan_id, plan} ->
      pricing = resolve_subscription_pricing(variant, plan)

      %{
        id: plan.id,
        key: plan.key,
        label: plan.name || plan.key,
        price_minor: pricing.amount_minor,
        currency: pricing.currency,
        selected?: plan.id == selected_plan_id
      }
    end)
  end

  defp fetch_variant_targets_for_product_plan(product_id, plan_id)
       when is_binary(product_id) and is_binary(plan_id) do
    query =
      from(variant in Variant,
        join: product in Product,
        on: product.id == variant.product_id,
        join: attachment in VariantSubscriptionPlan,
        on:
          attachment.variant_id == variant.id and attachment.subscription_plan_id == ^plan_id and
            attachment.active == true,
        where:
          variant.product_id == ^product_id and variant.status == :active and
            product.status == :published and not is_nil(product.published_at),
        order_by: [asc: variant.inserted_at, asc: variant.id]
      )

    {:ok, Repo.all(query)}
  rescue
    error -> {:error, Normalize.normalize(error)}
  end

  defp resolve_subscription_pricing(%Variant{} = variant, %SubscriptionPlan{} = plan) do
    amount_minor =
      cond do
        is_integer(plan.amount_minor) -> plan.amount_minor
        is_integer(variant.price_minor) -> variant.price_minor
        true -> 0
      end

    currency =
      cond do
        is_binary(plan.currency) -> String.upcase(plan.currency)
        is_binary(variant.currency_code) -> String.upcase(variant.currency_code)
        true -> "USD"
      end

    %{amount_minor: amount_minor, currency: currency}
  end

  defp effective_variant_id(%Subscription{} = subscription),
    do: subscription.pending_variant_id || subscription.variant_id

  defp effective_plan_id(%Subscription{} = subscription),
    do: subscription.pending_subscription_plan_id || subscription.subscription_plan_id

  defp pending_or_nil(value) when is_binary(value), do: value
  defp pending_or_nil(_value), do: nil

  defp payment_method_update_intent_key(subscription_id) do
    "pm-update:#{subscription_id}:#{System.unique_integer([:positive])}"
  end

  defp stripe_publishable_key do
    :store
    |> Application.get_env(:payments, [])
    |> Keyword.get(:stripe, [])
    |> Keyword.get(:publishable_key, "pk_test_store_blueprint")
  end

  defp fetch_payment_intent_for_system(payment_intent_id) when is_binary(payment_intent_id) do
    query = PaymentIntent |> Ash.Query.filter(expr(id == ^payment_intent_id))

    case Ash.read(query, domain: Store.Payments, authorize?: false, context: %{system?: true}) do
      {:ok, [%PaymentIntent{} = payment_intent | _]} -> {:ok, payment_intent}
      {:ok, []} -> {:error, Error.new("NOT_FOUND", "payment intent not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_setup_payment_intent(%PaymentIntent{
         purpose: :subscription_payment_method_update,
         subscription_id: subscription_id
       })
       when is_binary(subscription_id),
       do: :ok

  defp ensure_setup_payment_intent(%PaymentIntent{}) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "payment intent is not a subscription payment method update intent"
     )}
  end

  defp persist_updated_payment_method(subscription, payment_intent) do
    case Repo.transaction(fn ->
           persist_updated_payment_method_tx(subscription, payment_intent)
         end)
         |> normalize_transaction_notifications() do
      {:ok, result, notifications} ->
        :ok =
          AshNotifications.notify_post_commit(
            notifications,
            context: %{
              flow: :handle_payment_method_update_succeeded_for_system,
              subscription_id: subscription.id,
              payment_intent_id: payment_intent.id
            }
          )

        {:ok, result}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp persist_updated_payment_method_tx(subscription, payment_intent) do
    with {:ok, stored_payment_method, stored_payment_method_notifications} <-
           maybe_upsert_stored_payment_method(subscription.user_id, payment_intent),
         :ok <-
           ensure_stored_payment_method_active_for_payment_method_update(stored_payment_method),
         {:ok, updated_subscription, subscription_notifications} <-
           update_subscription_payment_method_reference(
             subscription,
             payment_intent,
             stored_payment_method
           ) do
      {:ok,
       %{
         subscription: updated_subscription,
         retry_now?: retry_now?(updated_subscription),
         notifications: stored_payment_method_notifications ++ subscription_notifications
       }}
    else
      {:error, reason} ->
        Repo.rollback(Normalize.normalize(reason))
    end
  end

  defp ensure_stored_payment_method_active_for_payment_method_update(%StoredPaymentMethod{
         status: :active
       }),
       do: :ok

  defp ensure_stored_payment_method_active_for_payment_method_update(_stored_payment_method) do
    {:error,
     Error.new(
       "PAYMENT_METHOD_REQUIRED",
       "subscription cannot renew without an active stored payment method"
     )}
  end

  defp update_subscription_payment_method_reference(
         subscription,
         payment_intent,
         stored_payment_method
       ) do
    subscription
    |> Ash.Changeset.for_update(
      :set_provider_billing_reference,
      payment_method_reference_attrs(subscription, payment_intent, stored_payment_method),
      context: %{system?: true}
    )
    |> Ash.update(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> normalize_subscription_update_with_notifications(subscription)
  end

  defp payment_method_reference_attrs(subscription, payment_intent, stored_payment_method) do
    clear_retry_suppressed? = payment_method_update_retry_reset?(subscription)

    %{
      provider_customer_ref:
        payment_intent.provider_customer_ref ||
          (stored_payment_method && stored_payment_method.provider_customer_ref),
      provider_billing_ref:
        payment_intent.provider_payment_method_ref ||
          (stored_payment_method && stored_payment_method.provider_payment_method_ref),
      stored_payment_method_id: stored_payment_method && stored_payment_method.id,
      billing_status_reason: nil,
      next_retry_at: payment_method_retry_at(subscription, clear_retry_suppressed?),
      retry_suppressed_at:
        if(clear_retry_suppressed?, do: nil, else: subscription.retry_suppressed_at)
    }
  end

  defp payment_method_retry_at(%Subscription{status: :past_due}, true) do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end

  defp payment_method_retry_at(%Subscription{} = subscription, _clear_retry_suppressed?),
    do: subscription.next_retry_at

  defp payment_method_update_retry_reset?(%Subscription{} = subscription) do
    MapSet.member?(@payment_retry_reasons, subscription.billing_status_reason || "")
  end

  defp normalize_subscription_update_with_notifications(
         {:ok, updated_subscription, notifications},
         _subscription
       ) do
    {:ok, updated_subscription, notifications}
  end

  defp normalize_subscription_update_with_notifications(
         {:ok, updated_subscription},
         _subscription
       ) do
    {:ok, updated_subscription, []}
  end

  defp normalize_subscription_update_with_notifications({:error, reason}, subscription) do
    normalize_subscription_update_result({:error, reason}, subscription)
  end

  defp maybe_enqueue_immediate_collection_retry(_subscription, false), do: :ok

  defp maybe_enqueue_immediate_collection_retry(%Subscription{} = subscription, true) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case due_renewal_key(subscription, now) do
      {:ok, renewal_key} ->
        %{"subscription_id" => subscription.id, "renewal_key" => renewal_key}
        |> ProcessSubscriptionRenewalWorker.new()
        |> Oban.insert()

        :ok

      _ ->
        :ok
    end
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

  @spec ensure_membership_purchase_allowed_for_system(String.t() | nil, String.t() | [String.t()]) ::
          :ok | {:error, Error.t()}
  def ensure_membership_purchase_allowed_for_system(user_id, plan_id_or_ids)

  def ensure_membership_purchase_allowed_for_system(_user_id, nil), do: :ok

  def ensure_membership_purchase_allowed_for_system(user_id, plan_id) when is_binary(plan_id) do
    ensure_membership_purchase_allowed_for_system(user_id, [plan_id])
  end

  def ensure_membership_purchase_allowed_for_system(user_id, plan_ids) when is_list(plan_ids) do
    normalized_plan_ids =
      plan_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    with {:ok, membership_keys} <- membership_keys_for_plan_ids(normalized_plan_ids),
         :ok <- ensure_membership_user(user_id, membership_keys),
         :ok <- ensure_no_open_membership_subscription(user_id, membership_keys) do
      ensure_no_pending_membership_order(user_id, membership_keys)
    end
  end

  def ensure_membership_purchase_allowed_for_system(_user_id, _plan_ids) do
    {:error, Error.new("VALIDATION_ERROR", "subscription plan ids must be UUIDs")}
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
         :ok <- ensure_initial_subscription_order(order.id),
         :ok <- ensure_order_user(order),
         {:ok, line_items} <- fetch_subscription_order_line_items(order.id),
         {:ok, payment_intent} <- fetch_succeeded_payment_intent(order.id),
         {:ok, result} <- build_subscription_creation_result(order, line_items, payment_intent) do
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

  defp ensure_initial_subscription_order(order_id) do
    case fetch_renewal_attempt_by_order(order_id) do
      {:ok, %RenewalAttempt{}} ->
        {:error,
         Error.new(
           "SUBSCRIPTION_RENEWAL_ORDER",
           "renewal orders must reconcile the existing subscription instead of creating a new one"
         )}

      {:error, %Error{code: "NOT_FOUND"}} ->
        :ok

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp build_subscription_creation_result(order, line_items, payment_intent) do
    case run_subscription_creation_transaction(order, line_items, payment_intent) do
      {:ok, tx_result, notifications} ->
        :ok =
          AshNotifications.notify_post_commit(
            notifications,
            context: %{
              flow: :create_subscriptions_from_paid_order_for_system,
              order_id: order.id
            }
          )

        {:ok,
         %{
           created: tx_result.created,
           skipped: tx_result.skipped,
           entitlements: issue_subscription_entitlements_after_commit(tx_result.entitlements)
         }}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp run_subscription_creation_transaction(order, line_items, payment_intent) do
    Repo.transaction(fn ->
      case maybe_upsert_stored_payment_method(order.user_id, payment_intent) do
        {:ok, stored_payment_method, stored_payment_method_notifications} ->
          reduce_subscription_line_items(
            order,
            line_items,
            payment_intent,
            stored_payment_method,
            stored_payment_method_notifications
          )

        {:error, reason} ->
          Repo.rollback(Normalize.normalize(reason))
      end
    end)
    |> normalize_transaction_notifications()
  end

  defp reduce_subscription_line_items(
         order,
         line_items,
         payment_intent,
         stored_payment_method,
         stored_payment_method_notifications
       ) do
    Enum.reduce_while(
      line_items,
      {:ok,
       %{
         created: 0,
         skipped: 0,
         entitlements: [],
         notifications: stored_payment_method_notifications
       }},
      fn line_item, {:ok, acc} ->
        reduce_subscription_line_item(
          order,
          line_item,
          payment_intent,
          stored_payment_method,
          acc
        )
      end
    )
  end

  defp reduce_subscription_line_item(order, line_item, payment_intent, stored_payment_method, acc) do
    case create_subscription_from_line(order, line_item, payment_intent, stored_payment_method) do
      {:ok, :created, %{subscription: subscription, plan: _plan, revision: revision},
       line_notifications} ->
        updated =
          %{
            created: acc.created + 1,
            skipped: acc.skipped,
            entitlements: [{subscription, revision} | acc.entitlements],
            notifications: acc.notifications ++ line_notifications
          }

        {:cont, {:ok, updated}}

      {:ok, :skipped, line_notifications} ->
        {:cont,
         {:ok,
          %{
            acc
            | skipped: acc.skipped + 1,
              notifications: acc.notifications ++ line_notifications
          }}}

      {:error, reason} ->
        Repo.rollback(Normalize.normalize(reason))
    end
  end

  @spec cancel_subscription_for_user(
          map(),
          Ecto.UUID.t(),
          :now | :period_end | :rescind_period_end
        ) ::
          {:ok, Subscription.t()} | {:error, Error.t() | term()}
  def cancel_subscription_for_user(actor, subscription_id, mode \\ :period_end)

  def cancel_subscription_for_user(actor, subscription_id, mode)
      when is_map(actor) and is_binary(subscription_id) and
             mode in [:now, :period_end, :rescind_period_end] do
    with {:ok, %Subscription{} = subscription} <-
           get_subscription_for_user(actor, subscription_id),
         {:ok, updated} <-
           if(mode == :rescind_period_end,
             do: run_rescind_cancellation(subscription, actor),
             else: run_cancel(subscription, mode, actor)
           ) do
      {:ok, updated}
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
    started_at = System.monotonic_time()
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    limit = Keyword.get(opts, :limit, @default_due_limit)

    query = Subscription |> Ash.Query.for_read(:read_due_for_system, %{now: now, limit: limit})

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, due_subscriptions} ->
        result = count_due_renewal_results(due_subscriptions, now)
        emit_subscription_tick_telemetry(started_at, length(due_subscriptions), result)

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

  @spec list_due_renewal_jobs_for_system(keyword()) ::
          {:ok,
           [
             %{
               subscription_id: String.t(),
               renewal_key: String.t(),
               schedule_in: non_neg_integer()
             }
           ]}
          | {:error, Error.t() | term()}
  def list_due_renewal_jobs_for_system(opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    limit = Keyword.get(opts, :limit, @default_due_limit)

    query =
      Subscription
      |> Ash.Query.for_read(:read_due_for_system, %{now: now, limit: limit})
      |> Ash.Query.load([:subscription_plan])

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, due_subscriptions} ->
        due_subscriptions
        |> build_due_renewal_jobs(now)
        |> case do
          {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
          {:error, reason} -> {:error, Normalize.normalize(reason)}
        end

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp build_due_renewal_jobs(due_subscriptions, now) do
    Enum.reduce_while(due_subscriptions, {:ok, []}, fn subscription, {:ok, jobs} ->
      case due_job_for_subscription(subscription, now) do
        {:ok, job} ->
          {:cont, {:ok, [job | jobs]}}

        {:error,
         %Error{
           code: "VALIDATION_ERROR",
           message: @unresolved_contract_message
         }} ->
          {:cont, {:ok, jobs}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  @spec process_due_subscription_renewal_for_system(String.t(), keyword()) ::
          {:ok, :processed | :noop} | {:error, Error.t() | term()}
  def process_due_subscription_renewal_for_system(subscription_id, opts \\ [])

  def process_due_subscription_renewal_for_system(subscription_id, opts)
      when is_binary(subscription_id) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    renewal_key = Keyword.get(opts, :renewal_key)

    with {:ok, %Subscription{} = subscription} <- fetch_subscription_for_renewal(subscription_id),
         :ok <- ensure_subscription_due(subscription, now),
         {:ok, current_renewal_key} <- due_renewal_key(subscription, now),
         :ok <- ensure_matching_renewal_key(renewal_key, current_renewal_key) do
      case run_single_due_renewal(subscription, now) do
        :ok -> {:ok, :processed}
        {:error, reason} -> {:error, reason}
      end
    else
      :not_due ->
        {:ok, :noop}

      :stale ->
        {:ok, :noop}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def process_due_subscription_renewal_for_system(_subscription_id, _opts) do
    {:error, Error.new("VALIDATION_ERROR", "subscription_id must be a UUID")}
  end

  @spec reconcile_paid_subscription_renewal_for_system(String.t(), keyword()) ::
          {:ok, :reconciled | :noop} | {:error, Error.t() | term()}
  def reconcile_paid_subscription_renewal_for_system(order_id, opts \\ [])

  def reconcile_paid_subscription_renewal_for_system(order_id, opts)
      when is_binary(order_id) and is_list(opts) do
    renewal_attempt_id = Keyword.get(opts, :renewal_attempt_id)

    with {:ok, %RenewalAttempt{} = attempt} <-
           fetch_renewal_attempt_by_order(order_id, renewal_attempt_id),
         :ok <- ensure_attempt_reconcilable(attempt),
         {:ok, %Subscription{} = subscription} <-
           fetch_subscription_for_renewal(attempt.subscription_id),
         :ok <- ensure_subscription_contract_resolved(subscription),
         :ok <- ensure_paid_reconciliation_contract(subscription, attempt),
         {:ok, %Order{state: :paid}} <- fetch_paid_order(order_id),
         {:ok, plan} <- fetch_plan(effective_subscription_plan_id(subscription)),
         :ok <- ensure_matching_attempt_payment(order_id, attempt),
         {:ok, updated_subscription} <-
           reconcile_paid_renewal_attempt(subscription, plan, attempt),
         :ok <- maybe_sync_entitlement(updated_subscription, plan),
         {:ok, _attempt} <- mark_attempt_succeeded(attempt, order_id, attempt.payment_intent_id) do
      {:ok, :reconciled}
    else
      :already_reconciled ->
        {:ok, :noop}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def reconcile_paid_subscription_renewal_for_system(_order_id, _opts) do
    {:error, Error.new("VALIDATION_ERROR", "order_id must be a UUID")}
  end

  defp count_due_renewal_results(due_subscriptions, now) do
    Enum.reduce(due_subscriptions, %{success: 0, failed: 0}, fn subscription, acc ->
      case run_single_due_renewal(subscription, now) do
        :ok -> %{success: acc.success + 1, failed: acc.failed}
        {:error, _reason} -> %{success: acc.success, failed: acc.failed + 1}
      end
    end)
  end

  defp due_job_for_subscription(%Subscription{} = subscription, now) do
    with {:ok, renewal_key} <- due_renewal_key(subscription, now) do
      {:ok,
       %{
         subscription_id: subscription.id,
         renewal_key: renewal_key,
         schedule_in: Scheduler.renewal_jitter_seconds(subscription.id)
       }}
    end
  end

  defp due_renewal_key(%Subscription{} = subscription, now) do
    with :ok <- ensure_subscription_contract_resolved(subscription),
         {:ok, revision} <- fetch_plan_revision(subscription.current_plan_revision_id),
         :ok <- ensure_revision_belongs_to_plan(revision, subscription.subscription_plan_id),
         {:ok, renewal_period} <- renewal_period(subscription, revision, now) do
      {:ok, Scheduler.renewal_key(subscription.id, renewal_period.current_period_end_at)}
    end
  end

  defp fetch_subscription_for_renewal(subscription_id) do
    query =
      Subscription
      |> Ash.Query.filter(expr(id == ^subscription_id))
      |> Ash.Query.load([:subscription_plan])

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [%Subscription{} = subscription | _]} ->
        {:ok, subscription}

      {:ok, []} ->
        {:error, Error.new("SUBSCRIPTION_NOT_FOUND", "subscription not found")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_subscription_due(
         %Subscription{status: :active, next_renewal_at: %DateTime{} = next_at},
         now
       ) do
    if DateTime.compare(next_at, now) in [:lt, :eq], do: :ok, else: :not_due
  end

  defp ensure_subscription_due(
         %Subscription{status: :past_due, retry_suppressed_at: %DateTime{}},
         _now
       ),
       do: :not_due

  defp ensure_subscription_due(
         %Subscription{status: :past_due, retry_suppressed_at: nil, next_retry_at: nil},
         _now
       ),
       do: :ok

  defp ensure_subscription_due(
         %Subscription{
           status: :past_due,
           retry_suppressed_at: nil,
           next_retry_at: %DateTime{} = next_retry_at
         },
         now
       ) do
    if DateTime.compare(next_retry_at, now) in [:lt, :eq], do: :ok, else: :not_due
  end

  defp ensure_subscription_due(_subscription, _now), do: :not_due

  defp ensure_matching_renewal_key(nil, _current_renewal_key), do: :ok

  defp ensure_matching_renewal_key(expected_renewal_key, current_renewal_key)
       when expected_renewal_key == current_renewal_key,
       do: :ok

  defp ensure_matching_renewal_key(_expected_renewal_key, _current_renewal_key), do: :stale

  defp run_single_due_renewal(%Subscription{} = subscription, now) do
    started_at = System.monotonic_time()

    result =
      with :ok <- ensure_subscription_contract_resolved(subscription),
           {:ok, live_revision} <- fetch_plan_revision(subscription.current_plan_revision_id),
           :ok <-
             ensure_revision_belongs_to_plan(live_revision, subscription.subscription_plan_id),
           {:ok, renewal_identity_period} <- renewal_period(subscription, live_revision, now),
           renewal_key <-
             Scheduler.renewal_key(subscription.id, renewal_identity_period.current_period_end_at),
           {:ok, expiry_policy} <-
             renewal_policy_for_occurrence(subscription, renewal_key, live_revision),
           :continue <- maybe_expire_past_due(subscription, expiry_policy, now),
           {:ok, binding} <- bind_renewal_attempt(subscription, renewal_key) do
        bound_subscription = binding.subscription
        bound_attempt = binding.attempt
        bound_policy = renewal_policy_from_attempt(bound_attempt)

        result =
          case claim_renewal_attempt(bound_attempt) do
            :ok ->
              run_claimed_due_renewal(bound_subscription, bound_attempt, now)

            {:skip, :already_claimed} ->
              :ok

            {:error, reason} ->
              {:error, reason}
          end

        settle_claimed_due_renewal_result(bound_subscription, bound_policy, result, now)
      else
        :expired ->
          :ok

        {:error,
         %Error{
           code: "VALIDATION_ERROR",
           message: @unresolved_contract_message
         } = error} ->
          {:error, error}

        {:error, %Error{code: "STALE_RECORD"} = error} ->
          {:error, error}

        {:error, %Error{code: "VALIDATION_ERROR"} = error} ->
          {:error, error}

        {:error, reason} ->
          mark_subscription_past_due(subscription, reason)
          |> stale_result_or({:error, reason})
      end

    emit_subscription_renewal_attempt_telemetry(subscription, result, started_at)
    result
  end

  defp settle_claimed_due_renewal_result(_subscription, _plan, :ok, _now), do: :ok

  defp settle_claimed_due_renewal_result(
         _subscription,
         _plan,
         {:error, %Error{code: "STALE_RECORD"} = error},
         _now
       ),
       do: {:error, error}

  defp settle_claimed_due_renewal_result(
         _subscription,
         _plan,
         {:error, %Error{code: "PAYMENT_AUTHENTICATION_REQUIRED"} = error},
         _now
       ),
       do: {:error, error}

  defp settle_claimed_due_renewal_result(
         subscription,
         plan,
         {:error, %Error{} = error},
         now
       ) do
    mark_subscription_past_due(subscription, plan, error, now)
    |> stale_result_or({:error, error})
  end

  defp settle_claimed_due_renewal_result(subscription, plan, {:error, reason}, now) do
    mark_subscription_past_due(subscription, plan, reason, now)
    |> stale_result_or({:error, reason})
  end

  defp ensure_subscription_contract_resolved(%Subscription{current_plan_revision_id: id})
       when is_binary(id),
       do: :ok

  defp ensure_subscription_contract_resolved(%Subscription{}) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       @unresolved_contract_message
     )}
  end

  defp ensure_no_future_target_for_renewal(%Subscription{} = subscription) do
    if is_binary(subscription.current_contract_change_id) or
         legacy_future_projection?(subscription) do
      {:error, Error.new("VALIDATION_ERROR", @unresolved_contract_message)}
    else
      case fetch_queued_contract_change(subscription.id) do
        {:ok, nil} ->
          :ok

        {:ok, _orphaned_target} ->
          {:error, Error.new("VALIDATION_ERROR", @unresolved_contract_message)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ensure_paid_reconciliation_contract(
         %Subscription{} = subscription,
         %RenewalAttempt{} = attempt
       ) do
    with :ok <- ensure_complete_bound_renewal_attempt(attempt),
         :ok <- ensure_paid_reconciliation_has_no_bound_target(attempt) do
      ensure_no_future_target_for_renewal(subscription)
    end
  end

  defp ensure_paid_reconciliation_has_no_bound_target(%RenewalAttempt{contract_change_id: id})
       when is_binary(id) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "ContractChange-bound renewal requires charged-contract reconciliation"
     )}
  end

  defp ensure_paid_reconciliation_has_no_bound_target(%RenewalAttempt{}), do: :ok

  defp legacy_future_projection?(%Subscription{} = subscription) do
    is_binary(subscription.pending_subscription_plan_id) or
      is_binary(subscription.pending_variant_id) or
      not is_nil(subscription.pending_renewal_amount_minor) or
      not is_nil(subscription.pending_renewal_currency) or
      not is_nil(subscription.change_effective_at)
  end

  defp run_claimed_due_renewal(subscription, attempt, now) do
    renewal_period = renewal_period_from_attempt(attempt)

    with {:ok, effective_contract} <- effective_renewal_contract(attempt),
         :ok <- ensure_renewal_chargeability(subscription, effective_contract.plan),
         {:ok, checkout} <-
           build_or_reuse_renewal_checkout(
             subscription,
             effective_contract,
             renewal_period,
             attempt,
             now
           ),
         {:ok, _payment_intent} <-
           request_off_session_renewal_charge(
             subscription,
             effective_contract.plan,
             attempt,
             checkout,
             now
           ) do
      :ok
    else
      {:error, %Error{code: "STALE_RECORD"} = reason} ->
        {:error, reason}

      {:error, %Error{code: "PAYMENT_AUTHENTICATION_REQUIRED"} = reason} ->
        _ = mark_attempt_failed(attempt, reason)
        {:error, reason}

      {:error, reason} ->
        case mark_attempt_failed(attempt, reason) do
          :terminal_success ->
            :ok

          :ok ->
            {:error, reason}
        end
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

  defp fetch_order_for_system(order_id) do
    query = Order |> Ash.Query.filter(expr(id == ^order_id))

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, [%Order{} = order | _]} -> {:ok, order}
      {:ok, []} -> {:error, Error.new("ORDER_NOT_FOUND", "order not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
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

  defp create_subscription_from_line(
         %Order{} = order,
         %OrderLineItem{} = line_item,
         %PaymentIntent{} = payment_intent,
         stored_payment_method
       ) do
    with {:ok, nil} <- fetch_subscription_by_source_line(line_item.id),
         {:ok, plan} <- fetch_plan(Map.get(line_item, :subscription_plan_id_snapshot)),
         {:ok, revision} <-
           fetch_plan_revision(Map.get(line_item, :subscription_plan_revision_id_snapshot)),
         :ok <- ensure_revision_belongs_to_plan(revision, plan.id),
         :ok <- ensure_revision_has_purchase_history(revision),
         {:ok, provider_selection} <- resolve_provider_and_billing_mode(order, plan),
         period <-
           Scheduler.initial_period(
             DateTime.utc_now() |> DateTime.truncate(:microsecond),
             revision
           ),
         {:ok, subscription, subscription_notifications} <-
           create_subscription_record(
             order,
             line_item,
             plan,
             revision,
             period,
             provider_selection,
             payment_intent,
             stored_payment_method
           ),
         {:ok, _item, item_notifications} <-
           create_subscription_item_record(subscription, line_item, plan, revision) do
      {:ok, :created, %{subscription: subscription, plan: plan, revision: revision},
       subscription_notifications ++ item_notifications}
    else
      {:ok, %Subscription{}} ->
        {:ok, :skipped, []}

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

  defp fetch_plan_revision(revision_id) when is_binary(revision_id) do
    query = PlanRevision |> Ash.Query.filter(expr(id == ^revision_id))

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [%PlanRevision{} = revision | _]} ->
        {:ok, revision}

      {:ok, []} ->
        {:error, Error.new("VALIDATION_ERROR", @unresolved_contract_message)}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_plan_revision(_revision_id) do
    {:error, Error.new("VALIDATION_ERROR", @unresolved_contract_message)}
  end

  defp ensure_revision_belongs_to_plan(
         %PlanRevision{subscription_plan_id: subscription_plan_id},
         subscription_plan_id
       ),
       do: :ok

  defp ensure_revision_belongs_to_plan(_revision, _subscription_plan_id) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "purchased plan revision does not belong to the snapshotted subscription plan"
     )}
  end

  defp ensure_revision_has_purchase_history(%PlanRevision{status: status})
       when status in [:effective, :retired],
       do: :ok

  defp ensure_revision_has_purchase_history(%PlanRevision{}) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "purchased plan revision was never effective"
     )}
  end

  defp resolve_provider_and_billing_mode(%Order{} = order, _plan) do
    with {:ok, %PaymentIntent{} = payment_intent} <- fetch_succeeded_payment_intent(order.id),
         {:ok, provider} <- normalize_selected_provider(payment_intent.provider),
         :ok <- Providers.ensure_enabled_provider(provider),
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
      :unknown ->
        {:error,
         Error.new("SUBSCRIPTION_PROVIDER_UNSUPPORTED", "subscription provider is unsupported")}

      known ->
        if Providers.known_provider?(known) do
          {:ok, known}
        else
          {:error,
           Error.new(
             "SUBSCRIPTION_PROVIDER_UNSUPPORTED",
             "subscription provider is unsupported"
           )}
        end
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

  defp create_subscription_record(
         order,
         line_item,
         plan,
         revision,
         period,
         provider_selection,
         payment_intent,
         stored_payment_method
       ) do
    attrs = %{
      user_id: order.user_id,
      subscription_plan_id: plan.id,
      variant_id: line_item.variant_id_snapshot,
      status: :active,
      provider: provider_selection.provider,
      billing_mode: provider_selection.billing_mode,
      quantity: line_item.quantity,
      renewal_amount_minor: revision.amount_minor,
      renewal_currency: String.upcase(revision.currency),
      membership_key: membership_key_for_plan(revision),
      provider_customer_ref:
        payment_intent.provider_customer_ref ||
          (stored_payment_method && stored_payment_method.provider_customer_ref),
      provider_billing_ref:
        payment_intent.provider_payment_method_ref ||
          (stored_payment_method && stored_payment_method.provider_payment_method_ref),
      stored_payment_method_id: stored_payment_method && stored_payment_method.id,
      started_at: period.current_period_start_at,
      current_period_start_at: period.current_period_start_at,
      current_period_end_at: period.current_period_end_at,
      next_renewal_at: period.next_renewal_at,
      dunning_attempt_count: 0,
      next_retry_at: nil,
      source_order_id: order.id,
      source_order_line_item_id: line_item.id,
      current_plan_revision_id: revision.id
    }

    Subscription
    |> Ash.Changeset.for_create(:create_from_order_line, attrs, context: %{system?: true})
    |> Ash.create(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> unwrap_create_with_notifications()
  end

  defp maybe_upsert_stored_payment_method(_user_id, %PaymentIntent{} = payment_intent)
       when payment_intent.provider_customer_ref in [nil, ""] or
              payment_intent.provider_payment_method_ref in [nil, ""] do
    {:ok, nil, []}
  end

  defp maybe_upsert_stored_payment_method(user_id, %PaymentIntent{} = payment_intent)
       when is_binary(user_id) do
    with {:ok, provider} <- normalize_selected_provider(payment_intent.provider) do
      StoredPaymentMethod
      |> Ash.Changeset.for_create(
        :create_or_reuse,
        %{
          user_id: user_id,
          provider: provider,
          provider_customer_ref: payment_intent.provider_customer_ref,
          provider_payment_method_ref: payment_intent.provider_payment_method_ref,
          status: :active
        },
        context: %{system?: true}
      )
      |> Ash.create(
        domain: Subscriptions,
        authorize?: false,
        context: %{system?: true},
        return_notifications?: true
      )
      |> unwrap_create_with_notifications()
    end
  end

  defp maybe_upsert_stored_payment_method(_user_id, _payment_intent), do: {:ok, nil, []}

  defp create_subscription_item_record(subscription, line_item, plan, revision) do
    attrs = %{
      subscription_id: subscription.id,
      variant_id: line_item.variant_id_snapshot,
      quantity: line_item.quantity,
      plan_key_snapshot: line_item.subscription_plan_key_snapshot || plan.key,
      amount_minor_snapshot: revision.amount_minor,
      currency_snapshot: revision.currency,
      interval_unit_snapshot: revision.interval_unit,
      interval_count_snapshot: revision.interval_count,
      source_order_line_item_id: line_item.id
    }

    SubscriptionItem
    |> Ash.Changeset.for_create(:create_from_order_line, attrs, context: %{system?: true})
    |> Ash.create(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> unwrap_create_with_notifications()
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

  defp unwrap_create_with_notifications({:ok, record, notifications}) when is_list(notifications),
    do: {:ok, record, notifications}

  defp unwrap_create_with_notifications({:ok, record}), do: {:ok, record, []}
  defp unwrap_create_with_notifications({:error, reason}), do: {:error, reason}

  defp normalize_transaction_notifications({:ok, {:ok, tx_result}}) when is_map(tx_result) do
    {:ok, Map.delete(tx_result, :notifications), Map.get(tx_result, :notifications, [])}
  end

  defp normalize_transaction_notifications({:error, reason}),
    do: {:error, Normalize.normalize(reason)}

  defp issue_subscription_entitlements_after_commit(entitlement_pairs) do
    entitlement_pairs
    |> Enum.reverse()
    |> Enum.reduce(0, fn {subscription, plan}, count ->
      case maybe_issue_entitlement(subscription, plan) do
        :issued -> count + 1
        _ -> count
      end
    end)
  end

  defp run_cancel(%Subscription{} = subscription, mode, actor)
       when mode in [:period_end, :now] do
    action =
      case mode do
        :period_end -> :cancel_at_period_end_transition
        :now -> :cancel_now_transition
      end

    attrs =
      %{
        current_contract_change_id: nil,
        pending_variant_id: nil,
        pending_subscription_plan_id: nil,
        pending_renewal_amount_minor: nil,
        pending_renewal_currency: nil,
        change_effective_at: nil
      }
      |> then(fn attrs ->
        if mode == :now, do: Map.put(attrs, :canceled_reason, "user_request"), else: attrs
      end)

    transaction_result =
      Repo.transaction(fn ->
        cancel_subscription_in_transaction(subscription, action, attrs, actor)
      end)
      |> normalize_transaction_notifications()

    case transaction_result do
      {:ok, %{subscription: canceled}, notifications} ->
        :ok =
          AshNotifications.notify_post_commit(
            notifications,
            context: %{flow: :cancel_subscription, subscription_id: subscription.id, mode: mode}
          )

        if mode == :now do
          finalize_immediate_cancellation(canceled, subscription)
        end

        {:ok, canceled}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp finalize_immediate_cancellation(canceled, subscription) do
    plan =
      case fetch_plan(subscription.subscription_plan_id) do
        {:ok, fetched_plan} -> fetched_plan
        _ -> nil
      end

    _ =
      EntitlementsFacade.revoke_subscription_entitlements_for_system(
        canceled.id,
        "canceled_now"
      )

    _ = maybe_enqueue_membership_access_ended_email(canceled, plan, "canceled_now")
  end

  defp cancel_subscription_in_transaction(subscription, action, attrs, actor) do
    with :ok <- lock_subscription_aggregate_version(subscription),
         {:ok, current_target} <- current_contract_change(subscription),
         {:ok, transition_notifications} <-
           maybe_transition_contract_change(current_target, :cancel),
         {:ok, canceled, subscription_notifications} <-
           update_subscription_contract_change(subscription, action, attrs, actor) do
      {:ok,
       %{
         subscription: canceled,
         notifications: transition_notifications ++ subscription_notifications
       }}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp run_rescind_cancellation(%Subscription{} = subscription, actor) do
    with true <- subscription.cancel_at_period_end,
         true <- subscription.status in [:active, :past_due],
         :ok <- ensure_subscription_contract_resolved(subscription),
         {:ok, revision} <- fetch_plan_revision(subscription.current_plan_revision_id),
         :ok <- ensure_revision_belongs_to_plan(revision, subscription.subscription_plan_id),
         {:ok, effective_at} <- contract_change_effective_at(subscription) do
      target = %{
        instruction_kind: :renew_unchanged,
        target_plan_revision_id: revision.id,
        target_variant_id: subscription.variant_id,
        target_quantity: subscription.quantity,
        target_amount_minor: subscription.renewal_amount_minor,
        target_currency: subscription.renewal_currency,
        effective_at: effective_at
      }

      projection =
        contract_change_projection(
          subscription,
          target,
          subscription.subscription_plan_id
        )

      persist_contract_change(
        subscription,
        target,
        projection,
        actor,
        :rescind_cancel_at_period_end_transition
      )
    else
      false ->
        {:error,
         Error.new(
           "VALIDATION_ERROR",
           "only a current scheduled cancellation can be rescinded"
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp renewal_period(
         %Subscription{current_period_end_at: %DateTime{} = period_start},
         %PlanRevision{} = revision,
         _now
       ) do
    {:ok, Scheduler.next_period(period_start, revision)}
  end

  defp renewal_period(%Subscription{}, %PlanRevision{}, _now) do
    {:error, Error.new("VALIDATION_ERROR", "subscription renewal boundary is missing")}
  end

  defp renewal_period_from_attempt(%RenewalAttempt{
         period_start_at: %DateTime{} = period_start,
         period_end_at: %DateTime{} = period_end
       }) do
    %{
      current_period_start_at: period_start,
      current_period_end_at: period_end,
      next_renewal_at: period_end
    }
  end

  defp renewal_policy_for_occurrence(
         %Subscription{status: :past_due} = subscription,
         renewal_key,
         %PlanRevision{} = live_revision
       ) do
    case fetch_renewal_attempt_by_key(subscription.id, renewal_key) do
      {:ok, attempt} -> renewal_policy_for_existing_attempt(attempt, live_revision)
      {:error, _reason} = error -> error
    end
  end

  defp renewal_policy_for_occurrence(
         %Subscription{},
         _renewal_key,
         %PlanRevision{} = live_revision
       ),
       do: {:ok, renewal_policy(live_revision)}

  defp renewal_policy_for_existing_attempt(nil, %PlanRevision{} = live_revision),
    do: {:ok, renewal_policy(live_revision)}

  defp renewal_policy_for_existing_attempt(
         %RenewalAttempt{} = attempt,
         %PlanRevision{}
       ) do
    with :ok <- ensure_complete_bound_renewal_attempt(attempt) do
      {:ok, renewal_policy_from_attempt(attempt)}
    end
  end

  defp bind_renewal_attempt(%Subscription{} = expected_subscription, renewal_key) do
    transaction_result =
      Repo.transaction(fn ->
        case fetch_renewal_attempt_by_key(expected_subscription.id, renewal_key) do
          {:ok, %RenewalAttempt{} = attempt} ->
            reuse_bound_renewal_attempt(attempt)

          {:ok, nil} ->
            bind_new_renewal_attempt(expected_subscription, renewal_key)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
      |> normalize_transaction_notifications()

    case transaction_result do
      {:ok, binding, notifications} ->
        :ok =
          AshNotifications.notify_post_commit(notifications,
            context: %{
              flow: :bind_renewal_attempt,
              subscription_id: expected_subscription.id,
              renewal_key: renewal_key
            }
          )

        {:ok, binding}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp bind_new_renewal_attempt(expected_subscription, renewal_key) do
    case lock_subscription_aggregate_version(expected_subscription) do
      :ok ->
        bind_locked_or_reuse_attempt(expected_subscription, renewal_key)

      {:error, %Error{code: "STALE_RECORD"} = stale_error} ->
        reuse_attempt_after_stale_lock(expected_subscription, renewal_key, stale_error)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp bind_locked_or_reuse_attempt(expected_subscription, renewal_key) do
    case fetch_renewal_attempt_by_key(expected_subscription.id, renewal_key) do
      {:ok, %RenewalAttempt{} = attempt} -> reuse_bound_renewal_attempt(attempt)
      {:ok, nil} -> bind_locked_new_renewal_attempt(expected_subscription, renewal_key)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp reuse_attempt_after_stale_lock(expected_subscription, renewal_key, stale_error) do
    case fetch_renewal_attempt_by_key(expected_subscription.id, renewal_key) do
      {:ok, %RenewalAttempt{} = attempt} -> reuse_bound_renewal_attempt(attempt)
      {:ok, nil} -> Repo.rollback(stale_error)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp bind_locked_new_renewal_attempt(expected_subscription, renewal_key) do
    with {:ok, subscription} <- fetch_subscription_for_renewal(expected_subscription.id),
         :ok <- ensure_subscription_contract_resolved(subscription),
         {:ok, target} <- current_contract_change(subscription),
         :ok <- ensure_live_contract_has_no_projection(subscription, target),
         {:ok, selection} <- renewal_binding_selection(subscription, target),
         {:ok, plan} <- fetch_plan(selection.revision.subscription_plan_id),
         {:ok, period} <- renewal_period(subscription, selection.revision, nil),
         snapshot <- charged_contract_snapshot(selection.revision, plan),
         attrs <-
           renewal_attempt_binding_attrs(
             subscription,
             expected_subscription.aggregate_version,
             selection,
             period,
             snapshot,
             renewal_key
           ),
         {:ok, attempt, attempt_notifications} <- create_bound_renewal_attempt(attrs),
         :ok <- ensure_complete_bound_renewal_attempt(attempt),
         {:ok, consumed_subscription, consume_notifications} <-
           consume_contract_change_for_renewal(subscription, target) do
      {:ok,
       %{
         subscription: consumed_subscription,
         attempt: attempt,
         notifications: attempt_notifications ++ consume_notifications
       }}
    else
      {:error, reason} ->
        Repo.rollback(Normalize.normalize(reason))
    end
  end

  defp reuse_bound_renewal_attempt(%RenewalAttempt{} = attempt) do
    with :ok <- ensure_complete_bound_renewal_attempt(attempt),
         {:ok, subscription} <- fetch_subscription_for_renewal(attempt.subscription_id) do
      {:ok, %{subscription: subscription, attempt: attempt, notifications: []}}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp renewal_binding_selection(%Subscription{} = subscription, nil) do
    with false <- legacy_future_projection?(subscription),
         {:ok, %PlanRevision{} = revision} <-
           fetch_plan_revision(subscription.current_plan_revision_id),
         :ok <- ensure_revision_belongs_to_plan(revision, subscription.subscription_plan_id),
         :ok <-
           validate_renewal_contract_values(
             subscription.quantity,
             subscription.renewal_amount_minor,
             subscription.renewal_currency
           ) do
      {:ok,
       %{
         plan_revision_id: revision.id,
         revision: revision,
         variant_id: subscription.variant_id,
         quantity: subscription.quantity,
         amount_minor: subscription.renewal_amount_minor,
         currency: subscription.renewal_currency,
         contract_change_id: nil,
         contract_change: nil
       }}
    else
      true -> {:error, inconsistent_current_contract_change_error()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp renewal_binding_selection(
         %Subscription{} = subscription,
         %ContractChange{} = target
       ) do
    with :ok <- ensure_current_target_boundary(subscription, target),
         {:ok, %PlanRevision{} = revision} <- fetch_plan_revision(target.target_plan_revision_id),
         :ok <- ensure_contract_change_price_matches(target, revision),
         :ok <-
           validate_renewal_contract_values(
             target.target_quantity,
             target.target_amount_minor,
             target.target_currency
           ) do
      {:ok,
       %{
         plan_revision_id: revision.id,
         revision: revision,
         variant_id: target.target_variant_id,
         quantity: target.target_quantity,
         amount_minor: target.target_amount_minor,
         currency: target.target_currency,
         contract_change_id: target.id,
         contract_change: target
       }}
    end
  end

  defp ensure_current_target_boundary(
         %Subscription{current_period_end_at: boundary},
         %ContractChange{effective_at: effective_at}
       ) do
    if effective_at == boundary do
      :ok
    else
      {:error, inconsistent_current_contract_change_error()}
    end
  end

  defp ensure_contract_change_price_matches(
         %ContractChange{} = target,
         %PlanRevision{} = revision
       ) do
    if target.target_amount_minor == revision.amount_minor and
         target.target_currency == revision.currency do
      :ok
    else
      {:error,
       Error.new(
         "VALIDATION_ERROR",
         "ContractChange price evidence does not match its PlanRevision"
       )}
    end
  end

  defp ensure_live_contract_has_no_projection(%Subscription{} = subscription, nil) do
    if legacy_future_projection?(subscription),
      do: {:error, Error.new("VALIDATION_ERROR", @unresolved_contract_message)},
      else: :ok
  end

  defp ensure_live_contract_has_no_projection(%Subscription{}, %ContractChange{}), do: :ok

  defp validate_renewal_contract_values(quantity, amount_minor, currency) do
    if is_integer(quantity) and quantity > 0 and is_integer(amount_minor) and amount_minor >= 0 and
         is_binary(currency) and Regex.match?(~r/^[A-Z]{3}$/, currency) do
      :ok
    else
      {:error, Error.new("VALIDATION_ERROR", "renewal contract evidence is invalid")}
    end
  end

  defp renewal_attempt_binding_attrs(
         %Subscription{} = subscription,
         expected_version,
         selection,
         period,
         snapshot,
         renewal_key
       ) do
    %{
      subscription_id: subscription.id,
      period_start_at: period.current_period_start_at,
      period_end_at: period.current_period_end_at,
      renewal_key: renewal_key,
      plan_revision_id: selection.plan_revision_id,
      variant_id: selection.variant_id,
      quantity: selection.quantity,
      amount_minor: selection.amount_minor,
      currency: selection.currency,
      contract_change_id: selection.contract_change_id,
      expected_subscription_version: expected_version,
      charged_contract_version: 1,
      charged_contract_snapshot: snapshot,
      status: :pending
    }
  end

  defp charged_contract_snapshot(%PlanRevision{} = revision, %SubscriptionPlan{} = plan) do
    %{
      "version" => 1,
      "subscription_plan_key" => plan.key,
      "interval_unit" => Atom.to_string(revision.interval_unit),
      "interval_count" => revision.interval_count,
      "trial_days" => revision.trial_days,
      "anchor_mode" => Atom.to_string(revision.anchor_mode),
      "anchor_day_of_month" => revision.anchor_day_of_month,
      "billing_timezone" => revision.billing_timezone,
      "term_mode" => Atom.to_string(revision.term_mode),
      "term_cycles" => revision.term_cycles,
      "term_end_at" => datetime_snapshot(revision.term_end_at),
      "access_on_past_due" => Atom.to_string(revision.access_on_past_due),
      "access_on_cancel" => Atom.to_string(revision.access_on_cancel),
      "grace_period_days" => revision.grace_period_days,
      "max_retry_attempts" => revision.max_retry_attempts,
      "retry_schedule_hours" => revision.retry_schedule_hours,
      "entitlement_kind" => enum_snapshot(revision.entitlement_kind),
      "entitlement_scope_key" => revision.entitlement_scope_key
    }
  end

  defp datetime_snapshot(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime_snapshot(_value), do: nil

  defp enum_snapshot(nil), do: nil
  defp enum_snapshot(value) when is_atom(value), do: Atom.to_string(value)

  defp renewal_policy(%PlanRevision{} = revision) do
    %{
      interval_unit: revision.interval_unit,
      interval_count: revision.interval_count,
      anchor_mode: revision.anchor_mode,
      anchor_day_of_month: revision.anchor_day_of_month,
      billing_timezone: revision.billing_timezone,
      term_mode: revision.term_mode,
      term_cycles: revision.term_cycles,
      term_end_at: revision.term_end_at,
      access_on_past_due: revision.access_on_past_due,
      access_on_cancel: revision.access_on_cancel,
      grace_period_days: revision.grace_period_days,
      max_retry_attempts: revision.max_retry_attempts,
      retry_schedule_hours: revision.retry_schedule_hours,
      entitlement_kind: revision.entitlement_kind,
      entitlement_scope_key: revision.entitlement_scope_key
    }
  end

  defp renewal_policy_from_attempt(%RenewalAttempt{charged_contract_snapshot: snapshot})
       when is_map(snapshot) do
    %{
      interval_unit: snapshot_enum(snapshot, "interval_unit"),
      interval_count: Map.get(snapshot, "interval_count"),
      anchor_mode: snapshot_enum(snapshot, "anchor_mode"),
      anchor_day_of_month: Map.get(snapshot, "anchor_day_of_month"),
      billing_timezone: Map.get(snapshot, "billing_timezone"),
      term_mode: snapshot_enum(snapshot, "term_mode"),
      term_cycles: Map.get(snapshot, "term_cycles"),
      term_end_at: Map.get(snapshot, "term_end_at"),
      access_on_past_due: snapshot_enum(snapshot, "access_on_past_due"),
      access_on_cancel: snapshot_enum(snapshot, "access_on_cancel"),
      grace_period_days: Map.get(snapshot, "grace_period_days"),
      max_retry_attempts: Map.get(snapshot, "max_retry_attempts"),
      retry_schedule_hours: Map.get(snapshot, "retry_schedule_hours"),
      entitlement_kind: snapshot_enum(snapshot, "entitlement_kind"),
      entitlement_scope_key: Map.get(snapshot, "entitlement_scope_key")
    }
  end

  defp snapshot_enum(snapshot, key) do
    values = %{
      "interval_unit" => %{"day" => :day, "month" => :month, "year" => :year},
      "anchor_mode" => %{
        "start_anniversary" => :start_anniversary,
        "fixed_day_of_month" => :fixed_day_of_month
      },
      "term_mode" => %{
        "until_canceled" => :until_canceled,
        "fixed_cycles" => :fixed_cycles,
        "fixed_end_at" => :fixed_end_at
      },
      "access_on_past_due" => %{
        "keep_during_grace" => :keep_during_grace,
        "remove_immediately" => :remove_immediately
      },
      "access_on_cancel" => %{
        "keep_until_period_end" => :keep_until_period_end,
        "remove_immediately" => :remove_immediately
      },
      "entitlement_kind" => %{
        "membership_access" => :membership_access,
        "digital_library" => :digital_library,
        "discount_tier" => :discount_tier
      }
    }

    snapshot
    |> Map.get(key)
    |> then(&Map.get(Map.get(values, key, %{}), &1))
  end

  defp ensure_complete_bound_renewal_attempt(
         %RenewalAttempt{
           charged_contract_version: 1,
           plan_revision_id: plan_revision_id,
           variant_id: variant_id,
           quantity: quantity,
           amount_minor: amount_minor,
           currency: currency,
           expected_subscription_version: expected_version,
           charged_contract_snapshot: snapshot
         } = attempt
       ) do
    binding = %{
      plan_revision_id: plan_revision_id,
      variant_id: variant_id,
      quantity: quantity,
      amount_minor: amount_minor,
      currency: currency,
      expected_subscription_version: expected_version,
      snapshot: snapshot
    }

    if valid_bound_attempt_fields?(binding) and valid_attempt_period?(attempt) do
      :ok
    else
      {:error,
       Error.new("VALIDATION_ERROR", "renewal attempt charged-contract binding is incomplete")}
    end
  end

  defp ensure_complete_bound_renewal_attempt(%RenewalAttempt{}) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "renewal attempt has no durable charged-contract binding"
     )}
  end

  defp valid_bound_attempt_fields?(binding) do
    valid_bound_identity?(binding) and valid_bound_price?(binding) and
      valid_bound_version?(binding) and charged_contract_snapshot_valid?(binding.snapshot)
  end

  defp valid_bound_identity?(%{plan_revision_id: revision_id, variant_id: variant_id}),
    do: is_binary(revision_id) and is_binary(variant_id)

  defp valid_bound_price?(%{quantity: quantity, amount_minor: amount, currency: currency}) do
    is_integer(quantity) and quantity > 0 and is_integer(amount) and amount >= 0 and
      canonical_currency?(currency)
  end

  defp valid_bound_version?(%{expected_subscription_version: version}),
    do: is_integer(version) and version > 0

  defp valid_attempt_period?(%RenewalAttempt{period_start_at: start_at, period_end_at: end_at}),
    do: match?(%DateTime{}, start_at) and match?(%DateTime{}, end_at)

  defp canonical_currency?(currency) when is_binary(currency),
    do: Regex.match?(~r/^[A-Z]{3}$/, currency)

  defp canonical_currency?(_currency), do: false

  defp charged_contract_snapshot_valid?(snapshot) do
    snapshot_keys_present?(snapshot) and snapshot_identity_valid?(snapshot) and
      snapshot_period_valid?(snapshot) and snapshot_term_valid?(snapshot) and
      snapshot_access_valid?(snapshot) and snapshot_retry_valid?(snapshot) and
      snapshot_entitlement_valid?(snapshot)
  end

  defp snapshot_keys_present?(snapshot) do
    keys = [
      "version",
      "subscription_plan_key",
      "interval_unit",
      "interval_count",
      "trial_days",
      "anchor_mode",
      "anchor_day_of_month",
      "billing_timezone",
      "term_mode",
      "term_cycles",
      "term_end_at",
      "access_on_past_due",
      "access_on_cancel",
      "grace_period_days",
      "max_retry_attempts",
      "retry_schedule_hours",
      "entitlement_kind",
      "entitlement_scope_key"
    ]

    is_map(snapshot) and Enum.all?(keys, &Map.has_key?(snapshot, &1))
  end

  defp snapshot_identity_valid?(snapshot) do
    Map.get(snapshot, "version") == 1 and
      is_binary(Map.get(snapshot, "subscription_plan_key"))
  end

  defp snapshot_period_valid?(snapshot) do
    unit_valid? = Map.get(snapshot, "interval_unit") in ["day", "month", "year"]
    interval_count = Map.get(snapshot, "interval_count")
    count_valid? = is_integer(interval_count) and interval_count > 0

    anchor_valid? =
      Map.get(snapshot, "anchor_mode") in ["start_anniversary", "fixed_day_of_month"]

    timezone_valid? = is_binary(Map.get(snapshot, "billing_timezone"))
    trial_valid? = optional_non_negative_integer?(Map.get(snapshot, "trial_days"))
    anchor_day_valid? = optional_integer_in?(Map.get(snapshot, "anchor_day_of_month"), 1..31)

    unit_valid? and count_valid? and anchor_valid? and timezone_valid? and trial_valid? and
      anchor_day_valid?
  end

  defp snapshot_term_valid?(snapshot) do
    mode = Map.get(snapshot, "term_mode")

    valid_term_mode?(mode) and
      valid_term_cycles?(mode, Map.get(snapshot, "term_cycles")) and
      valid_term_end?(mode, Map.get(snapshot, "term_end_at"))
  end

  defp valid_term_mode?(mode),
    do: mode in ["until_canceled", "fixed_cycles", "fixed_end_at"]

  defp valid_term_cycles?(mode, cycles) do
    optional_cycles_valid? = is_nil(cycles) or (is_integer(cycles) and cycles > 0)
    required_cycles_valid? = mode != "fixed_cycles" or is_integer(cycles)

    optional_cycles_valid? and required_cycles_valid?
  end

  defp valid_term_end?(mode, end_at) do
    optional_end_valid? = is_nil(end_at) or is_binary(end_at)
    required_end_valid? = mode != "fixed_end_at" or is_binary(end_at)

    optional_end_valid? and required_end_valid?
  end

  defp snapshot_access_valid?(snapshot) do
    Map.get(snapshot, "access_on_past_due") in ["keep_during_grace", "remove_immediately"] and
      Map.get(snapshot, "access_on_cancel") in ["keep_until_period_end", "remove_immediately"] and
      non_negative_integer?(Map.get(snapshot, "grace_period_days"))
  end

  defp snapshot_retry_valid?(snapshot) do
    non_negative_integer?(Map.get(snapshot, "max_retry_attempts")) and
      is_list(Map.get(snapshot, "retry_schedule_hours")) and
      Enum.all?(Map.get(snapshot, "retry_schedule_hours"), &non_negative_integer?/1)
  end

  defp snapshot_entitlement_valid?(snapshot) do
    kind = Map.get(snapshot, "entitlement_kind")
    scope = Map.get(snapshot, "entitlement_scope_key")

    kind_valid? =
      is_nil(kind) or kind in ["membership_access", "digital_library", "discount_tier"]

    scope_valid? = is_nil(scope) or is_binary(scope)

    kind_valid? and scope_valid? and (is_nil(kind) or is_binary(scope))
  end

  defp optional_non_negative_integer?(nil), do: true
  defp optional_non_negative_integer?(value), do: non_negative_integer?(value)

  defp optional_integer_in?(nil, _range), do: true

  defp optional_integer_in?(value, range),
    do: is_integer(value) and value in range

  defp non_negative_integer?(value),
    do: is_integer(value) and value >= 0

  defp fetch_renewal_attempt_by_key(subscription_id, renewal_key) do
    query =
      RenewalAttempt
      |> Ash.Query.filter(
        expr(subscription_id == ^subscription_id and renewal_key == ^renewal_key)
      )

    case Ash.read_one(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, %RenewalAttempt{} = attempt} -> {:ok, attempt}
      {:ok, nil} -> {:ok, nil}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp create_bound_renewal_attempt(attrs) do
    RenewalAttempt
    |> Ash.Changeset.for_create(:create_or_reuse, attrs, context: %{system?: true})
    |> Ash.create(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> unwrap_create_with_notifications()
    |> case do
      {:ok, %RenewalAttempt{} = attempt, notifications} -> {:ok, attempt, notifications}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp consume_contract_change_for_renewal(
         %Subscription{} = subscription,
         %ContractChange{id: contract_change_id} = target
       ) do
    with true <- subscription.current_contract_change_id == contract_change_id,
         {:ok, _bound_change, change_notifications} <- bind_contract_change_to_renewal(target),
         {:ok, updated_subscription, subscription_notifications} <-
           update_subscription_after_renewal_target_consumption(subscription) do
      {:ok, updated_subscription, change_notifications ++ subscription_notifications}
    else
      false -> {:error, inconsistent_current_contract_change_error()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp consume_contract_change_for_renewal(%Subscription{} = subscription, nil),
    do: {:ok, subscription, []}

  defp bind_contract_change_to_renewal(%ContractChange{} = target) do
    target
    |> Ash.Changeset.for_update(:bind_to_renewal, %{}, context: %{system?: true})
    |> Ash.update(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> case do
      {:ok, %ContractChange{} = bound, notifications} -> {:ok, bound, notifications}
      {:ok, %ContractChange{} = bound} -> {:ok, bound, []}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp update_subscription_after_renewal_target_consumption(subscription) do
    attrs = %{
      current_contract_change_id: nil,
      pending_variant_id: nil,
      pending_subscription_plan_id: nil,
      pending_renewal_amount_minor: nil,
      pending_renewal_currency: nil,
      change_effective_at: nil
    }

    subscription
    |> Ash.Changeset.for_update(:consume_contract_change_for_renewal, attrs,
      context: %{system?: true}
    )
    |> Ash.update(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> case do
      {:ok, %Subscription{} = updated, notifications} -> {:ok, updated, notifications}
      {:ok, %Subscription{} = updated} -> {:ok, updated, []}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
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
      {:ok, _updated_attempt} ->
        :ok

      {:error, reason} ->
        if terminal_success_conflict?(reason), do: :terminal_success, else: :ok
    end
  end

  defp terminal_success_conflict?(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  defp terminal_success_conflict?(_reason), do: false

  defp ensure_renewal_chargeability(subscription, _plan) do
    with :ok <- Providers.ensure_enabled_provider(subscription.provider),
         {:ok, %StoredPaymentMethod{} = stored_payment_method} <-
           fetch_active_stored_payment_method(subscription),
         true <- stored_payment_method.provider == subscription.provider do
      :ok
    else
      false ->
        {:error,
         Error.new(
           "PAYMENT_METHOD_REQUIRED",
           "active stored payment method provider does not match subscription provider"
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_active_stored_payment_method(%Subscription{stored_payment_method_id: nil}) do
    {:error,
     Error.new(
       "PAYMENT_METHOD_REQUIRED",
       "subscription cannot renew without an active stored payment method"
     )}
  end

  defp fetch_active_stored_payment_method(%Subscription{
         stored_payment_method_id: stored_payment_method_id,
         user_id: user_id
       })
       when is_binary(stored_payment_method_id) and is_binary(user_id) do
    query =
      StoredPaymentMethod
      |> Ash.Query.filter(
        expr(id == ^stored_payment_method_id and user_id == ^user_id and status == :active)
      )
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [%StoredPaymentMethod{} = stored_payment_method | _]} ->
        {:ok, stored_payment_method}

      {:ok, []} ->
        {:error,
         Error.new(
           "PAYMENT_METHOD_REQUIRED",
           "subscription cannot renew without an active stored payment method"
         )}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_active_stored_payment_method(%Subscription{}) do
    {:error,
     Error.new(
       "PAYMENT_METHOD_REQUIRED",
       "subscription cannot renew without an active stored payment method"
     )}
  end

  defp effective_renewal_contract(%RenewalAttempt{} = attempt) do
    with :ok <- ensure_complete_bound_renewal_attempt(attempt),
         {:ok, %PlanRevision{} = revision} <- fetch_plan_revision(attempt.plan_revision_id),
         {:ok, %Variant{} = variant} <- fetch_variant_for_renewal(attempt.variant_id) do
      snapshot = attempt.charged_contract_snapshot
      policy = renewal_policy_from_attempt(attempt)

      plan =
        Map.merge(policy, %{
          id: revision.subscription_plan_id,
          key: Map.get(snapshot, "subscription_plan_key"),
          amount_minor: attempt.amount_minor,
          currency: attempt.currency
        })

      membership_key =
        if policy.entitlement_kind == :membership_access,
          do: policy.entitlement_scope_key,
          else: nil

      {:ok,
       %{
         plan: plan,
         plan_revision_id: attempt.plan_revision_id,
         variant: variant,
         variant_id: attempt.variant_id,
         quantity: attempt.quantity,
         amount_minor: attempt.amount_minor,
         currency: attempt.currency,
         membership_key: membership_key,
         physical?: physical_renewal_variant?(variant),
         pending_change?: is_binary(attempt.contract_change_id)
       }}
    end
  end

  defp build_or_reuse_renewal_checkout(
         subscription,
         effective_contract,
         renewal_period,
         attempt,
         now
       ) do
    with {:ok, order} <-
           fetch_or_create_renewal_order(
             subscription,
             effective_contract,
             renewal_period,
             attempt,
             now
           ),
         {:ok, order} <-
           prepare_renewal_order(order, subscription, effective_contract, renewal_period, now),
         {:ok, payment_terms} <- renewal_order_payment_terms(order, effective_contract),
         {:ok, payment_intent_result} <-
           Store.Payments.create_or_reuse_payment_intent(
             %{
               order_id: order.id,
               amount_received_minor: payment_terms.amount_minor,
               currency: payment_terms.currency,
               provider: subscription.provider,
               payment_intent_key: renewal_payment_intent_key(attempt.renewal_key)
             },
             context: %{system?: true}
           ),
         :ok <-
           ensure_renewal_payment_intent_matches(
             payment_intent_result.payment_intent,
             order,
             subscription,
             attempt,
             payment_terms
           ),
         {:ok, payment_intent} <-
           maybe_submit_virtual_payment_intent(payment_intent_result.payment_intent),
         {:ok, updated_attempt} <- mark_attempt_processing(attempt, order.id, payment_intent.id) do
      {:ok,
       %{
         order: order,
         payment_intent: payment_intent,
         renewal_attempt: updated_attempt
       }}
    end
  end

  defp prepare_renewal_order(
         %Order{} = order,
         %Subscription{} = subscription,
         %{physical?: true} = effective_contract,
         renewal_period,
         now
       ) do
    with {:ok, snapshot} <- write_virtual_renewal_snapshot(order, effective_contract),
         :ok <- ensure_renewal_snapshot_matches(snapshot, effective_contract) do
      prepare_physical_renewal_order(
        order,
        subscription,
        effective_contract,
        renewal_period,
        now
      )
    end
  end

  defp prepare_renewal_order(
         %Order{} = order,
         %Subscription{} = _subscription,
         effective_contract,
         _renewal_period,
         _now
       ) do
    with {:ok, snapshot} <- write_virtual_renewal_snapshot(order, effective_contract),
         :ok <- ensure_renewal_snapshot_matches(snapshot, effective_contract) do
      finalize_virtual_renewal_order(order, effective_contract)
    end
  end

  defp prepare_physical_renewal_order(
         %Order{totals_finalized_at: %DateTime{}} = order,
         _subscription,
         effective_contract,
         renewal_period,
         now
       ) do
    with :ok <- ensure_physical_renewal_totals_match(order, effective_contract),
         {:ok, _reservation_result} <-
           reserve_renewal_inventory(order, effective_contract, renewal_period, now) do
      {:ok, order}
    end
  end

  defp prepare_physical_renewal_order(
         %Order{} = order,
         _subscription,
         effective_contract,
         renewal_period,
         now
       )
       when not is_nil(order.shipping_rate_id) or not is_nil(order.tax_as_of) do
    with {:ok, _reservation_result} <-
           reserve_renewal_inventory(order, effective_contract, renewal_period, now) do
      case finalize_physical_renewal_order(order, effective_contract) do
        {:ok, prepared_order} ->
          {:ok, prepared_order}

        {:error, reason} ->
          _ = release_renewal_inventory(order)
          {:error, reason}
      end
    end
  end

  defp prepare_physical_renewal_order(
         %Order{} = order,
         %Subscription{} = subscription,
         effective_contract,
         renewal_period,
         now
       ) do
    with {:ok, shipping_profile} <- fetch_subscription_shipping_profile(subscription),
         {:ok, order} <- apply_shipping_profile_to_order(order, shipping_profile),
         {:ok, quote_option} <-
           quote_physical_renewal_shipping(shipping_profile, effective_contract),
         :ok <- ensure_shipping_quote_within_surge_limit(quote_option, shipping_profile),
         {:ok, _reservation_result} <-
           reserve_renewal_inventory(order, effective_contract, renewal_period, now) do
      case prepare_reserved_physical_renewal_order(order, effective_contract, quote_option) do
        {:ok, prepared_order} ->
          {:ok, prepared_order}

        {:error, reason} ->
          _ = release_renewal_inventory(order)
          {:error, reason}
      end
    end
  end

  defp prepare_reserved_physical_renewal_order(
         %Order{} = order,
         effective_contract,
         %QuoteOption{} = quote_option
       ) do
    quote_evidence = QuoteEvidence.from_quote_option(quote_option)

    with {:ok, order} <- persist_renewal_quote_evidence(order, quote_evidence),
         {:ok, quote_output} <-
           evaluate_physical_renewal_quote_output(order, effective_contract, quote_option),
         {:ok, %{order: snapshot_order, idempotent?: idempotent?}} <-
           Orders.write_tax_shipping_snapshot(order.id, quote_output),
         :ok <-
           ensure_new_physical_snapshot_matches_output(
             snapshot_order,
             quote_output,
             idempotent?
           ) do
      finalize_physical_renewal_order(snapshot_order, effective_contract)
    end
  end

  defp persist_renewal_quote_evidence(
         %Order{} = order,
         %QuoteEvidence{} = _quote_evidence
       )
       when not is_nil(order.shipping_rate_id) or not is_nil(order.tax_as_of) do
    {:ok, order}
  end

  defp persist_renewal_quote_evidence(%Order{} = order, %QuoteEvidence{} = quote_evidence) do
    order
    |> Ash.Changeset.for_update(
      :set_shipping_quote_evidence,
      %{
        shipping_quote_hash: quote_evidence.quote_hash,
        shipping_quote_currency_code: quote_evidence.currency_code,
        shipping_quote_amount_minor: quote_evidence.amount_minor,
        shipping_weight_grams: quote_evidence.shipping_weight_grams,
        shipping_method_code: quote_evidence.shipping_method_code,
        shipping_rule_id: quote_evidence.shipping_rule_id,
        shipping_zone_id: quote_evidence.zone_id,
        shipping_effective_from: quote_evidence.effective_from,
        shipping_effective_to: quote_evidence.effective_to
      },
      context: %{system?: true}
    )
    |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp fetch_or_create_renewal_order(
         _subscription,
         _effective_contract,
         _renewal_period,
         %RenewalAttempt{order_id: order_id},
         _now
       )
       when is_binary(order_id) do
    fetch_order_for_system(order_id)
  end

  defp fetch_or_create_renewal_order(
         subscription,
         effective_contract,
         renewal_period,
         attempt,
         _now
       ) do
    begin_attrs = %{
      user_id: subscription.user_id,
      line_items: [
        %{variant_id: effective_contract.variant_id, quantity: effective_contract.quantity}
      ],
      currency: effective_contract.currency,
      as_of: renewal_period.current_period_start_at,
      pricing_contract_version: "phase27_virtual_renewal",
      tax_shipping_inputs: %{}
    }

    with {:ok, begin_checkout} <-
           Orders.begin_checkout(begin_attrs, context: %{system?: true}),
         {:ok, _updated_attempt} <-
           mark_attempt_processing(attempt, begin_checkout.order.id, attempt.payment_intent_id) do
      {:ok, begin_checkout.order}
    end
  end

  defp write_virtual_renewal_snapshot(%Order{} = order, effective_contract) do
    Orders.write_priced_snapshot(
      order.id,
      build_virtual_renewal_pricing_output(effective_contract)
    )
  end

  defp build_virtual_renewal_pricing_output(effective_contract) do
    quantity = effective_contract.quantity
    amount_minor = effective_contract.amount_minor
    line_total_minor = amount_minor * quantity

    %Contract.Output{
      currency: effective_contract.currency,
      subtotal_minor: line_total_minor,
      discount_total_minor: 0,
      total_minor: line_total_minor,
      lines: [
        %{
          line_id: effective_contract.variant_id,
          line_no: 1,
          sku_snapshot: effective_contract.variant.sku || "SUB-RENEWAL",
          product_title_snapshot: effective_contract.variant.product.title,
          variant_title_snapshot: effective_contract.variant.title,
          quantity: quantity,
          unit_price_minor: amount_minor,
          line_total_minor: line_total_minor,
          discount_allocated_minor: 0,
          net_line_total_minor: line_total_minor,
          subscription_plan_id_snapshot: effective_contract.plan.id,
          subscription_plan_revision_id_snapshot: effective_contract.plan_revision_id,
          subscription_plan_key_snapshot: effective_contract.plan.key,
          subscription_interval_unit_snapshot:
            effective_contract.plan.interval_unit |> Atom.to_string(),
          subscription_interval_count_snapshot: effective_contract.plan.interval_count,
          tax_category_snapshot: "STANDARD",
          tax_minor: 0
        }
      ],
      line_allocations: [
        %Contract.LineAllocation{line_id: effective_contract.variant_id, discount_minor: 0}
      ],
      applied_adjustments: []
    }
  end

  defp ensure_renewal_snapshot_matches(
         %{line_items: [line_item], adjustments: []},
         effective_contract
       ) do
    if renewal_line_matches_contract?(line_item, effective_contract) do
      :ok
    else
      renewal_evidence_mismatch()
    end
  end

  defp ensure_renewal_snapshot_matches(_snapshot, _effective_contract),
    do: renewal_evidence_mismatch()

  defp renewal_line_matches_contract?(line_item, effective_contract) do
    renewal_line_matches_amount?(line_item, effective_contract) and
      renewal_line_matches_variant?(line_item, effective_contract) and
      renewal_line_matches_plan?(line_item, effective_contract)
  end

  defp renewal_line_matches_amount?(line_item, effective_contract) do
    expected_total = effective_contract.amount_minor * effective_contract.quantity

    line_item.line_no == 1 and line_item.quantity == effective_contract.quantity and
      line_item.unit_price_minor == effective_contract.amount_minor and
      line_item.currency == effective_contract.currency and
      line_item.line_total_minor == expected_total and
      line_item.net_line_total_minor == expected_total and
      line_item.discount_allocated_minor == 0
  end

  defp renewal_line_matches_variant?(line_item, effective_contract) do
    line_item.variant_id_snapshot == effective_contract.variant_id
  end

  defp renewal_line_matches_plan?(line_item, effective_contract) do
    plan = effective_contract.plan

    line_item.subscription_plan_id_snapshot == plan.id and
      line_item.subscription_plan_revision_id_snapshot == effective_contract.plan_revision_id and
      line_item.subscription_plan_key_snapshot == plan.key and
      line_item.subscription_interval_unit_snapshot == Atom.to_string(plan.interval_unit) and
      line_item.subscription_interval_count_snapshot == plan.interval_count
  end

  defp finalize_virtual_renewal_order(
         %Order{totals_finalized_at: nil} = order,
         effective_contract
       ) do
    finalize_renewal_order(order, effective_contract, nil)
  end

  defp finalize_virtual_renewal_order(%Order{} = order, effective_contract) do
    expected_total = effective_contract.amount_minor * effective_contract.quantity

    if order.currency_code == effective_contract.currency and
         order.items_subtotal_minor == expected_total and
         order.shipping_total_minor == 0 and order.shipping_cost_minor_effective == 0 and
         order.tax_total_minor == 0 and order.grand_total_minor == expected_total do
      {:ok, order}
    else
      renewal_evidence_mismatch()
    end
  end

  defp ensure_new_physical_snapshot_matches_output(_order, _output, true), do: :ok

  defp ensure_new_physical_snapshot_matches_output(
         %Order{} = order,
         %TaxShippingContract.Output{} = output,
         false
       ) do
    if physical_order_currency_matches?(order, output.currency) do
      ensure_new_physical_snapshot_fields_match_output(order, output)
    else
      renewal_evidence_mismatch()
    end
  end

  defp ensure_new_physical_snapshot_matches_output(_order, _output, _idempotent?),
    do: renewal_evidence_mismatch()

  defp ensure_new_physical_snapshot_fields_match_output(
         %Order{} = order,
         %TaxShippingContract.Output{} = output
       ) do
    if shipping_quote_fields_match?(order, output) and
         shipping_adjustment_fields_match?(order, output) and
         shipping_destination_tax_fields_match?(order, output) do
      :ok
    else
      renewal_evidence_mismatch()
    end
  end

  defp shipping_quote_fields_match?(order, output) do
    order.shipping_quote_currency_code == output.currency and
      order.shipping_quote_amount_minor == output.shipping_cost_minor_original and
      order.shipping_method_code == output.selected_shipping_rate_code and
      order.shipping_rate_id == output.selected_shipping_rate_id and
      order.shipping_rate_code == output.selected_shipping_rate_code and
      order.shipping_cost_minor_original == output.shipping_cost_minor_original
  end

  defp shipping_adjustment_fields_match?(order, output) do
    order.shipping_cost_minor_effective == output.shipping_cost_minor_effective and
      order.free_shipping_applied == output.free_shipping_applied and
      order.free_shipping_reason == output.free_shipping_reason and
      order.shipping_tax_minor == output.shipping_tax_minor and
      order.tax_total_minor == output.tax_total_minor
  end

  defp shipping_destination_tax_fields_match?(order, output) do
    order.shipping_country_code == output.destination_country_code and
      order.shipping_region_code == output.destination_region_code and
      order.shipping_postal_code == output.destination_postal_code and
      order.tax_as_of == output.tax_as_of
  end

  defp finalize_physical_renewal_order(%Order{} = order, effective_contract) do
    with :ok <- ensure_physical_shipping_tax_evidence(order, effective_contract) do
      finalize_or_verify_physical_order(order, effective_contract)
    end
  end

  defp finalize_or_verify_physical_order(
         %Order{totals_finalized_at: nil} = order,
         effective_contract
       ) do
    subtotal_minor = effective_contract.amount_minor * effective_contract.quantity

    finalize_renewal_order(order, effective_contract, %{
      currency: effective_contract.currency,
      subtotal_minor: subtotal_minor,
      shipping_cost_minor_effective: order.shipping_cost_minor_effective,
      order_total_minor:
        subtotal_minor + order.shipping_cost_minor_effective + order.tax_total_minor
    })
  end

  defp finalize_or_verify_physical_order(%Order{} = order, effective_contract) do
    case ensure_physical_renewal_totals_match(order, effective_contract) do
      :ok -> {:ok, order}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_physical_renewal_totals_match(%Order{} = order, effective_contract) do
    case ensure_physical_shipping_tax_evidence(order, effective_contract) do
      :ok -> ensure_renewal_order_totals_match(order, effective_contract)
      {:error, _reason} = error -> error
    end
  end

  defp ensure_physical_shipping_tax_evidence(%Order{} = order, effective_contract) do
    if physical_order_currency_matches?(order, effective_contract.currency) and
         physical_shipping_evidence_complete?(order, effective_contract.currency) do
      :ok
    else
      renewal_evidence_mismatch()
    end
  end

  defp physical_shipping_evidence_complete?(order, currency) do
    has_shipping_identity?(order) and has_shipping_amounts?(order) and
      has_shipping_tax_context?(order, currency)
  end

  defp has_shipping_identity?(order) do
    is_binary(order.shipping_rate_id) and is_binary(order.shipping_rate_code) and
      is_binary(order.shipping_method_code) and is_binary(order.shipping_quote_hash) and
      order.shipping_rate_code == order.shipping_method_code
  end

  defp has_shipping_amounts?(order) do
    is_integer(order.shipping_quote_amount_minor) and order.shipping_quote_amount_minor >= 0 and
      is_integer(order.shipping_cost_minor_original) and order.shipping_cost_minor_original >= 0 and
      is_integer(order.shipping_cost_minor_effective) and
      order.shipping_cost_minor_effective >= 0
  end

  defp has_shipping_tax_context?(order, currency) do
    is_integer(order.shipping_tax_minor) and order.shipping_tax_minor >= 0 and
      is_integer(order.tax_total_minor) and order.tax_total_minor >= order.shipping_tax_minor and
      order.shipping_quote_currency_code == currency and
      order.shipping_quote_amount_minor == order.shipping_cost_minor_original and
      not is_nil(order.tax_as_of) and is_binary(order.shipping_country_code)
  end

  defp physical_order_currency_matches?(%Order{} = order, currency) do
    order.currency_code == currency or
      (is_nil(order.currency_code) and is_nil(order.totals_finalized_at))
  end

  defp ensure_renewal_order_totals_match(%Order{} = order, effective_contract) do
    expected_subtotal = effective_contract.amount_minor * effective_contract.quantity

    expected_total =
      expected_subtotal + order.shipping_total_minor + order.tax_total_minor

    if not is_nil(order.totals_finalized_at) and
         order.currency_code == effective_contract.currency and
         order.items_subtotal_minor == expected_subtotal and
         order.shipping_total_minor == order.shipping_cost_minor_effective and
         order.grand_total_minor == expected_total do
      :ok
    else
      renewal_evidence_mismatch()
    end
  end

  defp renewal_order_payment_terms(%Order{} = order, effective_contract) do
    with :ok <- ensure_renewal_order_totals_match(order, effective_contract) do
      {:ok, %{amount_minor: order.grand_total_minor, currency: order.currency_code}}
    end
  end

  defp ensure_renewal_payment_intent_matches(
         %PaymentIntent{} = payment_intent,
         %Order{} = order,
         %Subscription{} = subscription,
         %RenewalAttempt{} = attempt,
         %{amount_minor: amount_minor, currency: currency}
       ) do
    expected_key = renewal_payment_intent_key(attempt.renewal_key)
    expected_provider = Providers.normalize_provider(subscription.provider)
    payment_intent_provider = Providers.normalize_provider(payment_intent.provider)

    if payment_intent.payment_intent_key == expected_key and
         payment_intent.order_id == order.id and
         payment_intent.amount_received_minor == amount_minor and
         payment_intent.currency == currency and
         payment_intent_provider == expected_provider and
         (is_nil(attempt.payment_intent_id) or payment_intent.id == attempt.payment_intent_id) do
      :ok
    else
      renewal_evidence_mismatch()
    end
  end

  defp renewal_evidence_mismatch do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "renewal Order or PaymentIntent evidence does not match the bound contract"
     )}
  end

  defp finalize_renewal_order(%Order{} = order, effective_contract, nil) do
    total_minor = effective_contract.amount_minor * effective_contract.quantity

    order
    |> Ash.Changeset.for_update(
      :finalize_checkout_totals,
      %{
        currency_code: effective_contract.currency,
        items_subtotal_minor: total_minor,
        shipping_total_minor: 0,
        grand_total_minor: total_minor
      },
      context: %{system?: true}
    )
    |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp finalize_renewal_order(%Order{} = order, _effective_contract, quote_output)
       when is_map(quote_output) do
    order
    |> Ash.Changeset.for_update(
      :finalize_checkout_totals,
      %{
        currency_code: quote_output.currency,
        items_subtotal_minor: quote_output.subtotal_minor,
        shipping_total_minor: quote_output.shipping_cost_minor_effective,
        grand_total_minor: quote_output.order_total_minor
      },
      context: %{system?: true}
    )
    |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp fetch_subscription_shipping_profile(%Subscription{} = subscription) do
    case fetch_shipping_profile_order(subscription) do
      {:ok, %Order{} = profile_order} ->
        build_shipping_profile(profile_order)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_shipping_profile_order(%Subscription{} = subscription) do
    latest_paid_order_query =
      from(attempt in RenewalAttempt,
        join: order in Order,
        on: order.id == attempt.order_id,
        where: attempt.subscription_id == ^subscription.id and order.state == :paid,
        order_by: [desc: attempt.inserted_at, desc: attempt.id],
        limit: 1,
        select: order
      )

    case Repo.one(latest_paid_order_query) do
      %Order{} = order ->
        {:ok, order}

      nil when is_binary(subscription.source_order_id) ->
        fetch_order_for_system(subscription.source_order_id)

      nil ->
        {:error,
         Error.new(
           "SHIPPING_PROFILE_MISSING",
           "physical renewal requires a stored shipping profile"
         )}
    end
  rescue
    error ->
      {:error, Normalize.normalize(error)}
  end

  defp build_shipping_profile(%Order{} = order) do
    country_code = normalize_shipping_text(order.shipping_country_code)
    method_code = normalize_shipping_text(order.shipping_method_code)
    baseline_currency = normalize_shipping_text(order.shipping_quote_currency_code)
    address_line1 = normalize_shipping_text(order.shipping_address_line1)

    if country_code in [nil, ""] or method_code in [nil, ""] or address_line1 in [nil, ""] or
         not is_integer(order.shipping_quote_amount_minor) or baseline_currency in [nil, ""] do
      {:error,
       Error.new("SHIPPING_PROFILE_MISSING", "physical renewal requires prior shipping evidence")}
    else
      {:ok,
       %{
         source_order_id: order.id,
         shipping_country_code: country_code,
         shipping_region_code: normalize_shipping_text(order.shipping_region_code),
         shipping_postal_code: normalize_shipping_text(order.shipping_postal_code),
         shipping_address_line1: address_line1,
         shipping_address_line2: normalize_shipping_text(order.shipping_address_line2),
         shipping_method_code: method_code,
         baseline_shipping_amount_minor: order.shipping_quote_amount_minor,
         baseline_shipping_currency: baseline_currency
       }}
    end
  end

  defp apply_shipping_profile_to_order(%Order{} = order, shipping_profile) do
    case update_renewal_order_shipping_address(order, shipping_profile) do
      {:ok, addressed_order} ->
        update_renewal_order_shipping_method(addressed_order, shipping_profile)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_renewal_order_shipping_address(%Order{} = order, shipping_profile) do
    order
    |> Ash.Changeset.for_update(
      :set_shipping_address,
      %{
        shipping_country_code: shipping_profile.shipping_country_code,
        shipping_region_code: shipping_profile.shipping_region_code,
        shipping_postal_code: shipping_profile.shipping_postal_code,
        shipping_address_line1: shipping_profile.shipping_address_line1,
        shipping_address_line2: shipping_profile.shipping_address_line2
      },
      context: %{system?: true}
    )
    |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp update_renewal_order_shipping_method(%Order{} = order, shipping_profile) do
    order
    |> Ash.Changeset.for_update(
      :set_shipping_method,
      %{shipping_rate_code: shipping_profile.shipping_method_code},
      context: %{system?: true}
    )
    |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp quote_physical_renewal_shipping(shipping_profile, effective_contract) do
    request_attrs = %{
      destination_country_code: shipping_profile.shipping_country_code,
      destination_region_code: shipping_profile.shipping_region_code,
      destination_postal_code: shipping_profile.shipping_postal_code,
      currency_code: effective_contract.currency,
      shipping_weight_grams: physical_renewal_weight_grams(effective_contract)
    }

    with {:ok, request} <- QuoteRequest.new(request_attrs),
         {:ok, options} <- ShippingFacade.quote_options_for_system(request, []) do
      select_shipping_quote_option(options, shipping_profile.shipping_method_code)
    else
      {:error, %Error{code: "VALIDATION_ERROR"}} ->
        {:error,
         Error.new(
           "SHIPPING_PROFILE_MISSING",
           "physical renewal requires a valid shipping profile"
         )}

      {:error, _reason} ->
        {:error,
         Error.new("SHIPPING_PROVIDER_DOWN", "unable to fetch shipping quote for renewal")}
    end
  end

  defp select_shipping_quote_option(options, shipping_method_code)
       when is_list(options) and is_binary(shipping_method_code) do
    case Enum.find(options, &(&1.shipping_method_code == shipping_method_code)) do
      %QuoteOption{} = option ->
        {:ok, option}

      nil ->
        {:error,
         Error.new(
           "SHIPPING_UNAVAILABLE",
           "stored shipping method is no longer available for renewal"
         )}
    end
  end

  defp ensure_shipping_quote_within_surge_limit(%QuoteOption{} = option, shipping_profile) do
    baseline_amount = shipping_profile.baseline_shipping_amount_minor
    baseline_currency = shipping_profile.baseline_shipping_currency
    current_currency = normalize_shipping_text(option.currency_code)

    cond do
      not is_integer(baseline_amount) or baseline_amount < 0 or baseline_currency in [nil, ""] ->
        {:error,
         Error.new(
           "SHIPPING_PROFILE_MISSING",
           "physical renewal requires prior shipping evidence"
         )}

      current_currency != baseline_currency ->
        {:error,
         Error.new(
           "SHIPPING_PROFILE_MISSING",
           "renewal shipping currency does not match the stored shipping profile"
         )}

      shipping_cost_surge?(option.amount_minor, baseline_amount) ->
        {:error,
         Error.new(
           "SHIPPING_COST_SURGE",
           "renewal shipping cost exceeds the allowed drift threshold"
         )}

      true ->
        :ok
    end
  end

  defp shipping_cost_surge?(current_amount_minor, baseline_amount_minor)
       when is_integer(current_amount_minor) and is_integer(baseline_amount_minor) do
    diff = current_amount_minor - baseline_amount_minor

    diff > @shipping_surge_absolute_minor or
      (baseline_amount_minor > 0 and
         diff * 10_000 > baseline_amount_minor * @shipping_surge_percent_bps)
  end

  defp reserve_renewal_inventory(%Order{} = order, effective_contract, _renewal_period, _now) do
    Orders.reserve_inventory_for_checkout(
      order.id,
      [%{variant_id: effective_contract.variant_id, quantity: effective_contract.quantity}],
      context: %{system?: true}
    )
  end

  defp evaluate_physical_renewal_quote_output(
         %Order{} = order,
         effective_contract,
         %QuoteOption{} = option
       ) do
    quote_evidence = QuoteEvidence.from_quote_option(option)
    subtotal_minor = effective_contract.amount_minor * effective_contract.quantity

    with {:ok, tax_rates} <- fetch_active_tax_rates(order.shipping_country_code),
         input <-
           TaxShippingContract.to_input!(%{
             as_of: DateTime.utc_now() |> DateTime.truncate(:microsecond),
             currency: effective_contract.currency,
             destination_country_code: order.shipping_country_code,
             destination_region_code: order.shipping_region_code,
             destination_postal_code: order.shipping_postal_code,
             subtotal_minor: subtotal_minor,
             shipping_weight_grams: quote_evidence.shipping_weight_grams,
             lines: [
               %{
                 line_id: effective_contract.variant_id,
                 line_no: 1,
                 net_line_total_minor: subtotal_minor,
                 tax_category_snapshot: "STANDARD"
               }
             ],
             shipping_rates: [shipping_candidate_from_quote_evidence(quote_evidence)],
             tax_rates: Enum.map(tax_rates, &tax_rate_candidate/1),
             free_shipping_coupon?: false,
             shipping_enabled?: true,
             tax_enabled?: true
           }),
         {:ok, output} <- TaxShippingEvaluator.evaluate(input) do
      {:ok, output}
    else
      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_active_tax_rates(country_code) when is_binary(country_code) do
    query = TaxRate |> Ash.Query.filter(expr(country_code == ^country_code))

    case Ash.read(query, domain: Store.Pricing, authorize?: false) do
      {:ok, tax_rates} -> {:ok, tax_rates}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp shipping_candidate_from_quote_evidence(%QuoteEvidence{} = quote_evidence) do
    %{
      id: quote_evidence.shipping_rule_id || "00000000-0000-0000-0000-000000000000",
      code: quote_evidence.shipping_method_code,
      shipping_cost_minor: quote_evidence.amount_minor,
      country_code: quote_evidence.destination_country_code,
      region_code: quote_evidence.destination_region_code,
      weight_min_grams: nil,
      weight_max_grams: nil,
      free_over_subtotal_minor: nil,
      allow_free_shipping_coupon: false,
      starts_at: quote_evidence.effective_from,
      ends_at: quote_evidence.effective_to,
      active?: true,
      precedence_rank: 0
    }
  end

  defp tax_rate_candidate(rate) do
    %{
      id: rate.id,
      code: rate.code,
      country_code: rate.country_code,
      region_code: rate.region_code,
      product_tax_category: rate.product_tax_category,
      rate_basis_points: rate.rate_basis_points,
      shipping_taxable: rate.shipping_taxable,
      starts_at: rate.starts_at,
      ends_at: rate.ends_at,
      active?: rate.active,
      precedence_rank: rate.precedence_rank
    }
  end

  defp physical_renewal_weight_grams(effective_contract) do
    max((effective_contract.variant.weight_grams || 0) * effective_contract.quantity, 0)
  end

  defp normalize_shipping_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_shipping_text(_value), do: nil

  defp hard_retry_suppressed_reason?(message) when is_binary(message) do
    MapSet.member?(@hard_retry_suppressed_reasons, message)
  end

  defp hard_retry_suppressed_reason?(_message), do: false

  defp maybe_submit_virtual_payment_intent(%PaymentIntent{state: :created} = payment_intent) do
    payment_intent
    |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
    |> Ash.update(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp maybe_submit_virtual_payment_intent(%PaymentIntent{state: state} = payment_intent)
       when state in [:submitted, :requires_action, :succeeded] do
    {:ok, payment_intent}
  end

  defp maybe_submit_virtual_payment_intent(%PaymentIntent{}) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "payment intent cannot be submitted from the current state"
     )}
  end

  defp request_off_session_renewal_charge(
         subscription,
         plan,
         attempt,
         %{order: order, payment_intent: payment_intent},
         now
       ) do
    with {:ok, stored_payment_method} <- fetch_active_stored_payment_method(subscription),
         {:ok, charge_response} <-
           Providers.charge_off_session(
             subscription.provider,
             %{
               amount_minor: payment_intent.amount_received_minor,
               currency: payment_intent.currency,
               renewal_key: attempt.renewal_key,
               local_intent_id: payment_intent.id,
               order_id: order.id,
               renewal_attempt_id: attempt.id,
               subscription_id: subscription.id,
               provider_customer_ref: stored_payment_method.provider_customer_ref,
               provider_payment_method_ref: stored_payment_method.provider_payment_method_ref
             },
             []
           ),
         {:ok, payment_intent} <-
           persist_payment_intent_provider_refs(payment_intent, charge_response) do
      case Map.get(charge_response, :status) do
        :succeeded ->
          {:ok, payment_intent}

        :failed ->
          _ = release_renewal_inventory(order)
          _ = mark_virtual_payment_intent_failed(payment_intent)

          {:error,
           Error.new(
             "PAYMENT_FAILED",
             "off-session renewal charge failed"
           )}

        :requires_action ->
          _ = release_renewal_inventory(order)
          _ = mark_virtual_payment_intent_requires_action(payment_intent)

          subscription_update_result =
            mark_subscription_authentication_required(subscription, plan, now, charge_response)

          _ = enqueue_payment_authentication_required_email(order, charge_response)

          stale_result_or(
            subscription_update_result,
            {:error,
             Error.new(
               "PAYMENT_AUTHENTICATION_REQUIRED",
               "customer authentication is required to complete renewal"
             )}
          )

        _ ->
          {:error, Error.new("PAYMENT_PROVIDER_DOWN", "unexpected recurring charge response")}
      end
    end
  end

  defp release_renewal_inventory(%Order{} = order) do
    Orders.release_reservations_for_order(order.id, context: %{system?: true})
    :ok
  end

  defp persist_payment_intent_provider_refs(%PaymentIntent{} = payment_intent, charge_response) do
    payment_intent
    |> Ash.Changeset.for_update(
      :set_provider_reference,
      %{
        provider: payment_intent.provider,
        provider_payment_id: Map.get(charge_response, :provider_payment_id),
        provider_customer_ref: Map.get(charge_response, :provider_customer_ref),
        provider_payment_method_ref: Map.get(charge_response, :provider_payment_method_ref),
        provider_client_secret: Map.get(charge_response, :provider_client_secret)
      },
      context: %{system?: true}
    )
    |> Ash.update(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp mark_virtual_payment_intent_failed(%PaymentIntent{state: :failed}), do: :ok

  defp mark_virtual_payment_intent_failed(%PaymentIntent{} = payment_intent) do
    payment_intent
    |> Ash.Changeset.for_update(:mark_failed, %{}, context: %{system?: true})
    |> Ash.update(domain: Store.Payments, authorize?: false, context: %{system?: true})

    :ok
  end

  defp mark_virtual_payment_intent_requires_action(%PaymentIntent{state: :requires_action}),
    do: :ok

  defp mark_virtual_payment_intent_requires_action(%PaymentIntent{} = payment_intent) do
    payment_intent
    |> Ash.Changeset.for_update(:mark_requires_action, %{}, context: %{system?: true})
    |> Ash.update(domain: Store.Payments, authorize?: false, context: %{system?: true})

    :ok
  end

  defp mark_attempt_processing(%RenewalAttempt{} = attempt, order_id, payment_intent_id) do
    attempt
    |> Ash.Changeset.for_update(
      :mark_processing,
      %{order_id: order_id, payment_intent_id: payment_intent_id},
      context: %{system?: true}
    )
    |> Ash.update(domain: Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp mark_subscription_authentication_required(subscription, plan, now, charge_response) do
    next_retry_at = Scheduler.grace_expires_at(now, plan)
    next_attempt_count = max((subscription.dunning_attempt_count || 0) + 1, 1)

    subscription
    |> Ash.Changeset.for_update(
      :mark_past_due_transition,
      %{
        billing_status_reason: "PAYMENT_AUTHENTICATION_REQUIRED",
        dunning_attempt_count: next_attempt_count,
        next_retry_at: next_retry_at
      },
      context: %{system?: true}
    )
    |> Ash.update(domain: Subscriptions, authorize?: false, context: %{system?: true})
    |> normalize_subscription_update_result(subscription)
    |> case do
      {:error, %Error{code: "STALE_RECORD"} = error} -> {:error, error}
      _ -> charge_response
    end
  end

  defp enqueue_payment_authentication_required_email(%Order{} = order, charge_response) do
    Comms.enqueue_payment_authentication_required_for_system(
      order.id,
      action_url: Map.get(charge_response, :action_url),
      provider_client_secret: Map.get(charge_response, :provider_client_secret)
    )
  end

  defp maybe_enqueue_membership_access_ended_email(
         %Subscription{} = subscription,
         %SubscriptionPlan{entitlement_kind: :membership_access},
         reason
       )
       when is_binary(reason) do
    Comms.enqueue_membership_access_ended_for_system(subscription.id, reason)
  end

  defp maybe_enqueue_membership_access_ended_email(_subscription, _plan, _reason), do: :ok

  defp fetch_variant_for_renewal(variant_id) when is_binary(variant_id) do
    query =
      Variant
      |> Ash.Query.filter(expr(id == ^variant_id))
      |> Ash.Query.load([:product])

    case Ash.read(query, domain: Store.Catalog, authorize?: false, context: %{system?: true}) do
      {:ok, [%Variant{} = variant | _]} ->
        {:ok, variant}

      {:ok, []} ->
        {:error, Error.new("VALIDATION_ERROR", "subscription variant is unavailable")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_variant_subscription_plan_active(variant_id, plan_id) do
    query =
      VariantSubscriptionPlan
      |> Ash.Query.filter(
        expr(variant_id == ^variant_id and subscription_plan_id == ^plan_id and active == true)
      )
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [_ | _]} ->
        :ok

      {:ok, []} ->
        {:error,
         Error.new(
           "VARIANT_PLAN_UNAVAILABLE",
           "subscription plan is no longer active for this variant"
         )}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_variant_catalog_renewable(%Variant{
         status: :active,
         product: %Product{status: :published}
       }),
       do: :ok

  defp ensure_variant_catalog_renewable(%Variant{}) do
    {:error, Error.new("VALIDATION_ERROR", "subscription variant is unavailable")}
  end

  defp physical_renewal_variant?(%Variant{weight_grams: weight_grams})
       when is_integer(weight_grams) and weight_grams > 0,
       do: true

  defp physical_renewal_variant?(%Variant{}), do: false

  defp renewal_payment_intent_key(renewal_key) when is_binary(renewal_key),
    do: "renewal:#{renewal_key}"

  defp fetch_renewal_attempt_by_order(order_id, renewal_attempt_id \\ nil)

  defp fetch_renewal_attempt_by_order(order_id, renewal_attempt_id)
       when is_binary(order_id) and is_binary(renewal_attempt_id) do
    query =
      RenewalAttempt
      |> Ash.Query.filter(expr(id == ^renewal_attempt_id and order_id == ^order_id))
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [%RenewalAttempt{} = attempt | _]} -> {:ok, attempt}
      {:ok, []} -> {:error, Error.new("NOT_FOUND", "renewal attempt not found for order")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_renewal_attempt_by_order(order_id, _renewal_attempt_id) when is_binary(order_id) do
    query =
      RenewalAttempt
      |> Ash.Query.filter(expr(order_id == ^order_id))
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [%RenewalAttempt{} = attempt | _]} -> {:ok, attempt}
      {:ok, []} -> {:error, Error.new("NOT_FOUND", "renewal attempt not found for order")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_matching_attempt_payment(order_id, %RenewalAttempt{order_id: order_id}), do: :ok

  defp ensure_matching_attempt_payment(_order_id, _attempt) do
    {:error, Error.new("VALIDATION_ERROR", "renewal attempt does not match the paid order")}
  end

  defp ensure_attempt_reconcilable(%RenewalAttempt{status: :succeeded}), do: :already_reconciled
  defp ensure_attempt_reconcilable(%RenewalAttempt{}), do: :ok

  defp reconcile_paid_renewal_attempt(subscription, _plan, attempt) do
    promoted_plan_id =
      subscription.pending_subscription_plan_id || subscription.subscription_plan_id

    promoted_variant_id = subscription.pending_variant_id || subscription.variant_id

    promoted_amount_minor =
      subscription.pending_renewal_amount_minor || subscription.renewal_amount_minor

    promoted_currency = subscription.pending_renewal_currency || subscription.renewal_currency

    promoted_membership_key =
      if is_binary(subscription.pending_subscription_plan_id) do
        subscription.pending_subscription_plan_id
        |> fetch_plan()
        |> case do
          {:ok, plan} -> membership_key_for_plan(plan)
          _ -> subscription.membership_key
        end
      else
        subscription.membership_key
      end

    attrs = %{
      current_period_start_at: attempt.period_start_at,
      current_period_end_at: attempt.period_end_at,
      next_renewal_at: attempt.period_end_at,
      subscription_plan_id: promoted_plan_id,
      variant_id: promoted_variant_id,
      renewal_amount_minor: promoted_amount_minor,
      renewal_currency: promoted_currency,
      membership_key: promoted_membership_key,
      pending_variant_id: nil,
      pending_subscription_plan_id: nil,
      pending_renewal_amount_minor: nil,
      pending_renewal_currency: nil,
      change_effective_at: nil,
      dunning_attempt_count: 0,
      next_retry_at: nil
    }

    subscription
    |> Ash.Changeset.for_update(:extend_period, attrs, context: %{system?: true})
    |> Ash.update(domain: Subscriptions, authorize?: false, context: %{system?: true})
    |> normalize_subscription_update_result(subscription)
  end

  defp effective_subscription_plan_id(%Subscription{subscription_plan_id: plan_id}), do: plan_id

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
        plan =
          case fetch_plan(subscription.subscription_plan_id) do
            {:ok, fetched_plan} -> fetched_plan
            _ -> nil
          end

        _ =
          EntitlementsFacade.revoke_subscription_entitlements_for_system(
            expired.id,
            "grace_expired"
          )

        _ = maybe_enqueue_membership_access_ended_email(expired, plan, "grace_expired")

        :expired

      {:error, reason} ->
        normalize_subscription_update_result({:error, reason}, subscription)
    end
  end

  defp mark_attempt_succeeded(attempt, order_id, payment_intent_id) do
    attempt
    |> Ash.Changeset.for_update(
      :mark_succeeded,
      %{order_id: order_id, payment_intent_id: payment_intent_id},
      context: %{system?: true}
    )
    |> Ash.update(domain: Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp mark_subscription_past_due(subscription, plan, reason, now) do
    message =
      case reason do
        %Error{code: code} -> code
        other -> inspect(other)
      end

    next_attempt_count = max((subscription.dunning_attempt_count || 0) + 1, 1)
    max_retry_attempts = Map.get(plan, :max_retry_attempts) || 0
    retry_suppressed? = hard_retry_suppressed_reason?(message)
    past_due_since_at = dunning_anchor(subscription, now)

    status =
      if next_attempt_count > max_retry_attempts do
        :expired
      else
        :past_due
      end

    next_retry_at =
      if retry_suppressed? do
        nil
      else
        next_retry_at_or_nil(past_due_since_at, next_attempt_count - 1, plan)
      end

    attrs = %{
      billing_status_reason: message,
      past_due_since_at: past_due_since_at,
      dunning_attempt_count: next_attempt_count,
      next_retry_at: next_retry_at,
      retry_suppressed_at: if(retry_suppressed?, do: now, else: nil)
    }

    result =
      persist_subscription_dunning_update(subscription, status, attrs)
      |> stale_result_or(:ok)

    emit_subscription_dunning_telemetry(subscription, status, next_attempt_count)
    result
  end

  defp persist_subscription_dunning_update(subscription, :expired, _attrs) do
    expire_past_due_subscription(subscription)
  end

  defp persist_subscription_dunning_update(subscription, _status, attrs) do
    subscription
    |> Ash.Changeset.for_update(:mark_past_due_transition, attrs, context: %{system?: true})
    |> Ash.update(domain: Subscriptions, authorize?: false, context: %{system?: true})
    |> normalize_subscription_update_result(subscription)
  end

  defp next_retry_at_or_nil(reference_at, attempt_index, plan) do
    case Scheduler.next_retry_at(reference_at, attempt_index, plan) do
      :exhausted -> nil
      next_retry_at -> next_retry_at
    end
  end

  defp dunning_anchor(%Subscription{past_due_since_at: nil}, now), do: now
  defp dunning_anchor(%Subscription{past_due_since_at: anchor}, _now), do: anchor

  defp mark_subscription_past_due(subscription, reason) do
    message =
      case reason do
        %Error{code: code} -> code
        other -> inspect(other)
      end

    subscription
    |> Ash.Changeset.for_update(
      :mark_past_due_transition,
      %{billing_status_reason: message},
      context: %{system?: true}
    )
    |> Ash.update(domain: Subscriptions, authorize?: false, context: %{system?: true})
    |> normalize_subscription_update_result(subscription)
    |> case do
      {:error, %Error{code: "STALE_RECORD"} = error} ->
        {:error, error}

      _ ->
        emit_subscription_dunning_telemetry(
          subscription,
          :past_due,
          subscription.dunning_attempt_count || 0
        )

        :ok
    end
  end

  defp emit_subscription_tick_telemetry(started_at, due_count, result) do
    :telemetry.execute(
      [:store, :subscriptions, :tick],
      %{
        duration: System.monotonic_time() - started_at,
        due_count: due_count,
        success_count: result.success,
        failed_count: result.failed
      },
      %{due_count: due_count}
    )
  end

  defp emit_subscription_renewal_attempt_telemetry(subscription, result, started_at) do
    :telemetry.execute(
      [:store, :subscriptions, :renewal_attempt],
      %{duration: System.monotonic_time() - started_at},
      %{subscription_id: subscription.id, outcome: renewal_attempt_outcome(result)}
    )
  end

  defp renewal_attempt_outcome(:ok), do: :ok
  defp renewal_attempt_outcome({:error, _reason}), do: :error
  defp renewal_attempt_outcome(_result), do: :unknown

  defp emit_subscription_dunning_telemetry(subscription, status, attempt_no) do
    :telemetry.execute(
      [:store, :subscriptions, :dunning],
      %{count: 1},
      %{subscription_id: subscription.id, status: status, attempt_no: attempt_no}
    )
  end

  defp membership_keys_for_plan_ids([]), do: {:ok, []}

  defp membership_keys_for_plan_ids(plan_ids) do
    membership_keys =
      SubscriptionPlan
      |> where(
        [plan],
        plan.id in ^plan_ids and
          plan.entitlement_kind == ^:membership_access and
          not is_nil(plan.entitlement_scope_key)
      )
      |> select([plan], plan.entitlement_scope_key)
      |> Repo.all()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    {:ok, membership_keys}
  end

  defp ensure_membership_user(_user_id, []), do: :ok

  defp ensure_membership_user(user_id, _membership_keys) when is_binary(user_id), do: :ok

  defp ensure_membership_user(_user_id, _membership_keys) do
    {:error, Error.new("VALIDATION_ERROR", "memberships require an authenticated user")}
  end

  defp ensure_no_open_membership_subscription(_user_id, []), do: :ok

  defp ensure_no_open_membership_subscription(user_id, membership_keys) do
    exists? =
      Subscription
      |> where(
        [subscription],
        subscription.user_id == ^user_id and
          subscription.membership_key in ^membership_keys and
          is_nil(subscription.ended_at) and
          subscription.status in ^[:pending, :active, :past_due]
      )
      |> select([subscription], subscription.id)
      |> limit(1)
      |> Repo.exists?()

    if exists? do
      {:error,
       Error.new(
         "SUBSCRIPTION_DUPLICATE",
         "you already have an active or pending membership for this access tier"
       )}
    else
      :ok
    end
  end

  defp ensure_no_pending_membership_order(_user_id, []), do: :ok

  defp ensure_no_pending_membership_order(user_id, membership_keys) do
    exists? =
      from(draft in CheckoutDraft,
        join: order in Order,
        on: order.id == draft.order_id,
        join: item in CartItem,
        on: item.cart_id == draft.cart_id,
        join: plan in SubscriptionPlan,
        on: plan.id == item.subscription_plan_id,
        where:
          draft.user_id == ^user_id and
            draft.status == ^:open and
            order.state == ^:pending_payment and
            plan.entitlement_kind == ^:membership_access and
            plan.entitlement_scope_key in ^membership_keys,
        select: draft.id,
        limit: 1
      )
      |> Repo.exists?()

    if exists? do
      {:error,
       Error.new(
         "SUBSCRIPTION_DUPLICATE",
         "you already have a membership checkout awaiting payment for this access tier"
       )}
    else
      :ok
    end
  end

  defp membership_key_for_plan(plan) do
    case {Map.get(plan, :entitlement_kind), Map.get(plan, :entitlement_scope_key)} do
      {:membership_access, scope_key} when is_binary(scope_key) and scope_key != "" ->
        scope_key

      _ ->
        nil
    end
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

  defp normalize_subscription_update_result({:ok, _} = result, _subscription), do: result

  defp normalize_subscription_update_result({:error, reason} = result, subscription) do
    if StaleWrite.stale_record_error?(reason) do
      _ = reload_subscription_after_stale_update(subscription.id)
    end

    StaleWrite.normalize_update_result(result)
  end

  defp stale_result_or({:error, %Error{code: "STALE_RECORD"} = error}, _fallback),
    do: {:error, error}

  defp stale_result_or(_result, fallback), do: fallback

  defp reload_subscription_after_stale_update(subscription_id) do
    query =
      Subscription
      |> Ash.Query.filter(expr(id == ^subscription_id))

    case Ash.read_one(query,
           domain: Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, %Subscription{} = subscription} -> subscription
      _ -> nil
    end
  end
end
