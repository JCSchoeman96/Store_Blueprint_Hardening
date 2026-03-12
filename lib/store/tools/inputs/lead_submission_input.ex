defmodule Store.Tools.Inputs.LeadSubmissionInput do
  @moduledoc """
  Typed input contract for tool lead submissions.
  """

  alias Store.Support.Errors.Error

  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  @enforce_keys [:tool_slug, :name, :email, :consent_contact, :consent_store_data, :score, :category, :answers]
  defstruct [:tool_slug, :name, :email, :phone, :consent_contact, :consent_store_data, :score, :category, :answers]

  @type t :: %__MODULE__{
          tool_slug: String.t(),
          name: String.t(),
          email: String.t(),
          phone: String.t() | nil,
          consent_contact: boolean(),
          consent_store_data: boolean(),
          score: integer(),
          category: String.t(),
          answers: map()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with {:ok, tool_slug} <- parse_non_empty_string(params, :tool_slug, "tool_slug"),
         {:ok, name} <- parse_non_empty_string(params, :name, "name"),
         {:ok, email} <- parse_email(params),
         {:ok, phone} <- parse_optional_string(params, :phone, "phone"),
         {:ok, true} <- parse_consent(params, :consent_contact, "consent_contact"),
         {:ok, true} <- parse_consent(params, :consent_store_data, "consent_store_data"),
         {:ok, score} <- parse_integer(params, :score, "score"),
         {:ok, category} <- parse_non_empty_string(params, :category, "category"),
         {:ok, answers} <- parse_answers(params) do
      {:ok,
       %__MODULE__{
         tool_slug: tool_slug,
         name: name,
         email: email,
         phone: phone,
         consent_contact: true,
         consent_store_data: true,
         score: score,
         category: category,
         answers: answers
       }}
    end
  end

  def new(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}

  defp parse_non_empty_string(params, key, label) do
    value = Map.get(params, key) || Map.get(params, to_string(key))

    if is_binary(value) and String.trim(value) != "" do
      {:ok, String.trim(value)}
    else
      {:error, Error.new("VALIDATION_ERROR", "#{label} is required")}
    end
  end

  defp parse_optional_string(params, key, _label) do
    value = Map.get(params, key) || Map.get(params, to_string(key))

    cond do
      is_nil(value) -> {:ok, nil}
      is_binary(value) and String.trim(value) == "" -> {:ok, nil}
      is_binary(value) -> {:ok, String.trim(value)}
      true -> {:ok, nil}
    end
  end

  defp parse_email(params) do
    value = Map.get(params, :email) || Map.get(params, "email")

    cond do
      not is_binary(value) ->
        {:error, Error.new("VALIDATION_ERROR", "email is required")}

      not Regex.match?(@email_regex, value) ->
        {:error, Error.new("VALIDATION_ERROR", "email is not valid")}

      true ->
        {:ok, String.downcase(String.trim(value))}
    end
  end

  defp parse_consent(params, key, label) do
    value = Map.get(params, key) || Map.get(params, to_string(key))

    case value do
      true ->
        {:ok, true}

      "true" ->
        {:ok, true}

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "#{label} must be accepted")}
    end
  end

  defp parse_integer(params, key, label) do
    value = Map.get(params, key) || Map.get(params, to_string(key))

    cond do
      is_integer(value) ->
        {:ok, value}

      is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> {:ok, parsed}
          _ -> {:error, Error.new("VALIDATION_ERROR", "#{label} must be an integer")}
        end

      true ->
        {:error, Error.new("VALIDATION_ERROR", "#{label} must be an integer")}
    end
  end

  defp parse_answers(params) do
    value = Map.get(params, :answers) || Map.get(params, "answers")

    if is_map(value) do
      {:ok, value}
    else
      {:error, Error.new("VALIDATION_ERROR", "answers must be a map")}
    end
  end
end
