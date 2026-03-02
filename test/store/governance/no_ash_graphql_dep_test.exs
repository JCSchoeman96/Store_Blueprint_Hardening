defmodule Store.Governance.NoAshGraphqlDepTest do
  use ExUnit.Case, async: false

  @task "check.no_ash_graphql_dep"
  @tmp_mix_exs "tmp/check_no_ash_graphql_dep/mix.exs"
  @tmp_mix_lock "tmp/check_no_ash_graphql_dep/mix.lock"

  test "mix check alias includes no ash_graphql dep gate" do
    check_alias = Mix.Project.config()[:aliases][:check]
    assert "check.no_ash_graphql_dep" in check_alias
  end

  test "task fails when mix.exs contains ash_graphql dependency token" do
    write_tmp_file(@tmp_mix_exs, "defp deps, do: [{:ash_graphql, \"~> 1.0\"}]")
    write_tmp_file(@tmp_mix_lock, "%{}")

    with_env(
      "CHECK_NO_ASH_GRAPHQL_DEP_MIX_EXS",
      @tmp_mix_exs,
      fn ->
        with_env("CHECK_NO_ASH_GRAPHQL_DEP_MIX_LOCK", @tmp_mix_lock, fn ->
          assert_raise Mix.Error,
                       ~r/ash_graphql dependency is forbidden/,
                       fn -> run_task() end
        end)
      end
    )
  after
    File.rm(@tmp_mix_exs)
    File.rm(@tmp_mix_lock)
  end

  test "task fails when mix.lock contains ash_graphql dependency token" do
    write_tmp_file(@tmp_mix_exs, "defp deps, do: []")
    write_tmp_file(@tmp_mix_lock, "\"ash_graphql\": {:hex, :ash_graphql, \"1.0.0\"}")

    with_env(
      "CHECK_NO_ASH_GRAPHQL_DEP_MIX_EXS",
      @tmp_mix_exs,
      fn ->
        with_env("CHECK_NO_ASH_GRAPHQL_DEP_MIX_LOCK", @tmp_mix_lock, fn ->
          assert_raise Mix.Error,
                       ~r/ash_graphql dependency is forbidden/,
                       fn -> run_task() end
        end)
      end
    )
  after
    File.rm(@tmp_mix_exs)
    File.rm(@tmp_mix_lock)
  end

  defp run_task do
    Mix.Task.reenable(@task)
    Mix.Task.run(@task)
    :ok
  end

  defp write_tmp_file(path, contents) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, contents)
  end

  defp with_env(key, value, fun) do
    previous = System.get_env(key)
    System.put_env(key, value)

    try do
      fun.()
    after
      if previous do
        System.put_env(key, previous)
      else
        System.delete_env(key)
      end
    end
  end
end
