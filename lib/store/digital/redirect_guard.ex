defmodule Store.Digital.RedirectGuard do
  @moduledoc """
  Signed URL redirect safety checks.
  """

  alias Store.Support.Errors.Error

  @spec validate_signed_url(String.t()) :: :ok | {:error, Error.t()}
  def validate_signed_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme != "https" ->
        {:error, Error.new("DIGITAL_REDIRECT_UNSAFE", "signed URL must use https")}

      not is_binary(uri.host) or uri.host == "" ->
        {:error, Error.new("DIGITAL_REDIRECT_UNSAFE", "signed URL host is required")}

      not allowed_host?(uri.host) ->
        {:error, Error.new("DIGITAL_REDIRECT_UNSAFE", "signed URL host is not allowlisted")}

      true ->
        :ok
    end
  end

  def validate_signed_url(_url),
    do: {:error, Error.new("DIGITAL_REDIRECT_UNSAFE", "signed URL is invalid")}

  defp allowed_host?(host) do
    Application.get_env(:store, :digital, [])
    |> Keyword.get(:allowed_redirect_hosts, [])
    |> Enum.any?(fn allowed -> String.downcase(allowed) == String.downcase(host) end)
  end
end
