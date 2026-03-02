defmodule Store.Support.AshNotifications do
  @moduledoc """
  Post-commit Ash notification delivery helpers for transaction-bound flows.
  """

  require Logger

  @spec notify_post_commit([Ash.Notifier.Notification.t()], keyword()) :: :ok
  def notify_post_commit(notifications, opts \\ []) when is_list(notifications) do
    context = Keyword.get(opts, :context, %{})

    case notifications do
      [] ->
        :ok

      _ ->
        do_notify_post_commit(notifications, context)
    end
  end

  defp do_notify_post_commit(notifications, context) do
    case Ash.Notifier.notify(notifications) do
      [] ->
        :ok

      unsent ->
        Logger.warning(
          "ash_post_commit_notifications_unsent count=#{length(unsent)} context=#{inspect(context)}"
        )

        :ok
    end
  rescue
    exception ->
      Logger.error(
        "ash_post_commit_notifications_failed " <>
          Exception.format(:error, exception, __STACKTRACE__) <>
          " context=#{inspect(context)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.error(
        "ash_post_commit_notifications_failed kind=#{inspect(kind)} reason=#{inspect(reason)} context=#{inspect(context)}"
      )

      :ok
  end
end
