defmodule Mix.Tasks.Check.ApiV1ForwardOnly do
  use Mix.Task

  @moduledoc false

  @shortdoc "Fails when /api/v1 routes are anything other than the JSON:API forward"

  @default_glob "lib/store_web/**/*router*.ex"
  @allowed_forward ~r/^\s*forward\s*\(?\s*"\/v1"\s*,\s*StoreWeb\.JsonApiRouter\b/
  @forbidden_v1_route ~r/^\s*(get|post|put|patch|delete|options|head|match|live|resources)\s*\(?\s*"\/v1(?:\/|")/
  @forbidden_api_v1_route ~r/^\s*(get|post|put|patch|delete|options|head|match|live|resources|forward)\s*\(?\s*"\/api\/v1(?:\/|")/
  @forward_v1 ~r/^\s*forward\s*\(?\s*"\/v1"\s*,\s*([A-Za-z0-9_.]+)/

  @impl Mix.Task
  def run(_args) do
    glob = System.get_env("CHECK_API_V1_FORWARD_ONLY_GLOB", @default_glob)

    files =
      glob
      |> Path.wildcard()
      |> Enum.uniq()

    offenses =
      files
      |> Enum.flat_map(&scan_file/1)
      |> Enum.reverse()

    forward_found? =
      files
      |> Enum.any?(fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.any?(&Regex.match?(@allowed_forward, &1))
      end)

    cond do
      files == [] ->
        Mix.raise("api_v1_forward_only gate found no router files with glob #{inspect(glob)}")

      offenses != [] ->
        details =
          Enum.map_join(offenses, "\n", fn {file, line_number, line} ->
            "#{file}:#{line_number}: #{String.trim(line)}"
          end)

        Mix.raise(
          "Only forward \"/v1\", StoreWeb.JsonApiRouter is allowed for /api/v1 routing:\n" <>
            details
        )

      not forward_found? ->
        Mix.raise(
          "Missing required JSON:API route forward: forward \"/v1\", StoreWeb.JsonApiRouter"
        )

      true ->
        Mix.shell().info("check.api_v1_forward_only: OK")
    end
  end

  defp scan_file(file) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce([], fn {line, line_number}, offenses ->
      if route_line_offense?(line) do
        [{file, line_number, line} | offenses]
      else
        offenses
      end
    end)
  end

  defp route_line_offense?(line) do
    cond do
      Regex.match?(@allowed_forward, line) ->
        false

      Regex.match?(@forbidden_v1_route, line) ->
        true

      Regex.match?(@forbidden_api_v1_route, line) ->
        true

      true ->
        invalid_forward_module?(line)
    end
  end

  defp invalid_forward_module?(line) do
    case Regex.run(@forward_v1, line, capture: :all_but_first) do
      [module] ->
        module != "StoreWeb.JsonApiRouter"

      _ ->
        false
    end
  end
end
