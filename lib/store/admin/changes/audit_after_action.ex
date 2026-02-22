defmodule Store.Admin.Changes.AuditAfterAction do
  @moduledoc """
  Writes an audit log entry in an `after_action` hook for privileged mutations.
  """

  use Ash.Resource.Change

  alias Store.Admin.AuditLog
  alias Store.Admin.AuditMeta

  @impl true
  def change(changeset, opts, change_context) do
    Ash.Changeset.after_action(changeset, &after_action(&1, &2, opts, change_context))
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp after_action(updated_changeset, result, opts, change_context) do
    with {:ok, context} <- normalize_context(updated_changeset, change_context),
         {:ok, actor_id} <- resolve_actor_id(updated_changeset, context),
         {:ok, audit_attrs} <-
           build_audit_attrs(updated_changeset, result, opts, context, actor_id),
         {:ok, _audit_log} <- persist_audit(audit_attrs) do
      {:ok, result}
    else
      {:error, _} = error -> error
    end
  end

  defp normalize_context(changeset, change_context) do
    resource_change_context = change_context || %Ash.Resource.Change.Context{}

    {:ok,
     %{
       context: changeset.context || %{},
       source_context: Map.get(resource_change_context, :source_context, %{}),
       actor: Map.get(resource_change_context, :actor)
     }}
  end

  defp resolve_actor_id(changeset, context) do
    context_actor_id =
      context.context[:actor]
      |> actor_id()
      |> fallback_actor_id(context.actor)
      |> fallback_actor_id(attribute_or_argument(changeset, :assigned_by))

    if is_nil(context_actor_id) and !system_context?(context.context) do
      {:error, "audit actor is required for non-system mutations"}
    else
      {:ok, context_actor_id}
    end
  end

  defp build_audit_attrs(changeset, result, opts, context, actor_id) do
    meta =
      opts
      |> build_meta(changeset)
      |> AuditMeta.sanitize()

    {:ok,
     %{
       actor_id: actor_id,
       action: to_string(opts[:event] || changeset.action.name),
       resource: to_string(opts[:resource] || changeset.resource),
       record_id: Map.get(result, :id),
       request_id: context.context[:request_id] || context.source_context[:request_id],
       meta: meta,
       payload_sha256: opts[:payload_sha256]
     }}
  end

  defp persist_audit(audit_attrs) do
    audit_changeset =
      AuditLog
      |> Ash.Changeset.for_create(:create, audit_attrs, context: %{system?: true})

    Ash.create(audit_changeset, domain: Store.Admin, authorize?: false)
  end

  defp build_meta(opts, changeset) do
    opts[:meta]
    |> default_map()
    |> maybe_put("arguments", changeset.arguments, opts[:include_arguments?])
    |> maybe_put("attributes", changeset.attributes, opts[:include_attributes?])
    |> Map.put_new("action_name", to_string(changeset.action.name))
  end

  defp maybe_put(meta, _key, _value, false), do: meta
  defp maybe_put(meta, key, value, true), do: Map.put(meta, key, value || %{})

  defp default_map(map) when is_map(map), do: map
  defp default_map(_), do: %{}

  defp system_context?(context), do: context[:system?] || context[:bootstrap?]

  defp fallback_actor_id(nil, fallback), do: actor_id(fallback)
  defp fallback_actor_id(actor_id, _fallback), do: actor_id

  defp attribute_or_argument(changeset, key) do
    Ash.Changeset.get_attribute(changeset, key) || Map.get(changeset.arguments || %{}, key)
  end

  defp actor_id(nil), do: nil
  defp actor_id(%{id: id}), do: id
  defp actor_id(id) when is_binary(id), do: id
  defp actor_id(_), do: nil
end
