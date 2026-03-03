defmodule Store.Comms do
  @moduledoc """
  Outbound communications domain for transactional email delivery.
  """

  import Ash.Expr
  import Swoosh.Email

  require Ash.Query
  require Logger

  use Ash.Domain

  alias Store.Accounts.User
  alias Store.Comms.EmailOutbox
  alias Store.Orders.Order
  alias Store.Workers.DeliverEmailOutboxWorker

  resources do
    resource(Store.Comms.EmailOutbox)
  end

  @spec enqueue_order_receipt_for_system(String.t(), keyword()) ::
          {:ok, EmailOutbox.t()} | {:error, term()}
  def enqueue_order_receipt_for_system(order_id, opts \\ []) when is_binary(order_id) do
    with {:ok, order} <- fetch_order(order_id),
         {:ok, to_email} <- resolve_recipient_email(order, opts),
         {:ok, outbox} <- upsert_order_receipt_outbox(order, to_email),
         {:ok, _job} <- enqueue_delivery_job(outbox.id) do
      {:ok, outbox}
    end
  end

  @spec deliver_outbox_email_for_system(String.t()) :: :ok | {:error, term()} | {:discard, term()}
  def deliver_outbox_email_for_system(outbox_id) when is_binary(outbox_id) do
    with {:ok, outbox} <- fetch_outbox(outbox_id),
         :ok <- maybe_mark_processing(outbox) do
      maybe_deliver(outbox_id)
    end
  end

  defp fetch_order(order_id) do
    query = Order |> Ash.Query.filter(expr(id == ^order_id))

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, [order | _]} -> {:ok, order}
      {:ok, []} -> {:error, {:order_not_found, order_id}}
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_recipient_email(order, opts) do
    case Keyword.get(opts, :to_email) do
      to_email when is_binary(to_email) and to_email != "" ->
        {:ok, String.trim(to_email)}

      _ ->
        resolve_order_user_email(order, opts)
    end
  end

  defp resolve_order_user_email(order, opts) do
    user_id = order.user_id || Keyword.get(opts, :order_user_id)

    case user_id do
      user_id when is_binary(user_id) ->
        fetch_user_email(user_id)

      _ ->
        {:error, :missing_order_recipient}
    end
  end

  defp fetch_user_email(user_id) do
    query = User |> Ash.Query.filter(expr(id == ^user_id))

    case Ash.read(query, domain: Store.Accounts, authorize?: false, context: %{system?: true}) do
      {:ok, [%User{email: email} | _]} when is_binary(email) and email != "" ->
        {:ok, email}

      {:ok, [_ | _]} ->
        {:error, :missing_order_recipient}

      {:ok, []} ->
        {:error, :missing_order_recipient}

      {:error, error} ->
        {:error, error}
    end
  end

  defp upsert_order_receipt_outbox(order, to_email) do
    idempotency_key = "order_receipt:#{order.id}"

    attrs = %{
      order_id: order.id,
      template_kind: "order_receipt",
      to_email: to_email,
      subject: "Order receipt #{order.order_ref}",
      body_text: order_receipt_body(order),
      body_html: nil,
      idempotency_key: idempotency_key
    }

    EmailOutbox
    |> Ash.Changeset.for_create(:enqueue, attrs, context: %{system?: true})
    |> Ash.create(domain: __MODULE__, authorize?: false, context: %{system?: true})
  end

  defp enqueue_delivery_job(outbox_id) do
    %{"email_outbox_id" => outbox_id}
    |> DeliverEmailOutboxWorker.new()
    |> Oban.insert()
  end

  defp fetch_outbox(outbox_id) do
    case EmailOutbox.get_for_system(outbox_id, context: %{system?: true}, authorize?: false) do
      {:ok, %EmailOutbox{} = outbox} -> {:ok, outbox}
      {:ok, nil} -> {:discard, :outbox_not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_mark_processing(%EmailOutbox{state: :sent}), do: :ok

  defp maybe_mark_processing(%EmailOutbox{} = outbox) do
    outbox
    |> Ash.Changeset.for_update(
      :mark_processing,
      %{attempt_count: outbox.attempt_count + 1},
      context: %{system?: true}
    )
    |> Ash.update(domain: __MODULE__, authorize?: false, context: %{system?: true})
    |> case do
      {:ok, _updated} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_deliver(outbox_id) do
    with {:ok, outbox} <- fetch_outbox(outbox_id) do
      case outbox.state do
        :sent ->
          :ok

        _ ->
          do_deliver(outbox)
      end
    end
  end

  defp do_deliver(%EmailOutbox{} = outbox) do
    email =
      new()
      |> to(outbox.to_email)
      |> from({"Store", "noreply@example.com"})
      |> subject(outbox.subject)
      |> text_body(outbox.body_text)

    case Store.Mailer.deliver(email) do
      {:ok, _response} ->
        outbox
        |> Ash.Changeset.for_update(
          :mark_sent,
          %{
            attempt_count: outbox.attempt_count,
            sent_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
          },
          context: %{system?: true}
        )
        |> Ash.update(domain: __MODULE__, authorize?: false, context: %{system?: true})
        |> case do
          {:ok, _updated} -> :ok
          {:error, error} -> {:error, error}
        end

      {:error, reason} ->
        update_failed_delivery(outbox, reason)
    end
  end

  defp update_failed_delivery(%EmailOutbox{} = outbox, reason) do
    message = inspect(reason)

    Logger.warning("email_outbox_delivery_failed outbox_id=#{outbox.id} reason=#{message}")

    outbox
    |> Ash.Changeset.for_update(
      :mark_failed,
      %{attempt_count: outbox.attempt_count, last_error: message},
      context: %{system?: true}
    )
    |> Ash.update(domain: __MODULE__, authorize?: false, context: %{system?: true})
    |> case do
      {:ok, _updated} -> {:error, reason}
      {:error, error} -> {:error, error}
    end
  end

  defp order_receipt_body(order) do
    total = order.grand_total_minor || 0
    currency = order.currency_code || "USD"
    amount = :erlang.float_to_binary(total / 100, decimals: 2)
    "Your order #{order.order_ref} has been paid. Total: #{currency} #{amount}."
  end
end
