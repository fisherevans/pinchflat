defmodule Pinchflat.Repo.Migrations.AddTitleCleaningToSources do
  use Ecto.Migration

  # Per-source title cleaning rules. `aliases` are show-name variants used to strip
  # "{alias} Full Episode" phrases; `extra_strip` are per-channel regex taglines.
  def change do
    alter table(:sources) do
      add :title_clean_enabled, :boolean, default: false, null: false
      add :title_clean_aliases, {:array, :string}, default: []
      add :title_clean_extra_strip, {:array, :string}, default: []
    end
  end
end
