defmodule StoreWeb.Router do
  @moduledoc false

  use StoreWeb, :router
  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :load_from_session
    plug :set_actor, :user
    plug :fetch_live_flash
    plug :put_root_layout, html: {StoreWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :load_from_bearer
    plug :set_actor, :user
  end

  scope "/", StoreWeb do
    pipe_through :browser

    auth_routes(AuthController, Store.Accounts.User, path: "/auth")
    sign_out_route(AuthController)

    sign_in_route(
      path: "/sign-in",
      auth_routes_prefix: "/auth",
      register_path: "/register",
      reset_path: "/forgot-password",
      on_mount: [{StoreWeb.LiveUserAuth, :live_no_user}],
      overrides: [StoreWeb.AuthOverrides]
    )

    reset_route(
      path: "/password-reset",
      auth_routes_prefix: "/auth",
      overrides: [StoreWeb.AuthOverrides]
    )

    confirm_route(Store.Accounts.User, :confirm_new_user,
      path: "/confirm-new-user",
      auth_routes_prefix: "/auth",
      overrides: [StoreWeb.AuthOverrides]
    )

    get "/", PageController, :home
  end

  scope "/", StoreWeb do
    pipe_through :browser

    ash_authentication_live_session :authentication_required,
      on_mount: [{StoreWeb.LiveUserAuth, :live_user_required}] do
      live "/account", AccountLive, :index
      live "/admin", AdminLive, :index
    end
  end

  # Other scopes may use custom stacks.
  scope "/api", StoreWeb do
    pipe_through :api

    get "/orders/:id", OrderApiController, :show
    post "/webhooks/:provider", WebhookController, :create
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:store, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: StoreWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
