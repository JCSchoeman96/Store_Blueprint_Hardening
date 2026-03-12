defmodule Store.Repo.Migrations.Phase31cOpsMetricBuckets do
  use Ecto.Migration

  def change do
    create table(:ops_metric_buckets, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :bucket_start, :utc_datetime_usec, null: false
      add :bucket_width_seconds, :integer, null: false
      add :event_name, :text, null: false
      add :metric_kind, :text, null: false
      add :dimension, :text, null: false, default: "total"
      add :value, :bigint, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :ops_metric_buckets,
             [:bucket_start, :bucket_width_seconds, :event_name, :metric_kind, :dimension],
             name: :ops_metric_buckets_unique_bucket_metric_index
           )

    create index(:ops_metric_buckets, [:event_name, :bucket_start],
             name: :ops_metric_buckets_event_name_bucket_start_index
           )
  end
end
