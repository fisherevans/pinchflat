defmodule Pinchflat.Repo.Migrations.AddMp4TagsHashToMediaItems do
  use Ecto.Migration

  def change do
    # Hash of the mp4 tag inputs (title + cleaned plot) last written by the organizer, so a
    # reprocess can skip the expensive ffmpeg re-mux when the embedded tags would not change
    # (e.g. a pure season renumber). Nil = never tagged, so the first organize always writes.
    alter table(:media_items) do
      add :mp4_tags_hash, :string
    end
  end
end
