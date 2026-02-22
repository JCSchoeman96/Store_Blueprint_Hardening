defmodule Store.Accounts.User.Senders.SendNewUserConfirmationEmail do
  @moduledoc """
  Sends account confirmation emails.
  """

  use AshAuthentication.Sender
  use StoreWeb, :verified_routes
  alias Store.Accounts.Emails

  @impl AshAuthentication.Sender
  def send(user, token, _opts) do
    Emails.deliver_email_confirmation_instructions(
      user,
      url(~p"/confirm-new-user/#{token}")
    )
  end
end
