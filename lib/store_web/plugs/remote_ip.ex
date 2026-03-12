defmodule StoreWeb.Plugs.RemoteIp do
  @moduledoc """
  Restores the real client IP from trusted Cloudflare proxy headers.
  """

  @behaviour Plug

  import Bitwise

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    config = Application.get_env(:store, :trusted_proxy, [])
    headers = Keyword.get(config, :headers, ["cf-connecting-ip", "x-forwarded-for"])
    proxies = Keyword.get(config, :proxies, [])

    if trusted_proxy?(conn.remote_ip, proxies) do
      case forwarded_ip(conn.req_headers, headers) do
        {:ok, ip} ->
          Logger.metadata(remote_ip: format_ip(ip))
          %{conn | remote_ip: ip}

        :error ->
          conn
      end
    else
      conn
    end
  end

  defp forwarded_ip(headers, allowed_headers) do
    allowed_headers
    |> Enum.find_value(:error, fn header ->
      headers
      |> Enum.filter(fn {name, _value} -> name == header end)
      |> Enum.flat_map(fn {_name, value} -> String.split(value, ",", trim: true) end)
      |> Enum.map(&String.trim/1)
      |> Enum.find_value(:error, &parse_ip_result/1)
    end)
  end

  defp trusted_proxy?(ip, cidrs) when is_tuple(ip) and is_list(cidrs) do
    Enum.any?(cidrs, &cidr_contains?(&1, ip))
  end

  defp trusted_proxy?(_ip, _cidrs), do: false

  defp cidr_contains?(cidr, ip) when is_binary(cidr) and is_tuple(ip) do
    with [network, prefix_bits] <- String.split(cidr, "/", parts: 2),
         {:ok, network_ip} <- parse_ip(network),
         {prefix, ""} <- Integer.parse(prefix_bits),
         true <- same_ip_family?(network_ip, ip) do
      bits = ip_bit_size(ip)

      if prefix >= 0 and prefix <= bits do
        <<network_prefix::bitstring-size(prefix), _::bitstring>> =
          <<ip_to_int(network_ip)::unsigned-size(bits)>>

        <<ip_prefix::bitstring-size(prefix), _::bitstring>> =
          <<ip_to_int(ip)::unsigned-size(bits)>>

        network_prefix == ip_prefix
      else
        false
      end
    else
      _ -> false
    end
  end

  defp cidr_contains?(_cidr, _ip), do: false

  defp same_ip_family?({_, _, _, _}, {_, _, _, _}), do: true
  defp same_ip_family?({_, _, _, _, _, _, _, _}, {_, _, _, _, _, _, _, _}), do: true
  defp same_ip_family?(_left, _right), do: false

  defp ip_bit_size({_, _, _, _}), do: 32
  defp ip_bit_size({_, _, _, _, _, _, _, _}), do: 128

  defp ip_to_int({a, b, c, d}) do
    Enum.reduce([a, b, c, d], 0, fn segment, acc ->
      (acc <<< 8) + segment
    end)
  end

  defp ip_to_int({a, b, c, d, e, f, g, h}) do
    Enum.reduce([a, b, c, d, e, f, g, h], 0, fn segment, acc ->
      (acc <<< 16) + segment
    end)
  end

  defp parse_ip(value) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> :error
    end
  end

  defp parse_ip_result(candidate) do
    case parse_ip(candidate) do
      {:ok, ip} -> {:ok, ip}
      :error -> false
    end
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> List.to_string()
end
