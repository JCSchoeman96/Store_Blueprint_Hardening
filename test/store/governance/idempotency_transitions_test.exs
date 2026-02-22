defmodule Store.Governance.IdempotencyTransitionsTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Orders.Order
  alias Store.Payments.ProviderEvent

  test "provider event duplicate ingest returns existing record and does not increase count" do
    attrs = %{
      provider: "stripe",
      provider_event_id: "evt_001",
      event_type: "payment_intent.succeeded",
      payload_sha256: "payload-one"
    }

    first_event = ingest_provider_event!(attrs)
    second_event = ingest_provider_event!(attrs)

    assert first_event.id == second_event.id
    assert first_event.provider_event_key == "stripe:evt_001"
    assert is_binary(first_event.payload_hash)
    assert first_event.received_at

    count =
      ProviderEvent
      |> Ash.Query.filter(expr(provider == "stripe" and provider_event_id == "evt_001"))
      |> Ash.count!(domain: Store.Payments, authorize?: false)

    assert count == 1
  end

  test "stale order transition returns stale-record error signal" do
    order = create_order!()
    _paid_order = update_order!(order, :mark_paid)

    assert {:error, error} =
             order
             |> Ash.Changeset.for_update(:cancel, %{})
             |> Ash.update(domain: Store.Orders, authorize?: false)

    assert Exception.message(error) =~ "stale"
  end

  defp create_order! do
    Order
    |> Ash.Changeset.for_create(:create, %{})
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp update_order!(order, action) do
    order
    |> Ash.Changeset.for_update(action, %{})
    |> Ash.update!(domain: Store.Orders, authorize?: false)
  end

  defp ingest_provider_event!(attrs) do
    ProviderEvent
    |> Ash.Changeset.for_create(:ingest, attrs)
    |> Ash.create!(domain: Store.Payments, authorize?: false)
  end
end
