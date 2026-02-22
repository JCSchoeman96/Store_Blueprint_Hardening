defmodule Store.Support.Errors.Error do
  @moduledoc """
  Stable error envelope for governance-safe API responses.
  """

  alias Store.Support.Errors.ErrorCodes

  @enforce_keys [:code, :message]
  defstruct [:code, :message, meta: %{}]

  @type t :: %__MODULE__{
          code: String.t(),
          message: String.t(),
          meta: map()
        }

  @spec new(String.t(), String.t(), map()) :: t()
  def new(code, message, meta \\ %{})
      when is_binary(code) and is_binary(message) and is_map(meta) do
    if ErrorCodes.exists?(code) do
      %__MODULE__{code: code, message: message, meta: meta}
    else
      raise ArgumentError, "unknown error code: #{inspect(code)}"
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{
      code: error.code,
      message: error.message,
      meta: error.meta
    }
  end
end
