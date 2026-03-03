defmodule Store.Comms.Providers.Behavior do
  @moduledoc """
  Contract for transactional email delivery backends.
  """

  @type message_payload :: %{
          required(:to_email) => String.t(),
          optional(:to_name) => String.t() | nil,
          required(:subject) => String.t(),
          required(:text_body) => String.t(),
          optional(:html_body) => String.t() | nil
        }

  @callback deliver_email(message_payload(), keyword()) ::
              {:ok, String.t() | nil}
              | {:error, :transient, term()}
              | {:error, :permanent, term()}
end
