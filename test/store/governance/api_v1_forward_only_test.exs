defmodule Store.Governance.ApiV1ForwardOnlyTest do
  use ExUnit.Case, async: false

  @task "check.api_v1_forward_only"
  @tmp_router_file "lib/store_web/__api_v1_forward_only_tmp_router_test__.ex"

  test "mix check alias includes api v1 forward-only gate" do
    check_alias = Mix.Project.config()[:aliases][:check]
    assert "check.api_v1_forward_only" in check_alias
  end

  test "task fails when custom /v1 route is added" do
    write_tmp_file(
      @tmp_router_file,
      """
      defmodule StoreWeb.__ApiV1ForwardOnlyTmpRouterTest do
        use Phoenix.Router

        scope "/api" do
          get "/v1/orders", StoreWeb.PageController, :home
        end
      end
      """
    )

    with_env("CHECK_API_V1_FORWARD_ONLY_GLOB", @tmp_router_file, fn ->
      assert_raise Mix.Error,
                   ~r/Only forward "\/v1", StoreWeb\.JsonApiRouter is allowed/,
                   fn -> run_task() end
    end)
  after
    File.rm(@tmp_router_file)
  end

  test "task fails when /v1 is forwarded to the wrong router module" do
    write_tmp_file(
      @tmp_router_file,
      """
      defmodule StoreWeb.__ApiV1ForwardOnlyTmpRouterTest do
        use Phoenix.Router

        scope "/api" do
          forward "/v1", StoreWeb.OtherRouter
        end
      end
      """
    )

    with_env("CHECK_API_V1_FORWARD_ONLY_GLOB", @tmp_router_file, fn ->
      assert_raise Mix.Error,
                   ~r/Only forward "\/v1", StoreWeb\.JsonApiRouter is allowed/,
                   fn -> run_task() end
    end)
  after
    File.rm(@tmp_router_file)
  end

  test "task passes when /v1 is forwarded to StoreWeb.JsonApiRouter" do
    write_tmp_file(
      @tmp_router_file,
      """
      defmodule StoreWeb.__ApiV1ForwardOnlyTmpRouterTest do
        use Phoenix.Router

        scope "/api" do
          forward "/v1", StoreWeb.JsonApiRouter
        end
      end
      """
    )

    with_env("CHECK_API_V1_FORWARD_ONLY_GLOB", @tmp_router_file, fn ->
      assert :ok == run_task()
    end)
  after
    File.rm(@tmp_router_file)
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
