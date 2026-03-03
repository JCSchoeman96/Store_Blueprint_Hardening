defmodule StoreWeb.Digital.DownloadsLive do
  @moduledoc """
  Customer download-grant listing and launch surface.
  """

  use StoreWeb, :live_view

  alias Store.Digital.Facade, as: DigitalFacade
  alias StoreWeb.Params.Digital.DownloadGrantsParams

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, nil)
     |> stream(:download_grants, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    actor = socket.assigns.current_user

    with {:ok, query} <- DownloadGrantsParams.index_query(params),
         {:ok, download_grants} <- DigitalFacade.list_download_grants_for_user(actor, query) do
      {:noreply,
       socket
       |> assign(:query, query)
       |> stream(:download_grants, download_grants, reset: true)}
    else
      _error ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to load downloads")
         |> stream(:download_grants, [], reset: true)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        id="account-downloads"
        class="space-y-6 rounded-xl border border-base-300 bg-base-200/50 p-6"
      >
        <div class="space-y-1">
          <h1 class="text-2xl font-semibold">Downloads</h1>
          <p class="text-sm text-base-content/70">
            Access digital purchases from your paid orders.
          </p>
        </div>

        <.table
          id="download-grants"
          rows={@streams.download_grants}
          row_id={fn {id, _download_grant} -> id end}
          row_item={fn {_id, download_grant} -> download_grant end}
        >
          <:col :let={grant} label="Asset">{asset_title(grant)}</:col>
          <:col :let={grant} label="Status">{grant.status}</:col>
          <:col :let={grant} label="Expires">{format_expiry(grant.expires_at)}</:col>
          <:col :let={grant} label="Order">{grant.order_id}</:col>
          <:action :let={grant}>
            <.link
              href={~p"/account/downloads/#{grant.id}/request"}
              class="btn btn-xs"
              data-confirm="Issue a new signed URL and continue?"
            >
              Download
            </.link>
          </:action>
        </.table>
      </section>
    </Layouts.app>
    """
  end

  defp asset_title(%{digital_asset: %{title: title}}) when is_binary(title), do: title
  defp asset_title(_grant), do: "Digital asset"

  defp format_expiry(%DateTime{} = expires_at),
    do: Calendar.strftime(expires_at, "%Y-%m-%d %H:%M UTC")

  defp format_expiry(_expires_at), do: "Never"
end
