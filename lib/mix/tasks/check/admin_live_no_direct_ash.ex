defmodule Mix.Tasks.Check.AdminLiveNoDirectAsh do
  use Mix.Task

  @moduledoc false

  @shortdoc "Fails if admin LiveViews use direct Ash reads/writes/query/changeset primitives"

  @target_globs ["lib/store_web/live/admin/**/*.{ex,exs}"]

  @ash_call_denylist [:create, :create!, :update, :update!, :destroy, :destroy!, :read, :read!]

  @impl Mix.Task
  def run(_args) do
    offenses =
      @target_globs
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.uniq()
      |> Enum.flat_map(&scan_file/1)

    if offenses == [] do
      Mix.shell().info("check.admin_live_no_direct_ash: OK")
    else
      details =
        offenses
        |> Enum.sort_by(fn {file, line, _message} -> {file, line} end)
        |> Enum.map_join("\n", fn {file, line, message} -> "#{file}:#{line}: #{message}" end)

      Mix.raise("Direct Ash usage under lib/store_web/live/admin/** is forbidden:\n" <> details)
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
        [{file, 1, "unable to parse file for admin Ash gate"}]
    end
  end

  defp collect_offenses(ast) do
    {_ast, offenses} =
      Macro.prewalk(ast, [], fn node, offenses ->
        {node, node_offenses(node) ++ offenses}
      end)

    offenses
  end

  defp node_offenses({:require, meta, args}) do
    if Enum.any?(args, &alias_match?(&1, [:Ash, :Query])) do
      [{line(meta), "require Ash.Query"}]
    else
      []
    end
  end

  defp node_offenses({:alias, meta, args}) do
    if Enum.any?(List.wrap(args), &contains_alias?(&1, [:Ash, :Changeset])) do
      [{line(meta), "Ash.Changeset alias/reference"}]
    else
      []
    end
  end

  defp node_offenses({{:., meta, [target, fun]}, _call_meta, _args})
       when fun in @ash_call_denylist do
    if alias_match?(target, [:Ash]) do
      [{line(meta), "Ash.#{fun} call"}]
    else
      []
    end
  end

  defp node_offenses({{:., meta, [target, _fun]}, _call_meta, _args}) do
    ash_query_offense(meta, target) ++ ash_changeset_offense(meta, target)
  end

  defp node_offenses({:__aliases__, meta, _parts} = alias_node) do
    if alias_match?(alias_node, [:Ash, :Changeset]) do
      [{line(meta), "Ash.Changeset reference"}]
    else
      []
    end
  end

  defp node_offenses(_node), do: []

  defp ash_query_offense(meta, target) do
    if alias_match?(target, [:Ash, :Query]), do: [{line(meta), "Ash.Query usage"}], else: []
  end

  defp ash_changeset_offense(meta, target) do
    if alias_match?(target, [:Ash, :Changeset]),
      do: [{line(meta), "Ash.Changeset usage"}],
      else: []
  end

  defp contains_alias?({:__aliases__, _meta, _parts} = alias_node, match),
    do: alias_match?(alias_node, match)

  defp contains_alias?({:{}, _meta, list}, match),
    do: Enum.any?(list, &contains_alias?(&1, match))

  defp contains_alias?(list, match) when is_list(list),
    do: Enum.any?(list, &contains_alias?(&1, match))

  defp contains_alias?(_other, _match), do: false

  defp alias_match?({:__aliases__, _meta, parts}, expected), do: parts == expected
  defp alias_match?(_other, _expected), do: false

  defp line(meta), do: Keyword.get(meta, :line, 1)
end
