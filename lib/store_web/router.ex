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
    plug StoreWeb.Plugs.EnsureCartToken
    plug StoreWeb.Plugs.MergeCartOnAuth
    plug :fetch_live_flash
    plug :put_root_layout, html: {StoreWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json", "jsonapi"]
    plug :load_from_bearer
    plug :set_actor, :user
    plug StoreWeb.Plugs.ApiV1JsonApiGuard
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

    ash_authentication_live_session :current_user,
      on_mount: [{StoreWeb.LiveUserAuth, :live_user_optional}] do
      live "/shop", ShopLive.Index, :index
      live "/shop/:slug", ShopLive.Show, :show
      live "/cart", CartLive, :index
      live "/checkout", CheckoutLive.Placeholder, :index
      live "/checkout/return", CheckoutLive.Placeholder, :return
      live "/checkout/cancel", CheckoutLive.Placeholder, :cancel
    end

    ash_authentication_live_session :authentication_required,
      on_mount: [{StoreWeb.LiveUserAuth, :live_user_required}] do
      live "/account", AccountLive, :index
      live "/account/orders/:order_ref", Orders.ShowLive, :show
      live "/account/downloads", Digital.DownloadsLive, :index
      live "/admin", AdminLive, :index
      live "/admin/products", Admin.Products.IndexLive, :index
      live "/admin/products/new", Admin.Products.IndexLive, :new
      live "/admin/products/:id/edit", Admin.Products.IndexLive, :edit
      live "/admin/digital-assets", Admin.DigitalAssets.IndexLive, :index
      live "/admin/digital-assets/new", Admin.DigitalAssets.IndexLive, :new
      live "/admin/digital-assets/:id/edit", Admin.DigitalAssets.IndexLive, :edit
      live "/admin/product-digital-links", Admin.ProductDigitalLinks.IndexLive, :index
      live "/admin/product-digital-links/new", Admin.ProductDigitalLinks.IndexLive, :new
      live "/admin/product-digital-links/:id/edit", Admin.ProductDigitalLinks.IndexLive, :edit
      live "/admin/shipping-methods", Admin.ShippingMethods.IndexLive, :index
      live "/admin/shipping-methods/new", Admin.ShippingMethods.IndexLive, :new
      live "/admin/shipping-methods/:id/edit", Admin.ShippingMethods.IndexLive, :edit
      live "/admin/shipping-zones", Admin.ShippingZones.IndexLive, :index
      live "/admin/shipping-zones/new", Admin.ShippingZones.IndexLive, :new
      live "/admin/shipping-zones/:id/edit", Admin.ShippingZones.IndexLive, :edit
      live "/admin/shipping-rates", Admin.ShippingRates.IndexLive, :index
      live "/admin/shipping-rates/new", Admin.ShippingRates.IndexLive, :new
      live "/admin/shipping-rates/:id/edit", Admin.ShippingRates.IndexLive, :edit
      live "/admin/fulfillment", Admin.Fulfillment.IndexLive, :index
      live "/admin/email-outbox", Admin.EmailOutbox.IndexLive, :index
      live "/admin/tax-rates", Admin.TaxRates.IndexLive, :index
      live "/admin/tax-rates/new", Admin.TaxRates.IndexLive, :new
      live "/admin/tax-rates/:id/edit", Admin.TaxRates.IndexLive, :edit
    end

    get "/account/downloads/:grant_id/request", DigitalDownloadController, :create
  end

  # Other scopes may use custom stacks.
  scope "/api" do
    pipe_through :api

    forward "/v1", StoreWeb.JsonApiRouter
    post "/webhooks/:provider", StoreWeb.WebhookController, :create
    post "/payments/:provider/callback", StoreWeb.PaymentCallbackController, :create
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
