defmodule Store.Governance.CommsBoundaryTest do
  use ExUnit.Case, async: true

  @web_glob "lib/store_web/**/*.{ex,exs}"
  @deny_patterns [
    "Store.Comms.Providers",
    "Store.Mailer.deliver",
    "Swoosh.Email"
  ]

  test "web layer does not send email or call provider adapters directly" do
    root = Path.expand("../../..", __DIR__)

    violations =
      root
      |> Path.join(@web_glob)
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        content = File.read!(file)

        @deny_patterns
        |> Enum.filter(&String.contains?(content, &1))
        |> Enum.map(fn pattern -> {file, pattern} end)
      end)

    assert violations == [],
           "web comms boundary violations:\n" <>
             Enum.map_join(violations, "\n", fn {file, pattern} -> "- #{file}: #{pattern}" end)
  end
end
