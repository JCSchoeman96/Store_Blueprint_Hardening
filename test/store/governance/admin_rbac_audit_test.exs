defmodule Store.Governance.AdminRbacAuditTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ash.Resource.Info
  alias Store.Admin.AuditLog
  alias Store.Admin.RoleAssignment
  alias Store.TestFixtures

  test "customer is denied admin role assignment mutation" do
    customer = TestFixtures.register_user!(email: TestFixtures.unique_email("customer"))
    target = TestFixtures.register_user!(email: TestFixtures.unique_email("target"))

    changeset =
      RoleAssignment
      |> Ash.Changeset.for_create(:assign, %{
        user_id: target.id,
        role: :support,
        assigned_by: customer.id
      })

    assert {:error, error} = Ash.create(changeset, domain: Store.Admin, actor: customer)
    assert Exception.message(error) =~ "forbidden"
  end

  test "admin mutation creates audit entry" do
    super_admin_user = TestFixtures.register_user!(email: TestFixtures.unique_email("super"))
    target = TestFixtures.register_user!(email: TestFixtures.unique_email("target"))

    _bootstrap = TestFixtures.assign_role!(super_admin_user, :super_admin)

    assignment =
      TestFixtures.assign_role!(target, :support,
        actor: super_admin_user,
        assigned_by: super_admin_user.id
      )

    query =
      AuditLog
      |> Ash.Query.filter(expr(record_id == ^assignment.id and action == "ROLE_ASSIGNED"))

    assert {:ok, [audit_log]} =
             Ash.read(query, domain: Store.Admin, actor: super_admin_user, authorize?: false)

    assert audit_log.resource == "role_assignments"
    assert audit_log.actor_id == super_admin_user.id
  end

  test "audit log resource is append-only (no update/destroy actions)" do
    action_types =
      AuditLog
      |> Info.actions()
      |> Enum.map(& &1.type)

    refute :update in action_types
    refute :destroy in action_types
  end

  test "audit metadata is scrubbed and capped" do
    oversized_payload = String.duplicate("x", 3000)

    extra_keys =
      1..60
      |> Enum.map(fn idx -> {"extra_key_#{idx}", idx} end)
      |> Map.new()

    meta =
      extra_keys
      |> Map.merge(%{
        "email" => "person@example.com",
        "secret" => "s3cr3t",
        "webhook_payload" => oversized_payload
      })

    changeset =
      AuditLog
      |> Ash.Changeset.for_create(:create, %{action: "TEST", resource: "tests", meta: meta},
        context: %{system?: true}
      )

    assert {:ok, log} = Ash.create(changeset, domain: Store.Admin, authorize?: false)
    assert map_size(log.meta) <= 50
    assert log.meta["email"] == "[REDACTED]"
    assert log.meta["secret"] == "[REDACTED]"
    refute Map.has_key?(log.meta, "webhook_payload")
    assert byte_size(Jason.encode!(log.meta)) <= 8192
  end

  test "non-bootstrap role assignment requires assigned_by" do
    super_admin_user = TestFixtures.register_user!(email: TestFixtures.unique_email("super"))
    target = TestFixtures.register_user!(email: TestFixtures.unique_email("target"))
    _bootstrap = TestFixtures.assign_role!(super_admin_user, :super_admin)

    changeset =
      RoleAssignment
      |> Ash.Changeset.for_create(:assign, %{user_id: target.id, role: :support}, context: %{})

    assert {:error, error} = Ash.create(changeset, domain: Store.Admin, actor: super_admin_user)
    assert Exception.message(error) =~ "assigned_by"
  end

  test "role assignments enforce uniqueness on (user_id, role)" do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("unique"))

    _first = TestFixtures.assign_role!(user, :support)

    assert {:error, error} =
             RoleAssignment
             |> Ash.Changeset.for_create(:assign, %{user_id: user.id, role: :support},
               context: %{bootstrap?: true, system?: true}
             )
             |> Ash.create(domain: Store.Admin, authorize?: false)

    assert Exception.message(error) =~ "already been taken"
  end
end
