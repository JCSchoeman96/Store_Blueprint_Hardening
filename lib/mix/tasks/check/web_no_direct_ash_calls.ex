defmodule Mix.Tasks.Check.WebNoDirectAshCalls do
  use Mix.Task

  @moduledoc false

  @shortdoc "Fails if web layer makes direct Ash read/create/update/destroy calls"

  @target_globs ["lib/store_web/**/*.{ex,exs}"]
  @ash_call_denylist [:create, :create!, :update, :update!, :destroy, :destroy!, :read, :read!]

  @impl Mix.Task
  def run(_args) do
    offenses =
      @target_globs
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.uniq()
      |> Enum.flat_map(&scan_file/1)

    if offenses == [] do
      Mix.shell().info("check.web_no_direct_ash_calls: OK")
    else
      details =
        offenses
        |> Enum.sort_by(fn {file, line, _message} -> {file, line} end)
        |> Enum.map_join("\n", fn {file, line, message} -> "#{file}:#{line}: #{message}" end)

      Mix.raise("Direct Ash web usage under lib/store_web/** is forbidden:\n" <> details)
    end
  end

  defp scan_file(file) do
    source = File.read!(file)

    case Code.string_to_quoted(source, columns: true) do
      {:ok, ast} ->
        ast
        |> collect_offenses()
        |> Enum.uniq()
        |> Enum.map(fn {line, message} -> {file, line, message} end)

      {:error, {_line, _error, _token}} ->
        [{file, 1, "unable to parse file for direct Ash call gate"}]
    end
  end

  defp collect_offenses(ast) do
    {_ast, offenses} =
      Macro.prewalk(ast, [], fn node, offenses ->
        {node, node_offenses(node) ++ offenses}
      end)

    offenses
  end

  defp node_offenses({{:., meta, [target, fun]}, _call_meta, _args})
       when fun in @ash_call_denylist do
    if alias_match?(target, [:Ash]) do
      [{line(meta), "Ash.#{fun} call"}]
    else
      []
    end
  end

  defp node_offenses(_node), do: []

  defp alias_match?({:__aliases__, _meta, parts}, expected), do: parts == expected
  defp alias_match?(_other, _expected), do: false
  defp line(meta), do: Keyword.get(meta, :line, 1)
end
