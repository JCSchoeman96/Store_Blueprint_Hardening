defmodule StoreWeb.ToolsLive.Index do
  @moduledoc """
  Tools index page — lists available lead-generation tools.
  """

  use StoreWeb, :live_view

  alias StoreWeb.Layouts

  @tools [
    %{
      title: "Risk Appetite Calculator",
      description: "Discover your investment risk profile in under 5 minutes.",
      path: "/tools/risk-appetite",
      icon: "hero-chart-bar"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :tools, @tools)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-8">
        <header class="space-y-2">
          <h1 class="text-3xl font-bold">Free Financial Tools</h1>
          <p class="text-base text-base-content/70">
            Use our free tools to better understand your financial profile.
          </p>
        </header>

        <div class="grid gap-6 sm:grid-cols-2">
          <.link
            :for={tool <- @tools}
            navigate={tool.path}
            class="group rounded-xl border border-base-300 bg-base-200/50 p-6 transition hover:border-primary/40 hover:shadow-md"
          >
            <.icon name={tool.icon} class="size-10 text-primary" />
            <h2 class="mt-4 text-lg font-semibold group-hover:text-primary">{tool.title}</h2>
            <p class="mt-2 text-sm text-base-content/70">{tool.description}</p>
            <span class="mt-4 inline-flex items-center gap-1 text-sm font-medium text-primary">
              Get started <.icon name="hero-arrow-right-mini" class="size-4" />
            </span>
          </.link>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
