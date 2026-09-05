defmodule Store.Orders.InventoryAdmission.Request do
  @moduledoc """
  Trusted, single-variant mutation intent for inventory admission.

  The constructor normalizes the two UUID identities and derives the durable
  reservation key. Operation and lease-coordination identities deliberately do not
  belong to this value.
  """

  alias Store.Support.ID.UUIDv7

  @allowed_keys MapSet.new([
                  :order_id,
                  "order_id",
                  :variant_id,
                  "variant_id",
                  :quantity,
                  "quantity",
                  :mutation_kind,
                  "mutation_kind",
                  :expiry_policy,
                  "expiry_policy"
                ])

  @server_owned_keys [
    {:reservation_key, "reservation_key", :reservation_key_is_server_derived},
    {:operation_id, "operation_id", :operation_id_is_server_generated},
    {:operation_epoch, "operation_epoch", :operation_epoch_is_server_generated},
    {:identity_digest, "identity_digest", :identity_digest_is_server_derived}
  ]

  @mutation_kinds [:reserve, :adjust]
  @enforce_keys [
    :order_id,
    :variant_id,
    :quantity,
    :reservation_key,
    :identity_digest,
    :request_fingerprint
  ]
  defstruct [
    :order_id,
    :variant_id,
    :quantity,
    :reservation_key,
    :identity_digest,
    :request_fingerprint,
    mutation_kind: :reserve,
    expiry_policy: :default
  ]

  @type mutation_kind :: :reserve | :adjust
  @type expiry_policy :: :default | {:ttl_seconds, non_neg_integer()}

  @type t :: %__MODULE__{
          order_id: Ecto.UUID.t(),
          variant_id: Ecto.UUID.t(),
          quantity: non_neg_integer(),
          reservation_key: String.t(),
          identity_digest: String.t(),
          request_fingerprint: String.t(),
          mutation_kind: mutation_kind(),
          expiry_policy: expiry_policy()
        }

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(%__MODULE__{} = request) do
    case validate(request) do
      :ok -> {:ok, request}
      {:error, reason} -> {:error, reason}
    end
  end

  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, order_id} <- fetch_and_normalize_uuid(params, :order_id),
         {:ok, variant_id} <- fetch_and_normalize_uuid(params, :variant_id),
         {:ok, quantity} <- fetch_quantity(params),
         {:ok, mutation_kind} <- fetch_mutation_kind(params),
         {:ok, expiry_policy} <- fetch_expiry_policy(params) do
      reservation_key = build_reservation_key(order_id, variant_id)

      {:ok,
       %__MODULE__{
         order_id: order_id,
         variant_id: variant_id,
         quantity: quantity,
         reservation_key: reservation_key,
         identity_digest: build_identity_digest(reservation_key),
         request_fingerprint:
           build_fingerprint(reservation_key, quantity, mutation_kind, expiry_policy),
         mutation_kind: mutation_kind,
         expiry_policy: expiry_policy
       }}
    end
  end

  def new(_params), do: {:error, :params_must_be_a_map}

  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, atom()}
  def new(order_id, variant_id, quantity), do: new(order_id, variant_id, quantity, [])

  @spec new(term(), term(), term(), keyword()) :: {:ok, t()} | {:error, atom()}
  def new(order_id, variant_id, quantity, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      params =
        %{order_id: order_id, variant_id: variant_id, quantity: quantity}
        |> Map.merge(Map.new(opts))

      new(params)
    else
      {:error, :options_must_be_a_keyword_list}
    end
  end

  def new(_order_id, _variant_id, _quantity, _opts),
    do: {:error, :options_must_be_a_keyword_list}

  @spec canonical_reservation_key(term(), term()) ::
          {:ok, String.t()} | {:error, :invalid_order_id | :invalid_variant_id}
  def canonical_reservation_key(order_id, variant_id) do
    with {:ok, normalized_order_id} <- normalize_uuid(order_id, :order_id),
         {:ok, normalized_variant_id} <- normalize_uuid(variant_id, :variant_id) do
      {:ok, build_reservation_key(normalized_order_id, normalized_variant_id)}
    end
  end

  @spec identity_digest(t()) :: String.t() | nil
  def identity_digest(%__MODULE__{identity_digest: identity_digest}), do: identity_digest
  def identity_digest(_request), do: nil

  @spec identity_digest_for_reservation_key(term()) ::
          {:ok, String.t()} | {:error, atom()}
  def identity_digest_for_reservation_key(reservation_key) do
    with {:ok, canonical_key} <- canonicalize_reservation_key(reservation_key) do
      {:ok, build_identity_digest(canonical_key)}
    end
  end

  @spec fingerprint_for(term(), term(), term(), term()) ::
          {:ok, String.t()} | {:error, atom()}
  def fingerprint_for(reservation_key, quantity, mutation_kind, expiry_policy) do
    with {:ok, canonical_key} <- canonicalize_reservation_key(reservation_key),
         :ok <- validate_quantity(quantity),
         :ok <- validate_mutation_kind(mutation_kind),
         :ok <- validate_expiry_policy(expiry_policy) do
      {:ok, build_fingerprint(canonical_key, quantity, mutation_kind, expiry_policy)}
    end
  end

  @spec fingerprint(t()) :: String.t() | nil
  def fingerprint(%__MODULE__{request_fingerprint: fingerprint}), do: fingerprint
  def fingerprint(_request), do: nil

  @spec valid?(term()) :: boolean()
  def valid?(request), do: match?(:ok, validate(request))

  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = request) do
    with {:ok, order_id} <- normalize_uuid(request.order_id, :order_id),
         {:ok, variant_id} <- normalize_uuid(request.variant_id, :variant_id),
         :ok <- validate_quantity(request.quantity),
         :ok <- validate_mutation_kind(request.mutation_kind),
         :ok <- validate_expiry_policy(request.expiry_policy),
         :ok <- validate_reservation_key(request, order_id, variant_id),
         :ok <- validate_identity_digest(request, order_id, variant_id) do
      validate_fingerprint(request, order_id, variant_id)
    end
  end

  def validate(_request), do: {:error, :invalid_request}

  @spec valid_mutation_kind?(term()) :: boolean()
  def valid_mutation_kind?(kind), do: kind in @mutation_kinds

  @spec valid_expiry_policy?(term()) :: boolean()
  def valid_expiry_policy?(policy) do
    match?(:ok, validate_expiry_policy(policy))
  end

  defp validate_keys(params) do
    with :ok <- validate_server_owned_keys(params) do
      validate_allowed_keys(params)
    end
  end

  defp validate_server_owned_keys(params) do
    case Enum.find(@server_owned_keys, &server_owned_key_present?(params, &1)) do
      {_atom_key, _string_key, reason} -> {:error, reason}
      nil -> :ok
    end
  end

  defp server_owned_key_present?(params, {atom_key, string_key, _reason}) do
    Map.has_key?(params, atom_key) or Map.has_key?(params, string_key)
  end

  defp validate_allowed_keys(params) do
    if Enum.all?(Map.keys(params), &MapSet.member?(@allowed_keys, &1)) do
      :ok
    else
      {:error, :unknown_request_key}
    end
  end

  defp fetch_and_normalize_uuid(params, key) do
    case fetch(params, key) do
      {:ok, value} -> normalize_uuid(value, key)
      :error -> {:error, required_reason(key)}
    end
  end

  defp fetch_quantity(params) do
    case fetch(params, :quantity) do
      {:ok, quantity} ->
        case validate_quantity(quantity) do
          :ok -> {:ok, quantity}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, :quantity_required}
    end
  end

  defp fetch_mutation_kind(params) do
    case fetch(params, :mutation_kind) do
      :error ->
        {:ok, :reserve}

      {:ok, mutation_kind} ->
        case validate_mutation_kind(mutation_kind) do
          :ok -> {:ok, mutation_kind}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp fetch_expiry_policy(params) do
    case fetch(params, :expiry_policy) do
      :error ->
        {:ok, :default}

      {:ok, expiry_policy} ->
        case validate_expiry_policy(expiry_policy) do
          :ok -> {:ok, expiry_policy}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp fetch(params, key) when is_map(params) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(params, key) -> {:ok, Map.fetch!(params, key)}
      Map.has_key?(params, string_key) -> {:ok, Map.fetch!(params, string_key)}
      true -> :error
    end
  end

  defp normalize_uuid(value, :order_id) do
    case UUIDv7.decode(value) do
      {:ok, raw16} -> {:ok, UUIDv7.encode!(raw16)}
      :error -> {:error, :invalid_order_id}
    end
  end

  defp normalize_uuid(value, :variant_id) do
    case UUIDv7.decode(value) do
      {:ok, raw16} -> {:ok, UUIDv7.encode!(raw16)}
      :error -> {:error, :invalid_variant_id}
    end
  end

  defp normalize_uuid(_value, _key), do: {:error, :invalid_uuid}

  defp validate_quantity(quantity) when is_integer(quantity) and quantity >= 0, do: :ok
  defp validate_quantity(_quantity), do: {:error, :quantity_must_be_non_negative_integer}

  defp validate_mutation_kind(kind) when kind in @mutation_kinds, do: :ok
  defp validate_mutation_kind(_kind), do: {:error, :invalid_mutation_kind}

  defp validate_expiry_policy(:default), do: :ok

  defp validate_expiry_policy({:ttl_seconds, seconds})
       when is_integer(seconds) and seconds >= 0,
       do: :ok

  defp validate_expiry_policy(_policy), do: {:error, :invalid_expiry_policy}

  defp validate_reservation_key(request, order_id, variant_id) do
    if request.reservation_key == build_reservation_key(order_id, variant_id) do
      :ok
    else
      {:error, :reservation_key_mismatch}
    end
  end

  defp validate_identity_digest(request, order_id, variant_id) do
    expected_digest = build_identity_digest(build_reservation_key(order_id, variant_id))

    if request.identity_digest == expected_digest do
      :ok
    else
      {:error, :identity_digest_mismatch}
    end
  end

  defp validate_fingerprint(request, order_id, variant_id) do
    expected_key = build_reservation_key(order_id, variant_id)

    expected_fingerprint =
      build_fingerprint(
        expected_key,
        request.quantity,
        request.mutation_kind,
        request.expiry_policy
      )

    if request.request_fingerprint == expected_fingerprint do
      :ok
    else
      {:error, :request_fingerprint_mismatch}
    end
  end

  defp required_reason(:order_id), do: :order_id_required
  defp required_reason(:variant_id), do: :variant_id_required
  defp required_reason(_key), do: :required_field_missing

  defp build_reservation_key(order_id, variant_id),
    do: "order:#{order_id}:sku:#{variant_id}"

  defp canonicalize_reservation_key(reservation_key) when is_binary(reservation_key) do
    case String.split(reservation_key, ":") do
      ["order", order_id, "sku", variant_id] ->
        case canonical_reservation_key(order_id, variant_id) do
          {:ok, ^reservation_key} -> {:ok, reservation_key}
          {:ok, _canonical_key} -> {:error, :reservation_key_not_normalized}
          {:error, _reason} -> {:error, :invalid_reservation_key}
        end

      _parts ->
        {:error, :invalid_reservation_key}
    end
  end

  defp canonicalize_reservation_key(_reservation_key), do: {:error, :invalid_reservation_key}

  defp build_identity_digest(reservation_key) do
    {:inventory_admission_identity_v1, reservation_key}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp build_fingerprint(reservation_key, quantity, mutation_kind, expiry_policy) do
    canonical_expiry_policy = canonical_expiry_policy(expiry_policy)

    {:inventory_admission_request_v1, reservation_key, quantity, Atom.to_string(mutation_kind),
     canonical_expiry_policy}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_expiry_policy(:default), do: "default"
  defp canonical_expiry_policy({:ttl_seconds, seconds}), do: "ttl_seconds:#{seconds}"
end
