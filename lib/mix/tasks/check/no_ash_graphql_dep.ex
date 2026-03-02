defmodule Mix.Tasks.Check.NoAshGraphqlDep do
  use Mix.Task

  @moduledoc false

  @shortdoc "Fails if ash_graphql is introduced while JSON:API is the public API surface"

  @default_mix_exs "mix.exs"
  @default_mix_lock "mix.lock"
  @deny_token ":ash_graphql"
  @deny_lock_token "\"ash_graphql\""

  @impl Mix.Task
  def run(_args) do
    mix_exs = System.get_env("CHECK_NO_ASH_GRAPHQL_DEP_MIX_EXS", @default_mix_exs)
    mix_lock = System.get_env("CHECK_NO_ASH_GRAPHQL_DEP_MIX_LOCK", @default_mix_lock)

    offenses =
      []
      |> maybe_add_offense(mix_exs, @deny_token)
      |> maybe_add_offense(mix_lock, @deny_lock_token)

    if offenses == [] do
      Mix.shell().info("check.no_ash_graphql_dep: OK")
    else
      details =
        Enum.map_join(offenses, "\n", fn {path, token} ->
          "#{path}: contains forbidden token #{token}"
        end)

      Mix.raise(
        "ash_graphql dependency is forbidden while JSON:API is the only public API surface:\n" <>
          details
      )
    end
  end

  defp maybe_add_offense(offenses, path, token) do
    if File.exists?(path) and String.contains?(File.read!(path), token) do
      [{path, token} | offenses]
    else
      offenses
    end
  end
end
