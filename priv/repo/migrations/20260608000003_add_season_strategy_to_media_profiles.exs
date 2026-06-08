defmodule Pinchflat.Repo.Migrations.AddSeasonStrategyToMediaProfiles do
  use Ecto.Migration

  # How the media organizer numbers seasons/episodes on disk. "none" preserves the
  # existing episode prefix (organizer only swaps in a cleaned title); the others
  # renumber stably from the upload date so a flat single list / per-year / per-month
  # layout shows correctly in Plex/Jellyfin without a post-hoc renumber.
  def change do
    alter table(:media_profiles) do
      add :season_strategy, :string, default: "none", null: false
    end
  end
end
