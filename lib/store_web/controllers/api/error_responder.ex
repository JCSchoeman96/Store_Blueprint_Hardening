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
  defp status_for_code("VALIDATION_ERROR"), do: :bad_request
  defp status_for_code(_), do: :internal_server_error
end
