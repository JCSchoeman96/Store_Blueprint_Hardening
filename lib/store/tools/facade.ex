defmodule Store.Tools.Facade do
  @moduledoc """
  Consumer-scoped surfaces for public lead-generation tools.
  """

  alias Ecto.Changeset
  alias Store.Repo
  alias Store.Support.Errors.{Error, Normalize}
  alias Store.Support.ID.UUIDv7
  alias Store.Tools.Inputs.LeadSubmissionInput
  alias Store.Tools.LeadSubmission

  @spec submit_lead(LeadSubmissionInput.t()) :: {:ok, LeadSubmission.t()} | {:error, Error.t()}
  def submit_lead(%LeadSubmissionInput{} = input) do
    attrs = %{
      id: UUIDv7.generate(),
      tool_slug: input.tool_slug,
      name: input.name,
      email: input.email,
      phone: input.phone,
      consent_contact: input.consent_contact,
      consent_store_data: input.consent_store_data,
      score: input.score,
      category: input.category,
      answers: input.answers
    }

    %LeadSubmission{}
    |> Changeset.change(attrs)
    |> Repo.insert()
    |> case do
      {:ok, lead} -> {:ok, lead}
      {:error, changeset} -> {:error, normalize_db_error(changeset)}
    end
  end

  def submit_lead(_input) do
    {:error, Error.new("VALIDATION_ERROR", "invalid lead submission input")}
  end

  defp normalize_db_error(%Ecto.Changeset{} = _changeset) do
    Error.new("INTERNAL_ERROR", "lead submission failed")
  end

  defp normalize_db_error(error) do
    Normalize.normalize(error)
  end
end
