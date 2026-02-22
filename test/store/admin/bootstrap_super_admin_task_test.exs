defmodule Store.Admin.BootstrapSuperAdminTaskTest do
  use Store.DataCase, async: false

  import Ash.Expr
  import ExUnit.CaptureIO
  require Ash.Query

  alias Mix.Tasks.Store.Bootstrap.SuperAdmin
  alias Store.Admin.AuditLog
  alias Store.Admin.RoleAssignment
  alias Store.TestFixtures

  test "mix task bootstraps super_admin idempotently with audit evidence" do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("bootstrap"))
    email = to_string(user.email)

    Mix.Task.reenable("store.bootstrap.super_admin")
    capture_io(fn -> SuperAdmin.run([email]) end)

    assert TestFixtures.role_assignment_count!(user, :super_admin) == 1

    role_assignment =
      RoleAssignment
      |> Ash.Query.filter(expr(user_id == ^user.id and role == :super_admin))
      |> Ash.read_one!(domain: Store.Admin, authorize?: false)

    audit_query =
      AuditLog
      |> Ash.Query.filter(expr(record_id == ^role_assignment.id and action == "ROLE_ASSIGNED"))

    assert {:ok, [audit_log]} = Ash.read(audit_query, domain: Store.Admin, authorize?: false)
    assert audit_log.resource == "role_assignments"

    Mix.Task.reenable("store.bootstrap.super_admin")
    capture_io(fn -> SuperAdmin.run([email]) end)

    assert TestFixtures.role_assignment_count!(user, :super_admin) == 1
  end
end
