defmodule Mix.Tasks.Check.DocsNotes do
  use Mix.Task

  @moduledoc false

  @shortdoc "Fails if required docs-first phase notes are missing"

  @required_files [
    "docs/agent_notes/phase_00_docs.md",
    "docs/agent_notes/phase_01_docs.md",
    "docs/agent_notes/phase_02_docs.md",
    "docs/agent_notes/phase_03_docs.md"
  ]

  @impl Mix.Task
  def run(_args) do
    missing_files = Enum.reject(@required_files, &File.exists?/1)

    empty_files =
      @required_files
      |> Enum.filter(&(File.exists?(&1) and String.trim(File.read!(&1)) == ""))

    if missing_files == [] and empty_files == [] do
      Mix.shell().info("check.docs_notes: OK")
    else
      missing = Enum.map_join(missing_files, "\n", &"- missing: #{&1}")
      empty = Enum.map_join(empty_files, "\n", &"- empty: #{&1}")

      details =
        [missing, empty]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      Mix.raise("Docs-first phase notes gate failed:\n" <> details)
    end
  end
end
