defmodule Pinchflat.Repo.Migrations.AddOriginalTitleToMediaItems do
  use Ecto.Migration

  # Preserve the raw YouTube title/description so title cleaning can be re-applied
  # when the rules change. `title`/`description` hold the effective (cleaned) values
  # that everything downstream consumes; these hold the source of truth.
  def change do
    alter table(:media_items) do
      add :original_title, :string
      add :original_description, :string
    end

    # Backfill existing rows so original is never null for already-indexed media.
    execute(
      "UPDATE media_items SET original_title = title WHERE original_title IS NULL",
      "SELECT 1"
    )
  end
end
