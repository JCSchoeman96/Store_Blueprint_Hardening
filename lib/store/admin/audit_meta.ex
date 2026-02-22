defmodule Store.Admin.AuditMeta do
  @moduledoc """
  Scrubbing and size limits for audit metadata.
  """

  @max_keys 50
  @max_meta_bytes 8192
  @max_value_bytes 1024
  @redacted "[REDACTED]"
  @sensitive_keys ~w(email phone address name card bank account iban bic token secret)

  @spec sanitize(map() | nil) :: map()
  def sanitize(nil), do: %{}

  def sanitize(meta) when is_map(meta) do
    meta
    |> normalize_keys()
    |> scrub_sensitive_values()
    |> drop_oversized_values()
    |> limit_keys()
    |> limit_total_bytes()
  end

  def sanitize(_), do: %{}

  defp normalize_keys(meta) do
    meta
    |> Enum.map(fn {key, value} -> {to_string(key), normalize_value(value)} end)
    |> Map.new()
  end

  defp normalize_value(value) when is_binary(value), do: value
  defp normalize_value(value) when is_number(value), do: value
  defp normalize_value(value) when is_boolean(value), do: value
  defp normalize_value(nil), do: nil
  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_value(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_value(%Time{} = value), do: Time.to_iso8601(value)

  defp normalize_value(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.map(fn {key, nested_value} -> {to_string(key), normalize_value(nested_value)} end)
    |> Map.new()
  end

  defp normalize_value(value) when is_list(value) do
    Enum.map(value, &normalize_value/1)
  end

  defp normalize_value(value), do: inspect(value, limit: 20, printable_limit: 200)

  defp scrub_sensitive_values(meta) do
    Enum.reduce(meta, %{}, fn {key, value}, acc ->
      if sensitive_key?(key) do
        Map.put(acc, key, @redacted)
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp sensitive_key?(key) do
    key
    |> String.downcase()
    |> then(fn normalized ->
      Enum.any?(@sensitive_keys, &String.contains?(normalized, &1))
    end)
  end

  defp drop_oversized_values(meta) do
    Enum.reduce(meta, %{}, fn {key, value}, acc ->
      if value_too_large?(value) do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp value_too_large?(value) do
    value
    |> Jason.encode!()
    |> byte_size()
    |> Kernel.>(@max_value_bytes)
  rescue
    _ -> true
  end

  defp limit_keys(meta) do
    meta
    |> Enum.sort_by(fn {key, _value} -> {sensitive_priority(key), key} end)
    |> Enum.take(@max_keys)
    |> Map.new()
  end

  defp limit_total_bytes(meta) do
    meta
    |> Enum.sort_by(fn {key, _value} -> {sensitive_priority(key), key} end)
    |> Enum.reduce({%{}, 0}, fn {key, value}, {acc, size} ->
      encoded = Jason.encode!(%{key => value})
      entry_size = byte_size(encoded)

      if size + entry_size <= @max_meta_bytes do
        {Map.put(acc, key, value), size + entry_size}
      else
        {acc, size}
      end
    end)
    |> elem(0)
  end

  defp sensitive_priority(key) do
    if sensitive_key?(key), do: 0, else: 1
  end
end
