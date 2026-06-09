# Metrics export

Pinchflat can push behavioral/operational metrics, events, and error logs straight to a
hosted observability backend over HTTP - no local agent. It is **off by default** and turns
on when a backend is configured (currently Datadog, via `DATADOG_API_KEY`). The export layer
is pluggable: a backend implements `Pinchflat.Metrics.Backend` and is selected by
`:metrics_backend`, so Grafana/OTLP/etc. can be added without touching instrumentation.

When disabled, every emission is a near-free no-op and nothing is started or attached.

## Enabling (Datadog)

Set `DATADOG_API_KEY`; the rest are optional:

| Env var             | Default         | Purpose                                                       |
| ------------------- | --------------- | ------------------------------------------------------------- |
| `DATADOG_API_KEY`   | _(unset = off)_ | Datadog API key. Presence enables the whole subsystem.        |
| `DATADOG_SITE`      | `datadoghq.com` | Datadog site (`datadoghq.eu`, `us3.datadoghq.com`, `ap1...`). |
| `DATADOG_SERVICE`   | `pinchflat`     | `service` tag / log service.                                  |
| `DATADOG_ENV`       | _(none)_        | `env` tag (e.g. `prod`).                                      |
| `DATADOG_TAGS`      | _(none)_        | Comma-separated global tags, e.g. `team:media,host:nas-1`.    |
| `DATADOG_LOG_LEVEL` | `warning`       | Minimum log level forwarded to Datadog Logs.                  |
| `DATADOG_HOSTNAME`  | system hostname | Host reported on metrics/events/logs.                         |

Metrics are pushed to `api.{site}/api/v2/series`, events to `/api/v1/events`, and logs to
`http-intake.logs.{site}/api/v2/logs`, batched and flushed every ~15s.

## Emitted metrics

All names are prefixed `pinchflat.`. Counters are summed per flush window; gauges report the
latest value (including `0`).

| Metric                  | Type  | Tags                  | Meaning                                              |
| ----------------------- | ----- | --------------------- | ---------------------------------------------------- |
| `download.completed`    | count | `source_id`           | A media item finished downloading.                   |
| `download.recovered`    | count | `source_id`           | Downloaded despite a recoverable error.              |
| `download.failed`       | count | `source_id`, `reason` | A download failed. `reason` is the classified cause. |
| `download.bytes`        | count | `source_id`           | Bytes written. GB downloaded = `sum / 1e9`.          |
| `jobs.executing`        | gauge | `queue`               | Currently-executing jobs per queue (concurrency).    |
| `job.completed`         | count | `queue`, `worker`     | Oban job finished OK.                                |
| `job.failed`            | count | `queue`, `worker`     | Oban job raised.                                     |
| `job.duration_ms.sum`   | count | `queue`, `worker`     | Summed job duration. Avg = `sum / job.completed`.    |
| `index.new_items`       | count | `source_id`           | New media found by a slow/fast index run.            |
| `retention.culled`      | count | `pass`                | Items deleted by retention (`retention`/`cutoff`).   |
| `retention.evicted`     | count | `pass`, `source_id`   | Items deleted by a count/size budget (`budget`).     |
| `retention.bytes_freed` | count | `pass`[, `source_id`] | Bytes freed by a retention pass.                     |
| `ytdlp.update.success`  | count | -                     | yt-dlp self-update succeeded.                        |
| `ytdlp.update.failed`   | count | -                     | yt-dlp self-update failed.                           |

`download.failed{reason}` is one of: `auth_needed` (bot/sign-in/age check - usually fix with
fresh cookies), `members_only`, `unavailable` (private/removed/geo-blocked), `rate_limited`
(HTTP 429), `forbidden` (HTTP 403), `other`.

The download concurrency gauge is `jobs.executing{queue:media_fetching}`.

## Events

- **Download failed** (`alert_type: error`, tags `source_id`/`reason`) - text is the raw
  yt-dlp error.
- **yt-dlp update failed** (`alert_type: error`).

## Logs

Every `Logger` line at or above `DATADOG_LOG_LEVEL` (default `warning`) is forwarded to
Datadog Logs with `ddsource:pinchflat`, the service, the level as `status`, and any
`source_id`/`media_item_id`/`media_id` metadata as tags. This captures the existing download
and indexing error logs - the "why" behind a failure - without a log-collecting agent.

## Recommended Datadog monitors

- **Re-auth needed** - `sum:pinchflat.download.failed{reason:auth_needed}` over the last hour
  `> 0`. The signal that cookies are stale / a source needs re-auth.
- **Download failure rate** - `sum:pinchflat.download.failed` / (`download.failed` +
  `download.completed`) over 1h above a threshold (e.g. 25%).
- **Nothing downloading** - `sum:pinchflat.download.completed` over the last 6-12h `== 0`
  during hours you expect activity (catches a wedged pipeline).
- **yt-dlp update failing** - `sum:pinchflat.ytdlp.update.failed` over 1d `> 0` (extraction
  breakage often follows an upstream YouTube change).
- **Stuck downloads** - `max:pinchflat.jobs.executing{queue:media_fetching}` pinned at the
  configured concurrency for a long stretch with no `download.completed` progress.

## Adding another backend

Implement `Pinchflat.Metrics.Backend` (`ship_series/1`, `ship_events/1`, `ship_logs/1`) and
point `:metrics_backend` at it. The facade, buffering, aggregation, and instrumentation are
backend-agnostic; only the wire format changes. `Pinchflat.Metrics.Backends.Noop` is the
default (disabled) sink and `Backends.Datadog` is the reference implementation.
