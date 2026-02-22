defmodule Store.Admin.Types.SiteSettingKey do
  @moduledoc """
  Allowed non-secret provider configuration keys for admin site settings.
  """

  use Ash.Type.Enum,
    values: [
      :provider_display_name,
      :provider_mode,
      :provider_webhook_endpoint,
      :provider_checkout_label,
      :provider_support_contact
    ]
end
