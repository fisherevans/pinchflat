# Ops task: deploy Pinchflat fork `v2026.6.10` to arr-matey

You are deploying a new image of the self-hosted Pinchflat fork onto the `arr-matey` host and
verifying it. Work the steps in order. Stop and report if any **T+0** check fails.

## Context

- Target: the `pinchflat` service in `~/dev/nottingham-cloud/containers/arr-matey/docker-compose.yaml`.
- New image: **`ghcr.io/fisherevans/pinchflat:v2026.6.10`** (public, multi-arch amd64+arm64, no pull auth).
- The host runs Pinchflat in Docker. `/config` (SQLite DB + scratch) is local disk; the media
  library **`/media` is an NFSv3 mount to a Synology over 1 GbE** - every file op there is a
  synchronous network RPC. This box has wedged hard (hypervisor reset) from NFS RPC floods and
  from memory exhaustion when a heavy job collides with a download.
- This is a **stateful upgrade**: new schema migrations run against the existing SQLite DB on
  first boot, then a one-time DB-only background backfill. All migrations are **additive** (new
  columns + one new table); none drop or rewrite existing data. Ecto only runs migrations not
  already applied, so it is safe regardless of which image is currently running.

## What changed (so you know what to verify)

1. **MediaOrganizer NFS hardening.** The organizer (clean-titles + season layout) now does
   metadata `rename`s instead of full-file copies, only re-muxes an mp4 when its embedded tags
   actually changed, lists each directory once per run, runs on a **dedicated `organizing`
   Oban queue at concurrency 1** (one organize app-wide), and **snoozes** under memory/CPU
   pressure or while a download is in flight. This is the change that makes it safe to enable
   the organizer on this NFS box.
2. **One new additive migration** (`mp4_tags_hash` on `media_items`) - DB-only, instant, never
   touches `/media`.
3. **Agentless metrics export** - **off by default**, fully inert unless `DATADOG_API_KEY` is
   set. Do not set it as part of this deploy. No behavior change.

## Pre-deploy: back up and record rollback state

```bash
cd ~/dev/nottingham-cloud/containers/arr-matey
docker compose stop pinchflat
cp -a "${CONFIG_MOUNT}/pinchflat" "${CONFIG_MOUNT}/pinchflat.bak-pre-2026.6.10"
docker compose images pinchflat | tee /tmp/pinchflat-image-before.txt
docker pull ghcr.io/fisherevans/pinchflat:v2026.6.10
```

Record the current `image:` value and digest from `/tmp/pinchflat-image-before.txt` - that is
your rollback target.

## Deploy

1. In `docker-compose.yaml`, set the `pinchflat` service image:

```yaml
image: ghcr.io/fisherevans/pinchflat:v2026.6.10
```

2. Recreate and watch the logs:

```bash
docker compose up -d pinchflat
docker compose logs -f pinchflat
```

3. Confirm in the logs: the migrations apply cleanly, the app starts, and (if coming from a
   pre-fork image) the post-boot `RecomputeDownloadStatusWorker` jobs enqueue. No
   errors/stacktraces. Volumes, port `8945`, env, and the scratch/yt-dlp mounts are unchanged.

## Verify

`GET /healthcheck` returns 200 with no auth (host-mapped `8945`). To find the DB for `sqlite3`
checks: it is the `.sqlite3`/`.db` file under `${CONFIG_MOUNT}/pinchflat`.

### T+0 - immediately. If any of these fail, roll back now.

- `curl -fsS http://<host>:8945/healthcheck` returns 200.
- Logs show migrations applied and no errors during boot.
- `/media` UI page loads; a source page shows Overview / Media / Tasks tabs.
- The `mp4_tags_hash` column exists: `sqlite3 <db> "PRAGMA table_info(media_items);" | grep mp4_tags_hash`.

### T+1 hour - background work settled

- Status backfill done: `sqlite3 <db> "SELECT COUNT(*) FROM media_items WHERE status_computed_at IS NULL;"` returns 0.
- No `local_data`/`organizing` Oban backlog stuck retrying; no recurring errors in logs.

### Enable the organizer (the point of this release) - do AFTER T+1h is clean

Do this for **one source first** as a canary, not the whole library at once.

1. On a media profile, set `season_strategy = single_season` (or your chosen layout).
2. On a source using that profile, trigger **Reprocess Media**.
3. Watch `docker compose logs -f pinchflat` and the host. Expected behavior:
   - Renames on `/media`, not copies (no multi-GB transfers); confirm with `nfsiostat`/`iftop`
     that there is no sustained read+write throughput proportional to file sizes.
   - At most **one** organize running at a time (queue concurrency 1).
   - The **first** reprocess of each item does one ffmpeg re-mux (writing cleaned tags); this
     is expected once. Subsequent reprocesses/renumbers do zero re-muxing.
   - Under memory/load pressure or an active download, the worker logs a snooze and defers -
     it should not pile heavy I/O onto a busy box.
4. If the canary source completes cleanly with no host stress, repeat for the rest.

### T+1 day / T+1 week

- A full index -> download -> retention cycle ran without host wedges; memory and DB size stable.
- Files on disk and in Plex/Jellyfin reflect the cleaned titles + chosen season layout.

## Rollback

Image-only rollback is safe (migrations are additive; the prior image ignores the extra
columns/table):

```bash
cd ~/dev/nottingham-cloud/containers/arr-matey
# restore the recorded previous image: line, then
docker compose pull pinchflat && docker compose up -d pinchflat
```

If the DB looks wrong, also restore the backup:

```bash
docker compose stop pinchflat
rm -rf "${CONFIG_MOUNT}/pinchflat" && mv "${CONFIG_MOUNT}/pinchflat.bak-pre-2026.6.10" "${CONFIG_MOUNT}/pinchflat"
docker compose up -d pinchflat
```

Note: organize renames/tag-writes that already ran persist through an image-only rollback; use
the DB restore only if you also intend to undo those, and be aware the on-disk files do not
auto-revert.

## Report back

Image digest deployed, T+0 results, backfill-complete confirmation at T+1h, and the canary
organize result (rename-not-copy confirmed, one-at-a-time, snooze-under-pressure observed).
