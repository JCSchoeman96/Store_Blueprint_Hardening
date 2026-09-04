defmodule Store.Comms.Templates do
  @moduledoc """
  Builds render payloads for transactional email templates.
  """

  import Ash.Expr
  require Ash.Query

  alias Store.Accounts.User
  alias Store.Comms.EmailOutbox
  alias Store.Orders.{Order, OrderLineItem}
  alias Store.Payments.Refund
  alias Store.Subscriptions.{Subscription, SubscriptionPlan}

  @spec build_message_for_delivery(EmailOutbox.t()) ::
          {:ok,
           %{
             to_email: String.t(),
             subject: String.t(),
             text_body: String.t(),
             html_body: String.t()
           }}
          | {:error, term()}
  def build_message_for_delivery(%EmailOutbox{} = outbox) do
    with {:ok, assigns} <- template_assigns(outbox),
         {:ok, text_body} <- render(outbox.template_kind, :text, assigns),
         {:ok, html_body} <- render(outbox.template_kind, :html, assigns) do
      {:ok,
       %{
         to_email: outbox.to_email,
         to_name: nil,
         subject: outbox.subject,
         text_body: text_body,
         html_body: html_body
       }}
    end
  end

  defp template_assigns(%EmailOutbox{template_kind: :order_receipt} = outbox) do
    with {:ok, order} <- fetch_order(outbox.order_id),
         {:ok, line_items} <- fetch_order_line_items(order.id) do
      {:ok,
       %{
         order_ref: order.order_ref,
         grand_total: format_money(order.grand_total_minor || 0, order.currency_code || "USD"),
         currency: order.currency_code || "USD",
         line_items: build_line_item_assigns(line_items, order.currency_code || "USD"),
         shipping_recipient: order.shipping_recipient_name || "Not provided",
         shipping_address_line1: order.shipping_address_line1 || "Not provided",
         shipping_address_line2: order.shipping_address_line2,
         shipping_city: order.shipping_city,
         shipping_region_code: order.shipping_region_code,
         shipping_postal_code: order.shipping_postal_code,
         support_email: support_email()
       }}
    end
  end

  defp template_assigns(%EmailOutbox{template_kind: template_kind} = outbox)
       when template_kind in [:refund_requested, :refund_processed] do
    with {:ok, refund} <- fetch_refund(outbox.refund_id),
         {:ok, order} <- fetch_order(outbox.order_id) do
      {:ok,
       %{
         order_ref: order.order_ref,
         refund_amount:
           format_money(
             refund.requested_amount_minor,
             refund.currency || order.currency_code || "USD"
           ),
         refund_reason: refund.reason || "unspecified",
         support_email: support_email(),
         refund_state: refund.state
       }}
    end
  end

  defp template_assigns(%EmailOutbox{template_kind: :payment_authentication_required} = outbox) do
    with {:ok, order} <- fetch_order(outbox.order_id) do
      {:ok,
       %{
         order_ref: order.order_ref,
         action_url: outbox.template_assigns["action_url"],
         provider_client_secret: outbox.template_assigns["provider_client_secret"],
         support_email: outbox.template_assigns["support_email"] || support_email()
       }}
    end
  end

  defp template_assigns(%EmailOutbox{template_kind: :identity_link_confirmation} = outbox) do
    with {:ok, confirmation_url} <- required_assign(outbox, "confirmation_url"),
         {:ok, identity_provider} <- required_assign(outbox, "identity_provider") do
      {:ok,
       %{
         confirmation_url: confirmation_url,
         identity_provider: identity_provider
       }}
    end
  end

  defp template_assigns(%EmailOutbox{template_kind: :renewal_reminder} = outbox) do
    with {:ok, subscription} <- fetch_subscription(outbox.subscription_id),
         {:ok, plan} <- fetch_subscription_plan(subscription.subscription_plan_id),
         {:ok, user} <- fetch_user(subscription.user_id) do
      {:ok,
       %{
         customer_email: user.email,
         plan_name: plan.name || plan.key,
         days_before: outbox.template_assigns["days_before"],
         renewal_date: format_datetime(subscription.next_renewal_at),
         renewal_amount:
           format_money(
             subscription.renewal_amount_minor || 0,
             subscription.renewal_currency || "USD"
           ),
         support_email: outbox.template_assigns["support_email"] || support_email()
       }}
    end
  end

  defp template_assigns(%EmailOutbox{template_kind: :access_ended} = outbox) do
    with {:ok, subscription} <- fetch_subscription(outbox.subscription_id),
         {:ok, plan} <- fetch_subscription_plan(subscription.subscription_plan_id),
         {:ok, user} <- fetch_user(subscription.user_id) do
      {:ok,
       %{
         customer_email: user.email,
         plan_name: plan.name || plan.key,
         reason: outbox.template_assigns["reason"] || "membership_ended",
         period_end_at: format_datetime(subscription.current_period_end_at),
         support_email: outbox.template_assigns["support_email"] || support_email()
       }}
    end
  end

  defp fetch_order(order_id) do
    query = Order |> Ash.Query.filter(expr(id == ^order_id))

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, [order | _]} -> {:ok, order}
      {:ok, []} -> {:error, {:order_not_found, order_id}}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_subscription(subscription_id) do
    query = Subscription |> Ash.Query.filter(expr(id == ^subscription_id))

    case Ash.read(query,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, [subscription | _]} -> {:ok, subscription}
      {:ok, []} -> {:error, {:subscription_not_found, subscription_id}}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_subscription_plan(subscription_plan_id) do
    query = SubscriptionPlan |> Ash.Query.filter(expr(id == ^subscription_plan_id))

    case Ash.read(query,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, [plan | _]} -> {:ok, plan}
      {:ok, []} -> {:error, {:subscription_plan_not_found, subscription_plan_id}}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_user(user_id) do
    query = User |> Ash.Query.filter(expr(id == ^user_id))

    case Ash.read(query, domain: Store.Accounts, authorize?: false, context: %{system?: true}) do
      {:ok, [user | _]} -> {:ok, user}
      {:ok, []} -> {:error, {:user_not_found, user_id}}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_refund(refund_id) do
    query = Refund |> Ash.Query.filter(expr(id == ^refund_id))

    case Ash.read(query, domain: Store.Payments, authorize?: false, context: %{system?: true}) do
      {:ok, [refund | _]} -> {:ok, refund}
      {:ok, []} -> {:error, {:refund_not_found, refund_id}}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_order_line_items(order_id) do
    query = OrderLineItem |> Ash.Query.filter(expr(order_id == ^order_id))

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, line_items} -> {:ok, line_items}
      {:error, error} -> {:error, error}
    end
  end

  defp build_line_item_assigns(line_items, currency) do
    line_items
    |> Enum.sort_by(& &1.line_no)
    |> Enum.take(8)
    |> Enum.map(fn line_item ->
      %{
        title: line_item.product_title_snapshot,
        quantity: line_item.quantity,
        line_total: format_money(line_item.line_total_minor, currency)
      }
    end)
  end

  defp render(template_kind, format, assigns) do
    path =
      Application.app_dir(
        :store,
        "priv/email_templates/#{template_kind}.#{format_suffix(format)}.eex"
      )

    try do
      {:ok, EEx.eval_file(path, assigns: assigns)}
    rescue
      error -> {:error, error}
    end
  end

  defp required_assign(%EmailOutbox{template_assigns: assigns}, key) do
    case Map.get(assigns, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_template_assign, key}}
    end
  end

  defp format_suffix(:text), do: "text"
  defp format_suffix(:html), do: "html"

  defp format_money(minor, currency) do
    amount = :erlang.float_to_binary(minor / 100, decimals: 2)
    "#{String.upcase(currency)} #{amount}"
  end

  defp format_datetime(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")
  defp format_datetime(_value), do: "-"

  defp support_email do
    Application.get_env(:store, :comms, [])
    |> Keyword.get(:support_email, "support@store.local")
  end
end
