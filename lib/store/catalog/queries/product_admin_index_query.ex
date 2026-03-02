defmodule Store.Catalog.Queries.ProductAdminIndexQuery do
  @moduledoc """
  Typed admin query contract for product list reads.
  """

  alias Store.Support.Errors.Error

  @allowed_sorts ~w(newest oldest title_asc title_desc)
  @allowed_statuses ~w(draft published archived)
  @allowed_keys MapSet.new([
                  "q",
                  :q,
                  "status",
                  :status,
                  "sort",
                  :sort,
                  "page",
                  :page,
                  "page_size",
                  :page_size
                ])
  @default_sort :newest
  @default_page 1
  @default_page_size 20
  @max_page_size 100

  @enforce_keys [:sort, :page, :page_size]
  defstruct [:q, :status, :sort, :page, :page_size]

  @type status_t :: :draft | :published | :archived | nil
  @type sort_t :: :newest | :oldest | :title_asc | :title_desc

  @type t :: %__MODULE__{
          q: String.t() | nil,
          status: status_t(),
          sort: sort_t(),
          page: pos_integer(),
          page_size: pos_integer()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, q} <- parse_optional_string(params, :q),
         {:ok, status} <- parse_status(params),
         {:ok, sort} <- parse_sort(params),
         {:ok, page} <- parse_positive_integer(params, :page, @default_page),
         {:ok, page_size} <- parse_positive_integer(params, :page_size, @default_page_size) do
      {:ok,
       %__MODULE__{
         q: q,
         status: status,
         sort: sort,
         page: page,
         page_size: min(page_size, @max_page_size)
       }}
    end
  end

  def new(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}

  @spec offset(t()) :: non_neg_integer()
  def offset(%__MODULE__{page: page, page_size: page_size}), do: (page - 1) * page_size

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

  defp parse_optional_string(params, key) do
    value = Map.get(params, key) || Map.get(params, Atom.to_string(key))

    case value do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      str when is_binary(str) -> {:ok, String.trim(str)}
      _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a string")}
    end
  end

  defp parse_status(params) do
    params
    |> status_param()
    |> normalize_status()
    |> validate_status()
  end

  defp status_param(params), do: Map.get(params, :status) || Map.get(params, "status")

  defp normalize_status(nil), do: nil
  defp normalize_status(""), do: nil
  defp normalize_status(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp normalize_status(str) when is_binary(str), do: String.trim(str)
  defp normalize_status(_other), do: :invalid

  defp validate_status(nil), do: {:ok, nil}

  defp validate_status(status) when status in @allowed_statuses do
    {:ok, String.to_atom(status)}
  end

  defp validate_status(_status) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "status must be one of: #{Enum.join(@allowed_statuses, ", ")}"
     )}
  end

  defp parse_sort(params) do
    value = Map.get(params, :sort) || Map.get(params, "sort")

    normalized =
      case value do
        nil -> Atom.to_string(@default_sort)
        atom when is_atom(atom) -> Atom.to_string(atom)
        str when is_binary(str) -> String.trim(str)
        _ -> nil
      end

    if normalized in @allowed_sorts do
      {:ok, String.to_atom(normalized)}
    else
      {:error,
       Error.new("VALIDATION_ERROR", "sort must be one of: #{Enum.join(@allowed_sorts, ", ")}")}
    end
  end

  defp parse_positive_integer(params, key, default) do
    value = Map.get(params, key) || Map.get(params, Atom.to_string(key))

    case value do
      nil ->
        {:ok, default}

      int when is_integer(int) and int > 0 ->
        {:ok, int}

      str when is_binary(str) ->
        case Integer.parse(str) do
          {parsed, ""} when parsed > 0 -> {:ok, parsed}
          _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a positive integer")}
        end

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "#{key} must be a positive integer")}
    end
  end
end
