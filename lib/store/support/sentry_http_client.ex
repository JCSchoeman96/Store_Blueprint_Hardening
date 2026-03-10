defmodule Store.Support.SentryHTTPClient do
  @moduledoc false

  @behaviour Sentry.HTTPClient

  @impl true
  def child_spec do
    Supervisor.child_spec({Finch, name: __MODULE__}, id: __MODULE__)
  end

  @impl true
  def post(url, headers, body) do
    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, __MODULE__) do
      {:ok, %Finch.Response{status: status, headers: response_headers, body: response_body}} ->
        {:ok, status, response_headers, response_body}

      {:error, error} ->
        {:error, error}
    end
  end
end
