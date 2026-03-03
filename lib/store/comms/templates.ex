defmodule Store.Comms.Templates do
  @moduledoc """
  Builds render payloads for transactional email templates.
  """

  import Ash.Expr
  require Ash.Query

  alias Store.Comms.EmailOutbox
  alias Store.Orders.{Order, OrderLineItem}
  alias Store.Payments.Refund

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

  defp fetch_order(order_id) do
    query = Order |> Ash.Query.filter(expr(id == ^order_id))

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, [order | _]} -> {:ok, order}
      {:ok, []} -> {:error, {:order_not_found, order_id}}
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

  defp format_suffix(:text), do: "text"
  defp format_suffix(:html), do: "html"

  defp format_money(minor, currency) do
    amount = :erlang.float_to_binary(minor / 100, decimals: 2)
    "#{String.upcase(currency)} #{amount}"
  end

  defp support_email do
    Application.get_env(:store, :comms, [])
    |> Keyword.get(:support_email, "support@store.local")
  end
end
