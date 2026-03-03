defmodule StoreWeb.Admin.ShippingZones.FormComponent do
  @moduledoc """
  AshPhoenix-form component for shipping-zone create/update.
  """

  use StoreWeb, :live_component

  alias AshPhoenix.Form
  alias Store.Shipping
  alias Store.Shipping.ShippingZone

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_form(build_form(assigns, socket))

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"shipping_zone" => params}, socket) do
    ash_form = Form.validate(socket.assigns.ash_form, params)
    {:noreply, assign_form(socket, ash_form)}
  end

  @impl true
  def handle_event("save", %{"shipping_zone" => params}, socket) do
    case Form.submit(socket.assigns.ash_form,
           params: params,
           action_opts: [context: form_context(socket)]
         ) do
      {:ok, shipping_zone} ->
        send(self(), {:shipping_zone_saved, shipping_zone})
        {:noreply, socket}

      {:error, ash_form} ->
        {:noreply,
         socket
         |> put_flash(:error, "Write denied. Step-up may be required.")
         |> assign_form(ash_form)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="shipping-zone-form-component">
      <h2 class="mb-4 text-lg font-semibold">
        {if(@action == :new, do: "Create Shipping Zone", else: "Edit Shipping Zone")}
      </h2>

      <p :if={is_nil(@step_up_at_mono_usec)} class="mb-3 text-xs text-warning">
        No step-up proof in session. Create/update submit will be denied.
      </p>

      <.form
        for={@form}
        id="shipping-zone-form"
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
      >
        <.input field={@form[:code]} type="text" label="Code" required />
        <.input field={@form[:country_code]} type="text" label="Country Code" required />
        <.input field={@form[:region_code]} type="text" label="Region Code" />
        <.input field={@form[:active]} type="checkbox" label="Active" />

        <div class="mt-4 flex gap-2">
          <.button id="save-shipping-zone" type="submit">Save Zone</.button>
          <.button id="cancel-shipping-zone" type="button" patch={@patch} class="btn btn-soft">
            Cancel
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  defp build_form(%{action: :new} = assigns, socket) do
    Form.for_create(ShippingZone, :create,
      actor: assigns.current_user,
      domain: Shipping,
      context: form_context(socket),
      as: "shipping_zone",
      warn_on_unhandled_errors?: false
    )
  end

  defp build_form(%{action: :edit, shipping_zone: shipping_zone} = assigns, socket)
       when not is_nil(shipping_zone) do
    Form.for_update(shipping_zone, :update,
      actor: assigns.current_user,
      domain: Shipping,
      context: form_context(socket),
      as: "shipping_zone",
      warn_on_unhandled_errors?: false
    )
  end

  defp build_form(assigns, socket), do: build_form(Map.put(assigns, :action, :new), socket)

  defp assign_form(socket, ash_form) do
    socket |> assign(:ash_form, ash_form) |> assign(:form, to_form(ash_form))
  end

  defp form_context(socket) do
    case socket.assigns[:step_up_at_mono_usec] do
      value when is_integer(value) -> %{step_up_at_mono_usec: value}
      _ -> %{}
    end
  end
end
