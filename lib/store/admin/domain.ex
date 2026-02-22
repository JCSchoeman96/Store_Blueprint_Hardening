defmodule Store.Admin do
  @moduledoc """
  Admin domain for RBAC and audit evidence.
  """

  use Ash.Domain

  resources do
    resource(Store.Admin.AuditLog)
    resource(Store.Admin.RoleAssignment)
  end
end
