defmodule Store.Orders.InventoryAdmission.Operation.Deadline do
  @moduledoc false

  @allowed_keys MapSet.new([
                  :db_deadline,
                  :lease_deadline,
                  :recovery_deadline,
                  :safety_margin
                ])

  @enforce_keys [:db_deadline, :lease_deadline, :recovery_deadline, :safety_margin]
  defstruct [:db_deadline, :lease_deadline, :recovery_deadline, :safety_margin]

  @type t :: %__MODULE__{
          db_deadline: non_neg_integer(),
          lease_deadline: non_neg_integer(),
          recovery_deadline: non_neg_integer(),
          safety_margin: non_neg_integer()
        }

  @spec new(map() | t()) :: {:ok, t()} | {:error, atom()}
  def new(%__MODULE__{} = deadline) do
    case validate(deadline) do
      :ok -> {:ok, deadline}
      {:error, reason} -> {:error, reason}
    end
  end

  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, db_deadline} <- fetch_non_negative_integer(params, :db_deadline),
         {:ok, lease_deadline} <- fetch_non_negative_integer(params, :lease_deadline),
         {:ok, recovery_deadline} <- fetch_non_negative_integer(params, :recovery_deadline),
         {:ok, safety_margin} <- fetch_non_negative_integer(params, :safety_margin),
         :ok <- validate_order(db_deadline, lease_deadline, recovery_deadline, safety_margin) do
      {:ok,
       %__MODULE__{
         db_deadline: db_deadline,
         lease_deadline: lease_deadline,
         recovery_deadline: recovery_deadline,
         safety_margin: safety_margin
       }}
    end
  end

  def new(_params), do: {:error, :invalid_deadline}

  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{
        db_deadline: db_deadline,
        lease_deadline: lease_deadline,
        recovery_deadline: recovery_deadline,
        safety_margin: safety_margin
      }) do
    with :ok <- validate_non_negative_integer(db_deadline),
         :ok <- validate_non_negative_integer(lease_deadline),
         :ok <- validate_non_negative_integer(recovery_deadline),
         :ok <- validate_non_negative_integer(safety_margin) do
      validate_order(db_deadline, lease_deadline, recovery_deadline, safety_margin)
    end
  end

  def validate(_deadline), do: {:error, :invalid_deadline}

  @spec valid?(term()) :: boolean()
  def valid?(deadline), do: match?(:ok, validate(deadline))

  @spec remaining_db_budget(t(), non_neg_integer()) :: non_neg_integer()
  def remaining_db_budget(%__MODULE__{db_deadline: db_deadline}, monotonic_now)
      when is_integer(monotonic_now) and monotonic_now >= 0 do
    max(db_deadline - monotonic_now, 0)
  end

  @spec expired?(t(), non_neg_integer()) :: boolean()
  def expired?(%__MODULE__{} = deadline, monotonic_now)
      when is_integer(monotonic_now) and monotonic_now >= 0 do
    remaining_db_budget(deadline, monotonic_now) == 0
  end

  defp validate_keys(params) do
    if Enum.all?(Map.keys(params), &MapSet.member?(@allowed_keys, &1)) do
      :ok
    else
      {:error, :unknown_deadline_key}
    end
  end

  defp fetch_non_negative_integer(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} ->
        case validate_non_negative_integer(value) do
          :ok -> {:ok, value}
          {:error, _reason} -> {:error, invalid_deadline_field(key)}
        end

      :error ->
        {:error, invalid_deadline_field(key)}
    end
  end

  defp validate_non_negative_integer(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_negative_integer(_value), do: {:error, :not_non_negative_integer}

  defp validate_order(db_deadline, lease_deadline, recovery_deadline, safety_margin) do
    cond do
      lease_deadline < db_deadline + safety_margin ->
        {:error, :lease_deadline_before_db_deadline_plus_safety_margin}

      recovery_deadline < lease_deadline ->
        {:error, :recovery_deadline_before_lease_deadline}

      true ->
        :ok
    end
  end

  defp invalid_deadline_field(:db_deadline), do: :invalid_db_deadline
  defp invalid_deadline_field(:lease_deadline), do: :invalid_lease_deadline
  defp invalid_deadline_field(:recovery_deadline), do: :invalid_recovery_deadline
  defp invalid_deadline_field(:safety_margin), do: :invalid_safety_margin
end

defmodule Store.Orders.InventoryAdmission.Operation.Mutation do
  @moduledoc false

  alias Store.Orders.InventoryAdmission.Request
  alias Store.Support.ID.UUIDv7

  @allowed_keys MapSet.new([
                  :variant_id,
                  :kind,
                  :desired_quantity,
                  :expiry_policy,
                  :expires_at,
                  :now
                ])

  @enforce_keys [:variant_id, :kind, :desired_quantity, :expiry_policy]
  defstruct [:variant_id, :kind, :desired_quantity, :expiry_policy, :expires_at, :now]

  @type t :: %__MODULE__{
          variant_id: Ecto.UUID.t(),
          kind: Request.mutation_kind(),
          desired_quantity: non_neg_integer(),
          expiry_policy: Request.expiry_policy(),
          expires_at: DateTime.t() | nil,
          now: DateTime.t() | nil
        }

  @spec new(Request.t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def new(request, opts \\ [])

  def new(%Request{} = request, opts) when is_list(opts) do
    if Keyword.keyword?(opts) and valid_options?(opts) do
      expires_at = Keyword.get(opts, :expires_at)
      now = Keyword.get(opts, :now)

      with :ok <- validate_optional_datetime(expires_at),
           :ok <- validate_optional_datetime(now) do
        {:ok,
         %__MODULE__{
           variant_id: request.variant_id,
           kind: request.mutation_kind,
           desired_quantity: request.quantity,
           expiry_policy: request.expiry_policy,
           expires_at: expires_at,
           now: now
         }}
      end
    else
      {:error, :invalid_mutation_options}
    end
  end

  def new(_request, _opts), do: {:error, :invalid_mutation}

  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{
        variant_id: variant_id,
        kind: kind,
        desired_quantity: desired_quantity,
        expiry_policy: expiry_policy,
        expires_at: expires_at,
        now: now
      }) do
    with {:ok, normalized_variant_id} <- normalize_variant_id(variant_id),
         :ok <- validate_kind(kind),
         :ok <- validate_quantity(desired_quantity),
         :ok <- validate_expiry_policy(expiry_policy),
         :ok <- validate_optional_datetime(expires_at),
         :ok <- validate_optional_datetime(now) do
      validate_normalized_variant_id(variant_id, normalized_variant_id)
    end
  end

  def validate(_mutation), do: {:error, :invalid_mutation}

  @spec valid?(term()) :: boolean()
  def valid?(mutation), do: match?(:ok, validate(mutation))

  defp valid_options?(opts) do
    Enum.all?(Keyword.keys(opts), &MapSet.member?(@allowed_keys, &1))
  end

  defp normalize_variant_id(variant_id) do
    case UUIDv7.decode(variant_id) do
      {:ok, raw16} -> {:ok, UUIDv7.encode!(raw16)}
      :error -> {:error, :invalid_mutation_variant_id}
    end
  end

  defp validate_normalized_variant_id(variant_id, normalized_variant_id) do
    if variant_id == normalized_variant_id do
      :ok
    else
      {:error, :mutation_variant_id_not_normalized}
    end
  end

  defp validate_kind(kind) do
    if Request.valid_mutation_kind?(kind), do: :ok, else: {:error, :invalid_mutation_kind}
  end

  defp validate_quantity(quantity) when is_integer(quantity) and quantity >= 0, do: :ok
  defp validate_quantity(_quantity), do: {:error, :invalid_mutation_quantity}

  defp validate_expiry_policy(policy) do
    if Request.valid_expiry_policy?(policy), do: :ok, else: {:error, :invalid_expiry_policy}
  end

  defp validate_optional_datetime(nil), do: :ok
  defp validate_optional_datetime(%DateTime{}), do: :ok
  defp validate_optional_datetime(_value), do: {:error, :invalid_mutation_datetime}
end

defmodule Store.Orders.InventoryAdmission.Operation.ReservationFacts do
  @moduledoc false

  alias Store.Support.ID.UUIDv7

  @allowed_keys MapSet.new([
                  :id,
                  :quantity,
                  :state,
                  :expires_at,
                  :consumed_at,
                  :expired_at,
                  :cancelled_at,
                  :version
                ])
  @states [:active, :consumed, :expired, :cancelled]

  @enforce_keys [:id, :quantity, :state, :expires_at, :version]
  defstruct [
    :id,
    :quantity,
    :state,
    :expires_at,
    :consumed_at,
    :expired_at,
    :cancelled_at,
    :version
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          quantity: non_neg_integer(),
          state: :active | :consumed | :expired | :cancelled,
          expires_at: DateTime.t(),
          consumed_at: DateTime.t() | nil,
          expired_at: DateTime.t() | nil,
          cancelled_at: DateTime.t() | nil,
          version: pos_integer()
        }

  @spec new(map() | t()) :: {:ok, t()} | {:error, atom()}
  def new(%__MODULE__{} = facts) do
    case validate(facts) do
      :ok -> {:ok, facts}
      {:error, reason} -> {:error, reason}
    end
  end

  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, id} <- fetch_id(params),
         {:ok, quantity} <- fetch_non_negative_integer(params, :quantity),
         {:ok, state} <- fetch_state(params),
         {:ok, expires_at} <- fetch_datetime(params, :expires_at),
         {:ok, consumed_at} <- fetch_optional_datetime(params, :consumed_at),
         {:ok, expired_at} <- fetch_optional_datetime(params, :expired_at),
         {:ok, cancelled_at} <- fetch_optional_datetime(params, :cancelled_at),
         {:ok, version} <- fetch_positive_integer(params, :version) do
      {:ok,
       %__MODULE__{
         id: id,
         quantity: quantity,
         state: state,
         expires_at: expires_at,
         consumed_at: consumed_at,
         expired_at: expired_at,
         cancelled_at: cancelled_at,
         version: version
       }}
    end
  end

  def new(_params), do: {:error, :invalid_reservation_facts}

  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = facts) do
    with {:ok, normalized_id} <- normalize_id(facts.id),
         :ok <- validate_quantity(facts.quantity),
         :ok <- validate_state(facts.state),
         :ok <- validate_datetime(facts.expires_at),
         :ok <- validate_optional_datetime(facts.consumed_at),
         :ok <- validate_optional_datetime(facts.expired_at),
         :ok <- validate_optional_datetime(facts.cancelled_at),
         :ok <- validate_version(facts.version) do
      validate_normalized_id(facts.id, normalized_id)
    end
  end

  def validate(_facts), do: {:error, :invalid_reservation_facts}

  @spec validate_existing(term()) :: :ok | {:error, atom()}
  def validate_existing(%__MODULE__{id: id} = facts) when not is_nil(id), do: validate(facts)
  def validate_existing(_facts), do: {:error, :pre_reservation_id_required}

  @spec valid?(term()) :: boolean()
  def valid?(facts), do: match?(:ok, validate(facts))

  defp validate_keys(params) do
    if Enum.all?(Map.keys(params), &MapSet.member?(@allowed_keys, &1)) do
      :ok
    else
      {:error, :unknown_reservation_fact_key}
    end
  end

  defp fetch_id(params) do
    case Map.fetch(params, :id) do
      {:ok, value} -> normalize_id(value)
      :error -> {:error, :reservation_id_required}
    end
  end

  defp normalize_id(nil), do: {:ok, nil}

  defp normalize_id(value) do
    case UUIDv7.decode(value) do
      {:ok, raw16} -> {:ok, UUIDv7.encode!(raw16)}
      :error -> {:error, :invalid_reservation_id}
    end
  end

  defp validate_normalized_id(nil, nil), do: :ok
  defp validate_normalized_id(id, normalized_id) when id == normalized_id, do: :ok
  defp validate_normalized_id(_id, _normalized_id), do: {:error, :reservation_id_not_normalized}

  defp fetch_non_negative_integer(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> {:error, invalid_field(key)}
      :error -> {:error, invalid_field(key)}
    end
  end

  defp fetch_positive_integer(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, invalid_field(key)}
      :error -> {:error, invalid_field(key)}
    end
  end

  defp fetch_state(params) do
    case Map.fetch(params, :state) do
      {:ok, state} when state in @states -> {:ok, state}
      {:ok, _state} -> {:error, :invalid_reservation_state}
      :error -> {:error, :reservation_state_required}
    end
  end

  defp fetch_datetime(params, key) do
    case Map.fetch(params, key) do
      {:ok, %DateTime{} = value} -> {:ok, value}
      {:ok, _value} -> {:error, invalid_field(key)}
      :error -> {:error, invalid_field(key)}
    end
  end

  defp fetch_optional_datetime(params, key) do
    case Map.fetch(params, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, %DateTime{} = value} -> {:ok, value}
      {:ok, _value} -> {:error, invalid_field(key)}
    end
  end

  defp validate_quantity(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_quantity(_value), do: {:error, :invalid_reservation_quantity}

  defp validate_state(state) when state in @states, do: :ok
  defp validate_state(_state), do: {:error, :invalid_reservation_state}

  defp validate_datetime(%DateTime{}), do: :ok
  defp validate_datetime(_value), do: {:error, :invalid_reservation_expiry}

  defp validate_optional_datetime(nil), do: :ok
  defp validate_optional_datetime(%DateTime{}), do: :ok
  defp validate_optional_datetime(_value), do: {:error, :invalid_reservation_timestamp}

  defp validate_version(value) when is_integer(value) and value > 0, do: :ok
  defp validate_version(_value), do: {:error, :invalid_reservation_version}

  defp invalid_field(:quantity), do: :invalid_reservation_quantity
  defp invalid_field(:expires_at), do: :invalid_reservation_expiry
  defp invalid_field(:consumed_at), do: :invalid_reservation_timestamp
  defp invalid_field(:expired_at), do: :invalid_reservation_timestamp
  defp invalid_field(:cancelled_at), do: :invalid_reservation_timestamp
  defp invalid_field(:version), do: :invalid_reservation_version
end

defmodule Store.Orders.InventoryAdmission.Operation.InventoryFacts do
  @moduledoc false

  alias Store.Support.ID.UUIDv7

  @allowed_keys MapSet.new([
                  :variant_id,
                  :stock_on_hand,
                  :reserved_count,
                  :allow_oversell,
                  :version
                ])

  @enforce_keys [:variant_id, :stock_on_hand, :reserved_count, :allow_oversell, :version]
  defstruct [:variant_id, :stock_on_hand, :reserved_count, :allow_oversell, :version]

  @type t :: %__MODULE__{
          variant_id: Ecto.UUID.t(),
          stock_on_hand: non_neg_integer(),
          reserved_count: non_neg_integer(),
          allow_oversell: boolean(),
          version: pos_integer()
        }

  @spec new(map() | t()) :: {:ok, t()} | {:error, atom()}
  def new(%__MODULE__{} = facts) do
    case validate(facts) do
      :ok -> {:ok, facts}
      {:error, reason} -> {:error, reason}
    end
  end

  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, variant_id} <- fetch_variant_id(params),
         {:ok, stock_on_hand} <- fetch_non_negative_integer(params, :stock_on_hand),
         {:ok, reserved_count} <- fetch_non_negative_integer(params, :reserved_count),
         {:ok, allow_oversell} <- fetch_boolean(params, :allow_oversell),
         {:ok, version} <- fetch_positive_integer(params, :version) do
      {:ok,
       %__MODULE__{
         variant_id: variant_id,
         stock_on_hand: stock_on_hand,
         reserved_count: reserved_count,
         allow_oversell: allow_oversell,
         version: version
       }}
    end
  end

  def new(_params), do: {:error, :invalid_inventory_facts}

  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = facts) do
    with {:ok, normalized_variant_id} <- normalize_variant_id(facts.variant_id),
         :ok <- validate_non_negative_integer(facts.stock_on_hand, :stock_on_hand),
         :ok <- validate_non_negative_integer(facts.reserved_count, :reserved_count),
         :ok <- validate_boolean(facts.allow_oversell),
         :ok <- validate_positive_integer(facts.version, :version) do
      validate_normalized_variant_id(facts.variant_id, normalized_variant_id)
    end
  end

  def validate(_facts), do: {:error, :invalid_inventory_facts}

  @spec valid?(term()) :: boolean()
  def valid?(facts), do: match?(:ok, validate(facts))

  defp validate_keys(params) do
    if Enum.all?(Map.keys(params), &MapSet.member?(@allowed_keys, &1)) do
      :ok
    else
      {:error, :unknown_inventory_fact_key}
    end
  end

  defp fetch_variant_id(params) do
    case Map.fetch(params, :variant_id) do
      {:ok, value} -> normalize_variant_id(value)
      :error -> {:error, :inventory_variant_id_required}
    end
  end

  defp normalize_variant_id(value) do
    case UUIDv7.decode(value) do
      {:ok, raw16} -> {:ok, UUIDv7.encode!(raw16)}
      :error -> {:error, :invalid_inventory_variant_id}
    end
  end

  defp validate_normalized_variant_id(variant_id, normalized_variant_id)
       when variant_id == normalized_variant_id,
       do: :ok

  defp validate_normalized_variant_id(_variant_id, _normalized_variant_id),
    do: {:error, :inventory_variant_id_not_normalized}

  defp fetch_non_negative_integer(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> {:error, invalid_field(key)}
      :error -> {:error, invalid_field(key)}
    end
  end

  defp fetch_positive_integer(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, invalid_field(key)}
      :error -> {:error, invalid_field(key)}
    end
  end

  defp fetch_boolean(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:error, :invalid_inventory_allow_oversell}
      :error -> {:error, :inventory_allow_oversell_required}
    end
  end

  defp validate_non_negative_integer(value, _key)
       when is_integer(value) and value >= 0,
       do: :ok

  defp validate_non_negative_integer(_value, :stock_on_hand),
    do: {:error, :invalid_inventory_stock_on_hand}

  defp validate_non_negative_integer(_value, :reserved_count),
    do: {:error, :invalid_inventory_reserved_count}

  defp validate_positive_integer(value, _key) when is_integer(value) and value > 0, do: :ok
  defp validate_positive_integer(_value, :version), do: {:error, :invalid_inventory_version}

  defp validate_boolean(value) when is_boolean(value), do: :ok
  defp validate_boolean(_value), do: {:error, :invalid_inventory_allow_oversell}

  defp invalid_field(:stock_on_hand), do: :invalid_inventory_stock_on_hand
  defp invalid_field(:reserved_count), do: :invalid_inventory_reserved_count
  defp invalid_field(:version), do: :invalid_inventory_version
end

defmodule Store.Orders.InventoryAdmission.Operation.Pre do
  @moduledoc false

  alias Store.Orders.InventoryAdmission.Operation.{InventoryFacts, ReservationFacts}

  @allowed_keys MapSet.new([:reservation, :inventory])
  @enforce_keys [:reservation, :inventory]
  defstruct [:reservation, :inventory]

  @type reservation :: :absent | ReservationFacts.t()
  @type t :: %__MODULE__{reservation: reservation(), inventory: InventoryFacts.t()}

  @spec new(map() | t()) :: {:ok, t()} | {:error, atom()}
  def new(%__MODULE__{} = facts) do
    case validate(facts) do
      :ok -> {:ok, facts}
      {:error, reason} -> {:error, reason}
    end
  end

  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, reservation} <- fetch_reservation(params),
         {:ok, inventory} <- fetch_inventory(params) do
      {:ok, %__MODULE__{reservation: reservation, inventory: inventory}}
    end
  end

  def new(_params), do: {:error, :invalid_pre_facts}

  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{reservation: reservation, inventory: inventory}) do
    with :ok <- validate_reservation(reservation) do
      InventoryFacts.validate(inventory)
    end
  end

  def validate(_facts), do: {:error, :invalid_pre_facts}

  @spec valid?(term()) :: boolean()
  def valid?(facts), do: match?(:ok, validate(facts))

  defp validate_keys(params) do
    if Enum.all?(Map.keys(params), &MapSet.member?(@allowed_keys, &1)) do
      :ok
    else
      {:error, :unknown_pre_fact_key}
    end
  end

  defp fetch_reservation(params) do
    case Map.fetch(params, :reservation) do
      {:ok, :absent} ->
        {:ok, :absent}

      {:ok, %ReservationFacts{} = reservation} ->
        validate_existing_reservation(reservation)

      {:ok, reservation} when is_map(reservation) ->
        reservation
        |> ReservationFacts.new()
        |> validate_existing_reservation_result()

      {:ok, _reservation} ->
        {:error, :invalid_pre_reservation}

      :error ->
        {:error, :pre_reservation_required}
    end
  end

  defp fetch_inventory(params) do
    case Map.fetch(params, :inventory) do
      {:ok, %InventoryFacts{} = inventory} ->
        case InventoryFacts.validate(inventory) do
          :ok -> {:ok, inventory}
          {:error, reason} -> {:error, reason}
        end

      {:ok, inventory} when is_map(inventory) ->
        InventoryFacts.new(inventory)

      {:ok, _inventory} ->
        {:error, :invalid_pre_inventory}

      :error ->
        {:error, :pre_inventory_required}
    end
  end

  defp validate_existing_reservation(%ReservationFacts{} = reservation) do
    case ReservationFacts.validate_existing(reservation) do
      :ok -> {:ok, reservation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_existing_reservation_result({:ok, reservation}),
    do: validate_existing_reservation(reservation)

  defp validate_existing_reservation_result({:error, reason}), do: {:error, reason}

  defp validate_reservation(:absent), do: :ok

  defp validate_reservation(%ReservationFacts{} = reservation),
    do: ReservationFacts.validate_existing(reservation)

  defp validate_reservation(_reservation), do: {:error, :invalid_pre_reservation}
end

defmodule Store.Orders.InventoryAdmission.Operation.Post do
  @moduledoc false

  alias Store.Orders.InventoryAdmission.Operation.{InventoryFacts, ReservationFacts}

  @allowed_keys MapSet.new([:reservation, :inventory])
  @enforce_keys [:reservation, :inventory]
  defstruct [:reservation, :inventory]

  @type reservation :: :absent | ReservationFacts.t()
  @type t :: %__MODULE__{reservation: reservation(), inventory: InventoryFacts.t()}

  @spec new(map() | t()) :: {:ok, t()} | {:error, atom()}
  def new(%__MODULE__{} = facts) do
    case validate(facts) do
      :ok -> {:ok, facts}
      {:error, reason} -> {:error, reason}
    end
  end

  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, reservation} <- fetch_reservation(params),
         {:ok, inventory} <- fetch_inventory(params) do
      {:ok, %__MODULE__{reservation: reservation, inventory: inventory}}
    end
  end

  def new(_params), do: {:error, :invalid_post_facts}

  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{reservation: reservation, inventory: inventory}) do
    with :ok <- validate_reservation(reservation) do
      InventoryFacts.validate(inventory)
    end
  end

  def validate(_facts), do: {:error, :invalid_post_facts}

  @spec valid?(term()) :: boolean()
  def valid?(facts), do: match?(:ok, validate(facts))

  defp validate_keys(params) do
    if Enum.all?(Map.keys(params), &MapSet.member?(@allowed_keys, &1)) do
      :ok
    else
      {:error, :unknown_post_fact_key}
    end
  end

  defp fetch_reservation(params) do
    case Map.fetch(params, :reservation) do
      {:ok, :absent} ->
        {:ok, :absent}

      {:ok, %ReservationFacts{} = reservation} ->
        case ReservationFacts.validate(reservation) do
          :ok -> {:ok, reservation}
          {:error, reason} -> {:error, reason}
        end

      {:ok, reservation} when is_map(reservation) ->
        ReservationFacts.new(reservation)

      {:ok, _reservation} ->
        {:error, :invalid_post_reservation}

      :error ->
        {:error, :post_reservation_required}
    end
  end

  defp fetch_inventory(params) do
    case Map.fetch(params, :inventory) do
      {:ok, %InventoryFacts{} = inventory} ->
        case InventoryFacts.validate(inventory) do
          :ok -> {:ok, inventory}
          {:error, reason} -> {:error, reason}
        end

      {:ok, inventory} when is_map(inventory) ->
        InventoryFacts.new(inventory)

      {:ok, _inventory} ->
        {:error, :invalid_post_inventory}

      :error ->
        {:error, :post_inventory_required}
    end
  end

  defp validate_reservation(:absent), do: :ok

  defp validate_reservation(%ReservationFacts{} = reservation),
    do: ReservationFacts.validate(reservation)

  defp validate_reservation(_reservation), do: {:error, :invalid_post_reservation}
end

defmodule Store.Orders.InventoryAdmission.Operation do
  @moduledoc """
  Server-owned descriptor for one protected inventory mutation attempt.

  This value records the durable identity, mutation identity, bounded evidence, and
  deadlines a later integration slice will use. Constructing it performs no durable
  read or write and does not allocate admission capacity.
  """

  alias Store.Orders.InventoryAdmission.Operation.{Deadline, Mutation, Post, Pre}
  alias Store.Orders.InventoryAdmission.Request
  alias Store.Support.ID.UUIDv7

  @allowed_options [:previous_epoch, :pre, :post, :deadline, :expires_at, :now]
  @fingerprint_regex ~r/\A[0-9a-f]{64}\z/

  @enforce_keys [
    :reservation_key,
    :operation_id,
    :operation_epoch,
    :request_fingerprint,
    :mutation,
    :pre,
    :post,
    :deadline
  ]
  defstruct [
    :reservation_key,
    :operation_id,
    :operation_epoch,
    :request_fingerprint,
    :mutation,
    :pre,
    :post,
    :deadline
  ]

  @type t :: %__MODULE__{
          reservation_key: String.t(),
          operation_id: Ecto.UUID.t(),
          operation_epoch: pos_integer(),
          request_fingerprint: String.t(),
          mutation: Mutation.t(),
          pre: Pre.t(),
          post: Post.t(),
          deadline: Deadline.t()
        }

  @spec new(Request.t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def new(request, opts \\ [])

  def new(%Request{} = request, opts) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, :options_must_be_a_keyword_list}

      Keyword.has_key?(opts, :operation_id) ->
        {:error, :operation_id_is_server_generated}

      Keyword.has_key?(opts, :operation_epoch) ->
        {:error, :operation_epoch_is_server_generated}

      not valid_options?(opts) ->
        {:error, :unknown_operation_option}

      not Request.valid?(request) ->
        {:error, :invalid_request}

      true ->
        build(request, opts)
    end
  end

  def new(_request, _opts), do: {:error, :invalid_operation}

  @spec next_epoch(non_neg_integer()) :: {:ok, pos_integer()} | {:error, atom()}
  def next_epoch(previous_epoch) when is_integer(previous_epoch) and previous_epoch >= 0,
    do: {:ok, previous_epoch + 1}

  def next_epoch(_previous_epoch), do: {:error, :invalid_previous_operation_epoch}

  @spec valid_epoch?(term()) :: boolean()
  def valid_epoch?(epoch), do: is_integer(epoch) and epoch > 0

  @spec validate_epoch_progression(term(), term()) :: :ok | {:error, atom()}
  def validate_epoch_progression(previous_epoch, next_epoch)
      when is_integer(previous_epoch) and previous_epoch >= 0 and is_integer(next_epoch) and
             next_epoch > previous_epoch,
      do: :ok

  def validate_epoch_progression(_previous_epoch, _next_epoch),
    do: {:error, :operation_epoch_not_monotonic}

  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = operation) do
    with :ok <- validate_reservation_key(operation.reservation_key),
         :ok <- validate_operation_id(operation.operation_id, operation.reservation_key),
         :ok <- validate_operation_epoch(operation.operation_epoch),
         :ok <- validate_fingerprint(operation.request_fingerprint),
         :ok <- Mutation.validate(operation.mutation),
         :ok <- Pre.validate(operation.pre),
         :ok <- Post.validate(operation.post) do
      Deadline.validate(operation.deadline)
    end
  end

  def validate(_operation), do: {:error, :invalid_operation}

  @spec valid?(term()) :: boolean()
  def valid?(operation), do: match?(:ok, validate(operation))

  @spec remaining_db_budget(t(), non_neg_integer()) :: non_neg_integer()
  def remaining_db_budget(%__MODULE__{deadline: deadline}, monotonic_now) do
    Deadline.remaining_db_budget(deadline, monotonic_now)
  end

  @spec expired?(t(), non_neg_integer()) :: boolean()
  def expired?(%__MODULE__{deadline: deadline}, monotonic_now) do
    Deadline.expired?(deadline, monotonic_now)
  end

  defp valid_options?(opts), do: Enum.all?(Keyword.keys(opts), &(&1 in @allowed_options))

  defp build(request, opts) do
    with {:ok, operation_epoch} <- next_epoch(Keyword.get(opts, :previous_epoch, 0)),
         {:ok, pre} <- Pre.new(Keyword.get(opts, :pre)),
         {:ok, post} <- Post.new(Keyword.get(opts, :post)),
         {:ok, deadline} <- Deadline.new(Keyword.get(opts, :deadline)),
         {:ok, mutation} <- Mutation.new(request, Keyword.take(opts, [:expires_at, :now])) do
      {:ok,
       %__MODULE__{
         reservation_key: request.reservation_key,
         operation_id: UUIDv7.generate(),
         operation_epoch: operation_epoch,
         request_fingerprint: request.request_fingerprint,
         mutation: mutation,
         pre: pre,
         post: post,
         deadline: deadline
       }}
    end
  end

  defp validate_reservation_key(value) when is_binary(value) do
    if String.starts_with?(value, "order:") and String.contains?(value, ":sku:") do
      :ok
    else
      {:error, :invalid_reservation_key}
    end
  end

  defp validate_reservation_key(_value), do: {:error, :invalid_reservation_key}

  defp validate_operation_id(operation_id, reservation_key) do
    cond do
      not is_binary(operation_id) -> {:error, :invalid_operation_id}
      operation_id == reservation_key -> {:error, :operation_id_must_be_distinct}
      not UUIDv7.valid?(operation_id) -> {:error, :invalid_operation_id}
      true -> :ok
    end
  end

  defp validate_operation_epoch(epoch) do
    if valid_epoch?(epoch), do: :ok, else: {:error, :invalid_operation_epoch}
  end

  defp validate_fingerprint(value) when is_binary(value) do
    if Regex.match?(@fingerprint_regex, value) do
      :ok
    else
      {:error, :invalid_request_fingerprint}
    end
  end

  defp validate_fingerprint(_value), do: {:error, :invalid_request_fingerprint}
end
