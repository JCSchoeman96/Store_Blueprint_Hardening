defmodule StoreWeb.Admin.ProductDigitalLinks.FormComponent do
  @moduledoc """
  AshPhoenix form component for product/variant digital-link create/update.
  """

  use StoreWeb, :live_component

  alias AshPhoenix.Form
  alias Store.Digital
  alias Store.Digital.ProductDigitalLink

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_form(build_form(assigns))

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"product_digital_link" => params}, socket) do
    ash_form = Form.validate(socket.assigns.ash_form, params)
    {:noreply, assign_form(socket, ash_form)}
  end

  @impl true
  def handle_event("save", %{"product_digital_link" => params}, socket) do
    case Form.submit(socket.assigns.ash_form, params: normalize_blank_fields(params)) do
      {:ok, product_digital_link} ->
        send(self(), {:product_digital_link_saved, product_digital_link})
        {:noreply, socket}

      {:error, ash_form} ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to save product digital link")
         |> assign_form(ash_form)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="product-digital-link-form-component">
      <h2 class="mb-4 text-lg font-semibold">
        {if(@action == :new, do: "Create Product Digital Link", else: "Edit Product Digital Link")}
      </h2>

      <.form
        for={@form}
        id="product-digital-link-form"
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
      >
        <.input field={@form[:product_id]} type="text" label="Product ID (UUID)" />
        <.input field={@form[:variant_id]} type="text" label="Variant ID (UUID)" />
        <.input field={@form[:digital_asset_id]} type="text" label="Digital Asset ID (UUID)" required />
        <.input field={@form[:position]} type="number" label="Position" required />
        <.input field={@form[:grant_expires_in_days]} type="number" label="Grant Expires In Days" />
        <.input field={@form[:grant_max_downloads]} type="number" label="Grant Max Downloads" />

        <p class="mt-2 text-xs text-base-content/70">
          Set either product_id or variant_id (exactly one).
        </p>

        <div class="mt-4 flex gap-2">
          <.button id="save-product-digital-link" type="submit">Save Link</.button>
          <.button
            id="cancel-product-digital-link"
            type="button"
            patch={@patch}
            class="btn btn-soft"
          >
            Cancel
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  defp build_form(%{action: :new, current_user: current_user}) do
    Form.for_create(ProductDigitalLink, :create,
      actor: current_user,
      domain: Digital,
      as: "product_digital_link",
      warn_on_unhandled_errors?: false
    )
  end

  defp build_form(%{
         action: :edit,
         product_digital_link: product_digital_link,
         current_user: current_user
       })
       when not is_nil(product_digital_link) do
    Form.for_update(product_digital_link, :update,
      actor: current_user,
      domain: Digital,
      as: "product_digital_link",
      warn_on_unhandled_errors?: false
    )
  end

  defp build_form(assigns), do: build_form(Map.put(assigns, :action, :new))

  defp normalize_blank_fields(params) when is_map(params) do
    params
    |> normalize_blank("product_id")
    |> normalize_blank("variant_id")
    |> normalize_blank("grant_expires_in_days")
    |> normalize_blank("grant_max_downloads")
  end

  defp normalize_blank(params, key) do
    case Map.get(params, key) do
      "" -> Map.put(params, key, nil)
      _ -> params
    end
  end

  defp assign_form(socket, ash_form) do
    socket
    |> assign(:ash_form, ash_form)
    |> assign(:form, to_form(ash_form))
  end
end
