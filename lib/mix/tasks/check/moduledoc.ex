defmodule Mix.Tasks.Check.Moduledoc do
  use Mix.Task

  @moduledoc false

  @shortdoc "Fails if modules under lib/** do not declare @moduledoc"

  @impl Mix.Task
  def run(_args) do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.filter(&module_file?/1)
      |> Enum.reject(&has_moduledoc?/1)

    if offenders == [] do
      Mix.shell().info("check.moduledoc: OK")
    else
      details =
        offenders
        |> Enum.map_join("\n", &offender_detail/1)

      Mix.raise("Missing @moduledoc (or @moduledoc false) in:\n" <> details)
    end
  end

  defp module_file?(file) do
    file
    |> File.read!()
    |> String.contains?("defmodule ")
  end

  defp has_moduledoc?(file) do
    file
    |> File.read!()
    |> String.contains?("@moduledoc")
  end

  defp offender_detail(file) do
    first_module_line =
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.find(fn {line, _line_number} -> String.contains?(line, "defmodule ") end)

    case first_module_line do
      {line, line_number} -> "#{file}:#{line_number}: #{String.trim(line)}"
      nil -> "#{file}:1"
    end
  end
end
