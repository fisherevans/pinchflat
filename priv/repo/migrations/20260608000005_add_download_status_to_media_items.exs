defmodule Pinchflat.Repo.Migrations.AddDownloadStatusToMediaItems do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      # Persisted, derived lifecycle status so the media table can sort/filter/paginate
      # on it in SQL. Source of truth is Pinchflat.Media.DownloadStatus, recomputed on
      # every lifecycle change. `status_reason` carries the human/machine reason an item
      # is filtered/culled/errored. `status_computed_at` doubles as the backfill marker
      # (nil = needs the precise boot-time recompute).
      add :download_status, :string
      add :status_reason, :string
      add :status_computed_at, :utc_datetime

      # Denormalized cache of the most recent budget eviction so the "evicted" view is a
      # single-table query (no join to retention_evictions). Written alongside the audit
      # row in the retention worker's budget pass.
      add :last_evicted_at, :utc_datetime
      add :last_bytes_freed, :integer
    end

    create index(:media_items, [:download_status])
    create index(:media_items, [:source_id, :download_status])

    # Fast, approximate backfill from columns alone so the column is usable immediately.
    # The `filtered` vs `pending` split and the precise reasons can't be expressed in pure
    # SQL (they need the source/profile bindings + FilterRules), so status_computed_at is
    # left null and the post-boot precise recompute (per source) finishes the job.
    execute(
      """
      UPDATE media_items SET download_status = CASE
        WHEN media_filepath IS NOT NULL THEN 'downloaded'
        WHEN culled_at IS NOT NULL THEN 'culled'
        WHEN prevent_download = 1 THEN 'ignored'
        WHEN last_error IS NOT NULL THEN 'errored'
        ELSE 'pending'
      END
      """,
      "SELECT 1"
    )
  end
end
