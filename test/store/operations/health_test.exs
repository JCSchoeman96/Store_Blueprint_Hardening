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

  test "runtime contract reports trusted proxy and cluster checks" do
    previous_trusted_proxy = Application.get_env(:store, :trusted_proxy, [])
    previous_dns_cluster_query = Application.get_env(:store, :dns_cluster_query)

    Application.put_env(:store, :trusted_proxy,
      headers: ["cf-connecting-ip"],
      proxies: ["173.245.48.0/20"]
    )

    Application.put_env(:store, :dns_cluster_query, nil)

    on_exit(fn ->
      Application.put_env(:store, :trusted_proxy, previous_trusted_proxy)
      Application.put_env(:store, :dns_cluster_query, previous_dns_cluster_query)
    end)

    status = Health.runtime_contract_status()

    assert get_in(status, [:checks, :trusted_proxy, :status]) == "ok"
    assert get_in(status, [:checks, :cluster, :status]) == "ok"
  end
end
