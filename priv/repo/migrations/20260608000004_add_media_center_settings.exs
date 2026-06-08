defmodule Pinchflat.Repo.Migrations.AddMediaCenterSettings do
  use Ecto.Migration

  # Plex/Jellyfin connection details for firing a library refresh after the organizer
  # renames files or a poster is replaced. Blank disables the respective server.
  def change do
    alter table(:settings) do
      add :plex_url, :string
      add :plex_token, :string
      add :plex_library_section, :string
      add :jellyfin_url, :string
      add :jellyfin_token, :string
    end
  end
end
