defmodule Pinchflat.Repo.Migrations.AddSizeAndCountRetentionToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :keep_count, :integer
      add :keep_bytes, :integer
      add :eviction_strategy, :string, default: "oldest", null: false
      add :max_delete_percent, :integer
    end
  end
end
