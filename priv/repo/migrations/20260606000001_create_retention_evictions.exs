defmodule Pinchflat.Repo.Migrations.CreateRetentionEvictions do
  use Ecto.Migration

  def change do
    create table(:retention_evictions) do
      add :source_id, references(:sources, on_delete: :delete_all), null: false
      add :media_item_id, references(:media_items, on_delete: :nilify_all)

      # Denormalized so the audit row stays meaningful even if the media_item changes or is removed.
      add :media_id, :string
      add :title, :string
      add :bytes_freed, :integer
      # Snapshot of the budget that triggered the eviction.
      add :eviction_strategy, :string
      add :keep_count, :integer
      add :keep_bytes, :integer

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create index(:retention_evictions, [:source_id])
  end
end
