defmodule Store.Comms.Types.EmailProvider do
  @moduledoc """
  Supported delivery backends for outbox email dispatch.
  """

  use Ash.Type.Enum, values: [:swoosh, :req_postmark]
end
