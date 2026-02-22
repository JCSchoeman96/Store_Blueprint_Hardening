defmodule Mix.Tasks.Check.NoRepoInWeb do
  use Mix.Task

  @moduledoc false

  @shortdoc "Fails if web layer references Repo modules"

  @deny_patterns [
    ~r/\bStore\.Repo\b/,
    ~r/\bEcto\.Repo\b/,
    ~r/\b[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\.Repo\b/
  ]

  @impl Mix.Task
  def run(_args) do
    offenses =
      Path.wildcard("lib/store_web/**/*.{ex,exs,heex}")
      |> Enum.flat_map(&scan_file/1)

    if offenses == [] do
      Mix.shell().info("check.no_repo_in_web: OK")
    else
      message =
        offenses
        |> Enum.map_join("\n", fn {file, line_number, line} ->
          "#{file}:#{line_number}: #{String.trim(line)}"
        end)

      Mix.raise("Repo usage under lib/store_web/** is forbidden:\n" <> message)
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
