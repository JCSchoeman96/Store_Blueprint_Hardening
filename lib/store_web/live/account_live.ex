defmodule StoreWeb.AccountLive do
  @moduledoc """
  Minimal authenticated page used to prove LiveView auth guards.
  """

  use StoreWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        id="account-protected"
        class="rounded-xl border border-neutral-700 bg-neutral-900/80 p-6"
      >
        <p class="text-sm text-neutral-300">Protected account area</p>
        <h1 class="mt-2 text-2xl font-semibold text-neutral-100">
          Signed in as {@current_user.email}
        </h1>
      </section>
    </Layouts.app>
    """
  end
end
