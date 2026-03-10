defmodule Store.Operations.Health do
  @moduledoc """
  Operational health, readiness, and restore-audit checks.
  """

  alias Ecto.Adapters.SQL
  alias Store.Payments.Providers
  alias Store.Support.RateLimit.RedisBackend
  alias Store.Support.RateLimit.RedixClient

  @spec live_status() :: map()
  def live_status do
    %{
      status: "ok",
      checks: %{
        application: %{status: "ok"},
        endpoint: component_status(Process.whereis(StoreWeb.Endpoint))
      }
    }
  end

  @spec ready_status() :: map()
  def ready_status do
    checks =
      %{
        repo: repo_status(Store.Repo),
        direct_repo: repo_status(Store.DirectRepo),
        oban: component_status(Oban.whereis(Oban))
      }
      |> maybe_put_redis_status()

    overall_status(checks)
  end

  @spec runtime_contract_status() :: map()
  def runtime_contract_status do
    checks = %{
      payments: payments_runtime_status(),
      comms: comms_runtime_status(),
      digital: digital_runtime_status(),
      security_headers: security_headers_status(),
      rate_limits: rate_limit_status()
    }

    overall_status(checks)
  end

  @spec restore_audit_status() :: map()
  def restore_audit_status do
    checks = %{
      order_count: count_status("orders"),
      payment_intent_count: count_status("payment_intents"),
      webhook_receipt_count: count_status("webhook_receipts"),
      email_outbox_count: count_status("email_outboxes"),
      download_grant_count: count_status("download_grants")
    }

    overall_status(checks)
  end

  defp repo_status(repo) do
    case SQL.query(repo, "SELECT 1", []) do
      {:ok, _result} -> %{status: "ok"}
      {:error, reason} -> %{status: "error", reason: Exception.message(reason)}
    end
  rescue
    error -> %{status: "error", reason: Exception.message(error)}
  end

  defp component_status(pid) when is_pid(pid) do
    if Process.alive?(pid), do: %{status: "ok"}, else: %{status: "error", reason: "not_running"}
  end

  defp component_status(_), do: %{status: "error", reason: "not_running"}

  defp maybe_put_redis_status(checks) do
    rate_limit_config = Application.get_env(:store, :rate_limit, [])

    if Keyword.get(rate_limit_config, :backend) == RedisBackend do
      Map.put(checks, :rate_limit_redis, redis_status())
    else
      checks
    end
  end

  defp redis_status do
    case RedixClient.ping() do
      :ok -> %{status: "ok"}
      {:error, reason} -> %{status: "error", reason: inspect(reason)}
    end
  end

  defp payments_runtime_status do
    payments = Application.get_env(:store, :payments, [])
    enabled = Keyword.get(payments, :enabled_providers, [])
    stripe = Keyword.get(payments, :stripe, [])

    conditions = [
      {:enabled_provider_shape, is_list(enabled)},
      {:stripe_webhook_secret,
       :stripe not in enabled or present?(Keyword.get(stripe, :webhook_secret))},
      {:stripe_secret_key, :stripe not in enabled or present?(Keyword.get(stripe, :secret_key))},
      {:stripe_publishable_key,
       :stripe not in enabled or present?(Keyword.get(stripe, :publishable_key))},
      {:known_enabled_providers, Enum.all?(enabled, &Providers.known_provider?/1)}
    ]

    predicate_status(conditions)
  end

  defp comms_runtime_status do
    comms = Application.get_env(:store, :comms, [])
    provider = Keyword.get(comms, :default_provider)
    postmark = Keyword.get(comms, :req_postmark, [])

    predicate_status([
      {:default_provider, provider in [:swoosh, :req_postmark]},
      {:from_email, present?(Keyword.get(comms, :from_email))},
      {:postmark_token,
       provider != :req_postmark or present?(Keyword.get(postmark, :server_token))}
    ])
  end

  defp digital_runtime_status do
    digital = Application.get_env(:store, :digital, [])
    provider = Keyword.get(digital, :storage_provider)
    s3 = Keyword.get(digital, :s3, [])

    predicate_status([
      {:provider, provider in [:fake, :s3]},
      {:signed_url_ttl_seconds, integer_positive?(Keyword.get(digital, :signed_url_ttl_seconds))},
      {:s3_region, provider != :s3 or present?(Keyword.get(s3, :region))},
      {:s3_access_key_id, provider != :s3 or present?(Keyword.get(s3, :access_key_id))},
      {:s3_secret_access_key, provider != :s3 or present?(Keyword.get(s3, :secret_access_key))}
    ])
  end

  defp security_headers_status do
    config = Application.get_env(:store, :security_headers, [])
    csp_mode = Keyword.get(config, :csp_mode, :disabled)

    predicate_status([
      {:csp_mode, csp_mode in [:disabled, :enforce, :report_only]},
      {:csp_policy, csp_mode == :disabled or present?(Keyword.get(config, :csp_policy))},
      {:csp_report_uri,
       csp_mode != :report_only or present?(Keyword.get(config, :csp_report_uri))}
    ])
  end

  defp rate_limit_status do
    config = Application.get_env(:store, :rate_limit, [])

    predicate_status([
      {:webhook_limit, integer_positive?(Keyword.get(config, :webhook_limit))},
      {:webhook_window_seconds, integer_positive?(Keyword.get(config, :webhook_window_seconds))},
      {:admin_limit, integer_positive?(Keyword.get(config, :admin_limit))},
      {:admin_window_seconds, integer_positive?(Keyword.get(config, :admin_window_seconds))}
    ])
  end

  defp count_status(table) when is_binary(table) do
    case SQL.query(Store.DirectRepo, "SELECT COUNT(*) FROM #{table}", []) do
      {:ok, %{rows: [[count]]}} -> %{status: "ok", count: count}
      {:error, reason} -> %{status: "error", reason: Exception.message(reason)}
    end
  rescue
    error -> %{status: "error", reason: Exception.message(error)}
  end

  defp predicate_status(conditions) do
    failed =
      conditions
      |> Enum.reject(fn {_check, passed?} -> passed? end)
      |> Enum.map(fn {check, _passed?} -> check end)

    if failed == [] do
      %{status: "ok"}
    else
      %{status: "error", failed_checks: failed}
    end
  end

  defp overall_status(checks) do
    if Enum.all?(checks, fn {_key, value} -> Map.get(value, :status) == "ok" end) do
      %{status: "ok", checks: checks}
    else
      %{status: "error", checks: checks}
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
  defp integer_positive?(value), do: is_integer(value) and value > 0
end
