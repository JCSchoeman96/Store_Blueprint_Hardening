defmodule StoreWeb.Admin.EmailOutbox.IndexLive do
  @moduledoc """
  Admin/support inspect-only view for transactional email outbox status.
  """

  use StoreWeb, :live_view

  alias Store.Admin.Authorization
  alias Store.Comms.Facade, as: CommsFacade
  alias Store.Comms.Queries.AdminEmailOutboxIndexQuery
  alias StoreWeb.Params.Admin.EmailOutboxIndexParams

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if Authorization.has_any_role?(actor, [:super_admin, :admin, :support]) do
      {:ok,
       socket
       |> assign(:query, %AdminEmailOutboxIndexQuery{
         limit: 20,
         offset: 0,
         state: nil,
         template_kind: nil
       })
       |> stream(:outboxes, [])}
    else
      {:ok, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_params(_params, uri, socket) do
    actor = socket.assigns.current_user

    with {:ok, query} <- EmailOutboxIndexParams.index_query(extract_query_params(uri)),
         {:ok, outboxes} <- CommsFacade.list_email_outboxes_for_admin(actor, query) do
      {:noreply,
       socket
       |> assign(:query, query)
       |> stream(:outboxes, outboxes, reset: true)}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to load email outbox")
         |> stream(:outboxes, [], reset: true)}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    query_params =
      socket.assigns.query
      |> query_to_params()
      |> Map.merge(Map.take(params, ["state", "template_kind"]))
      |> cleanup_blank("state")
      |> cleanup_blank("template_kind")

    {:noreply, push_patch(socket, to: ~p"/admin/email-outbox?#{query_params}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        id="admin-email-outbox"
        class="space-y-6 rounded-xl border border-base-300 bg-base-200/50 p-6"
      >
        <div class="flex items-center justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold">Email Outbox</h1>
            <p class="text-sm text-base-content/70">
              Inspect-only status for receipt and refund notifications.
            </p>
          </div>
        </div>

        <form id="email-outbox-filter-form" phx-change="filter" class="grid gap-3 md:grid-cols-2">
          <div>
            <label class="label mb-1 text-sm font-medium">State</label>
            <select name="state" class="select w-full">
              <option value="">All</option>
              <option value="pending" selected={@query.state == :pending}>pending</option>
              <option value="processing" selected={@query.state == :processing}>processing</option>
              <option value="sent" selected={@query.state == :sent}>sent</option>
              <option value="failed" selected={@query.state == :failed}>failed</option>
            </select>
          </div>
          <div>
            <label class="label mb-1 text-sm font-medium">Template Kind</label>
            <select name="template_kind" class="select w-full">
              <option value="">All</option>
              <option value="order_receipt" selected={@query.template_kind == :order_receipt}>
                order_receipt
              </option>
              <option value="refund_requested" selected={@query.template_kind == :refund_requested}>
                refund_requested
              </option>
              <option value="refund_processed" selected={@query.template_kind == :refund_processed}>
                refund_processed
              </option>
            </select>
          </div>
        </form>

        <.table
          id="email-outbox-table"
          rows={@streams.outboxes}
          row_id={fn {id, _row} -> id end}
          row_item={fn {_id, row} -> row end}
        >
          <:col :let={row} label="Template">{row.template_kind}</:col>
          <:col :let={row} label="Recipient">{mask_email(row.to_email)}</:col>
          <:col :let={row} label="Provider">{row.provider}</:col>
          <:col :let={row} label="State">{row.state}</:col>
          <:col :let={row} label="Attempts">{row.attempt_count}</:col>
          <:col :let={row} label="Inserted">{row.inserted_at}</:col>
          <:col :let={row} label="Sent">{row.sent_at}</:col>
          <:col :let={row} label="Last Error">{truncate_error(row.last_error)}</:col>
        </.table>
      </section>
    </Layouts.app>
    """
  end

  defp query_to_params(query) do
    %{"limit" => to_string(query.limit), "offset" => to_string(query.offset)}
    |> maybe_put("state", query.state)
    |> maybe_put("template_kind", query.template_kind)
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, to_string(value))

  defp cleanup_blank(params, key) do
    case Map.get(params, key) do
      nil -> params
      "" -> Map.delete(params, key)
      _ -> params
    end
  end

  defp extract_query_params(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.get(:query)
    |> case do
      nil -> %{}
      query -> URI.decode_query(query)
    end
  end

  defp extract_query_params(_), do: %{}

  defp mask_email(email) when is_binary(email) do
    case String.split(email, "@") do
      [local, domain] ->
        head = local |> String.slice(0, 1) |> Kernel.||("*")
        "#{head}***@#{domain}"

      _ ->
        "***"
    end
  end

  defp mask_email(_), do: "***"

  defp truncate_error(nil), do: nil

  defp truncate_error(error) when is_binary(error) and byte_size(error) > 120 do
    String.slice(error, 0, 117) <> "..."
  end

  defp truncate_error(error), do: error
end
