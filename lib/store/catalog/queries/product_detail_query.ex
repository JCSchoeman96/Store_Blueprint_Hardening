defmodule Store.Catalog.Queries.ProductDetailQuery do
  @moduledoc """
  Typed storefront product-detail contract including option selections by slug.
  """

  alias Store.Support.Errors.Error

  @allowed_keys MapSet.new([
                  "slug",
                  :slug,
                  "selection",
                  :selection
                ])

  @enforce_keys [:slug, :selection]
  defstruct [:slug, :selection]

  @type t :: %__MODULE__{
          slug: String.t(),
          selection: %{optional(String.t()) => String.t()}
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, slug} <- parse_slug(params),
         {:ok, selection} <- parse_selection(params) do
      {:ok, %__MODULE__{slug: slug, selection: selection}}
    end
  end

  def new(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}

  defp validate_keys(params) do
    unknown =
      params
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(@allowed_keys, &1))

    case unknown do
      [] ->
        :ok

      _ ->
        {:error,
         Error.new(
           "VALIDATION_ERROR",
           "unknown params: #{Enum.map_join(unknown, ", ", &to_string/1)}"
         )}
    end
  end

  defp parse_slug(params) do
    slug = Map.get(params, :slug) || Map.get(params, "slug")

    cond do
      not is_binary(slug) ->
        {:error, Error.new("VALIDATION_ERROR", "slug is required")}

      not valid_slug?(slug) ->
        {:error, Error.new("VALIDATION_ERROR", "slug must be lowercase URL-safe")}

      true ->
        {:ok, String.trim(slug)}
    end
  end

  defp parse_selection(params) do
    selection = Map.get(params, :selection) || Map.get(params, "selection") || %{}

    case selection do
      selection when is_map(selection) ->
        Enum.reduce_while(selection, {:ok, %{}}, &reduce_selection_entry/2)

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "selection must be a map")}
    end
  end

  defp reduce_selection_entry({option_slug, value_slug}, {:ok, acc}) do
    case parse_selection_entry(option_slug, value_slug) do
      {:ok, {_normalized_option_slug, nil}} ->
        {:cont, {:ok, acc}}

      {:ok, {normalized_option_slug, normalized_value_slug}} ->
        {:cont, {:ok, Map.put(acc, normalized_option_slug, normalized_value_slug)}}

      {:error, error} ->
        {:halt, {:error, error}}
    end
  end

  defp parse_selection_entry(option_slug, value_slug) do
    with {:ok, option_slug} <- normalize_slug(option_slug, "option key"),
         {:ok, value_slug} <- normalize_optional_slug(value_slug, "option value") do
      {:ok, {option_slug, value_slug}}
    end
  end

  defp normalize_slug(value, label) do
    value = value |> to_string() |> String.trim()

    if valid_slug?(value) do
      {:ok, value}
    else
      {:error, Error.new("VALIDATION_ERROR", "#{label} must be lowercase URL-safe")}
    end
  end

  defp normalize_optional_slug(nil, _label), do: {:ok, nil}
  defp normalize_optional_slug("", _label), do: {:ok, nil}

  defp normalize_optional_slug(value, label) do
    value = value |> to_string() |> String.trim()

    if valid_slug?(value) do
      {:ok, value}
    else
      {:error, Error.new("VALIDATION_ERROR", "#{label} must be lowercase URL-safe")}
    end
  end

  defp valid_slug?(value) when is_binary(value) do
    Regex.match?(~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/, value)
  end

  defp valid_slug?(_value), do: false
end
