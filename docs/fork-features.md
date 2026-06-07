# Fork Features

A running reference of what this fork adds on top of upstream Pinchflat. This is the "what's shipped" companion to `roadmap.md` (which is forward-looking). Maintained as features land - newest sections appended under each epic.

Branch: `fork-mvp`. All features below are tested and pass the full `mix check` gate.

---

## Epic 0 - Metadata foundation

### Metadata-only reindex action

Forces a full re-enumeration of a source's collection and upserts `media_items` without enqueueing any downloads - even on a source with `download_media` enabled. Useful for backfilling metadata on old videos (to power the cadence histogram, filter previews, etc).

- **Use it:** source page → Actions → "Reindex Metadata (no download)".
- **How:** `SlowIndexingHelpers.index_and_enqueue_download_for_media_items/2` takes an `enqueue_downloads` option, threaded through the file-follower path. The `MediaCollectionIndexingWorker` reads a `download` job arg (default true). `force_reindex_metadata` controller action enqueues with `%{force: true, download: false}`.
- Index-without-download for normal config already worked upstream via the `download_media` gate; this adds the on-demand, download-enabled-source case.

---

## Epic 1 - Count/size retention

Per-source budgets that keep a library bounded and self-trimming, instead of upstream's days-only retention.

### Budgets and eviction

- **`keep_count`** - keep at most N items. **`keep_bytes`** - keep at most N bytes (entered as GB in the UI). Most restrictive wins.
- **`eviction_strategy`** - `oldest` / `newest` / `shortest` / `longest`. Decides which items are kept vs evicted.
- **Use it:** source form (advanced) → Keep Most Recent / Maximum Total Size / Eviction Strategy.
- **How:** `Pinchflat.Downloading.RetentionPolicy` is a pure evaluator (`eviction_candidates/2`). The `MediaRetentionWorker` adds a budget pass that evicts via `Media.delete_media_files` (sets `prevent_download` + `culled_at`), respecting `prevent_culling` pins.

### Download gating (don't download then evict)

The count budget also gates download selection: only the N items the eviction strategy would keep are eligible to download, ranked from indexed metadata. So `keep_count = 10` with no cutoff downloads only the newest 10, not the whole back catalog.

- **How:** `MediaQuery.within_keep_count_window/0` - a correlated-subquery predicate in `pending`. `keep_bytes` can't gate downloads (sizes are unknown pre-download), so it's cleanup-only.
- Verified: a real source went from 419 pending downloads to 0 once a count budget was set.

### Safety guard

- **`max_delete_percent`** - skip eviction for a source if one run would remove more than this share of its downloaded media. Opt-in (blank = no guard).

### Live preview

On the source form, a line shows "Would keep X of Y, evict Z (~N GB freed)" computed live against the source's real downloaded media as you change the budget - before saving.

- **How:** `GET /sources/:id/retention_preview` returns JSON from `RetentionPolicy.summarize/2`. Alpine on the form fetches it (debounced). Note: the fetch must not send `Accept: application/json` (the browser pipeline's `:accepts ["html"]` 406s it).

### Eviction audit log

Every budget eviction writes an append-only `retention_evictions` row: what, when, bytes freed, and a snapshot of the triggering budget. Denormalized `media_id`/`title` so rows survive media-item changes. Surfaced in the UI as an **Evictions** tab on the source page (title, space freed, which budget triggered it, when).

- **How:** `Pinchflat.Downloading.RetentionEviction.record/2` (called from the worker) and `recent_for/2` (powers the tab).

---

## Epic 2 - Selection windows

### Download end date

Upper bound on upload date, complementing the existing `download_cutoff_date` lower bound. Together they form an explicit date range (e.g. only a show's 2022 run). Gates download selection only.

- **Use it:** source form (advanced) → Download End Date.
- **How:** `MediaQuery.upload_date_before_source_end/0` in `pending`.
- The other window cases are already covered: "last N" via `keep_count`, "N after a date" via cutoff + `keep_count`.

---

## Epic 3 - Metadata-driven config UX

### Upload-cadence histogram

A month-by-month bar chart of when a source published content (all indexed media, zero-filled gaps). Makes choosing a download window legible - you can see active periods and droughts at a glance. Shown on the source overview, and on the edit form directly above the date-window fields so the cadence sits next to the cutoff/end-date controls you're setting.

- **See it:** source page → Source tab → "Upload Cadence" (read-only); also the source edit form, where it's **interactive**: click a bar to set the download cutoff (start) date, and months inside the current window are highlighted live as you click or type the cutoff.
- **How:** `Media.upload_cadence_by_month_for/1` aggregates `uploaded_at` into a continuous monthly series. The overview uses the read-only `cadence_histogram/1` component; the form renders an interactive version whose bars share the cutoff-date Alpine state (click sets it, highlight reads it). CSS bars, no JS chart lib.
- The browsable media list (Pending / Downloaded / Other tabs) already exists upstream.

---

## Epic 4 - Filtering

### Title exclude regex

Inverse of the existing `title_filter_regex` (which only includes): media whose title matches `title_exclude_regex` is NOT downloaded. Solves the common case of dropping junk by title - "compilation", "best of", emoji, `#shorts` - which the include-only filter couldn't express. Use alternation (`foo|bar`) to exclude multiple terms in one pattern.

- **Use it:** source form (advanced) → Title Exclude Regex.
- **How:** `MediaQuery.does_not_match_source_exclude_regex/0` in `pending` (negated `regexp_like`). Both regex fields share `validate_regex_field/2` on the changeset.

### Live filter preview

On the source form, a line shows "X of Y indexed videos match (Z excluded)" computed live against the source's real indexed media as you edit the include/exclude patterns. A half-typed or invalid regex shows "Invalid regex" instead of crashing.

- **How:** `GET /sources/:id/filter_preview` runs the include/exclude patterns against the source's `media_items` and returns match counts; invalid patterns are probed first and return `{error: true}`. Same Alpine-fetch pattern as the retention preview (no `Accept: application/json` header).

### Structured filter rule builder

A multi-rule filter on the source form: build a list of rules and combine them with **all** (AND) or **any** (OR). Each rule is `field` + `operator` + `value`:

- title `contains` / `excludes` a regex
- duration `longer than` / `shorter than` N seconds

A live preview shows "X of Y indexed videos match (Z excluded)" as you edit, with an "Invalid rule pattern" state for a bad regex. Only matching media is downloaded; rules compose with the single title regexes above.

- **Use it:** source form (advanced) → Filter Rules → Add rule.
- **How:** rules are stored on `source.filter_config` (`%{"match", "rules"}` JSON) and compiled by `Pinchflat.Media.FilterRules` into a composable Ecto predicate applied in `list_pending_media_items_for` / `pending_download?`. The UI is Alpine-managed (rules array serialized to a hidden `filter_config_json` field, parsed in the controller). `GET /sources/:id/rules_preview` powers the live preview.
- **Impl note:** operator selects use `x-if` with static `<option>`s rather than `x-for`-generated options, because Alpine's `x-model` + `x-for` options race resets the select to the first option on load. Caught by screenshotting.

### Deferred

The "would download / keep / delete" three-way preview and in-list live highlighting are still ahead, as are more rule fields (date, short/livestream flags) and nested AND/OR groups.
