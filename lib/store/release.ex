defmodule Store.Release do
  @moduledoc """
  Release-safe operator entrypoints for production checks and restore audits.
  """

  alias Store.Operations.Health

  @spec preflight() :: map()
  def preflight do
    ensure_started!()

    report =
      %{
        command: "preflight",
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
        readiness: Health.ready_status(),
        runtime: Health.runtime_contract_status()
      }
      |> finalize_report()

    IO.puts(Jason.encode!(report, pretty: true))
    maybe_raise!(report)
    report
  end

  @spec restore_audit() :: map()
  def restore_audit do
    ensure_started!()

    report =
      %{
        command: "restore_audit",
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
        readiness: Health.ready_status(),
        restore_audit: Health.restore_audit_status()
      }
      |> finalize_report()

    IO.puts(Jason.encode!(report, pretty: true))
    maybe_raise!(report)
    report
  end

  defp ensure_started! do
    {:ok, _} = Application.ensure_all_started(:store)
  end

  defp finalize_report(report) do
    status =
      if Enum.all?(report, fn
           {:generated_at, _value} -> true
           {:command, _value} -> true
           {:status, _value} -> true
           {_key, %{status: "ok"}} -> true
           _other -> false
         end) do
        "ok"
      else
        "error"
      end

    Map.put(report, :status, status)
  end

  defp maybe_raise!(%{status: "ok"}), do: :ok

  defp maybe_raise!(report) do
    raise "release command failed: #{report.command}"
  end
end
