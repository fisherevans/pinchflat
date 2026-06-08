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

### Structured filter rule builder

A multi-rule filter on the source form: build a list of rules and combine them with **all** (AND) or **any** (OR). Each rule is `field` + `operator` + `value`:

- title `contains` / `excludes` a regex
- description `contains` / `excludes` a regex (a blank description passes an `excludes` rule)
- duration `longer than` / `shorter than` N seconds

Only matching media is downloaded; rules compose with the single title regexes above.

- **Use it:** source form (advanced) → Filtering → Add rule.
- **How:** rules are stored on `source.filter_config` (`%{"match", "rules"}` JSON) and compiled by `Pinchflat.Media.FilterRules` into a composable Ecto predicate applied in `list_pending_media_items_for` / `pending_download?`. The UI is Alpine-managed (rules array serialized to a hidden `filter_config_json` field, parsed in the controller).
- **Impl note:** operator selects use `x-if` with static `<option>`s rather than `x-for`-generated options, because Alpine's `x-model` + `x-for` options race resets the select to the first option on load. Caught by screenshotting.

### Live filter feedback (stacked histogram + title lists)

The title regexes and the rule builder share one **Filtering** panel with a live, comprehensive preview that updates as you edit any filter:

- A per-month **stacked bar histogram** - green = videos that would download, red = filtered out - so you see the in/out split over the channel's lifetime at a glance.
- Two **scrollable lists of the actual video titles**, "Will download (N)" and "Filtered out (N)", capped at 250 each.
- A summary line: "N downloading / M filtered out of T".

- **How:** `GET /sources/:id/filter_breakdown` runs all the content filters (include regex, exclude regex, and the rule config) against the source's `media_items` via `Media.filter_breakdown/4`, returning per-month matched/excluded counts plus the title lists. Invalid patterns return `{error: true}` (shown as an inline error). The whole panel is one Alpine scope so a change to any filter input re-fetches.

### Deferred

In-list live highlighting on the main media tables, more rule fields (date, short/livestream flags), and nested AND/OR groups are still ahead. The older `filter_preview` / `rules_preview` count endpoints remain but the UI now uses the richer `filter_breakdown`.

---

## Native sidecar replacements

Brings the `arr-matey` sidecars in-app so no external process writes the live SQLite DB.

### Title cleaning

Per-source rules strip YouTube clickbait (emoji, hashtags, channel handles, brand tags, "Full Episode" markers, season/episode markers, per-channel taglines) from titles. `Pinchflat.Metadata.TitleCleaner` is a pure port of the `cleaner.py` sidecar. The raw title/description are preserved (`media_items.original_title`/`original_description`) so rules can change and be re-applied; `title` holds the cleaned value the NFO/filename/search already consume. Rules (`title_clean_enabled` + `aliases` + `extra_strip`, validated) live in a **Titles** tab on the source form with a live preview (`GET /sources/:id/title_clean_preview`) of original → cleaned pairs.

### Media organizer (clean titles on disk + season strategy)

`Pinchflat.Organizing.MediaOrganizer` reconciles a downloaded item's on-disk layout: it computes the desired path (sanitized clean title + a stable, no-reshuffle season/episode prefix from the profile's `season_strategy`), then two-phase renames media + subtitles (vacate-all then place-all so a renumber can't collide), retags the mp4's embedded tags (`Mp4Tagger`, bundled ffmpeg `-c copy`, behind an injectable runner), rewrites the `.nfo`, and updates the DB. Idempotent; preserves the existing show directory (dodging yt-dlp's channel-name sanitization); skips items with an in-flight download; only touches opted-in sources. `season_strategy` (`:none`/`:single_season`/`:by_year`/`:by_month`) is a media-profile select. `:none` keeps the existing prefix and only swaps in the clean title. Replaces the titleclean file/tag side + normalize-seasons.

- Triggered after a download (`MediaOrganizeWorker`, per-source, unique) and by the **Reprocess Media** source action (`force: true`) which re-applies current rules to the existing library. Stable numbering means culls don't reshuffle survivors, so no cron is needed.

### Media center refresh

`Pinchflat.MediaCenter` fires a Plex section refresh (`X-Plex-Token`) and/or Jellyfin library refresh (`MediaBrowser` token) after the organizer changes files or a poster is replaced. Connection details in Settings; blank = skipped; runs detached so a slow server never blocks a job. Added a `post` callback + request timeouts to the HTTP client.

### Poster manager

A LiveView at `/posters` lists sources with their current `poster.jpg`; select a source, drop/choose an image, and it writes the poster into the show folder (atomic), updates `poster_filepath`, and fires a media-center refresh. First use of LiveView uploads in the app. Replaces the poster-manager sidecar.

## UX overhaul ("Control Room")

A cohesive visual language and layout pass across the subscription lifecycle. Shared kit in `PinchflatWeb.CustomComponents.DashboardComponents` (stat_tile, status_pill, sparkline, line_sparkline, change_badge, activity_graph, config_card/config_kv, source_avatar). Keeps the existing palette; adds `font-mono` for data.

### Sources list

A monitoring surface, not a flat table: summary tiles (downloaded +N/week, library size, culled/freed, net change) and per-source rows with avatar, status pill + enable toggle, downloaded count + size, a **last-year line sparkline** of weekly downloads, and `+new / -culled` badges. Sorting + pagination preserved.

### Source detail

Replaces the raw attribute dump with a briefing: identity header (avatar/profile/status), metric tiles, a diverging weekly **activity graph** (downloads up / culls down), the cadence histogram, and four labelled **config summary cards** (Window / Retention / Filtering / Output) with edit links.

### Edit form (workflow tabs)

Restructured from one long scroll into a four-stage workflow using the tab component, dissolving the old "advanced mode" toggle:

1. **Source** - URL, name, media profile, output template.
2. **Indexing** - frequency, fast index, download media, cookies.
3. **Filtering** - "what's a viable download": a **dual-range duration slider** sitting on a histogram of the channel's video lengths (drag the handles instead of guessing seconds; a handle at either end means "no bound"), the two title regexes side by side, and the rule builder (title/description/duration, all/any). Verbose guidance collapses behind `info_tip` icons on the section titles. The live in/out preview (stacked histogram + matched/excluded lists) now shows each video's **duration** next to its title and updates as the duration slider moves.
4. **Limits** - "of the viable, how much to keep": Time window (interactive cadence + cutoff/end date), Retention period (number + 30d/90d/6mo/1yr/forever preset chips), and Capacity. Capacity renders a **bar strip of the actual downloaded library** (one bar per item, sized by file size, ordered most-keepable first by the eviction strategy) with **count and size sliders** that highlight the kept run live - dragging "keep most recent" shows the resulting GB, dragging "maximum total size" shows the resulting item count, with a combined "keep N of T (X GB) · evict M (Y GB freed)" readout. Falls back to plain number inputs before anything is downloaded.

### Filter/retention preview endpoints

- `GET /sources/:id/filter_breakdown` now also takes `min_duration_seconds`/`max_duration_seconds`, returns a `durations` histogram (`%{axis_max, bin_seconds, bins}`, length distribution capped near the 95th percentile so an outlier livestream doesn't flatten it), and returns the matched/excluded lists as `%{title, duration}` rather than bare strings.
- `GET /sources/:id/retention_curve` returns the downloaded media's byte sizes ordered most-keepable-first for a given `eviction_strategy`. The form builds the cumulative curve client-side, so the count/size sliders give live GB↔count readouts with one fetch per strategy change instead of a round-trip per drag. Backed by `RetentionPolicy.keep_order/2`.

### Filter/Limits refinements

A second pass tightened both tabs:

- **Duration slider** - histogram sits above the track (not behind it), each thumb's selected time renders directly under the thumb, and the track/thumbs/labels are inset by half a thumb so a handle at the max actually reaches the right axis (the dual-range overlay's thumbs are inset 9px; the chart and labels share that inset via `mx-[9px]` so everything lines up).
- **Title regexes** - each field has an "ignore case" checkbox that manages the leading `(?i)` flag, and live per-pattern feedback ("N of T titles match") with an expandable sample list. `filter_breakdown` returns `include`/`exclude` `%{count, titles}` for this, independent of the other filters. The fields are Alpine-bound (`x-model`) and refresh is debounced through the section's bubbled input handler (no fetch-per-keystroke).
- **Time window** - the cutoff/end dates are now a dual-range slider dragged across the upload-cadence timeline (handle at either end = no bound), with the date text inputs kept in sync.
- **Capacity sliders** - run past the current library (≈3× headroom) so you can leave room to grow, each with an explicit "no limit" checkbox rather than overloading the max position. Counts/sizes beyond what's downloaded are extrapolated from the average item size and flagged `(est)`. The "keep most recent" label tracks the eviction strategy ("Keep earliest/longest/shortest").
- Retention period moved into the **Eviction** group next to the strategy, where it belongs conceptually.

### Capacity reflects the whole prospective library

The Capacity strip models the entire indexed catalog, not just what's on disk - important for a freshly subscribed source where only a handful of items have downloaded but the count cap gates everything still to come. `retention_curve` returns every indexed item ordered by the eviction strategy, with real byte sizes for downloaded items and a per-item estimate (the average of what's been downloaded, flagged `est`) for the rest. The strip renders kept-downloaded (solid green), kept-estimated (light green), and evicted (red), and the readouts surface "N downloaded so far · M of the kept set not downloaded yet (size estimated)". Sizes/counts that extend past what's downloaded are marked `(est)`. Backed by `Media.list_indexed_media_items_for/1`; `RetentionPolicy.keep_order/2` now sorts whatever set it's given (the caller decides downloaded-only vs the full catalog).
