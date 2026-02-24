defmodule Store.Support.HTTP.ReqClientTest do
  use ExUnit.Case, async: true

  alias Store.Support.HTTP.ReqClient

  @safe_method_max_retries 2
  @base_retry_delay_ms 1_000
  @max_retry_delay_ms 8_000

  test "builds a request with default timeout" do
    # Smoke test: calling our wrapper doesn't raise and returns {:error, _} for bad URL.
    assert {:error, _} =
             ReqClient.get("http://localhost:invalid", receive_timeout: 1, retry: false)
  end

  test "applies default timeouts of 5 seconds" do
    req = ReqClient.build(:get, [])
    assert req.options.receive_timeout == 5_000
    assert req.options.connect_options[:timeout] == 5_000
  end

  test "pins retry policy to safe_transient with bounded retries for GET/HEAD" do
    get_request = ReqClient.build(:get, [])
    head_request = ReqClient.build(:head, [])

    assert get_request.options.retry == :safe_transient
    assert get_request.options.max_retries == @safe_method_max_retries
    assert is_function(get_request.options.retry_delay, 1)

    assert head_request.options.retry == :safe_transient
    assert head_request.options.max_retries == @safe_method_max_retries
    assert is_function(head_request.options.retry_delay, 1)
  end

  test "pins retry policy to false for mutating methods" do
    assert ReqClient.build(:post, []).options.retry == false
    assert ReqClient.build(:put, []).options.retry == false
    assert ReqClient.build(:patch, []).options.retry == false
    assert ReqClient.build(:delete, []).options.retry == false
  end

  test "allows explicit opt-out or opt-in of retry" do
    assert ReqClient.build(:get, retry: false).options.retry == false
    assert ReqClient.build(:post, retry: true).options.retry == true
  end

  test "retry_delay_with_jitter keeps delay in bounded range" do
    assert_delay_within_range(ReqClient.retry_delay_with_jitter(0), @base_retry_delay_ms)
    assert_delay_within_range(ReqClient.retry_delay_with_jitter(1), @base_retry_delay_ms * 2)
    assert_delay_within_range(ReqClient.retry_delay_with_jitter(6), @max_retry_delay_ms)
  end

  defp assert_delay_within_range(delay, cap) do
    min_delay = trunc(cap * 0.90)
    assert is_integer(delay)
    assert delay >= min_delay
    assert delay <= cap
  end
end
