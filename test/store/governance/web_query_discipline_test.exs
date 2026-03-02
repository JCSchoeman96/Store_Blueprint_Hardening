defmodule Store.Governance.WebQueryDisciplineTest do
  use ExUnit.Case, async: false

  @task "check.web_no_ash_query"
  @controller_violation_file "lib/store_web/controllers/__web_no_ash_query_tmp_test__.ex"
  @params_allowlist_file "lib/store_web/params/__web_no_ash_query_tmp_allowed_test__.ex"

  test "mix check alias includes web no Ash.Query gate" do
    check_alias = Mix.Project.config()[:aliases][:check]
    assert "check.web_no_ash_query" in check_alias
  end

  test "task fails when scoped web surfaces reference Ash.Query" do
    write_tmp_file(
      @controller_violation_file,
      """
      defmodule StoreWeb.__WebNoAshQueryTmpTest do
        require Ash.Query
      end
      """
    )

    assert_raise Mix.Error,
                 ~r/Ash.Query usage under scoped lib\/store_web\/\*\* is forbidden/,
                 fn ->
                   run_task()
                 end
  after
    File.rm(@controller_violation_file)
  end

  test "task ignores params path outside scoped gate surfaces" do
    write_tmp_file(
      @params_allowlist_file,
      """
      defmodule StoreWeb.Params.__WebNoAshQueryTmpAllowedTest do
        require Ash.Query
      end
      """
    )

    assert :ok == run_task()
  after
    File.rm(@params_allowlist_file)
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
