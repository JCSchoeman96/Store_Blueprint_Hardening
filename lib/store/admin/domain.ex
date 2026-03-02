defmodule Store.Admin do
  @moduledoc """
  Admin domain for RBAC and audit evidence.
  """

  use Ash.Domain

  require Ash.Query

  alias Store.Admin.{AuditLog, Queries.RecentAuditLogsQuery}

  resources do
    resource(Store.Admin.AuditLog)
    resource(Store.Admin.RoleAssignment)
    resource(Store.Admin.SiteSetting)
  end

  @spec recent_audit_logs(RecentAuditLogsQuery.t(), map()) ::
          {:ok, [AuditLog.t()]} | {:error, term()}
  def recent_audit_logs(%RecentAuditLogsQuery{limit: limit}, actor) when is_map(actor) do
    query =
      AuditLog
      |> Ash.Query.for_read(:recent_for_admin, %{limit: limit}, actor: actor)

    Ash.read(query, domain: __MODULE__, actor: actor)
  end
end
