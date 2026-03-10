defmodule Store.Operations.HealthTest do
  use ExUnit.Case, async: false

  alias Store.Operations.Health

  test "runtime contract fails closed when stripe is enabled without webhook secret" do
    previous = Application.get_env(:store, :payments, [])

    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        secret_key: "sk_test_missing_webhook_secret",
        publishable_key: "pk_test_missing_webhook_secret",
        webhook_secret: nil
      ]
    )

    on_exit(fn ->
      Application.put_env(:store, :payments, previous)
    end)

    status = Health.runtime_contract_status()

    assert status.status == "error"
    assert :stripe_webhook_secret in get_in(status, [:checks, :payments, :failed_checks])
  end
end
