defmodule StoreWeb.AuthOverrides do
  @moduledoc """
  Auth UI overrides aligned to the Store Chelekom baseline styling.
  """

  use AshAuthentication.Phoenix.Overrides

  alias AshAuthentication.Phoenix.{Components, ConfirmLive, ResetLive, SignInLive}

  @panel_class """
  w-full max-w-md rounded-xl border border-neutral-700/60 bg-neutral-900/90 p-6 shadow-xl
  shadow-black/40 backdrop-blur
  """

  @title_class "mb-2 text-2xl font-semibold tracking-tight text-neutral-100"
  @link_class "text-sm font-medium text-lime-300 hover:text-lime-200 focus:outline-none"
  @button_class """
  mt-4 inline-flex w-full items-center justify-center rounded-md border border-lime-300/70
  bg-lime-300 px-4 py-2 text-sm font-semibold text-neutral-900 transition hover:bg-lime-200
  focus:outline-none focus-visible:ring-2 focus-visible:ring-lime-200
  """

  override SignInLive do
    set(:root_class, "grid min-h-screen place-items-center bg-neutral-950 px-4 py-10")
  end

  override ResetLive do
    set(:root_class, "grid min-h-screen place-items-center bg-neutral-950 px-4 py-10")
  end

  override ConfirmLive do
    set(:root_class, "grid min-h-screen place-items-center bg-neutral-950 px-4 py-10")
  end

  override Components.SignIn do
    set(:strategy_class, @panel_class)
    set(:strategy_display_order, :forms_first)

    set(
      :authentication_error_container_class,
      "mb-3 rounded border border-red-500/50 bg-red-950/70 p-3"
    )

    set(:authentication_error_text_class, "text-sm text-red-200")
  end

  override Components.Reset do
    set(:strategy_class, @panel_class)
  end

  override Components.Confirm do
    set(:strategy_class, @panel_class)
  end

  override Components.Password do
    set(:interstitial_class, "mt-4 flex items-center justify-between gap-3")
    set(:toggler_class, @link_class)
  end

  override Components.Password.SignInForm do
    set(:label_class, @title_class)
    set(:button_text, "Sign in")
    set(:disable_button_text, "Signing in...")
  end

  override Components.Password.RegisterForm do
    set(:label_class, @title_class)
    set(:button_text, "Create account")
    set(:disable_button_text, "Creating account...")
  end

  override Components.Password.ResetForm do
    set(:label_class, @title_class)
    set(:button_text, "Request reset link")
    set(:disable_button_text, "Requesting...")
  end

  override Components.Reset.Form do
    set(:label_class, @title_class)
    set(:button_text, "Change password")
    set(:disable_button_text, "Changing...")
  end

  override Components.Confirm.Input do
    set(:submit_class, @button_class)
  end

  override Components.Password.Input do
    set(:field_class, "mb-3")
    set(:label_class, "mb-1 block text-sm font-medium text-neutral-200")

    set(
      :input_class,
      "w-full rounded-md border border-neutral-700 bg-neutral-900 px-3 py-2 text-neutral-100 " <>
        "placeholder:text-neutral-500 focus:border-lime-300/70 focus:outline-none"
    )

    set(
      :input_class_with_error,
      "w-full rounded-md border border-red-500 bg-neutral-900 px-3 py-2 text-neutral-100 " <>
        "placeholder:text-neutral-500 focus:border-red-400 focus:outline-none"
    )

    set(:submit_class, @button_class)
    set(:error_ul, "mt-1 text-sm text-red-300")
  end

  override Components.OAuth2 do
    set(:root_class, "mt-4")
    set(:link_class, @button_class <> " bg-neutral-200 text-neutral-900 hover:bg-neutral-100")
    set(:icon_class, "-ml-0.5 mr-2 h-4 w-4")
  end
end
