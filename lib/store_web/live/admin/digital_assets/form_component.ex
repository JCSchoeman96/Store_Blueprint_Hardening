defmodule StoreWeb.Admin.DigitalAssets.FormComponent do
  @moduledoc """
  AshPhoenix form component for digital-asset create/update.
  """

  use StoreWeb, :live_component

  alias AshPhoenix.Form
  alias Store.Digital
  alias Store.Digital.DigitalAsset

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_form(build_form(assigns))

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"digital_asset" => params}, socket) do
    ash_form = Form.validate(socket.assigns.ash_form, params)
    {:noreply, assign_form(socket, ash_form)}
  end

  @impl true
  def handle_event("save", %{"digital_asset" => params}, socket) do
    case Form.submit(socket.assigns.ash_form, params: params) do
      {:ok, digital_asset} ->
        send(self(), {:digital_asset_saved, digital_asset})
        {:noreply, socket}

      {:error, ash_form} ->
        {:noreply,
         socket |> put_flash(:error, "Unable to save digital asset") |> assign_form(ash_form)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="digital-asset-form-component">
      <h2 class="mb-4 text-lg font-semibold">
        {if(@action == :new, do: "Create Digital Asset", else: "Edit Digital Asset")}
      </h2>

      <.form
        for={@form}
        id="digital-asset-form"
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
      >
        <.input field={@form[:key]} type="text" label="Key" required />
        <.input field={@form[:title]} type="text" label="Title" required />
        <.input field={@form[:content_type]} type="text" label="Content Type" required />
        <.input field={@form[:byte_size]} type="number" label="Byte Size" required />
        <.input field={@form[:storage_provider]} type="text" label="Storage Provider" required />
        <.input field={@form[:storage_bucket]} type="text" label="Storage Bucket" required />
        <.input field={@form[:storage_object_key]} type="text" label="Storage Object Key" required />
        <.input field={@form[:checksum_sha256]} type="text" label="Checksum SHA256" />
        <.input field={@form[:status]} type="select" label="Status" options={[:active, :archived]} />

        <div class="mt-4 flex gap-2">
          <.button id="save-digital-asset" type="submit">Save Asset</.button>
          <.button id="cancel-digital-asset" type="button" patch={@patch} class="btn btn-soft">
            Cancel
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  defp build_form(%{action: :new, current_user: current_user}) do
    Form.for_create(DigitalAsset, :create,
      actor: current_user,
      domain: Digital,
      as: "digital_asset",
      warn_on_unhandled_errors?: false
    )
  end

  defp build_form(%{action: :edit, digital_asset: digital_asset, current_user: current_user})
       when not is_nil(digital_asset) do
    Form.for_update(digital_asset, :update,
      actor: current_user,
      domain: Digital,
      as: "digital_asset",
      warn_on_unhandled_errors?: false
    )
  end

  defp build_form(assigns), do: build_form(Map.put(assigns, :action, :new))

  defp assign_form(socket, ash_form) do
    socket
    |> assign(:ash_form, ash_form)
    |> assign(:form, to_form(ash_form))
  end
end
