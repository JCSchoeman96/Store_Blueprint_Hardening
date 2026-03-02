defmodule StoreWeb.Params.AdminParams do
  @moduledoc """
  Params adapter for admin web read contracts.
  """

  alias Store.Admin.Queries.RecentAuditLogsQuery
  alias Store.Support.Errors.Error

  @spec recent_audit_logs_query(map()) :: {:ok, RecentAuditLogsQuery.t()} | {:error, Error.t()}
  def recent_audit_logs_query(params) when is_map(params), do: RecentAuditLogsQuery.new(params)

  def recent_audit_logs_query(_params),
    do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
