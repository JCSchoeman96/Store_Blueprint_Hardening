defmodule Store.Accounts.Secrets do
  @moduledoc """
  Runtime secret lookup for AshAuthentication strategies.
  """

  use AshAuthentication.Secret

  @impl true
  def secret_for([:authentication, :strategies, :google, :client_id], _resource, _opts, _context) do
    google_oauth_value(:client_id)
  end

  def secret_for(
        [:authentication, :strategies, :google, :client_secret],
        _resource,
        _opts,
        _context
      ) do
    google_oauth_value(:client_secret)
  end

  def secret_for(
        [:authentication, :strategies, :google, :redirect_uri],
        _resource,
        _opts,
        _context
      ) do
    google_oauth_value(:redirect_uri_base)
  end

  def secret_for(_path, _resource, _opts, _context), do: :error

  defp google_oauth_value(key) do
    case Application.fetch_env(:store, :google_oauth) do
      {:ok, config} when is_list(config) ->
        case Keyword.get(config, key) do
          nil -> :error
          value -> {:ok, value}
        end

      _ ->
        :error
    end
  end
end
