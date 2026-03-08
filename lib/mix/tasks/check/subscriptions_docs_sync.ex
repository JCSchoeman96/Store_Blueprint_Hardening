defmodule Mix.Tasks.Check.SubscriptionsDocsSync do
  use Mix.Task

  @moduledoc false

  @shortdoc "Fails when subscription governance/docs sections drift from required Phase 27/27A anchors"

  @default_policy_matrix_file "docs/governance/policy_matrix.md"
  @default_route_inventory_file "docs/governance/route_inventory.md"
  @default_phase_note_files [
    "docs/agent_notes/phase_27_docs.md",
    "docs/agent_notes/phase_27a_docs.md"
  ]

  @required_policy_patterns [
    "### 5.11 Subscriptions (SubscriptionPlan, Subscription, RenewalAttempt)",
    "### 5.12 Entitlements (EntitlementGrant)"
  ]

  @required_route_patterns [
    "| GET | `/account/subscriptions` |",
    "| GET | `/account/subscriptions/:id` |",
    "| GET | `/admin/subscriptions` |",
    "| GET | `/admin/subscriptions/:id` |"
  ]

  @required_phase_note_patterns [
    "## GOAL",
    "## PLAN",
    "## PERFORMANCE & SCALING REVIEW"
  ]

  @impl Mix.Task
  def run(_args) do
    policy_matrix_file =
      System.get_env("CHECK_SUBSCRIPTIONS_POLICY_MATRIX_FILE", @default_policy_matrix_file)

    route_inventory_file =
      System.get_env("CHECK_SUBSCRIPTIONS_ROUTE_INVENTORY_FILE", @default_route_inventory_file)

    phase_note_files = phase_note_files()

    with :ok <- ensure_file_contains(policy_matrix_file, @required_policy_patterns),
         :ok <- ensure_file_contains(route_inventory_file, @required_route_patterns),
         :ok <- ensure_phase_note_files(phase_note_files) do
      Mix.shell().info("check.subscriptions_docs_sync: OK")
    end
  end

  defp phase_note_files do
    cond do
      value = System.get_env("CHECK_SUBSCRIPTIONS_PHASE_NOTE_FILES") ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      value = System.get_env("CHECK_SUBSCRIPTIONS_PHASE_NOTE_FILE") ->
        [value]

      true ->
        @default_phase_note_files
    end
  end

  defp ensure_phase_note_files(paths) when is_list(paths) do
    paths
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.reduce(:ok, fn path, :ok ->
      ensure_file_contains(path, @required_phase_note_patterns)
    end)
  end

  defp ensure_file_contains(path, required_patterns) do
    case File.read(path) do
      {:ok, content} ->
        missing =
          required_patterns
          |> Enum.reject(&String.contains?(content, &1))

        if missing == [] do
          :ok
        else
          Mix.raise(
            "Subscriptions docs sync gate failed for #{path}. Missing anchors:\n" <>
              Enum.map_join(missing, "\n", &"- #{&1}")
          )
        end

      {:error, reason} ->
        Mix.raise("Subscriptions docs sync gate failed reading #{path}: #{inspect(reason)}")
    end
  end
end
