defmodule StoreWeb.Admin.ShippingRates.FormComponent do
  @moduledoc """
  AshPhoenix-form component for shipping-rate create/update.
  """

  use StoreWeb, :live_component

  alias AshPhoenix.Form
  alias Store.Pricing
  alias Store.Pricing.ShippingRate

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_form(build_form(assigns, socket))

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"shipping_rate" => params}, socket) do
    ash_form = Form.validate(socket.assigns.ash_form, params)
    {:noreply, assign_form(socket, ash_form)}
  end

  @impl true
  def handle_event("save", %{"shipping_rate" => params}, socket) do
    case Form.submit(socket.assigns.ash_form,
           params: params,
           action_opts: [context: form_context(socket)]
         ) do
      {:ok, shipping_rate} ->
        send(self(), {:shipping_rate_saved, shipping_rate})
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
    <div id="shipping-rate-form-component">
      <h2 class="mb-4 text-lg font-semibold">
        {if(@action == :new, do: "Create Shipping Rate", else: "Edit Shipping Rate")}
      </h2>

      <p :if={is_nil(@step_up_at_mono_usec)} class="mb-3 text-xs text-warning">
        No step-up proof in session. Create/update submit will be denied.
      </p>

      <.form
        for={@form}
        id="shipping-rate-form"
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
      >
        <.input field={@form[:code]} type="text" label="Code" required />
        <.input field={@form[:currency]} type="text" label="Currency" required />
        <.input
          field={@form[:shipping_zone_id]}
          type="select"
          label="Shipping Zone"
          prompt="Global (no zone)"
          options={@zone_options}
        />
        <.input
          field={@form[:shipping_cost_minor]}
          type="number"
          label="Shipping Cost (minor)"
          required
        />
        <.input field={@form[:weight_min_grams]} type="number" label="Min Weight (g)" />
        <.input field={@form[:weight_max_grams]} type="number" label="Max Weight (g)" />
        <.input
          field={@form[:free_over_subtotal_minor]}
          type="number"
          label="Free Over Subtotal (minor)"
        />
        <.input
          field={@form[:allow_free_shipping_coupon]}
          type="checkbox"
          label="Allow Free Shipping Coupon"
        />
        <.input field={@form[:active]} type="checkbox" label="Active" />
        <.input field={@form[:starts_at]} type="datetime-local" label="Starts At (UTC)" />
        <.input field={@form[:ends_at]} type="datetime-local" label="Ends At (UTC)" />
        <.input field={@form[:precedence_rank]} type="number" label="Precedence Rank" required />

        <div class="mt-4 flex gap-2">
          <.button id="save-shipping-rate" type="submit">Save Rate</.button>
          <.button id="cancel-shipping-rate" type="button" patch={@patch} class="btn btn-soft">
            Cancel
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  defp build_form(%{action: :new} = assigns, socket) do
    Form.for_create(ShippingRate, :create,
      actor: assigns.current_user,
      domain: Pricing,
      context: form_context(socket),
      as: "shipping_rate",
      warn_on_unhandled_errors?: false
    )
  end

  defp build_form(%{action: :edit, shipping_rate: shipping_rate} = assigns, socket)
       when not is_nil(shipping_rate) do
    Form.for_update(shipping_rate, :update,
      actor: assigns.current_user,
      domain: Pricing,
      context: form_context(socket),
      as: "shipping_rate",
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
