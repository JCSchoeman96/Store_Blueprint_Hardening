defmodule Store.Pricing do
  @moduledoc """
  Pricing domain for persisted discount definitions and deterministic evaluation.
  """

  use Ash.Domain

  import Ash.Expr
  require Ash.Query

  alias Store.Pricing.{Contract, Coupon, Evaluator, Promotion}
  alias Store.Support.Errors.Error

  resources do
    resource(Store.Pricing.Coupon)
    resource(Store.Pricing.Promotion)
  end

  @type evaluate_quote_opts :: [authorize?: boolean(), actor: term(), context: map()]

  @spec evaluate_quote(map(), evaluate_quote_opts()) ::
          {:ok, %{input: Contract.Input.t(), output: Contract.Output.t()}} | {:error, Error.t()}
  def evaluate_quote(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with {:ok, input} <- build_input(attrs, opts),
         {:ok, output} <- Evaluator.evaluate(input) do
      {:ok, %{input: input, output: output}}
    end
  end

  @spec build_input(map(), evaluate_quote_opts()) ::
          {:ok, Contract.Input.t()} | {:error, Error.t()}
  def build_input(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with {:ok, as_of} <- fetch_datetime(attrs, :as_of),
         {:ok, currency} <- fetch_string(attrs, :currency),
         {:ok, lines} <- fetch_lines(attrs),
         {:ok, promotions} <- fetch_promotions(attrs, opts),
         {:ok, coupon} <- fetch_coupon(attrs, opts) do
      eligibility = Map.get(attrs, :eligibility, %{})

      input =
        Contract.to_input!(%{
          as_of: as_of,
          currency: currency,
          lines: lines,
          promotions: promotions,
          coupon: coupon,
          eligibility: eligibility
        })

      {:ok, input}
    end
  rescue
    KeyError ->
      {:error, Error.new("VALIDATION_ERROR", "Missing required pricing input")}

    ArgumentError ->
      {:error, Error.new("VALIDATION_ERROR", "Invalid pricing input")}
  end

  @spec candidate_from_coupon(Coupon.t()) :: Contract.Candidate.t()
  def candidate_from_coupon(%Coupon{} = coupon) do
    %Contract.Candidate{
      id: coupon.id,
      source_kind: :coupon,
      code: coupon.code,
      discount_minor: coupon.discount_minor,
      starts_at: coupon.starts_at,
      ends_at: coupon.ends_at,
      active?: coupon.active,
      exclusive?: false,
      combinable?: coupon.combinable_with_promotions,
      allow_with_exclusive?: coupon.allow_with_exclusive,
      exclusive_priority: 0,
      precedence_rank: coupon.precedence_rank,
      inserted_at: coupon.inserted_at,
      eligibility_key: coupon.eligibility_key
    }
  end

  @spec candidate_from_promotion(Promotion.t()) :: Contract.Candidate.t()
  def candidate_from_promotion(%Promotion{} = promotion) do
    %Contract.Candidate{
      id: promotion.id,
      source_kind: :promotion,
      code: promotion.code,
      discount_minor: promotion.discount_minor,
      starts_at: promotion.starts_at,
      ends_at: promotion.ends_at,
      active?: promotion.active,
      exclusive?: promotion.exclusive,
      combinable?: promotion.combinable,
      allow_with_exclusive?: false,
      exclusive_priority: promotion.exclusive_priority,
      precedence_rank: promotion.precedence_rank,
      inserted_at: promotion.inserted_at,
      eligibility_key: promotion.eligibility_key
    }
  end

  defp fetch_lines(attrs) do
    lines = Map.get(attrs, :lines, [])

    if is_list(lines) and lines != [] do
      {:ok, lines}
    else
      {:error, Error.new("VALIDATION_ERROR", "Pricing lines are required")}
    end
  end

  defp fetch_promotions(attrs, opts) do
    promotion_ids = Map.get(attrs, :promotion_ids, [])

    query =
      case promotion_ids do
        [] -> Promotion
        ids when is_list(ids) -> Ash.Query.filter(Promotion, expr(id in ^ids))
      end

    case Ash.read(query, domain: __MODULE__, authorize?: Keyword.get(opts, :authorize?, false)) do
      {:ok, promotions} -> {:ok, Enum.map(promotions, &candidate_from_promotion/1)}
      {:error, _error} -> {:error, Error.new("INTERNAL_ERROR", "Unable to read promotions")}
    end
  end

  defp fetch_coupon(attrs, opts) do
    case Map.get(attrs, :coupon_code) do
      nil ->
        {:ok, nil}

      code when is_binary(code) ->
        normalized_code = String.upcase(String.trim(code))

        query = Ash.Query.filter(Coupon, expr(code == ^normalized_code))

        case Ash.read(query,
               domain: __MODULE__,
               authorize?: Keyword.get(opts, :authorize?, false)
             ) do
          {:ok, [coupon]} -> {:ok, candidate_from_coupon(coupon)}
          {:ok, []} -> {:error, Error.new("INVALID_COUPON", "Coupon not found")}
          {:ok, _many} -> {:error, Error.new("INTERNAL_ERROR", "Coupon code is not unique")}
          {:error, _error} -> {:error, Error.new("INTERNAL_ERROR", "Unable to read coupon")}
        end

      _other ->
        {:error, Error.new("VALIDATION_ERROR", "Coupon code must be a string")}
    end
  end

  defp fetch_datetime(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, %DateTime{} = datetime} -> {:ok, datetime}
      _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a DateTime")}
    end
  end

  defp fetch_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a non-empty string")}
    end
  end
end
