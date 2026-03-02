defmodule Mix.Tasks.Check.SurfaceNaming do
  use Mix.Task

  @moduledoc false

  @shortdoc "Fails when facade module exports drift from SurfaceRegistry consumer-scoped names"

  @default_registry_module Store.Support.Governance.SurfaceRegistry
  @built_in_exports MapSet.new([{:__info__, 1}, {:module_info, 0}, {:module_info, 1}])

  @impl Mix.Task
  def run(_args) do
    registry_module = registry_module()

    offenses =
      registry_module
      |> facade_modules()
      |> Enum.flat_map(&module_offenses(&1, registry_module))

    if offenses == [] do
      Mix.shell().info("check.surface_naming: OK")
    else
      details = Enum.map_join(offenses, "\n", &format_offense/1)
      Mix.raise("Facade surface naming drift detected:\n" <> details)
    end
  end

  defp module_offenses(module, registry_module) do
    case Code.ensure_compiled(module) do
      {:module, ^module} ->
        allowed =
          registry_module
          |> allowed_exports(module)
          |> MapSet.new()

        exported =
          module.__info__(:functions)
          |> Enum.reject(&MapSet.member?(@built_in_exports, &1))
          |> MapSet.new()

        missing = MapSet.difference(allowed, exported) |> MapSet.to_list() |> Enum.sort()
        disallowed = MapSet.difference(exported, allowed) |> MapSet.to_list() |> Enum.sort()

        non_consumer =
          allowed
          |> Enum.reject(&consumer_surface?(registry_module, &1))
          |> Enum.sort()

        []
        |> add_offense(module, :missing, missing)
        |> add_offense(module, :disallowed, disallowed)
        |> add_offense(module, :non_consumer, non_consumer)

      _ ->
        [{module, :not_loaded, []}]
    end
  end

  defp add_offense(offenses, _module, _kind, []), do: offenses
  defp add_offense(offenses, module, kind, items), do: [{module, kind, items} | offenses]

  defp format_offense({module, :missing, items}),
    do: "#{inspect(module)} missing registered exports: #{format_items(items)}"

  defp format_offense({module, :disallowed, items}),
    do: "#{inspect(module)} has unregistered exports: #{format_items(items)}"

  defp format_offense({module, :non_consumer, items}),
    do: "#{inspect(module)} has non-consumer registered names: #{format_items(items)}"

  defp format_offense({module, :not_loaded, _items}),
    do: "#{inspect(module)} could not be loaded"

  defp format_items(items) do
    items
    |> Enum.map_join(", ", fn {name, arity} -> "#{name}/#{arity}" end)
  end

  defp registry_module do
    case System.get_env("CHECK_SURFACE_NAMING_REGISTRY_MODULE") do
      nil ->
        @default_registry_module

      module_name ->
        module_name
        |> String.split(".")
        |> Module.concat()
    end
  end

  defp facade_modules(registry_module) do
    if function_exported?(registry_module, :facade_modules, 0) do
      registry_module.facade_modules()
    else
      Map.keys(registry_module.registry())
    end
  end

  defp allowed_exports(registry_module, module) do
    if function_exported?(registry_module, :allowed_exports, 1) do
      registry_module.allowed_exports(module)
    else
      Map.get(registry_module.registry(), module, [])
    end
  end

  defp consumer_surface?(registry_module, export) do
    if function_exported?(registry_module, :consumer_surface?, 1) do
      registry_module.consumer_surface?(export)
    else
      false
    end
  end
end
