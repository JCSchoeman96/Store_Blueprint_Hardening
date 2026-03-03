defmodule StoreWeb.DigitalDownloadController do
  @moduledoc false

  use StoreWeb, :controller

  alias Store.Digital.Facade, as: DigitalFacade
  alias Store.Support.Errors.Normalize

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"grant_id" => grant_id}) when is_binary(grant_id) do
    actor = conn.assigns[:current_user]

    case DigitalFacade.issue_signed_download_url_for_user(actor || %{}, grant_id) do
      {:ok, %{signed_url: signed_url}} ->
        redirect(conn, external: signed_url)

      {:error, error} ->
        normalized = Normalize.normalize(error)

        conn
        |> put_flash(:error, normalized.message)
        |> redirect(to: ~p"/account/downloads")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "grant_id is required")
    |> redirect(to: ~p"/account/downloads")
  end
end
