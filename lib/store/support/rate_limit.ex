defmodule Store.Support.RateLimit do
  @moduledoc """
  Behaviour-backed rate-limiting seam.

  Phase-24 pin:
  - ETS backend is the active default.
  - Redis backend wiring exists but is optional and non-forcing.
  """

  @type decision :: :allow | :deny
  @type scope :: atom() | String.t()
  @type key :: String.t()

  @callback allow?(scope(), key(), pos_integer(), pos_integer(), keyword()) ::
              {:ok, decision()} | {:error, term()}

  @spec allow?(scope(), key(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, decision()} | {:error, term()}
  def allow?(scope, key, limit, window_seconds, opts \\ [])

  def allow?(scope, key, limit, window_seconds, opts)
      when (is_atom(scope) or is_binary(scope)) and is_binary(key) and is_integer(limit) and
             limit > 0 and is_integer(window_seconds) and window_seconds > 0 and is_list(opts) do
    backend().allow?(scope, key, limit, window_seconds, opts)
  end

  def allow?(_scope, _key, _limit, _window_seconds, _opts),
    do: {:error, :invalid_rate_limit_args}

  @spec backend() :: module()
  def backend do
    Application.get_env(:store, :rate_limit, [])
    |> Keyword.get(:backend, Store.Support.RateLimit.EtsBackend)
  end
end
