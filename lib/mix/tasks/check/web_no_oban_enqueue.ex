defmodule Mix.Tasks.Check.WebNoObanEnqueue do
  use Mix.Task

  @moduledoc false

  @shortdoc "Fails if web layer enqueues Oban jobs outside webhook/callback allowlists"

  @webhook_allowlist_file "lib/store_web/controllers/webhook_controller.ex"
  @callback_allowlist_file "lib/store_web/controllers/payment_callback_controller.ex"
  @deny_pattern ~r/\bOban\.insert(?:_all)?\b/
  @allowlisted_deny_pattern ~r/\bOban\.insert_all\b/
  @worker_new_pattern ~r/\b[A-Za-z0-9_.]*Worker\.new\(/
  @callback_allowed_worker_new_pattern ~r/\bProcessWebhookReceiptWorker\.new\(/

  @impl Mix.Task
  def run(_args) do
    offenses =
      Path.wildcard("lib/store_web/**/*.{ex,exs,heex}")
      |> Enum.flat_map(&scan_file/1)

    if offenses == [] do
      Mix.shell().info("check.web_no_oban_enqueue: OK")
    else
      details =
        Enum.map_join(offenses, "\n", fn {file, line_number, line} ->
          "#{file}:#{line_number}: #{String.trim(line)}"
        end)

      Mix.raise(
        "Oban enqueue under lib/store_web/** is forbidden outside webhook/callback allowlists:\n" <>
          details
      )
    end
  end

  defp scan_file(@webhook_allowlist_file = file) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      if Regex.match?(@allowlisted_deny_pattern, line) do
        [{file, line_number, line}]
      else
        []
      end
    end)
  end

  defp scan_file(@callback_allowlist_file = file) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      cond do
        Regex.match?(@allowlisted_deny_pattern, line) ->
          [{file, line_number, line}]

        Regex.match?(@worker_new_pattern, line) and
            not Regex.match?(@callback_allowed_worker_new_pattern, line) ->
          [{file, line_number, line}]

        true ->
          []
      end
    end)
  end

  defp scan_file(file) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      if Regex.match?(@deny_pattern, line) do
        [{file, line_number, line}]
      else
        []
      end
    end)
  end
end
