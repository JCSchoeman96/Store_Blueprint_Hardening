defmodule Store.Tools.RiskAppetite do
  @moduledoc """
  Risk appetite questionnaire data and scoring logic.

  Each statement is rated 1–5 (Strongly Disagree → Strongly Agree).
  Statements with `weight: 1` are risk-seeking (higher agreement = more risk).
  Statements with `weight: -1` are risk-averse (higher agreement = less risk).

  The raw score is normalized to a 0–100 scale, then bucketed into five
  risk appetite categories.
  """

  @statements [
    %{
      id: "q1",
      text:
        "I am comfortable with investments that may lose value in the short term for potentially higher long-term returns.",
      weight: 1
    },
    %{
      id: "q2",
      text: "I prefer guaranteed returns, even if they are lower.",
      weight: -1
    },
    %{
      id: "q3",
      text: "Market volatility makes me anxious about my investments.",
      weight: -1
    },
    %{
      id: "q4",
      text: "I would invest a significant portion of my portfolio in stocks.",
      weight: 1
    },
    %{
      id: "q5",
      text: "I prioritize capital preservation over growth.",
      weight: -1
    },
    %{
      id: "q6",
      text: "I am willing to take on more risk for the chance of higher rewards.",
      weight: 1
    },
    %{
      id: "q7",
      text: "I would be comfortable if my portfolio dropped 20% in a single year.",
      weight: 1
    },
    %{
      id: "q8",
      text: "I prefer stable, predictable investment returns.",
      weight: -1
    },
    %{
      id: "q9",
      text: "I have a long time horizon and can wait for markets to recover.",
      weight: 1
    },
    %{
      id: "q10",
      text: "I would rather miss a gain than risk a loss.",
      weight: -1
    }
  ]

  @statement_count length(@statements)

  # With 10 statements rated 1-5, weight +1/-1:
  # Min raw = sum of (1*1 + 5*-1) for each type = 5*(1) + 5*(−5) = 5 − 25 = −20
  # Max raw = sum of (5*1 + 1*-1) for each type = 5*(5) + 5*(−1) = 25 − 5 = 20
  @min_raw -20
  @max_raw 20

  @spec statements() :: [map()]
  def statements, do: @statements

  @spec statement_count() :: non_neg_integer()
  def statement_count, do: @statement_count

  @doc """
  Calculate a normalized score (0–100) from a map of answers.

  Expects `answers` as `%{"q1" => 3, "q2" => 5, ...}` where values are 1–5.
  Unanswered questions are treated as 3 (neutral).
  """
  @spec calculate_score(map()) :: integer()
  def calculate_score(answers) when is_map(answers) do
    raw =
      Enum.reduce(@statements, 0, fn %{id: id, weight: weight}, acc ->
        value = get_answer_value(answers, id)
        acc + value * weight
      end)

    # Normalize from [@min_raw, @max_raw] to [0, 100]
    normalized = (raw - @min_raw) / (@max_raw - @min_raw) * 100
    round(normalized)
  end

  @doc """
  Map a normalized score (0–100) to a risk appetite category.
  """
  @spec categorize(integer()) :: String.t()
  def categorize(score) when is_integer(score) do
    cond do
      score <= 20 -> "Conservative"
      score <= 40 -> "Moderately Conservative"
      score <= 60 -> "Moderate"
      score <= 80 -> "Moderately Aggressive"
      true -> "Aggressive"
    end
  end

  @doc """
  Returns a brief description for a given risk appetite category.
  """
  @spec category_description(String.t()) :: String.t()
  def category_description(category) do
    case category do
      "Conservative" ->
        "You prefer stability and capital preservation. You are most comfortable with low-risk investments such as bonds and fixed deposits, even if returns are modest."

      "Moderately Conservative" ->
        "You lean towards safety but are open to a small allocation in growth assets. A balanced approach with a tilt towards fixed income suits you."

      "Moderate" ->
        "You are comfortable with a balanced mix of growth and stability. You accept some short-term volatility for the potential of reasonable long-term returns."

      "Moderately Aggressive" ->
        "You favour growth and are willing to accept meaningful short-term fluctuations. A portfolio weighted towards equities aligns with your outlook."

      "Aggressive" ->
        "You seek maximum growth and are comfortable with significant market swings. You have a long time horizon and high tolerance for volatility."

      _ ->
        ""
    end
  end

  @doc """
  Returns the badge color class for a given category (daisyUI).
  """
  @spec category_color(String.t()) :: String.t()
  def category_color(category) do
    case category do
      "Conservative" -> "badge-info"
      "Moderately Conservative" -> "badge-info"
      "Moderate" -> "badge-warning"
      "Moderately Aggressive" -> "badge-error"
      "Aggressive" -> "badge-error"
      _ -> "badge-ghost"
    end
  end

  @spec all_answered?(map()) :: boolean()
  def all_answered?(answers) when is_map(answers) do
    Enum.all?(@statements, fn %{id: id} ->
      value = get_answer_value(answers, id)
      value >= 1 and value <= 5
    end)
  end

  defp get_answer_value(answers, id) do
    raw = Map.get(answers, id) || Map.get(answers, to_string(id))

    case raw do
      v when is_integer(v) and v >= 1 and v <= 5 -> v
      v when is_binary(v) -> parse_answer_int(v)
      _ -> 3
    end
  end

  defp parse_answer_int(str) do
    case Integer.parse(str) do
      {v, ""} when v >= 1 and v <= 5 -> v
      _ -> 3
    end
  end
end
