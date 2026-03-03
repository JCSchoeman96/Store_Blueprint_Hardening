defmodule Store.Comms.Facade do
  @moduledoc """
  Consumer and system-scoped surfaces for comms outbox access.
  """

  import Ash.Expr
  require Ash.Query

  alias Store.Admin.Authorization
  alias Store.Comms.EmailOutbox
  alias Store.Comms.Queries.{AdminEmailOutboxIndexQuery, AdminEmailOutboxShowQuery}
  alias Store.Support.Errors.Error
  alias Store.Support.Errors.Normalize

  @spec list_email_outboxes_for_admin(map(), AdminEmailOutboxIndexQuery.t()) ::
          {:ok, [EmailOutbox.t()]} | {:error, term()}
  def list_email_outboxes_for_admin(actor, %AdminEmailOutboxIndexQuery{} = query)
      when is_map(actor) do
    with :ok <- authorize_admin_actor(actor) do
      ash_query =
        EmailOutbox
        |> Ash.Query.for_read(:read_for_admin, %{})
        |> maybe_filter_state(query.state)
        |> maybe_filter_template_kind(query.template_kind)
        |> Ash.Query.limit(query.limit)
        |> Ash.Query.offset(query.offset)

      case Ash.read(ash_query,
             domain: Store.Comms,
             authorize?: false,
             context: %{system?: true}
           ) do
        {:ok, outboxes} -> {:ok, outboxes}
        {:error, error} -> {:error, Normalize.normalize(error)}
      end
    end
  end

  @spec get_email_outbox_for_admin(map(), AdminEmailOutboxShowQuery.t()) ::
          {:ok, EmailOutbox.t() | nil} | {:error, term()}
  def get_email_outbox_for_admin(actor, %AdminEmailOutboxShowQuery{id: id}) when is_map(actor) do
    with :ok <- authorize_admin_actor(actor) do
      ash_query =
        EmailOutbox
        |> Ash.Query.for_read(:read_for_admin, %{})
        |> Ash.Query.filter(expr(id == ^id))
        |> Ash.Query.limit(1)

      case Ash.read_one(ash_query,
             domain: Store.Comms,
             authorize?: false,
             context: %{system?: true}
           ) do
        {:ok, outbox} -> {:ok, outbox}
        {:error, error} -> {:error, Normalize.normalize(error)}
      end
    end
  end

  defp maybe_filter_state(query, nil), do: query

  defp maybe_filter_state(query, state_value),
    do: Ash.Query.filter(query, expr(state == ^state_value))

  defp maybe_filter_template_kind(query, nil), do: query

  defp maybe_filter_template_kind(query, template_kind_value),
    do: Ash.Query.filter(query, expr(template_kind == ^template_kind_value))

  defp authorize_admin_actor(actor) do
    if Authorization.has_any_role?(actor, [:super_admin, :admin, :support]) do
      :ok
    else
      {:error, Error.new("FORBIDDEN", "Forbidden", %{reason: "forbidden"})}
    end
  end
end
