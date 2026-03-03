defmodule Store.Comms.Providers.SwooshAdapter do
  @moduledoc """
  Swoosh-backed transactional email provider adapter.
  """

  @behaviour Store.Comms.Providers.Behavior

  import Swoosh.Email

  @impl true
  def deliver_email(payload, _opts) when is_map(payload) do
    with {:ok, from_name, from_email} <- from_identity(),
         {:ok, email} <- build_email(payload, from_name, from_email) do
      case Store.Mailer.deliver(email) do
        {:ok, response} ->
          {:ok, extract_message_id(response)}

        {:error, reason} ->
          classify_delivery_error(reason)
      end
    end
  end

  defp from_identity do
    comms_config = Application.get_env(:store, :comms, [])
    from_email = Keyword.get(comms_config, :from_email, "no-reply@store.local")
    from_name = Keyword.get(comms_config, :from_name, "Store")

    if is_binary(from_email) and from_email != "" do
      {:ok, from_name, from_email}
    else
      {:error, :permanent, :missing_from_email}
    end
  end

  defp build_email(payload, from_name, from_email) do
    fields = extract_payload_fields(payload)

    with :ok <- validate_required_fields(fields) do
      {:ok,
       compose_email(
         fields,
         from_name,
         from_email
       )}
    end
  end

  defp extract_payload_fields(payload) do
    %{
      to_email: Map.get(payload, :to_email) || Map.get(payload, "to_email"),
      to_name: Map.get(payload, :to_name) || Map.get(payload, "to_name"),
      subject: Map.get(payload, :subject) || Map.get(payload, "subject"),
      text_body: Map.get(payload, :text_body) || Map.get(payload, "text_body"),
      html_body: Map.get(payload, :html_body) || Map.get(payload, "html_body")
    }
  end

  defp validate_required_fields(%{to_email: to_email, subject: subject, text_body: text_body}) do
    cond do
      not (is_binary(to_email) and to_email != "") -> {:error, :permanent, :missing_to_email}
      not (is_binary(subject) and subject != "") -> {:error, :permanent, :missing_subject}
      not (is_binary(text_body) and text_body != "") -> {:error, :permanent, :missing_text_body}
      true -> :ok
    end
  end

  defp compose_email(fields, from_name, from_email) do
    new()
    |> to(format_to(fields.to_email, fields.to_name))
    |> from({from_name, from_email})
    |> subject(fields.subject)
    |> text_body(fields.text_body)
    |> maybe_put_html(fields.html_body)
  end

  defp maybe_put_html(email, html_body) when is_binary(html_body) and html_body != "",
    do: html_body(email, html_body)

  defp maybe_put_html(email, _), do: email

  defp format_to(to_email, to_name) when is_binary(to_name) and to_name != "",
    do: {to_name, to_email}

  defp format_to(to_email, _to_name), do: to_email

  defp classify_delivery_error(reason) do
    message = inspect(reason) |> String.downcase()

    cond do
      String.contains?(message, "invalid") and String.contains?(message, "email") ->
        {:error, :permanent, reason}

      String.contains?(message, "mailbox unavailable") ->
        {:error, :permanent, reason}

      true ->
        {:error, :transient, reason}
    end
  end

  defp extract_message_id(response) when is_map(response) do
    Map.get(response, :id) ||
      Map.get(response, "id") ||
      Map.get(response, :message_id) ||
      Map.get(response, "message_id")
  end

  defp extract_message_id(_), do: nil
end
