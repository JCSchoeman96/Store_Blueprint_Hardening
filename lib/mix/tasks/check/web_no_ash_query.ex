defmodule Mix.Tasks.Check.WebNoAshQuery do
  use Mix.Task

  @moduledoc false

  @shortdoc "Fails if scoped web surfaces use Ash.Query"

  @target_globs [
    "lib/store_web/controllers/**/*.{ex,exs,heex}",
    "lib/store_web/live/**/*.{ex,exs,heex}",
    "lib/store_web/components/**/*.{ex,exs,heex}"
  ]

  @deny_patterns [
    ~r/\brequire\s+Ash\.Query\b/,
    ~r/\bAsh\.Query\./
  ]

  @impl Mix.Task
  def run(_args) do
    offenses =
      @target_globs
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.uniq()
      |> Enum.flat_map(&scan_file/1)

    if offenses == [] do
      Mix.shell().info("check.web_no_ash_query: OK")
    else
      details =
        Enum.map_join(offenses, "\n", fn {file, line_number, line} ->
          "#{file}:#{line_number}: #{String.trim(line)}"
        end)

      Mix.raise("Ash.Query usage under scoped lib/store_web/** is forbidden:\n" <> details)
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
