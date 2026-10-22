defmodule Store.Entitlements.Types.SourceConvergenceResultTest do
  use ExUnit.Case, async: true

  alias Store.Entitlements.Types.SourceConvergenceResult

  @subscription_id "11111111-1111-4111-8111-111111111111"
  @user_id "22222222-2222-4222-8222-222222222222"
  @target_grant_id "33333333-3333-4333-8333-333333333333"
  @revoked_grant_id "44444444-4444-4444-8444-444444444444"

  test "pair result contains the frozen fields" do
    result =
      %SourceConvergenceResult{
        mode: :pair,
        subscription_id: @subscription_id,
        target_grant_id: @target_grant_id,
        revoked_grant_ids: [@revoked_grant_id],
        projection_user_ids: [@user_id]
      }

    assert Map.from_struct(result) == %{
             mode: :pair,
             subscription_id: @subscription_id,
             target_grant_id: @target_grant_id,
             revoked_grant_ids: [@revoked_grant_id],
             projection_user_ids: [@user_id]
           }
  end

  test "empty result retains the owner and has no target" do
    result =
      %SourceConvergenceResult{
        mode: :empty,
        subscription_id: @subscription_id,
        target_grant_id: nil,
        revoked_grant_ids: [],
        projection_user_ids: [@user_id]
      }

    assert Map.from_struct(result) == %{
             mode: :empty,
             subscription_id: @subscription_id,
             target_grant_id: nil,
             revoked_grant_ids: [],
             projection_user_ids: [@user_id]
           }
  end
end
