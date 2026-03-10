defmodule StoreWeb.API.ErrorResponder do
  @moduledoc false

  use StoreWeb, :controller

  alias Store.Support.Errors.Normalize

  @spec render(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def render(conn, error) do
    normalized = Normalize.normalize(error)

    conn
    |> put_status(status_for_code(normalized.code))
    |> put_view(StoreWeb.ErrorJSON)
    |> render("error.json", error: normalized)
  end

  defp status_for_code("UNAUTHORIZED"), do: :unauthorized
  defp status_for_code("FORBIDDEN"), do: :forbidden
  defp status_for_code("NOT_FOUND"), do: :not_found
  defp status_for_code("PAYMENT_SIGNATURE_MISSING"), do: :unauthorized
  defp status_for_code("PAYMENT_SIGNATURE_INVALID"), do: :unauthorized
  defp status_for_code("PAYMENT_PROVIDER_VERIFICATION_FAILED"), do: :unauthorized
  defp status_for_code("PAYMENT_PROVIDER_SELECTION_REQUIRED"), do: :bad_request
  defp status_for_code("PAYMENT_PROVIDER_UNSUPPORTED"), do: :bad_request
  defp status_for_code("PAYMENT_PROVIDER_DISABLED"), do: :forbidden
  defp status_for_code("PAYMENT_PROVIDER_DOWN"), do: :bad_gateway
  defp status_for_code("PAYMENT_PROVIDER_TIMEOUT"), do: :gateway_timeout
  defp status_for_code("PAYMENT_PROCESSING_FAILED"), do: :bad_gateway
  defp status_for_code("PAYMENT_PAYLOAD_INVALID"), do: :bad_request
  defp status_for_code("PAYMENT_METHOD_REQUIRED"), do: :unprocessable_entity
  defp status_for_code("RATE_LIMITED"), do: :too_many_requests
  defp status_for_code("VALIDATION_ERROR"), do: :bad_request
  defp status_for_code("CURRENCY_MISMATCH"), do: :bad_request
  defp status_for_code("PAYMENT_EVENT_UNVERIFIED"), do: :unprocessable_entity
  defp status_for_code(_), do: :internal_server_error
end
