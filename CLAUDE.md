# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Pinchflat is a self-hosted YouTube media manager built on `yt-dlp`. You define sources (channels/playlists) and rules, and it periodically indexes and downloads new content to disk for use with media center apps (Plex, Jellyfin, Kodi) or podcast apps (via served RSS feeds). It ships as a single Docker container with no external services - SQLite is the only datastore.

Stack: Elixir 1.17 / Phoenix 1.7 (LiveView 1.0), Oban (SQLite/Lite engine) for background jobs, Ecto + `ecto_sqlite3`, esbuild + Tailwind for assets.

## Commands

Development is intended to run inside Docker (the container bundles `yt-dlp`, `ffmpeg`, etc.). `docker-compose.yml` mounts the repo and exposes the app on `:4008`. Run `mix`/`yarn` commands inside the `phx` container: `docker compose exec phx <cmd>`. The commands below assume you're in that shell or have the toolchain locally.

- `mix setup` - install deps, create/migrate DB, seed, build assets
- `mix phx.server` - run the app (port 4000 in-container)
- `mix test` - run tests (auto-creates/migrates the test DB via the `test` alias)
- `mix test path/to/file_test.exs:42` - run a single test by line
- `mix check` - **the full CI gate**: compile (warnings-as-errors), `mix format`, Sobelow security scan, Prettier, and ExUnit. Config in `tooling/.check.exs`. CI runs `mix check --no-fix --no-retry`.
- `mix credo` - linter (uses `tooling/.credo.exs`)
- `mix format` - Elixir/HEEx formatter (line length 120)
- `yarn run lint:fix` - Prettier over non-Elixir files

`mix check` runs in fix mode locally by default and is the single command to run before considering work done. Note `EX_CHECK=1` turns on warnings-as-errors during compile, so the CI build fails on any compiler warning.

## Architecture

### Domain contexts (`lib/pinchflat/`)

Each subdirectory is a context with a public API module (e.g. `Media`, `Sources`, `Profiles`), an Ecto schema, and often a `*_query.ex` query-builder module. The four core schemas and their relationships:

- **`Sources.Source`** - a YouTube channel or playlist to track. Belongs to a `MediaProfile`, has many `MediaItem`s. Inserting/updating a source makes expensive `yt-dlp` API calls, so the changeset does two-stage validation (cheap fields first, then the fields that require the API call) to fail fast.
- **`Media.MediaItem`** - a single downloadable video/audio. Belongs to a `Source`. Tracks predicted vs actual filepaths, download state, and culling/retention state.
- **`Profiles.MediaProfile`** - a reusable rule set (quality, output path template, format options) applied to sources.
- **`Tasks.Task`** - links a domain record to its in-flight Oban job, so the UI can show and cancel work.

### Indexing: fast vs slow (the central design idea)

Pinchflat's "novel approach" to finding new content quickly is the split between two indexing paths. Understand this before touching indexing code:

- **`SlowIndexing`** - the thorough path. Uses `yt-dlp` to enumerate a full collection. Runs on the source's `index_frequency_minutes` schedule. `FileFollowerServer` tails `yt-dlp`'s output file so items can be processed as they're discovered rather than waiting for the whole run.
- **`FastIndexing`** - the quick path, enabled per-source via `fast_index`. Polls YouTube's RSS feed (`youtube_rss.ex`) and the YouTube API (`youtube_api.ex`) to detect new uploads between slow-index runs, kicking off downloads much sooner.

`Downloading` consumes indexed items: `media_downloader.ex` orchestrates the actual `yt-dlp` download, `download_option_builder.ex` / `quality_option_builder.ex` translate a `MediaProfile` into `yt-dlp` flags, and `output_path_builder.ex` resolves the destination path template.

### Background jobs (Oban)

All real work happens in Oban workers (`*_worker.ex` files), not in web requests. Queues are defined in `config/config.exs` and concurrency is env-tunable (`YT_DLP_WORKER_CONCURRENCY`). Queue assignment by domain:

- `media_collection_indexing` - slow indexing
- `fast_indexing` - fast indexing
- `media_fetching` - downloads and quality upgrades
- `remote_metadata` - fetching source/media metadata from YouTube
- `local_data` - retention/deletion, file syncing, `yt-dlp` self-update

The `*_helpers.ex` modules (e.g. `slow_indexing_helpers.ex`, `downloading_helpers.ex`) hold the logic that workers call into; workers stay thin.

### Boot sequence

`Pinchflat.Application` starts children in a deliberate order (`lib/pinchflat/boot/`): `PreJobStartupTasks` runs before Oban starts, `PostJobStartupTasks` after, and `PostBootStartupTasks` last. Put startup migrations/cleanup in the right phase relative to whether jobs should be running.

### External commands and the runner-injection pattern

Anything that shells out to an external binary goes through a behaviour + a swappable runner, configured in `config/config.exs` and overridden with a Mox mock in `test/test_helper.exs`. The four:

- `yt_dlp_runner` (`YtDlp.YtDlpCommandRunner` / `CommandRunner`) - all `yt-dlp` calls
- `http_client` (`HTTP.HTTPBehaviour`)
- `apprise_runner` - notifications
- `user_script_runner` - custom lifecycle scripts

When adding a new external integration, follow this pattern: define a behaviour, register a runner in config, add a Mox mock in the test helper. Tests never hit the real `yt-dlp` or network.

### Web layer (`lib/pinchflat_web/`)

Mostly conventional Phoenix split between controllers (server-rendered HTML) and LiveView (`*_live/` dirs, e.g. `sources/source_live`). `router.ex` defines routes; `plugs.ex` holds custom plugs including optional basic auth (`BASIC_AUTH_USERNAME`/`PASSWORD`). RSS/OPML podcast feeds are built in `lib/pinchflat/podcasts/` and can be gated behind `EXPOSE_FEED_ENDPOINTS`.

## Configuration

Runtime is driven entirely by env vars (`config/runtime.exs`). Key ones: `MEDIA_PATH` (`/downloads`), `CONFIG_PATH` (`/config`, holds the SQLite DB, logs, metadata, extras), `TIMEZONE`/`TZ`, `YT_DLP_WORKER_CONCURRENCY`, `BASE_ROUTE_PATH`, `JOURNAL_MODE`, `EXPOSE_FEED_ENDPOINTS`, `ENABLE_PROMETHEUS`. The timezone is validated against `tzdata` at boot and falls back to UTC.

## Testing notes

- Tests use the Ecto SQL Sandbox in `:manual` mode and `Faker` for data. Fixtures live in `test/support`.
- `after_suite` wipes and recreates the media/metadata/extras/tmp directories - tests write real files to disk under those paths.
- Use the Mox mocks (above) to stub external commands; set expectations per-test.

## Conventions

- Version is date-based (`version.bump` alias runs `tooling/version_bump.sh`); don't hand-edit `version` in `mix.exs`.
- `mix ecto.migrate`/`rollback` regenerate `priv/repo/erd.png` via `yarn run create-erd` (only outside `MIX_ENV`).
- Branch off `master`; PRs target `master`.
