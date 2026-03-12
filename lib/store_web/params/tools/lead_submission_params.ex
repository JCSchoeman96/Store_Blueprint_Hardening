defmodule StoreWeb.Params.Tools.LeadSubmissionParams do
  @moduledoc """
  Params adapter for tool lead submission input.
  """

  alias Store.Support.Errors.Error
  alias Store.Tools.Inputs.LeadSubmissionInput

  @spec input(map()) :: {:ok, LeadSubmissionInput.t()} | {:error, Error.t()}
  def input(params) when is_map(params) do
    normalized = %{
      "tool_slug" => get_val(params, "tool_slug", :tool_slug),
      "name" => get_val(params, "name", :name),
      "email" => get_val(params, "email", :email),
      "phone" => get_val(params, "phone", :phone),
      "consent_contact" => normalize_bool(get_val(params, "consent_contact", :consent_contact)),
      "consent_store_data" =>
        normalize_bool(get_val(params, "consent_store_data", :consent_store_data)),
      "score" => get_val(params, "score", :score),
      "category" => get_val(params, "category", :category),
      "answers" => get_val(params, "answers", :answers)
    }

    LeadSubmissionInput.new(normalized)
  end

  def input(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}

  defp get_val(params, string_key, atom_key) do
    Map.get(params, string_key) || Map.get(params, atom_key)
  end

  defp normalize_bool("true"), do: true
  defp normalize_bool("on"), do: true
  defp normalize_bool(true), do: true
  defp normalize_bool(_), do: false
end
