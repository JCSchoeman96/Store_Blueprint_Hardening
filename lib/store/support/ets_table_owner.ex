defmodule Store.Support.EtsTableOwner do
  @moduledoc false

  use GenServer

  @default_options [
    :set,
    :public,
    :named_table,
    read_concurrency: true,
    write_concurrency: true
  ]

  def child_spec(opts) when is_list(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :table)},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    table = Keyword.fetch!(opts, :table)
    options = Keyword.get(opts, :options, @default_options)

    _ = ensure_table(table, options)

    {:ok, %{table: table}}
  end

  defp ensure_table(table, options) do
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, options)

      existing ->
        existing
    end
  rescue
    ArgumentError -> table
  end
end
