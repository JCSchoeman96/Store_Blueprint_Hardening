defmodule Store.Comms.Types.EmailOutboxState do
  @moduledoc """
  Delivery lifecycle states for outbound transactional email.
  """

  use Ash.Type.Enum, values: [:pending, :processing, :sent, :failed]
end
