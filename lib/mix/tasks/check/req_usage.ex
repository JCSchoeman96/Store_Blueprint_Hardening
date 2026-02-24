defmodule Mix.Tasks.Check.ReqUsage do
  use Mix.Task

  @moduledoc """
  Fails if `Req` is referenced outside sanctioned wrapper.

  Usage: mix check.req_usage
  """

  @shortdoc "Enforces Req client discipline"

  @impl Mix.Task
  def run(_args) do
    case System.find_executable("rg") do
      nil ->
        Mix.raise("ripgrep (rg) is not installed. Please install it to run Req usage check.")

      _executable ->
        check_usage()
    end
  end

  defp check_usage do
    # -w: match whole word (effectively \bReq\b).
    # This catches 'alias Req', 'import Req', or 'require Req' bypasses, not just 'Req.' calls.
    # The allowlist is strictly pinned to the sanctioned wrapper, this task, and the wrapper's tests.
    args = [
      "-w",
      "Req",
      "-t",
      "elixir",
      "--glob",
      "!lib/store/support/http/req_client.ex",
      "--glob",
      "!lib/mix/tasks/check/req_usage.ex",
      "--glob",
      "!lib/mix/tasks/check/web_no_http.ex",
      "--glob",
      "!test/store/support/http/req_client_test.exs",
      "lib",
      "test"
    ]

    case System.cmd("rg", args) do
      {output, 0} ->
        # Exit code 0 means matches were found.
        Mix.shell().error("Forbidden usage of 'Req' found outside sanctioned wrapper:")
        IO.puts(output)
        Mix.raise("Req discipline violation.")

      {_output, 1} ->
        # Exit code 1 means no matches found.
        Mix.shell().info("check.req_usage: OK")

      {output, _exit_code} ->
        # Exit code 2 or other means error.
        Mix.raise("ripgrep error: #{output}")
    end
  end
end
