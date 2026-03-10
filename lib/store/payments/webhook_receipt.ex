defmodule Store.Payments.WebhookReceipt do
  @moduledoc """
  Receipt-first webhook evidence with idempotent duplicate NOOP semantics.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Payments

  attributes do
    uuid_v7_primary_key(:id)

    attribute :provider, Store.Payments.Types.Provider do
      allow_nil?(false)
      public?(true)
    end

    attribute :idempotency_key, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :payload_sha256, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :verification_status, :string do
      allow_nil?(false)
      default("verified")
      public?(true)
    end

    attribute :processing_status, :string do
      allow_nil?(false)
      default("new")
      public?(true)
    end

    attribute :provider_event_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :event_type, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :error_code, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :error_detail, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :verified_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :processed_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :evidence_purged_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :raw_body, :string do
      allow_nil?(false)
      default("")
      public?(true)
    end

    attribute :headers, :map do
      allow_nil?(false)
      default(%{})
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
    identity(:unique_idempotency_key, [:idempotency_key])
    identity(:unique_provider_event, [:provider, :provider_event_id])
  end

  actions do
    defaults([:read])

    read :get_for_system do
      get?(true)

      argument :id, :uuid do
        allow_nil?(false)
      end

      filter(expr(id == ^arg(:id)))
    end

    create :ingest do
      accept([
        :provider,
        :idempotency_key,
        :payload_sha256,
        :verification_status,
        :processing_status,
        :provider_event_id,
        :event_type,
        :error_code,
        :error_detail,
        :verified_at,
        :processed_at,
        :evidence_purged_at,
        :raw_body,
        :headers,
        :received_at
      ])

      change(fn changeset, _context ->
        provider = Ash.Changeset.get_attribute(changeset, :provider)
        raw_body = Ash.Changeset.get_attribute(changeset, :raw_body)
        idempotency_key = Ash.Changeset.get_attribute(changeset, :idempotency_key)
        payload_sha256 = Ash.Changeset.get_attribute(changeset, :payload_sha256)

        changeset
        |> maybe_set_idempotency_key(idempotency_key, provider, raw_body)
        |> maybe_set_payload_sha(payload_sha256, raw_body)
      end)

      upsert?(true)
      upsert_identity(:unique_idempotency_key)
      upsert_fields([])
      return_skipped_upsert?(true)
    end

    update :mark_processing do
      accept([])
      change(set_attribute(:processing_status, "processing"))
    end

    update :mark_processed do
      accept([:processed_at])
      change(set_attribute(:processing_status, "processed"))
    end

    update :mark_failed do
      accept([:error_code, :error_detail, :processed_at])
      change(set_attribute(:processing_status, "failed"))
    end

    update :purge_evidence do
      accept([:raw_body, :headers, :evidence_purged_at])
    end
  end

  code_interface do
    define(:get_for_system, action: :get_for_system, args: [:id])
  end

  postgres do
    table("webhook_receipts")
    repo(Store.Repo)

    custom_indexes do
      index([:provider], name: "webhook_receipts_provider_index")
      index([:received_at], name: "webhook_receipts_received_at_index")
      index([:verification_status], name: "webhook_receipts_verification_status_index")
      index([:processing_status], name: "webhook_receipts_processing_status_index")
      index([:provider_event_id], name: "webhook_receipts_provider_event_id_index")
      index([:evidence_purged_at], name: "webhook_receipts_evidence_purged_at_index")
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

    policy action(:get_for_system) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy action([:mark_processing, :mark_processed, :mark_failed, :purge_evidence]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy always() do
      forbid_if(always())
    end
  end

  defp maybe_set_idempotency_key(changeset, idempotency_key, _provider, _raw_body)
       when is_binary(idempotency_key) do
    changeset
  end

  defp maybe_set_idempotency_key(changeset, _idempotency_key, provider, raw_body)
       when is_binary(raw_body) do
    case normalize_provider(provider) do
      nil ->
        changeset

      normalized_provider ->
        Ash.Changeset.change_attribute(
          changeset,
          :idempotency_key,
          sha256_hex("#{normalized_provider}\n" <> raw_body)
        )
    end
  end

  defp maybe_set_idempotency_key(changeset, _idempotency_key, _provider, _raw_body), do: changeset

  defp maybe_set_payload_sha(changeset, payload_sha256, _raw_body)
       when is_binary(payload_sha256) do
    changeset
  end

  defp maybe_set_payload_sha(changeset, _payload_sha256, raw_body) when is_binary(raw_body) do
    Ash.Changeset.change_attribute(changeset, :payload_sha256, sha256_hex(raw_body))
  end

  defp maybe_set_payload_sha(changeset, _payload_sha256, _raw_body), do: changeset

  defp sha256_hex(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp normalize_provider(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> String.downcase()

  defp normalize_provider(provider) when is_binary(provider),
    do: provider |> String.trim() |> String.downcase()

  defp normalize_provider(_provider), do: nil
end
