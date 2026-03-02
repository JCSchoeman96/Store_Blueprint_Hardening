defmodule StoreWeb.Admin.TaxRates.IndexLive do
  @moduledoc """
  Admin CRUD surface for tax rates using Ash-backed list reads and forms.
  """

  use StoreWeb, :live_view

  alias Store.Admin.Authorization
  alias Store.Pricing.Facade, as: PricingFacade
  alias StoreWeb.Admin.TaxRates.FormComponent
  alias StoreWeb.Params.Admin.TaxRatesParams

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if Authorization.has_any_role?(actor, [:super_admin, :admin]) do
      {:ok,
       socket
       |> assign(:query, nil)
       |> assign(:selected_tax_rate, nil)
       |> stream(:tax_rates, [])}
    else
      {:ok, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    actor = socket.assigns.current_user

    with {:ok, query} <- TaxRatesParams.index_query(extract_query_params(uri)),
         {:ok, tax_rates} <- PricingFacade.list_tax_rates_for_admin(actor, query),
         {:ok, selected_tax_rate} <- load_selected(socket.assigns.live_action, params, actor) do
      {:noreply,
       socket
       |> assign(:query, query)
       |> assign(:selected_tax_rate, selected_tax_rate)
       |> stream(:tax_rates, tax_rates, reset: true)}
    else
      _error ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to load tax rates")
         |> assign(:selected_tax_rate, nil)
         |> stream(:tax_rates, [], reset: true)}
    end
  end

  @impl true
  def handle_info({:tax_rate_saved, _tax_rate}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Tax rate saved")
     |> push_patch(to: ~p"/admin/tax-rates")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        id="admin-tax-rates"
        class="space-y-6 rounded-xl border border-base-300 bg-base-200/50 p-6"
      >
        <div class="flex items-center justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold">Tax Rates</h1>
            <p class="text-sm text-base-content/70">
              Jurisdiction-aware rates used for deterministic tax evaluation.
            </p>
          </div>
          <.button id="new-tax-rate" patch={~p"/admin/tax-rates/new"}>New Tax Rate</.button>
        </div>

        <.table
          id="tax-rates"
          rows={@streams.tax_rates}
          row_id={fn {id, _tax_rate} -> id end}
          row_item={fn {_id, tax_rate} -> tax_rate end}
        >
          <:col :let={tax_rate} label="Code">{tax_rate.code}</:col>
          <:col :let={tax_rate} label="Country">{tax_rate.country_code}</:col>
          <:col :let={tax_rate} label="Region">{tax_rate.region_code || "ALL"}</:col>
          <:col :let={tax_rate} label="Category">{tax_rate.product_tax_category || "ANY"}</:col>
          <:col :let={tax_rate} label="BPS">{tax_rate.rate_basis_points}</:col>
          <:col :let={tax_rate} label="Active">{if(tax_rate.active, do: "Yes", else: "No")}</:col>
          <:action :let={tax_rate}>
            <.link patch={~p"/admin/tax-rates/#{tax_rate.id}/edit"} class="btn btn-xs">
              Edit
            </.link>
          </:action>
        </.table>

        <section
          :if={@live_action in [:new, :edit]}
          id="tax-rate-form-panel"
          class="rounded-xl border border-base-300 bg-base-100 p-4"
        >
          <.live_component
            module={FormComponent}
            id={tax_rate_form_id(@live_action, @selected_tax_rate)}
            action={@live_action}
            current_user={@current_user}
            step_up_at_mono_usec={@step_up_at_mono_usec}
            tax_rate={@selected_tax_rate}
            patch={~p"/admin/tax-rates"}
          />
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp load_selected(:edit, %{"id" => id}, actor) do
    case PricingFacade.get_tax_rate_for_admin(actor, id) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, tax_rate} -> {:ok, tax_rate}
      {:error, _error} -> {:error, :not_found}
    end
  end

  defp load_selected(_live_action, _params, _actor), do: {:ok, nil}

  defp tax_rate_form_id(:new, _tax_rate), do: "tax-rate-form-new"
  defp tax_rate_form_id(:edit, %{id: id}), do: "tax-rate-form-#{id}"
  defp tax_rate_form_id(:edit, _tax_rate), do: "tax-rate-form-edit"
  defp tax_rate_form_id(_action, _tax_rate), do: "tax-rate-form"

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
