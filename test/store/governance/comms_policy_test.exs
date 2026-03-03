defmodule Store.Governance.CommsPolicyTest do
  use Store.DataCase, async: false

  alias Store.Comms.Facade, as: CommsFacade
  alias Store.Comms.Queries.AdminEmailOutboxIndexQuery
  alias Store.Orders.Order
  alias Store.TestFixtures

  test "admin and support can inspect outbox while customer is denied" do
    customer =
      TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_comms_customer"))

    _order = create_order_for_user_and_enqueue!(customer.id)

    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_comms_admin"))
    _admin_role = TestFixtures.assign_role!(admin, :admin)

    support =
      TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_comms_support"))

    _support_role = TestFixtures.assign_role!(support, :support)

    other_customer =
      TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_comms_other"))

    query = %AdminEmailOutboxIndexQuery{limit: 20, offset: 0, state: nil, template_kind: nil}

    assert {:ok, admin_rows} = CommsFacade.list_email_outboxes_for_admin(admin, query)
    refute admin_rows == []

    assert {:ok, support_rows} = CommsFacade.list_email_outboxes_for_admin(support, query)
    refute support_rows == []

    assert {:error, error} = CommsFacade.list_email_outboxes_for_admin(other_customer, query)
    assert error.code == "FORBIDDEN"
  end

  defp create_order_for_user_and_enqueue!(user_id) do
    order =
      Order
      |> Ash.Changeset.for_create(:create, %{user_id: user_id})
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    order =
      order
      |> Ash.Changeset.for_update(
        :finalize_checkout_totals,
        %{
          currency_code: "USD",
          grand_total_minor: 4_500,
          items_subtotal_minor: 4_500,
          shipping_total_minor: 0
        },
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    assert {:ok, _outbox} = Store.Comms.enqueue_order_receipt_for_system(order.id)
    order
  end
end
