#!/bin/sh
#
# Imports a snapshot of a deployed Pinchflat SQLite DB into the local dev
# environment, then runs this fork's migrations against it. Use this to work
# against real sources/media_items locally instead of setting everything up by
# hand.
#
# Usage:
#   tooling/import_deployed_db.sh <path-to-snapshot.db>
#
# Produce the snapshot on the deployed host with a WAL-safe copy, e.g.:
#   sqlite3 /path/to/config/db/pinchflat.db "VACUUM INTO '/tmp/pinchflat-snapshot.db'"
# then copy it onto this machine (scp/rsync) and pass its path here.
#
# Notes:
#   - media_filepath/metadata paths in the snapshot point at the deployed host,
#     so the actual media files won't exist locally. Sources, indexed metadata,
#     and settings all come across fine - which is what you want for evaluating
#     config/retention/indexing features without downloading anything.
#   - The current dev DB is backed up before being replaced.

set -e

SNAPSHOT="${1:?Usage: tooling/import_deployed_db.sh <path-to-snapshot.db>}"
DEV_DB="priv/repo/pinchflat_dev.db"

if [ ! -f "$SNAPSHOT" ]; then
  echo "Snapshot not found: $SNAPSHOT"
  exit 1
fi

echo "==> Stopping dev container"
docker compose stop phx

if [ -f "$DEV_DB" ]; then
  BACKUP="${DEV_DB}.bak.$(date +%Y%m%d%H%M%S)"
  echo "==> Backing up current dev DB to $BACKUP"
  cp "$DEV_DB" "$BACKUP"
fi

echo "==> Importing snapshot"
rm -f "${DEV_DB}-wal" "${DEV_DB}-shm"
cp "$SNAPSHOT" "$DEV_DB"

echo "==> Applying fork migrations"
docker compose run --rm phx mix ecto.migrate

echo "==> Starting dev container"
docker compose up -d phx

echo "==> Row counts"
docker compose run --rm phx mix run -e \
  'IO.puts("sources=#{Pinchflat.Repo.aggregate(Pinchflat.Sources.Source, :count)} media_items=#{Pinchflat.Repo.aggregate(Pinchflat.Media.MediaItem, :count)}")'

echo "==> Done. App will be available at http://localhost:4008 once it finishes booting."
