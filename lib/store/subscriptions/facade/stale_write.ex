defmodule Store.Subscriptions.Facade.StaleWrite do
  @moduledoc false

  alias Store.Support.Errors.{Error, Normalize}

  def normalize_update_result({:ok, _} = result), do: result

  def normalize_update_result({:error, reason}) do
    if stale_record_error?(reason) do
      {:error,
       Error.new(
         "STALE_RECORD",
         "subscription changed while the command was in progress; reload and re-evaluate it"
       )}
    else
      {:error, Normalize.normalize(reason)}
    end
  end

  def stale_record_error?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  def stale_record_error?(_reason), do: false
end
