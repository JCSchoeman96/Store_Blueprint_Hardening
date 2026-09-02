defmodule Store.Accounts.User.Senders.SendNewUserConfirmationEmail do
  @moduledoc """
  Sends account confirmation emails.
  """

  use AshAuthentication.Sender
  use StoreWeb, :verified_routes
  alias Store.Accounts.Emails

  @impl AshAuthentication.Sender
  def send(user, token, opts) do
    confirmation_url = url(~p"/confirm-new-user/#{token}")

    case Keyword.get(opts, :confirmation_type) do
      :identity_link ->
        Emails.deliver_identity_link_confirmation_instructions(
          user,
          confirmation_url,
          Keyword.fetch!(opts, :provider)
        )

      _ ->
        Emails.deliver_email_confirmation_instructions(user, confirmation_url)
    end
  end
end
