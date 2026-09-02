defmodule Store.Comms.Types.EmailTemplateKind do
  @moduledoc """
  Canonical template kinds for transactional customer email.
  """

  use Ash.Type.Enum,
    values: [
      :order_receipt,
      :refund_requested,
      :refund_processed,
      :payment_authentication_required,
      :renewal_reminder,
      :access_ended,
      :identity_link_confirmation
    ]
end
