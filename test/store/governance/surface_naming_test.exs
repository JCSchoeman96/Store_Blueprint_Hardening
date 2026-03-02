defmodule Store.Governance.SurfaceNamingTest do
  use ExUnit.Case, async: false

  @task "check.surface_naming"

  test "mix check alias includes surface naming gate" do
    check_alias = Mix.Project.config()[:aliases][:check]
    assert "check.surface_naming" in check_alias
  end

  test "task passes with the project surface registry" do
    assert :ok == run_task()
  end

  test "task fails when registry includes non-consumer names" do
    Code.compile_string("""
    defmodule Store.TestSupport.SurfaceGateBadFacade do
      def wrong_name, do: :ok
    end

    defmodule Store.TestSupport.SurfaceGateBadRegistry do
      def facade_modules, do: [Store.TestSupport.SurfaceGateBadFacade]
      def allowed_exports(_module), do: [{:wrong_name, 0}]
      def consumer_surface?(_export), do: false
    end
    """)

    with_env(
      "CHECK_SURFACE_NAMING_REGISTRY_MODULE",
      "Store.TestSupport.SurfaceGateBadRegistry",
      fn ->
        assert_raise Mix.Error, ~r/non-consumer/, fn ->
          run_task()
        end
      end
    )
  end

  defp run_task do
    Mix.Task.reenable(@task)
    Mix.Task.run(@task)
    :ok
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
