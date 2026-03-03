defmodule Store.Comms.DomainTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.Repo

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL
  alias Store.Comms.EmailOutbox
  alias Store.Orders.Order
  alias Store.TestFixtures
  alias Store.Workers.DeliverEmailOutboxWorker

  test "enqueue_order_receipt_for_system is idempotent by canonical key" do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_receipt_user"))
    order = create_finalized_order!(user.id)

    assert {:ok, first} = Store.Comms.enqueue_order_receipt_for_system(order.id)
    assert {:ok, second} = Store.Comms.enqueue_order_receipt_for_system(order.id)

    assert first.id == second.id
    assert first.idempotency_key == "order_receipt:order:#{order.id}"
    assert first.provider == :swoosh
    assert first.template_kind == :order_receipt

    assert 1 ==
             EmailOutbox
             |> Ash.Query.filter(expr(order_id == ^order.id and template_kind == :order_receipt))
             |> Ash.count!(domain: Store.Comms, authorize?: false)

    assert_enqueued(
      worker: DeliverEmailOutboxWorker,
      args: %{"email_outbox_id" => first.id},
      queue: "comms"
    )
  end

  test "template_kind/refund_id coherence validation rejects invalid combinations" do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_coherence_user"))
    order = create_finalized_order!(user.id)

    attrs = %{
      order_id: order.id,
      refund_id: nil,
      template_kind: :refund_requested,
      to_email: user.email,
      subject: "invalid",
      body_text: "",
      body_html: nil,
      template_assigns: %{},
      idempotency_key: "invalid:#{System.unique_integer([:positive])}",
      provider: :swoosh
    }

    assert {:error, error} =
             EmailOutbox
             |> Ash.Changeset.for_create(:enqueue, attrs, context: %{system?: true})
             |> Ash.create(domain: Store.Comms, authorize?: false, context: %{system?: true})

    assert Exception.message(error) =~ "template_kind/refund_id combination is invalid"
  end

  test "provider enum rejects unknown values" do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_provider_user"))
    order = create_finalized_order!(user.id)

    attrs = %{
      order_id: order.id,
      refund_id: nil,
      template_kind: :order_receipt,
      to_email: user.email,
      subject: "invalid provider",
      body_text: "",
      body_html: nil,
      template_assigns: %{},
      idempotency_key: "provider-invalid:#{System.unique_integer([:positive])}",
      provider: :bogus
    }

    assert {:error, error} =
             EmailOutbox
             |> Ash.Changeset.for_create(:enqueue, attrs, context: %{system?: true})
             |> Ash.create(domain: Store.Comms, authorize?: false, context: %{system?: true})

    assert Exception.message(error) =~ "provider"
  end

  test "CAS delivery claim prevents duplicate sends and increments attempts once" do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_cas_user"))
    order = create_finalized_order!(user.id)
    {:ok, outbox} = Store.Comms.enqueue_order_receipt_for_system(order.id)

    assert :ok = Store.Comms.deliver_outbox_email_for_system(outbox.id)
    assert {:discard, :already_sent} = Store.Comms.deliver_outbox_email_for_system(outbox.id)

    updated = fetch_outbox!(outbox.id)
    assert updated.state == :sent
    assert updated.attempt_count == 1
    assert not is_nil(updated.sent_at)
  end

  test "reclaim_stale_processing_for_system resets stale processing rows to pending" do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_reclaim_user"))
    order = create_finalized_order!(user.id)
    {:ok, outbox} = Store.Comms.enqueue_order_receipt_for_system(order.id)

    stale_started_at = DateTime.utc_now() |> DateTime.add(-3600, :second)

    assert {:ok, _} =
             SQL.query(
               Store.Repo,
               """
               UPDATE email_outboxes
               SET state = 'processing',
                   processing_started_at = $2
               WHERE id = $1::text::uuid
               """,
               [outbox.id, stale_started_at]
             )

    assert {:ok, %{reclaimed_count: 1, outbox_ids: [reclaimed_id]}} =
             Store.Comms.reclaim_stale_processing_for_system(timeout_seconds: 60)

    assert reclaimed_id == outbox.id

    updated = fetch_outbox!(outbox.id)
    assert updated.state == :pending
    assert is_nil(updated.processing_started_at)

    assert_enqueued(
      worker: DeliverEmailOutboxWorker,
      args: %{"email_outbox_id" => outbox.id},
      queue: "comms"
    )
  end

  defp create_finalized_order!(user_id) do
    order =
      Order
      |> Ash.Changeset.for_create(:create, %{user_id: user_id})
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    order
    |> Ash.Changeset.for_update(
      :finalize_checkout_totals,
      %{
        currency_code: "USD",
        grand_total_minor: 12_500,
        items_subtotal_minor: 12_500,
        shipping_total_minor: 0
      },
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp fetch_outbox!(id) do
    assert {:ok, [outbox]} =
             EmailOutbox
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Comms, authorize?: false, context: %{system?: true})

    outbox
  end
end
