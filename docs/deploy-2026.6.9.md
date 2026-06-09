# Deploy: Pinchflat fork `v2026.6.9` over the existing install

Handoff for the DevOps agent. This migrates the running Pinchflat container from the
**upstream** image (`ghcr.io/kieraneglin/pinchflat:latest`) to the **fork** image
(`ghcr.io/fisherevans/pinchflat:v2026.6.9`). The deployment target is the `pinchflat`
service in `~/dev/nottingham-cloud/containers/arr-matey/docker-compose.yaml`.

This is a stateful upgrade: the new version runs two **schema migrations** against the
existing SQLite DB on first boot and then a one-time background backfill. Read the
Rollback and Verification sections before starting.

---

## What this release changes (behavioral surface to verify)

- **Persisted media status.** Adds `download_status` / `status_reason` columns to
  `media_items` and a `media_table_views` table. Status (`downloaded` / `pending` /
  `filtered` / `culled` / `ignored` / `errored`) is now computed and stored on every
  lifecycle change instead of derived per request.
- **Unified media table.** The four per-source tabs (Pending/Downloaded/Other/Evictions)
  become one table; a new global `/media` page spans all sources. Preset + saved views.
- **Retention, filtering, selection windows, title cleaning, season layout, poster
  management, Plex/Jellyfin refresh** - all the fork features (see `docs/fork-features.md`).
- **Title-clean UTF-8 fix** - regexes are now Unicode-aware (previously could corrupt
  multibyte titles).

The migrations are **additive** (new columns + new table); they do not drop or rewrite
existing columns. Backfill of the new status column happens in two stages: a fast SQL
approximation during migration, then a precise per-source recompute kicked off after boot.

---

## Prerequisites

The image is **already built and published** (multi-arch amd64 + arm64) and the GHCR
package is **public**, so no registry auth is needed:

- `ghcr.io/fisherevans/pinchflat:v2026.6.9` (also tagged `latest`)

Confirm it pulls on the host before touching the running container:
```bash
docker pull ghcr.io/fisherevans/pinchflat:v2026.6.9
```

---

## Pre-deploy: back up and record rollback state

The container's `/config` volume holds the SQLite DB (`${CONFIG_MOUNT}/pinchflat`).
**Back it up while the container is stopped** so the file is consistent:

```bash
cd ~/dev/nottingham-cloud/containers/arr-matey
docker compose stop pinchflat
cp -a "${CONFIG_MOUNT}/pinchflat" "${CONFIG_MOUNT}/pinchflat.bak-pre-2026.6.9"
# record the image you're rolling back FROM:
docker compose images pinchflat | tee /tmp/pinchflat-image-before.txt
```

Rollback target: the current `image:` line is `ghcr.io/kieraneglin/pinchflat:latest`.
Note the resolved digest from `docker compose images` so rollback is exact.

---

## Deploy

1. Edit the `pinchflat` service `image:` in
   `~/dev/nottingham-cloud/containers/arr-matey/docker-compose.yaml`:
   ```yaml
   # was: image: ghcr.io/kieraneglin/pinchflat:latest
   image: ghcr.io/fisherevans/pinchflat:v2026.6.9
   ```
2. Pull and recreate:
   ```bash
   docker compose pull pinchflat
   docker compose up -d pinchflat
   docker compose logs -f pinchflat
   ```
3. On boot the entrypoint runs `Pinchflat.Release.migrate` (the two new migrations). Watch
   the logs for both migrations applying cleanly, then the app starting and the post-boot
   `RecomputeDownloadStatusWorker` jobs being enqueued (one per source, `local_data` queue).

Nothing about volumes, ports (`8945`), env, or the scratch/yt-dlp mounts changes.

---

## Verification

Use the host-mapped port (`8945`) or hit the service on `plexnet`. `GET /healthcheck`
returns 200 with no auth.

### T+0 - immediately after the container is healthy

The goal here is "did it boot, migrate, and render without errors." If any of these fail,
**roll back now** (see below) rather than letting it run.

- [ ] `curl -fsS http://<host>:8945/healthcheck` returns 200.
- [ ] Logs show both migrations applied (`add_download_status_to_media_items`,
      `create_media_table_views`) and **no** errors/stacktraces during boot.
- [ ] The UI loads. Open `/media` - the global table renders with status pills and a row of
      preset chips (Pending / Downloaded / Skipped-filtered / Evicted-culled / All /
      Ignored / Errored) showing per-status counts.
- [ ] A source page (`/sources/<id>`) shows three tabs - **Overview / Media / Tasks** (the
      old four media tabs are gone). The Media tab lists items with statuses.
- [ ] Counts sanity-check: `Downloaded` count ≈ what you expect on disk; `All` ≈ total
      indexed. They will not all be final yet (backfill still running) but should be
      populated, not all-zero and not all-"pending".

Optional DB-level check (find the `.sqlite3` file under `${CONFIG_MOUNT}/pinchflat`):
```bash
sqlite3 <db> "PRAGMA table_info(media_items);" | grep download_status   # column exists
sqlite3 <db> ".tables" | grep media_table_views                        # table exists
sqlite3 <db> "SELECT download_status, COUNT(*) FROM media_items GROUP BY 1;"
```

### T+1 hour - has the background work settled?

Why an hour: the precise status backfill runs as `local_data` Oban jobs after boot, one per
source, and yt-dlp self-update / metadata jobs also run early. An hour is enough for a
library of a few thousand items to finish on a homelab box.

- [ ] **Backfill complete**: no rows left unclassified.
      ```bash
      sqlite3 <db> "SELECT COUNT(*) FROM media_items WHERE status_computed_at IS NULL;"  # -> 0
      ```
- [ ] `local_data` Oban queue has drained (no piled-up `RecomputeDownloadStatusWorker` jobs
      stuck retrying). Check the Tasks tab on a source, or the `oban_jobs` table for
      `state='retryable'`/`'available'` backlog.
- [ ] Status counts on `/media` look **plausible and stable** vs T+0 - `filtered` should now
      reflect real filter rules (not lumped into pending), `culled` should match items whose
      files were retention-deleted.
- [ ] **Title-clean UTF-8 fix**: open a source that has non-ASCII titles, go to its title
      settings preview - it renders instead of showing "Invalid pattern". (This was the
      crash class the fix addresses.)
- [ ] No recurring errors in logs since boot.

### T+1 day - did a full cycle run correctly?

Why a day: indexing, downloading, and the **retention cron run daily**. A day proves new
items get a status at insert and that downloads/culls move items between statuses through
the real workers - not just the one-time backfill.

- [ ] New items appeared from a slow/fast index cycle and have a non-null `download_status`
      (they were classified at insert, not left blank):
      ```bash
      sqlite3 <db> "SELECT COUNT(*) FROM media_items WHERE download_status IS NULL;"  # -> 0
      ```
- [ ] Items that downloaded in the last day show `downloaded` with a real `media_size_bytes`;
      items the retention pass deleted show `culled` with a `status_reason`
      (`culled_retention` / `culled_cutoff`).
- [ ] The **consistency invariant** holds: the set the downloader will attempt
      (`download_status IN ('pending','errored')`) matches what the Pending preset shows and
      what's actually queued. Spot check: a handful of `pending` items are genuinely eligible
      (after cutoff, pass filters), and nothing in `filtered`/`ignored`/`culled` is being
      re-downloaded.
- [ ] Files on disk and Plex/Jellyfin look right (title cleaning + season layout applied as
      before - this release didn't change that logic, but confirm nothing regressed).
- [ ] DB size and memory are stable (no runaway growth from the new columns/jobs).

### T+1 week - do the slow-moving behaviors hold?

Why a week: count/size **budget evictions** only happen once a source exceeds its budget,
and the redownload/upgrade delays are multi-day. A week exercises the parts a day can't.

- [ ] A budget eviction occurred (if any source is over budget): those items show `culled`
      with `status_reason = 'evicted_budget'` and a populated `last_evicted_at` /
      `last_bytes_freed`, and they appear under the **Evicted/culled** preset with the
      Evicted/Freed columns filled.
- [ ] Changing a source's filters (or running **Reprocess Media**) re-flows items between
      `pending` and `filtered` within a few minutes (the per-source recompute job).
- [ ] A **saved view** created on day 1 still loads - and loads identically on a second
      device (phone), confirming server-side persistence.
- [ ] Pending/Downloaded/Filtered counts track reality over the week (library stays bounded;
      no unexpected growth or mass re-downloads).
- [ ] No slow leak: container memory, DB size, and Oban job tables are steady.

---

## Rollback

**Quick rollback (image only)** - safe because the migrations are additive. The old upstream
app simply ignores the extra `download_status`/`status_reason` columns and the
`media_table_views` table (Ecto only reads mapped fields; the extra table is inert):

```bash
cd ~/dev/nottingham-cloud/containers/arr-matey
# restore the image: line to ghcr.io/kieraneglin/pinchflat:latest (or the recorded digest)
docker compose pull pinchflat && docker compose up -d pinchflat
```

**Full rollback (image + data)** - if the DB looks wrong, restore the pre-deploy backup:

```bash
docker compose stop pinchflat
rm -rf "${CONFIG_MOUNT}/pinchflat" && mv "${CONFIG_MOUNT}/pinchflat.bak-pre-2026.6.9" "${CONFIG_MOUNT}/pinchflat"
# revert the image: line, then
docker compose up -d pinchflat
```

Note: title cleaning / season organizing that ran under the new version will have renamed
files on disk and updated stored titles. Those persist through an image-only rollback. Use
the full rollback (DB restore) only if you also intend to undo those, and be aware the
on-disk files won't revert automatically.

---

## Status

Ready to deploy. Code, version `2026.6.9`, tag `v2026.6.9`, the GHCR-only release workflow,
and the published **public multi-arch image** are all in place. Nothing is blocking - start
at "Pre-deploy" above.
