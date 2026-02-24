defmodule Mix.Tasks.Check.WebNoHttp do
  use Mix.Task

  @moduledoc false

  @shortdoc "Fails if web layer references outbound HTTP clients"

  @deny_patterns [
    ~r/\bStore\.Support\.HTTP\.ReqClient\b/,
    ~r/\bReq\b/
  ]

  @impl Mix.Task
  def run(_args) do
    offenses =
      Path.wildcard("lib/store_web/**/*.{ex,exs,heex}")
      |> Enum.flat_map(&scan_file/1)

    if offenses == [] do
      Mix.shell().info("check.web_no_http: OK")
    else
      details =
        Enum.map_join(offenses, "\n", fn {file, line_number, line} ->
          "#{file}:#{line_number}: #{String.trim(line)}"
        end)

      Mix.raise("Outbound HTTP usage under lib/store_web/** is forbidden:\n" <> details)
    end
  end

  defp scan_file(file) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      if Enum.any?(@deny_patterns, &Regex.match?(&1, line)) do
        [{file, line_number, line}]
      else
        []
      end
    end)
  end
end
