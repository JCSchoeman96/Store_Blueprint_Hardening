defmodule Store.Governance.UniquenessGatesTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias AshAuthentication.{Info, Strategy}
  alias Store.Accounts.User
  alias Store.Orders.Order
  alias Store.Payments.ProviderEvent
  alias Store.Payments.WebhookReceipt
  alias Store.Support.Governance.UniquenessRegistry

  test "active uniqueness constraints exist in the database" do
    Enum.each(UniquenessRegistry.active_now(), fn constraint ->
      assert unique_index_exists?(constraint.table, constraint.columns),
             "missing unique index for #{constraint.key} (#{constraint.table}.#{Enum.join(constraint.columns, ",")})"
    end)
  end

  test "deferred constraints are enforced when the table exists" do
    Enum.each(UniquenessRegistry.deferred_table_aware(), fn constraint ->
      if table_exists?(constraint.table) do
        assert unique_index_exists?(constraint.table, constraint.columns),
               "table #{constraint.table} exists but missing unique index for #{constraint.key}"
      else
        assert true
      end
    end)
  end

  test "users.email uniqueness is case-insensitive" do
    strategy = Info.strategy!(User, :password)
    email = "CaseSensitiveUser@example.com"

    assert {:ok, _user} =
             Strategy.action(
               strategy,
               :register,
               %{
                 "email" => email,
                 "password" => "Password123!",
                 "password_confirmation" => "Password123!"
               },
               []
             )

    assert {:error, error} =
             Strategy.action(
               strategy,
               :register,
               %{
                 "email" => String.downcase(email),
                 "password" => "Password123!",
                 "password_confirmation" => "Password123!"
               },
               []
             )

    assert Exception.message(error) =~ "has already been taken"
  end

  test "duplicate webhook receipt ingest is NOOP and returns existing record" do
    raw_body = Jason.encode!(%{"payment_intent_id" => "pi_duplicate_001"})

    attrs = %{
      provider: "stripe",
      idempotency_key: "stripe:evt_duplicate_001",
      payload_sha256: "payload-a",
      raw_body: raw_body,
      headers: %{"content-type" => ["application/json"]}
    }

    assert {:ok, first} =
             WebhookReceipt
             |> Ash.Changeset.for_create(:ingest, attrs)
             |> Ash.create(domain: Store.Payments, authorize?: false)

    assert {:ok, second} =
             WebhookReceipt
             |> Ash.Changeset.for_create(:ingest, Map.put(attrs, :payload_sha256, "payload-b"))
             |> Ash.create(domain: Store.Payments, authorize?: false)

    assert first.id == second.id
    assert second.payload_sha256 == first.payload_sha256

    count =
      WebhookReceipt
      |> Ash.Query.filter(expr(idempotency_key == "stripe:evt_duplicate_001"))
      |> Ash.count!(domain: Store.Payments, authorize?: false)

    assert count == 1
  end

  test "provider event uniqueness remains enforced" do
    attrs = %{
      provider: "stripe",
      provider_event_id: "evt_unique_001",
      event_type: "payment_intent.succeeded",
      payload_sha256: "payload-provider-a"
    }

    assert {:ok, first} =
             ProviderEvent
             |> Ash.Changeset.for_create(:ingest, attrs)
             |> Ash.create(domain: Store.Payments, authorize?: false)

    assert {:ok, second} =
             ProviderEvent
             |> Ash.Changeset.for_create(
               :ingest,
               Map.put(attrs, :payload_sha256, "payload-provider-b")
             )
             |> Ash.create(domain: Store.Payments, authorize?: false)

    assert first.id == second.id

    count =
      ProviderEvent
      |> Ash.Query.filter(expr(provider == "stripe" and provider_event_id == "evt_unique_001"))
      |> Ash.count!(domain: Store.Payments, authorize?: false)

    assert count == 1
  end

  test "order_ref uniqueness rejects duplicates" do
    order_ref = "ORDREF_DUPLICATE_001"

    assert {:ok, _first} =
             Order
             |> Ash.Changeset.for_create(:create, %{order_ref: order_ref})
             |> Ash.create(domain: Store.Orders, authorize?: false)

    assert {:error, error} =
             Order
             |> Ash.Changeset.for_create(:create, %{order_ref: order_ref})
             |> Ash.create(domain: Store.Orders, authorize?: false)

    assert Exception.message(error) =~ "order_ref"
    assert Exception.message(error) =~ "already been taken"
  end

  test "orders.create_order retries generated order_ref collisions and succeeds" do
    duplicate_ref = "ORDREF_RETRY_DUP"
    unique_ref = "ORDREF_RETRY_OK"

    assert {:ok, _existing} =
             Order
             |> Ash.Changeset.for_create(:create, %{order_ref: duplicate_ref})
             |> Ash.create(domain: Store.Orders, authorize?: false)

    generator = sequence_generator([duplicate_ref, unique_ref])

    assert {:ok, created} =
             Store.Orders.create_order(%{}, order_ref_generator: generator, max_attempts: 3)

    assert created.order_ref == unique_ref
  end

  test "orders.create_order enforces bounded retry limit" do
    duplicate_ref = "ORDREF_RETRY_LIMIT"

    assert {:ok, _existing} =
             Order
             |> Ash.Changeset.for_create(:create, %{order_ref: duplicate_ref})
             |> Ash.create(domain: Store.Orders, authorize?: false)

    generator = sequence_generator([duplicate_ref, duplicate_ref, duplicate_ref])

    assert {:error, "unable to generate unique order_ref after retry limit"} =
             Store.Orders.create_order(%{}, order_ref_generator: generator, max_attempts: 2)
  end

  defp sequence_generator(sequence) do
    parent = self()
    ref = make_ref()
    send(parent, {ref, sequence})

    fn ->
      receive do
        {^ref, [next | rest]} ->
          send(parent, {ref, rest})
          next
      after
        0 ->
          raise "sequence exhausted for order_ref generator"
      end
    end
  end

  defp table_exists?(table) do
    %{rows: [[value]]} = Repo.query!("SELECT to_regclass($1)::text", ["public." <> table])
    not is_nil(value)
  end

  defp unique_index_exists?(table, columns) do
    sql = """
    SELECT COUNT(*)::int
    FROM pg_index i
    JOIN pg_class t ON t.oid = i.indrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = current_schema()
      AND t.relname = $1
      AND i.indisunique
      AND (
        SELECT array_agg(a.attname::text ORDER BY k.ord)
        FROM unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
      ) = $2::text[]
    """

    %{rows: [[count]]} = Repo.query!(sql, [table, columns])
    count > 0
  end
end
