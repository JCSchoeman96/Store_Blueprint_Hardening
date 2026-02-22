defmodule Store.Admin.SiteSetting do
  @moduledoc """
  Single-tenant provider configuration settings (non-secret only).
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Admin

  @secret_like_terms ~w(secret token api_key api-key key private password client_secret signing_secret)

  attributes do
    uuid_v7_primary_key(:id)

    attribute :key, Store.Admin.Types.SiteSettingKey do
      allow_nil?(false)
      public?(true)
    end

    attribute :value, :map do
      allow_nil?(false)
      default(%{})
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_key, [:key])
  end

  actions do
    defaults([:read])

    create :upsert_setting do
      accept([:key, :value])

      upsert?(true)
      upsert_identity(:unique_key)
      upsert_fields([:value])

      change(fn changeset, _context ->
        value = Ash.Changeset.get_attribute(changeset, :value) || %{}

        if contains_secret_like_key?(value) do
          Ash.Changeset.add_error(changeset,
            field: :value,
            message: "secret-like values are not allowed in site settings"
          )
        else
          changeset
        end
      end)

      change(
        {Store.Admin.Changes.AuditAfterAction,
         event: "SITE_SETTING_UPSERTED",
         resource: "site_settings",
         include_arguments?: true,
         include_attributes?: true}
      )
    end
  end

  postgres do
    table("site_settings")
    repo(Store.Repo)
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end

    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:upsert_setting) do
      access_type(:runtime)

      authorize_if(
        {Store.Support.Governance.Checks.RoleWithStepUp,
         roles: [:super_admin, :admin], window_minutes: 15}
      )
    end
  end

  defp contains_secret_like_key?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested_value} ->
      secret_like_key?(key) || contains_secret_like_key?(nested_value)
    end)
  end

  defp contains_secret_like_key?(value) when is_list(value) do
    Enum.any?(value, &contains_secret_like_key?/1)
  end

  defp contains_secret_like_key?(_value), do: false

  defp secret_like_key?(key) do
    normalized_key =
      key
      |> to_string()
      |> String.downcase()

    Enum.any?(@secret_like_terms, &String.contains?(normalized_key, &1))
  end
end
