defmodule Store.Entitlements.SourceConvergenceTransactionBoundaryTest do
  use ExUnit.Case, async: false

  alias Store.Entitlements.Facade
  alias Store.Entitlements.Inputs.SubscriptionSourceConvergenceInput
  alias Store.Repo
  alias Store.Support.Errors.Error

  test "refuses calls outside the caller transaction without issuing a query" do
    ref = make_ref()
    handler_id = "task4-transaction-boundary-#{inspect(ref)}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:task4_boundary_query, ref, metadata[:query]})
        end,
        nil
      )

    try do
      refute Repo.in_transaction?()

      assert {:error, %Error{code: "VALIDATION_ERROR"}} =
               Facade.converge_subscription_source_grants_for_system(input())

      refute_receive {:task4_boundary_query, ^ref, _query}, 50
    after
      :telemetry.detach(handler_id)
    end
  end

  defp input do
    {:ok, input} =
      SubscriptionSourceConvergenceInput.new(%{
        subscription_id: "11111111-1111-4111-8111-111111111111",
        user_id: "22222222-2222-4222-8222-222222222222",
        disposition: :effective,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:gold",
        valid_from_at: ~U[2026-01-01 00:00:00.000001Z],
        valid_until_at: nil,
        reason: "source changed",
        access_effect_id: "33333333-3333-4333-8333-333333333333",
        source_version: 1,
        target_fingerprint: String.duplicate("a", 64)
      })

    input
  end
end

defmodule Store.Entitlements.SourceConvergenceTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Entitlements
  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Facade
  alias Store.Entitlements.Inputs.SubscriptionSourceConvergenceInput
  alias Store.Entitlements.Types.SourceConvergenceResult
  alias Store.SubscriptionsFixtures

  @system_context %{system?: true}
  @target_fingerprint String.duplicate("a", 64)

  test "creates an exact PAIR target and returns the final proof" do
    source = source_fixture!("task4_pair_create")
    input = input(source)

    assert {:ok, %SourceConvergenceResult{} = result} =
             converge_in_transaction(input)

    assert result.mode == :pair
    assert result.subscription_id == source.subscription_id
    assert result.revoked_grant_ids == []
    assert result.projection_user_ids == [source.user_id]
    assert is_binary(result.target_grant_id)

    assert [target] = active_grants!(source.subscription_id)
    assert target.id == result.target_grant_id
    assert_target_matches_input(target, input)
  end

  test "exact replay keeps the target identity and returns the same result" do
    source = source_fixture!("task4_pair_replay")
    input = input(source)

    assert {:ok, first} = converge_in_transaction(input)
    assert {:ok, second} = converge_in_transaction(input)

    assert second == first
    assert [target] = active_grants!(source.subscription_id)
    assert target.id == first.target_grant_id
    assert_target_matches_input(target, input)
  end

  test "changed target identity revokes the old target and creates a new one" do
    source = source_fixture!("task4_changed_identity")
    initial_input = input(source)

    assert {:ok, first} =
             converge_in_transaction(initial_input)

    changed_input =
      input(source, %{
        entitlement_kind: :digital_library,
        entitlement_scope_key: "library:premium"
      })

    assert {:ok, second} =
             converge_in_transaction(changed_input)

    assert second.mode == :pair
    assert second.target_grant_id != first.target_grant_id
    assert second.revoked_grant_ids == [first.target_grant_id]

    assert [target] = active_grants!(source.subscription_id)
    assert_target_matches_input(target, changed_input)
    assert [revoked] = Enum.filter(grants!(source.subscription_id), &(&1.status == :revoked))
    assert revoked.id == first.target_grant_id
  end

  test "reactivates a revoked matching target with the same database ID" do
    source = source_fixture!("task4_reactivation")
    initial_start = utc_now()

    existing =
      issue_grant!(source, source.user_id, :membership_access, "membership:gold", %{
        status: :revoked,
        valid_from_at: initial_start,
        valid_to_at: DateTime.add(initial_start, 3_600, :second),
        revoked_at: DateTime.add(initial_start, 1, :second),
        revoked_reason: "previous revocation"
      })

    input = input(source)

    assert {:ok, result} = converge_in_transaction(input)
    assert result.target_grant_id == existing.id
    assert result.revoked_grant_ids == []

    assert [target] = active_grants!(source.subscription_id)
    assert target.id == existing.id
    assert_target_matches_input(target, input)
  end

  test "clears a finite persisted end when the converged pair has a nil end" do
    source = source_fixture!("task4_nil_end")
    old_start = utc_now()

    existing =
      issue_grant!(source, source.user_id, :membership_access, "membership:gold", %{
        status: :revoked,
        valid_from_at: old_start,
        valid_to_at: DateTime.add(old_start, 3_600, :second),
        revoked_at: DateTime.add(old_start, 1, :second),
        revoked_reason: "previous revocation"
      })

    input = input(source, %{valid_until_at: nil})

    assert {:ok, result} = converge_in_transaction(input)
    assert result.target_grant_id == existing.id

    assert [target] = active_grants!(source.subscription_id)
    assert target.id == existing.id
    assert target.valid_from_at == input.valid_from_at
    assert target.valid_to_at == nil
    assert target.revoked_at == nil
    assert target.revoked_reason == nil
  end

  test "EFFECTIVE empty target revokes every active exact-source grant" do
    source = source_fixture!("task4_effective_empty")
    persisted_end = DateTime.add(utc_now(), 86_400, :second)

    grant =
      issue_grant!(source, source.user_id, :membership_access, "membership:old", %{
        valid_to_at: persisted_end
      })

    input = empty_input(source, :effective, %{valid_until_at: persisted_end})

    assert {:ok, result} = converge_in_transaction(input)
    assert result.mode == :empty
    assert result.target_grant_id == nil
    assert result.revoked_grant_ids == [grant.id]
    assert active_grants!(source.subscription_id) == []

    assert [revoked] = grants!(source.subscription_id)
    assert revoked.status == :revoked
    assert revoked.revoked_reason == input.reason
    assert revoked.valid_to_at == persisted_end
  end

  test "NON_EFFECTIVE empty target revokes every active exact-source grant" do
    source = source_fixture!("task4_non_effective_empty")

    grant =
      issue_grant!(source, source.user_id, :digital_library, "library:old", %{})

    input = empty_input(source, :non_effective)

    assert {:ok, result} = converge_in_transaction(input)
    assert result.mode == :empty
    assert result.target_grant_id == nil
    assert result.revoked_grant_ids == [grant.id]
    assert active_grants!(source.subscription_id) == []
  end

  test "empty convergence preserves grants belonging to a different source" do
    source = source_fixture!("task4_isolation_target")
    other_source = source_fixture!("task4_isolation_other")
    target_grant = issue_grant!(source, source.user_id, :membership_access, "membership:old", %{})

    other_grant =
      issue_grant!(
        other_source,
        other_source.user_id,
        :membership_access,
        "membership:other",
        %{}
      )

    assert {:ok, result} =
             source
             |> empty_input(:non_effective)
             |> converge_in_transaction()

    assert result.revoked_grant_ids == [target_grant.id]
    assert active_grants!(source.subscription_id) == []

    assert [%EntitlementGrant{status: :active, id: other_id}] =
             active_grants!(other_source.subscription_id)

    assert other_id == other_grant.id
  end

  test "zero locked grants retain the owner and skip the revoke update" do
    source = source_fixture!("task4_zero_rows")
    input = empty_input(source, :effective)

    {result, statements} =
      capture_repo_queries(fn ->
        converge_in_transaction(input)
      end)

    assert {:ok,
            %SourceConvergenceResult{
              mode: :empty,
              target_grant_id: nil,
              revoked_grant_ids: [],
              projection_user_ids: [owner_id]
            }} = result

    assert owner_id == source.user_id
    assert statement_counts(statements).update == 0
    assert length(final_active_proof_queries(statements)) == 1
    IO.puts("TASK4_SQL empty_revoke_set updates=0")
  end

  test "projection users include the owner and every distinct locked user" do
    source = source_fixture!("task4_projection_users")
    second_user = SubscriptionsFixtures.create_customer!("task4_projection_second")
    third_user = SubscriptionsFixtures.create_customer!("task4_projection_third")

    _first = issue_grant!(source, second_user.id, :membership_access, "membership:first", %{})
    _second = issue_grant!(source, third_user.id, :digital_library, "library:second", %{})
    _third = issue_grant!(source, second_user.id, :discount_tier, "discount:third", %{})

    assert {:ok, result} =
             empty_input(source, :non_effective)
             |> converge_in_transaction()

    assert MapSet.new(result.projection_user_ids) ==
             MapSet.new([source.user_id, second_user.id, third_user.id])

    assert length(result.projection_user_ids) == 3
  end

  test "caller rollback undoes the target upsert and source revocations" do
    source = source_fixture!("task4_outer_rollback")
    existing = issue_grant!(source, source.user_id, :membership_access, "membership:old", %{})
    input = input(source)

    assert {:error, :caller_aborted} =
             Repo.transaction(fn ->
               assert {:ok, result} =
                        Facade.converge_subscription_source_grants_for_system(input)

               assert result.target_grant_id != existing.id
               assert result.revoked_grant_ids == [existing.id]
               Repo.rollback(:caller_aborted)
             end)

    assert [%EntitlementGrant{id: existing_id, status: :active}] =
             grants!(source.subscription_id)

    assert existing_id == existing.id
    assert active_grants!(source.subscription_id) |> Enum.map(& &1.id) == [existing.id]
  end

  test "SQL statements stay bounded across repeated source sizes 1, 5, and 25" do
    all_reports =
      Enum.map([1, 5, 25], fn source_size ->
        source = source_fixture!("task4_sql_#{source_size}")

        reports =
          Enum.map(1..2, fn repetition ->
            reset_source_grants!(source.subscription_id)

            Enum.each(1..source_size, fn row_number ->
              issue_grant!(
                source,
                source.user_id,
                :membership_access,
                "sql:#{source_size}:#{row_number}",
                %{}
              )
            end)

            input = input(source, %{entitlement_scope_key: "membership:sql_target"})

            {result, statements} =
              capture_repo_queries(fn ->
                converge_in_transaction(input)
              end)

            assert {:ok, result} = result
            assert result.mode == :pair
            assert length(result.revoked_grant_ids) == source_size
            assert length(active_grants!(source.subscription_id)) == 1

            counts = statement_counts(statements)
            lock_queries = source_lock_queries(statements)
            proof_queries = final_active_proof_queries(statements)
            upsert_queries = target_upsert_queries(statements)

            assert length(lock_queries) == 1
            assert length(proof_queries) == 1
            assert length(upsert_queries) == 1
            assert counts.update == 1
            assert counts.select == 2
            assert counts.insert == 1
            assert counts.delete == 0
            assert Enum.any?(proof_queries, &limit_is_two?/1)
            assert lock_query_is_ordered_and_locked?(hd(lock_queries))

            IO.puts(
              "TASK4_SQL source_size=#{source_size} repetition=#{repetition} " <>
                "statements=#{length(statements)} selects=#{counts.select} " <>
                "upserts=#{length(upsert_queries)} updates=#{counts.update} " <>
                "locked_rows=#{source_size} final_limit=2"
            )

            Map.take(counts, [:select, :insert, :update, :delete, :other])
          end)

        assert [first_report, second_report] = reports
        assert first_report == second_report
        {source_size, first_report}
      end)

    reports_by_size = Enum.map(all_reports, &elem(&1, 1))
    assert Enum.uniq(reports_by_size) == [hd(reports_by_size)]
  end

  defp source_fixture!(prefix) do
    unique = "#{prefix}_#{Ecto.UUID.generate()}"
    customer = SubscriptionsFixtures.create_customer!(unique)
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "task4:#{unique}"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    %{subscription_id: subscription.id, user_id: customer.id}
  end

  defp converge_in_transaction(input) do
    case Repo.transaction(fn ->
           case Facade.converge_subscription_source_grants_for_system(input) do
             {:ok, _result} = result -> result
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp input(source, overrides \\ %{}) do
    start_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    params =
      %{
        subscription_id: source.subscription_id,
        user_id: source.user_id,
        disposition: :effective,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:gold",
        valid_from_at: start_at,
        valid_until_at: DateTime.add(start_at, 86_400, :second),
        reason: "subscription source convergence",
        access_effect_id: Ecto.UUID.generate(),
        source_version: 1,
        target_fingerprint: @target_fingerprint
      }
      |> Map.merge(overrides)

    {:ok, input} = SubscriptionSourceConvergenceInput.new(params)
    input
  end

  defp empty_input(source, disposition, overrides \\ %{}) do
    input(
      source,
      Map.merge(
        %{
          disposition: disposition,
          entitlement_kind: nil,
          entitlement_scope_key: nil,
          valid_from_at: nil,
          valid_until_at: nil
        },
        overrides
      )
    )
  end

  defp issue_grant!(source, user_id, kind, scope_key, overrides) do
    start_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs =
      %{
        user_id: user_id,
        kind: kind,
        scope_key: scope_key,
        source_kind: :subscription,
        source_id: source.subscription_id,
        status: :active,
        valid_from_at: start_at,
        valid_to_at: nil,
        revoked_at: nil,
        revoked_reason: nil
      }
      |> Map.merge(overrides)

    EntitlementGrant
    |> Ash.Changeset.for_create(:issue, attrs, context: @system_context)
    |> Ash.create!(domain: Entitlements, authorize?: false, context: @system_context)
  end

  defp grants!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(domain: Entitlements, authorize?: false, context: @system_context)
  end

  defp active_grants!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(
      expr(source_kind == :subscription and source_id == ^subscription_id and status == :active)
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(domain: Entitlements, authorize?: false, context: @system_context)
  end

  defp assert_target_matches_input(target, input) do
    assert target.user_id == input.user_id
    assert target.kind == input.entitlement_kind
    assert target.scope_key == input.entitlement_scope_key
    assert target.source_kind == :subscription
    assert target.source_id == input.subscription_id
    assert target.status == :active
    assert target.valid_from_at == input.valid_from_at
    assert target.valid_to_at == input.valid_until_at
    assert target.revoked_at == nil
    assert target.revoked_reason == nil
  end

  defp reset_source_grants!(subscription_id) do
    assert {:ok, _result} =
             Repo.query(
               "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
               [Ecto.UUID.dump!(subscription_id)]
             )
  end

  defp capture_repo_queries(fun) do
    ref = make_ref()
    parent = self()
    handler_id = "task4-source-convergence-#{inspect(ref)}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if is_binary(metadata[:query]) do
            send(parent, {:task4_repo_query, ref, metadata.query, metadata[:params]})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, collect_repo_queries(ref, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_repo_queries(ref, queries) do
    receive do
      {:task4_repo_query, ^ref, query, params} ->
        collect_repo_queries(ref, [%{query: query, params: params} | queries])
    after
      50 -> Enum.reverse(queries)
    end
  end

  defp statement_counts(statements) do
    Enum.reduce(statements, %{select: 0, insert: 0, update: 0, delete: 0, other: 0}, fn
      %{query: query}, counts ->
        key =
          case Regex.run(~r/^\s*([[:alpha:]]+)/, query) do
            [_, "SELECT"] -> :select
            [_, "INSERT"] -> :insert
            [_, "UPDATE"] -> :update
            [_, "DELETE"] -> :delete
            _ -> :other
          end

        Map.update!(counts, key, &(&1 + 1))
    end)
  end

  defp source_lock_queries(statements) do
    Enum.filter(statements, fn %{query: query} ->
      String.contains?(String.downcase(query), "for update")
    end)
  end

  defp final_active_proof_queries(statements) do
    Enum.filter(statements, fn %{query: query} ->
      normalized = String.downcase(query)

      Regex.match?(~r/^\s*select\b/, normalized) and
        String.contains?(normalized, "entitlement_grants") and
        String.contains?(normalized, "status") and
        String.contains?(normalized, "limit") and
        not String.contains?(normalized, "for update")
    end)
  end

  defp target_upsert_queries(statements) do
    Enum.filter(statements, fn %{query: query} ->
      normalized = String.downcase(query)

      Regex.match?(~r/^\s*insert\b/, normalized) and
        String.contains?(normalized, "entitlement_grants") and
        String.contains?(normalized, "on conflict")
    end)
  end

  defp limit_is_two?(%{query: query, params: params}) do
    Regex.match?(~r/\blimit\s+2\b/i, query) or
      (Regex.match?(~r/\blimit\s+\$\d+/i, query) and 2 in List.wrap(params))
  end

  defp lock_query_is_ordered_and_locked?(%{query: query}) do
    normalized = String.downcase(query)
    [order_clause | _rest] = String.split(normalized, "for update", parts: 2)
    order_clause = order_clause |> String.split("order by", parts: 2) |> List.last()

    String.contains?(normalized, "order by") and
      Regex.match?(~r/\bid\b/, order_clause) and
      not Regex.match?(~r/\bdesc\b/, order_clause) and
      String.contains?(normalized, "for update")
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
