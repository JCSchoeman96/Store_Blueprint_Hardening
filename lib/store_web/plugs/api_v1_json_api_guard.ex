defmodule StoreWeb.Plugs.ApiV1JsonApiGuard do
  @moduledoc """
  Enforces auth and path validation for JSON:API routes mounted under /api/v1.
  """

  @behaviour Plug

  import Plug.Conn

  alias Store.Admin.Authorization

  @admin_roles [:super_admin, :admin]
  @uuid_paths [
    ~r{^/api/v1/orders/([^/]+)$},
    ~r{^/api/v1/admin/orders/([^/]+)$},
    ~r{^/api/v1/admin/payment-intents/([^/]+)$}
  ]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if String.starts_with?(conn.request_path, "/api/v1") do
      actor = conn.assigns[:current_user] || conn.assigns[:actor]

      cond do
        is_nil(actor) ->
          json_api_error(conn, 401, "UNAUTHORIZED", "Unauthorized", "Authentication required")

        docs_route?(conn.request_path) and not Authorization.has_any_role?(actor, @admin_roles) ->
          json_api_error(conn, 403, "FORBIDDEN", "Forbidden", "Admin role required")

        invalid_uuid_path?(conn.request_path) ->
          json_api_error(
            conn,
            400,
            "VALIDATION_ERROR",
            "ValidationError",
            "id must be a valid UUID"
          )

        true ->
          conn
      end
    else
      conn
    end
  end

  defp docs_route?(path), do: path in ["/api/v1/open_api", "/api/v1/json_schema"]

  defp invalid_uuid_path?(path) do
    Enum.any?(@uuid_paths, fn pattern ->
      case Regex.run(pattern, path, capture: :all_but_first) do
        [id] ->
          Ecto.UUID.cast(id) == :error

        _ ->
          false
      end
    end)
  end

  defp json_api_error(conn, status, code, title, detail) do
    body =
      Jason.encode!(%{
        errors: [
          %{
            status: Integer.to_string(status),
            code: code,
            title: title,
            detail: detail
          }
        ]
      })

    conn
    |> put_resp_content_type("application/vnd.api+json")
    |> send_resp(status, body)
    |> halt()
  end
end
