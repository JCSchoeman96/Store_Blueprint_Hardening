defmodule StoreWeb.AdminLive do
  @moduledoc """
  Minimal admin page to prove role-gated access and audit visibility.
  """

  use StoreWeb, :live_view

  alias Store.Admin
  alias Store.Admin.Authorization
  alias StoreWeb.Params.AdminParams

  @impl true
  def mount(params, _session, socket) do
    current_user = socket.assigns.current_user

    if Authorization.has_any_role?(current_user, [:super_admin, :admin]) do
      {:ok, assign(socket, :audit_logs, load_audit_logs(params, current_user))}
    else
      {:ok, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="admin-console" class="rounded-xl border border-neutral-700 bg-neutral-900/80 p-6">
        <h1 class="text-2xl font-semibold text-neutral-100">Admin Console</h1>
        <p class="mt-2 text-sm text-neutral-300">
          Role-gated admin access. This page reads append-only audit evidence.
        </p>

        <div class="mt-6 flex flex-wrap gap-2">
          <.button id="admin-link-products" patch={~p"/admin/products"}>
            Products
          </.button>
          <.button id="admin-link-shipping-methods" patch={~p"/admin/shipping-methods"}>
            Shipping Methods
          </.button>
          <.button id="admin-link-shipping-zones" patch={~p"/admin/shipping-zones"}>
            Shipping Zones
          </.button>
          <.button id="admin-link-shipping-rates" patch={~p"/admin/shipping-rates"}>
            Shipping Rates
          </.button>
          <.button id="admin-link-fulfillment" patch={~p"/admin/fulfillment"}>
            Fulfillment Queue
          </.button>
          <.button id="admin-link-tax-rates" patch={~p"/admin/tax-rates"}>
            Tax Rates
          </.button>
        </div>

        <p :if={is_nil(@step_up_at_mono_usec)} class="mt-3 text-xs text-warning">
          Step-up proof is missing in this session. Pricing writes will be denied until step-up is provided.
        </p>

        <div class="mt-6 space-y-3">
          <p class="text-sm font-medium text-neutral-200">Recent audit entries</p>
          <ul id="audit-log-list" class="space-y-2">
            <li
              :for={audit <- @audit_logs}
              class="rounded border border-neutral-700 bg-neutral-950/70 px-3 py-2 text-sm text-neutral-200"
            >
              <span class="font-semibold">{audit.action}</span>
              <span class="ml-2">{audit.resource}</span>
            </li>
            <li :if={Enum.empty?(@audit_logs)} class="text-sm text-neutral-400">
              No audit entries yet.
            </li>
          </ul>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp load_audit_logs(params, actor) do
    with {:ok, query} <- AdminParams.recent_audit_logs_query(params),
         {:ok, logs} <- Admin.recent_audit_logs(query, actor) do
      logs
    else
      _ -> []
    end
  end
end
