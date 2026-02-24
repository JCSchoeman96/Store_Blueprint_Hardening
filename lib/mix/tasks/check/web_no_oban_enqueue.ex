defmodule Mix.Tasks.Check.WebNoObanEnqueue do
  use Mix.Task

  @moduledoc false

  @shortdoc "Fails if web layer enqueues Oban jobs outside webhook allowlist"

  @allowlist_file "lib/store_web/controllers/webhook_controller.ex"
  @deny_pattern ~r/\bOban\.insert(?:_all)?\b/
  @allowlisted_deny_pattern ~r/\bOban\.insert_all\b/

  @impl Mix.Task
  def run(_args) do
    offenses =
      Path.wildcard("lib/store_web/**/*.{ex,exs,heex}")
      |> Enum.flat_map(&scan_file/1)

    if offenses == [] do
      Mix.shell().info("check.web_no_oban_enqueue: OK")
    else
      details =
        Enum.map_join(offenses, "\n", fn {file, line_number, line} ->
          "#{file}:#{line_number}: #{String.trim(line)}"
        end)

      Mix.raise(
        "Oban enqueue under lib/store_web/** is forbidden outside webhook allowlist:\n" <> details
      )
    end
  end

  defp scan_file(@allowlist_file = file) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      if Regex.match?(@allowlisted_deny_pattern, line) do
        [{file, line_number, line}]
      else
        []
      end
    end)
  end

  defp scan_file(file) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      if Regex.match?(@deny_pattern, line) do
        [{file, line_number, line}]
      else
        []
      end
    end)
  end
end
