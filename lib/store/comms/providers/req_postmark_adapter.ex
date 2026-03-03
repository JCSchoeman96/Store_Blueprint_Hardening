defmodule Store.Comms.Providers.ReqPostmarkAdapter do
  @moduledoc """
  HTTP wrapper adapter for Postmark-style API delivery.
  """

  @behaviour Store.Comms.Providers.Behavior

  alias Store.Support.HTTP.ReqClient

  @impl true
  def deliver_email(payload, _opts) when is_map(payload) do
    with {:ok, config} <- config(),
         {:ok, request_body} <- build_request_body(payload, config),
         {:ok, response} <-
           ReqClient.post(config.url,
             headers: [
               {"content-type", "application/json"},
               {"x-postmark-server-token", config.server_token}
             ],
             json: request_body
           ) do
      normalize_response(response)
    else
      {:error, :missing_config} ->
        {:error, :permanent, :missing_postmark_config}

      {:error, :invalid_payload} ->
        {:error, :permanent, :invalid_payload}

      {:error, reason} ->
        {:error, :transient, reason}
    end
  end

  defp config do
    comms = Application.get_env(:store, :comms, [])
    req_config = Keyword.get(comms, :req_postmark, [])

    url = Keyword.get(req_config, :url, "https://api.postmarkapp.com/email")
    server_token = Keyword.get(req_config, :server_token)
    from_email = Keyword.get(req_config, :from_email, "no-reply@store.local")
    from_name = Keyword.get(req_config, :from_name, "Store")

    if is_binary(server_token) and server_token != "" do
      {:ok, %{url: url, server_token: server_token, from_email: from_email, from_name: from_name}}
    else
      {:error, :missing_config}
    end
  end

  defp build_request_body(payload, config) do
    to_email = Map.get(payload, :to_email) || Map.get(payload, "to_email")
    subject = Map.get(payload, :subject) || Map.get(payload, "subject")
    text_body = Map.get(payload, :text_body) || Map.get(payload, "text_body")
    html_body = Map.get(payload, :html_body) || Map.get(payload, "html_body")

    if valid_payload?(to_email, subject, text_body) do
      body = %{
        "From" => "#{config.from_name} <#{config.from_email}>",
        "To" => to_email,
        "Subject" => subject,
        "TextBody" => text_body
      }

      body =
        if is_binary(html_body) and html_body != "" do
          Map.put(body, "HtmlBody", html_body)
        else
          body
        end

      {:ok, body}
    else
      {:error, :invalid_payload}
    end
  end

  defp normalize_response(%{status: status, body: body}) when status in 200..299 do
    {:ok, extract_message_id(body)}
  end

  defp normalize_response(%{status: 429, body: body}),
    do: {:error, :transient, {:rate_limited, body}}

  defp normalize_response(%{status: status, body: body}) when status in 500..599,
    do: {:error, :transient, {:provider_error, status, body}}

  defp normalize_response(%{status: status, body: body}) when status in 400..499,
    do: {:error, :permanent, {:request_rejected, status, body}}

  defp normalize_response(%{status: status, body: body}),
    do: {:error, :transient, {:unexpected_status, status, body}}

  defp valid_payload?(to_email, subject, text_body) do
    is_binary(to_email) and to_email != "" and
      is_binary(subject) and subject != "" and
      is_binary(text_body) and text_body != ""
  end

  defp extract_message_id(body) when is_map(body) do
    body["MessageID"] || body["message_id"] || body["id"]
  end

  defp extract_message_id(_), do: nil
end
