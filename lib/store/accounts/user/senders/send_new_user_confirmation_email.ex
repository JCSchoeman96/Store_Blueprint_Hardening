defmodule Store.Accounts.User.Senders.SendNewUserConfirmationEmail do
  @moduledoc """
  Sends account confirmation emails.
  """

  use AshAuthentication.Sender
  use StoreWeb, :verified_routes
  alias Store.Accounts.Emails
  alias Store.Comms

  @impl AshAuthentication.Sender
  def send(user, token, opts) do
    confirmation_url = url(~p"/confirm-new-user/#{token}")

    case Keyword.get(opts, :confirmation_type) do
      :identity_link ->
        with {:ok, provider} <- identity_provider(opts),
             {:ok, _outbox} <-
               Comms.enqueue_identity_link_confirmation_for_system(
                 user,
                 confirmation_url,
                 token,
                 provider
               ) do
          :ok
        end

      _ ->
        Emails.deliver_email_confirmation_instructions(user, confirmation_url)
    end
  end

  defp identity_provider(opts) do
    case Keyword.fetch(opts, :provider) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, :missing_identity_provider}
    end
  end
end
