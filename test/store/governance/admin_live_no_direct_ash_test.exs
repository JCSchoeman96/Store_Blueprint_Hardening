defmodule Store.Governance.AdminLiveNoDirectAshTest do
  use ExUnit.Case, async: false

  @task "check.admin_live_no_direct_ash"
  @violation_file "lib/store_web/live/admin/__admin_live_no_direct_ash_tmp_test__.ex"
  @comment_only_file "lib/store_web/live/admin/__admin_live_no_direct_ash_tmp_comment_test__.ex"
  @outside_scope_file "lib/store_web/live/__admin_live_no_direct_ash_tmp_outside_test__.ex"

  test "mix check alias includes admin live direct Ash gate" do
    check_alias = Mix.Project.config()[:aliases][:check]
    assert "check.admin_live_no_direct_ash" in check_alias
  end

  test "task fails when admin live files use direct Ash calls" do
    write_tmp_file(
      @violation_file,
      """
      defmodule StoreWeb.Admin.__AdminLiveNoDirectAshTmpTest do
        def bad do
          Ash.read(Store.Pricing.ShippingZone)
        end
      end
      """
    )

    assert_raise Mix.Error,
                 ~r/Direct Ash usage under lib\/store_web\/live\/admin\/\*\* is forbidden/,
                 fn ->
                   run_task()
                 end
  after
    File.rm(@violation_file)
  end

  test "task ignores comments and docstrings" do
    write_tmp_file(
      @comment_only_file,
      """
      defmodule StoreWeb.Admin.__AdminLiveNoDirectAshTmpCommentTest do
        @moduledoc \"\"\"
        Ash.read(Store.Pricing.ShippingZone)
        \"\"\"

        # Ash.read(Store.Pricing.ShippingZone)
        def ok, do: :ok
      end
      """
    )

    assert :ok == run_task()
  after
    File.rm(@comment_only_file)
  end

  test "task ignores files outside admin live scope" do
    write_tmp_file(
      @outside_scope_file,
      """
      defmodule StoreWeb.__AdminLiveNoDirectAshTmpOutsideTest do
        def bad do
          Ash.read(Store.Pricing.ShippingZone)
        end
      end
      """
    )

    assert :ok == run_task()
  after
    File.rm(@outside_scope_file)
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
end
