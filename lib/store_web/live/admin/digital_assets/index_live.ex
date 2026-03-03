defmodule StoreWeb.Admin.DigitalAssets.IndexLive do
  @moduledoc """
  Admin CRUD surface for digital assets.
  """

  use StoreWeb, :live_view

  alias Store.Admin.Authorization
  alias Store.Digital.Facade, as: DigitalFacade
  alias StoreWeb.Admin.DigitalAssets.FormComponent
  alias StoreWeb.Params.Admin.DigitalAssetsParams

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if Authorization.has_any_role?(actor, [:super_admin, :admin]) do
      {:ok,
       socket
       |> assign(:query, nil)
       |> assign(:selected_digital_asset, nil)
       |> stream(:digital_assets, [])}
    else
      {:ok, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    actor = socket.assigns.current_user

    with {:ok, query} <- DigitalAssetsParams.index_query(extract_query_params(uri)),
         {:ok, digital_assets} <- DigitalFacade.list_digital_assets_for_admin(actor, query),
         {:ok, selected_digital_asset} <-
           load_selected(socket.assigns.live_action, params, actor) do
      {:noreply,
       socket
       |> assign(:query, query)
       |> assign(:selected_digital_asset, selected_digital_asset)
       |> stream(:digital_assets, digital_assets, reset: true)}
    else
      _error ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to load digital assets")
         |> assign(:selected_digital_asset, nil)
         |> stream(:digital_assets, [], reset: true)}
    end
  end

  @impl true
  def handle_info({:digital_asset_saved, _digital_asset}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Digital asset saved")
     |> push_patch(to: ~p"/admin/digital-assets")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        id="admin-digital-assets"
        class="space-y-6 rounded-xl border border-base-300 bg-base-200/50 p-6"
      >
        <div class="flex items-center justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold">Digital Assets</h1>
            <p class="text-sm text-base-content/70">
              Storage-backed assets available for digital grant issuance.
            </p>
          </div>
          <.button id="new-digital-asset" patch={~p"/admin/digital-assets/new"}>
            New Asset
          </.button>
        </div>

        <.table
          id="digital-assets"
          rows={@streams.digital_assets}
          row_id={fn {id, _digital_asset} -> id end}
          row_item={fn {_id, digital_asset} -> digital_asset end}
        >
          <:col :let={digital_asset} label="Key">{digital_asset.key}</:col>
          <:col :let={digital_asset} label="Title">{digital_asset.title}</:col>
          <:col :let={digital_asset} label="Content Type">{digital_asset.content_type}</:col>
          <:col :let={digital_asset} label="Bytes">{digital_asset.byte_size}</:col>
          <:col :let={digital_asset} label="Status">{digital_asset.status}</:col>
          <:action :let={digital_asset}>
            <.link patch={~p"/admin/digital-assets/#{digital_asset.id}/edit"} class="btn btn-xs">
              Edit
            </.link>
          </:action>
        </.table>

        <section
          :if={@live_action in [:new, :edit]}
          id="digital-asset-form-panel"
          class="rounded-xl border border-base-300 bg-base-100 p-4"
        >
          <.live_component
            module={FormComponent}
            id={digital_asset_form_id(@live_action, @selected_digital_asset)}
            action={@live_action}
            current_user={@current_user}
            digital_asset={@selected_digital_asset}
            patch={~p"/admin/digital-assets"}
          />
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp load_selected(:edit, %{"id" => id}, actor) do
    case DigitalFacade.get_digital_asset_for_admin(actor, id) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, digital_asset} -> {:ok, digital_asset}
      {:error, _error} -> {:error, :not_found}
    end
  end

  defp load_selected(_live_action, _params, _actor), do: {:ok, nil}

  defp digital_asset_form_id(:new, _digital_asset), do: "digital-asset-form-new"
  defp digital_asset_form_id(:edit, %{id: id}), do: "digital-asset-form-#{id}"
  defp digital_asset_form_id(:edit, _digital_asset), do: "digital-asset-form-edit"
  defp digital_asset_form_id(_action, _digital_asset), do: "digital-asset-form"

  defp extract_query_params(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.get(:query)
    |> case do
      nil -> %{}
      query -> URI.decode_query(query)
    end
  end

  defp extract_query_params(_uri), do: %{}
end
