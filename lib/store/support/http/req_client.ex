defmodule Store.Support.HTTP.ReqClient do
  @moduledoc """
  Central wrapper around `Req` for outbound HTTP.

  All outbound HTTP MUST go through this module.
  """

  @default_timeout 5_000
  @safe_method_max_retries 2
  @base_retry_delay_ms 1_000
  @max_retry_delay_ms 8_000

  @type method :: :get | :post | :put | :patch | :delete | :head

  @spec request(method(), keyword()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(method, opts) when is_atom(method) and is_list(opts) do
    method
    |> build(opts)
    |> Req.request()
  end

  @spec build(method(), keyword()) :: Req.Request.t()
  def build(method, opts) when is_atom(method) and is_list(opts) do
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)

    opts =
      opts
      |> Keyword.put_new(:receive_timeout, timeout)
      |> Keyword.put_new(:connect_options, timeout: timeout)
      |> Keyword.put_new(:method, method)
      |> put_retry_policy(method)

    Req.new(opts)
  end

  @spec get(String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def get(url, opts \\ []) when is_binary(url) and is_list(opts) do
    request(:get, Keyword.put(opts, :url, url))
  end

  @spec post(String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def post(url, opts \\ []) when is_binary(url) and is_list(opts) do
    request(:post, Keyword.put(opts, :url, url))
  end

  # Default retries are enabled only for idempotent safe methods (GET/HEAD).
  # Non-idempotent "money flows" (POST/PUT/DELETE/PATCH) are non-retrying by default (false).
  # If a non-GET call is truly idempotent, it must opt-in explicitly with a comment.
  defp put_retry_policy(opts, method) do
    if Keyword.has_key?(opts, :retry) do
      opts
    else
      if method in [:get, :head] do
        opts
        |> Keyword.put(:retry, :safe_transient)
        |> Keyword.put_new(:max_retries, @safe_method_max_retries)
        |> Keyword.put_new(:retry_delay, &retry_delay_with_jitter/1)
      else
        Keyword.put(opts, :retry, false)
      end
    end
  end

  @spec retry_delay_with_jitter(non_neg_integer()) :: non_neg_integer()
  def retry_delay_with_jitter(retry_count) when is_integer(retry_count) and retry_count >= 0 do
    delay =
      2
      |> Integer.pow(retry_count)
      |> Kernel.*(@base_retry_delay_ms)
      |> min(@max_retry_delay_ms)

    # Keep delay between 90%-100% of the capped exponential delay.
    jitter_reduction = trunc(delay * (0.10 * :rand.uniform()))
    max(delay - jitter_reduction, 0)
  end
end
