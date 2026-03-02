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
      def consumer_surface?(_module, _export), do: false
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

  test "task fails when non-catalog facade registers *_for_public export" do
    Code.compile_string("""
    defmodule Store.TestSupport.SurfaceGateOrdersFacade do
      def list_orders_for_public(_actor, _query), do: []
    end

    defmodule Store.TestSupport.SurfaceGateOrdersRegistry do
      def facade_modules, do: [Store.TestSupport.SurfaceGateOrdersFacade]
      def allowed_exports(_module), do: [{:list_orders_for_public, 2}]
      def consumer_surface?(_module, _export), do: false
    end
    """)

    with_env(
      "CHECK_SURFACE_NAMING_REGISTRY_MODULE",
      "Store.TestSupport.SurfaceGateOrdersRegistry",
      fn ->
        assert_raise Mix.Error, ~r/non-consumer/, fn ->
          run_task()
        end
      end
    )
  end

  test "task passes when catalog facade registers *_for_public export" do
    Code.compile_string("""
    defmodule Store.TestSupport.SurfaceGateCatalogFacade do
      def list_products_for_public(_actor, _query), do: []
    end

    defmodule Store.TestSupport.SurfaceGateCatalogRegistry do
      def facade_modules, do: [Store.TestSupport.SurfaceGateCatalogFacade]
      def allowed_exports(_module), do: [{:list_products_for_public, 2}]
      def consumer_surface?(_module, {:list_products_for_public, 2}), do: true
      def consumer_surface?(_module, _export), do: false
    end
    """)

    with_env(
      "CHECK_SURFACE_NAMING_REGISTRY_MODULE",
      "Store.TestSupport.SurfaceGateCatalogRegistry",
      fn ->
        assert :ok == run_task()
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
