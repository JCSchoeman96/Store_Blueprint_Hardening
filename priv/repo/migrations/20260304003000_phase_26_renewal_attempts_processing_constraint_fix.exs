defmodule Store.Repo.Migrations.Phase26RenewalAttemptsProcessingConstraintFix do
  use Ecto.Migration

  def up do
    drop_if_exists(constraint(:renewal_attempts, "renewal_attempts_status_value_check"))

    create(
      constraint(
        :renewal_attempts,
        "renewal_attempts_status_value_check",
        check: "status IN ('pending', 'processing', 'succeeded', 'failed')"
      )
    )
  end

  def down do
    drop_if_exists(constraint(:renewal_attempts, "renewal_attempts_status_value_check"))

    create(
      constraint(
        :renewal_attempts,
        "renewal_attempts_status_value_check",
        check: "status IN ('pending', 'succeeded', 'failed')"
      )
    )
  end
end
