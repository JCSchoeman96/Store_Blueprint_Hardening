defmodule Store.Payments.ProviderEvent do
  @moduledoc """
  Deduplicated provider event evidence resource for idempotent ingest.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Payments

  alias Store.Support.Governance.Idempotency

  attributes do
    uuid_v7_primary_key(:id)

    attribute :provider, Store.Payments.Types.Provider do
      allow_nil?(false)
      public?(true)
    end

    attribute :provider_event_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :provider_event_key, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :event_type, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :payload_sha256, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :payload_hash, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :received_at, :utc_datetime_usec do
      allow_nil?(false)
      default(&DateTime.utc_now/0)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_provider_event, [:provider, :provider_event_id])
  end

  actions do
    defaults([:read])

    create :ingest do
      accept([
        :provider,
        :provider_event_id,
        :provider_event_key,
        :event_type,
        :payload_sha256,
        :payload_hash,
        :received_at
      ])

      upsert?(true)
      upsert_identity(:unique_provider_event)
      upsert_fields([])
      return_skipped_upsert?(true)

      change(fn changeset, _context ->
        provider = Ash.Changeset.get_attribute(changeset, :provider)
        provider_event_id = Ash.Changeset.get_attribute(changeset, :provider_event_id)
        provider_event_key = Ash.Changeset.get_attribute(changeset, :provider_event_key)
        payload_hash = Ash.Changeset.get_attribute(changeset, :payload_hash)
        payload_sha256 = Ash.Changeset.get_attribute(changeset, :payload_sha256)

        changeset
        |> maybe_set_provider_event_key(provider_event_key, provider, provider_event_id)
        |> maybe_set_payload_hash(payload_hash, payload_sha256)
      end)
    end
  end

  postgres do
    table("provider_events")
    repo(Store.Repo)

    custom_indexes do
      index([:provider_event_key], name: "provider_events_provider_event_key_index")
      index([:received_at], name: "provider_events_received_at_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:ingest) do
      access_type(:strict)
      authorize_if(context_equals(:system?, true))
    end

    policy always() do
      forbid_if(always())
    end
  end

  defp maybe_set_provider_event_key(
         changeset,
         provider_event_key,
         _provider,
         _provider_event_id
       )
       when is_binary(provider_event_key) do
    changeset
  end

  defp maybe_set_provider_event_key(changeset, _provider_event_key, provider, provider_event_id)
       when is_binary(provider_event_id) do
    case normalize_provider(provider) do
      nil ->
        changeset

      normalized_provider ->
        Ash.Changeset.change_attribute(
          changeset,
          :provider_event_key,
          Idempotency.provider_event_key(normalized_provider, provider_event_id)
        )
    end
  end

  defp maybe_set_provider_event_key(changeset, _provider_event_key, _provider, _provider_event_id) do
    changeset
  end

  defp maybe_set_payload_hash(changeset, payload_hash, _payload_sha256)
       when is_binary(payload_hash) do
    changeset
  end

  defp maybe_set_payload_hash(changeset, _payload_hash, payload_sha256)
       when is_binary(payload_sha256) do
    Ash.Changeset.change_attribute(
      changeset,
      :payload_hash,
      Idempotency.payload_hash(payload_sha256)
    )
  end

  defp maybe_set_payload_hash(changeset, _payload_hash, _payload_sha256), do: changeset

  defp normalize_provider(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> String.downcase()

  defp normalize_provider(provider) when is_binary(provider),
    do: provider |> String.trim() |> String.downcase()

  defp normalize_provider(_provider), do: nil
end
