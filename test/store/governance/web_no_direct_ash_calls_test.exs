defmodule Store.Governance.WebNoDirectAshCallsTest do
  use ExUnit.Case, async: false

  @task "check.web_no_direct_ash_calls"
  @violation_file "lib/store_web/controllers/__web_no_direct_ash_calls_tmp_test__.ex"
  @comment_only_file "lib/store_web/controllers/__web_no_direct_ash_calls_tmp_comment_test__.ex"
  @outside_scope_file "lib/store/__web_no_direct_ash_calls_tmp_outside_test__.ex"

  test "mix check alias includes web no direct Ash calls gate" do
    check_alias = Mix.Project.config()[:aliases][:check]
    assert "check.web_no_direct_ash_calls" in check_alias
  end

  test "task fails when web files use direct Ash calls" do
    write_tmp_file(
      @violation_file,
      """
      defmodule StoreWeb.__WebNoDirectAshCallsTmpTest do
        def bad do
          Ash.read(Store.Pricing.ShippingZone)
        end
      end
      """
    )

    assert_raise Mix.Error,
                 ~r/Direct Ash web usage under lib\/store_web\/\*\* is forbidden/,
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
      defmodule StoreWeb.__WebNoDirectAshCallsTmpCommentTest do
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

  test "task ignores files outside lib/store_web scope" do
    write_tmp_file(
      @outside_scope_file,
      """
      defmodule Store.__WebNoDirectAshCallsTmpOutsideTest do
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
