defmodule Store.Admin.RoleAssignment do
  @moduledoc """
  Role assignments used as the RBAC source of truth.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Admin

  attributes do
    uuid_v7_primary_key(:id)

    attribute :user_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :role, Store.Admin.Types.Role do
      allow_nil?(false)
      public?(true)
    end

    attribute :assigned_by, :uuid do
      allow_nil?(true)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_user_role, [:user_id, :role])
  end

  actions do
    defaults([:read])

    create :assign do
      accept([:user_id, :role, :assigned_by])

      change(fn changeset, _context ->
        context = changeset.context || %{}
        bootstrap_or_system? = context[:bootstrap?] || context[:system?]
        assigned_by = Ash.Changeset.get_attribute(changeset, :assigned_by)

        if bootstrap_or_system? || not is_nil(assigned_by) do
          changeset
        else
          Ash.Changeset.add_error(changeset,
            field: :assigned_by,
            message: "must be set for non-bootstrap role assignment"
          )
        end
      end)

      change(
        {Store.Admin.Changes.AuditAfterAction,
         event: "ROLE_ASSIGNED",
         resource: "role_assignments",
         include_arguments?: true,
         include_attributes?: true}
      )
    end
  end

  postgres do
    table("role_assignments")
    repo(Store.Repo)

    custom_indexes do
      index([:role], name: "role_assignments_role_index")
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end

    policy action_type(:read) do
      access_type(:runtime)
      authorize_if(context_equals(:bootstrap?, true))
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action_type(:create) do
      access_type(:runtime)
      authorize_if(context_equals(:bootstrap?, true))
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin]})
    end

    policy always() do
      forbid_if(always())
    end
  end
end
