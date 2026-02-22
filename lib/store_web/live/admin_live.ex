defmodule StoreWeb.AdminLive do
  @moduledoc """
  Minimal admin page to prove role-gated access and audit visibility.
  """

  use StoreWeb, :live_view

  require Ash.Query

  alias Store.Admin.AuditLog
  alias Store.Admin.Authorization

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user

    if Authorization.has_any_role?(current_user, [:super_admin, :admin]) do
      {:ok, assign(socket, :audit_logs, load_audit_logs(current_user))}
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

  defp load_audit_logs(actor) do
    AuditLog
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(20)
    |> Ash.read(domain: Store.Admin, actor: actor)
    |> case do
      {:ok, logs} -> logs
      _ -> []
    end
  end
end
