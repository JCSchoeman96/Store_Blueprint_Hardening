defmodule Store.Operations.AggregateBucket do
  @moduledoc """
  Durable snapshots of Redis-backed minute aggregates.
  """

  use Ecto.Schema

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "ops_metric_buckets" do
    field :bucket_start, :utc_datetime_usec
    field :bucket_width_seconds, :integer
    field :event_name, :string
    field :metric_kind, :string
    field :dimension, :string
    field :value, :integer

    timestamps(type: :utc_datetime_usec)
  end
end
