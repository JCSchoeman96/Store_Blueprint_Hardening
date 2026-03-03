defmodule Store.Digital.RevocationPolicy do
  @moduledoc """
  Refund-driven download-grant revocation policy resolver.
  """

  @type t :: :strict_line_scoped | :strict_order_scoped | :threshold

  @default_policy :strict_line_scoped

  @spec current() :: t()
  def current do
    Application.get_env(:store, :digital, [])
    |> Keyword.get(:refund_revocation_policy, @default_policy)
    |> normalize()
  end

  @spec normalize(term()) :: t()
  def normalize(value) when value in [:strict_line_scoped, "strict_line_scoped"],
    do: :strict_line_scoped

  def normalize(value) when value in [:strict_order_scoped, "strict_order_scoped"],
    do: :strict_order_scoped

  def normalize(value) when value in [:threshold, "threshold"], do: :threshold
  def normalize(_value), do: @default_policy
end
