defmodule StoreWeb.Params.Admin.EmailOutboxIndexParams do
  @moduledoc """
  Params adapter for admin email outbox index query.
  """

  alias Store.Comms.Queries.AdminEmailOutboxIndexQuery
  alias Store.Support.Errors.Error

  @spec index_query(map()) :: {:ok, AdminEmailOutboxIndexQuery.t()} | {:error, Error.t()}
  def index_query(params) when is_map(params), do: AdminEmailOutboxIndexQuery.new(params)

  def index_query(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}
end
