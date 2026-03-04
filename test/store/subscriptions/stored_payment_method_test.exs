defmodule Store.Subscriptions.StoredPaymentMethodTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Subscriptions.StoredPaymentMethod
  alias Store.TestFixtures

  test "create_or_reuse is idempotent by provider+customer+payment_method reference" do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("phase26_spm_user"))

    attrs = %{
      user_id: user.id,
      provider: :stripe,
      provider_customer_ref: "cus_phase26_001",
      provider_payment_method_ref: "pm_phase26_001",
      status: :active,
      fingerprint: "fp_phase26_001"
    }

    assert {:ok, first} =
             StoredPaymentMethod
             |> Ash.Changeset.for_create(:create_or_reuse, attrs, context: %{system?: true})
             |> Ash.create(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:ok, second} =
             StoredPaymentMethod
             |> Ash.Changeset.for_create(
               :create_or_reuse,
               Map.put(attrs, :status, :inactive),
               context: %{system?: true}
             )
             |> Ash.create(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert first.id == second.id
    assert second.status == :inactive

    assert 1 ==
             StoredPaymentMethod
             |> Ash.Query.filter(
               expr(
                 provider == :stripe and provider_customer_ref == "cus_phase26_001" and
                   provider_payment_method_ref == "pm_phase26_001"
               )
             )
             |> Ash.count!(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )
  end
end
