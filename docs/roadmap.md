# Fork Roadmap

This is the product roadmap for this fork of [Pinchflat](https://github.com/kieraneglin/pinchflat). It is a definition/scoping document, not a design spec - design and implementation come after we agree on the shape here.

## Why this fork exists

The goal is "YouTube as TV": a fresh, bounded, well-presented library of recent content from creators I like, surfaced through Plex/Jellyfin. It is explicitly **not** a complete archive. The operating principle that everything below serves:

> Index broadly, download and keep selectively, auto-evict to stay within a budget, and present the result cleanly to media-center apps - all hands-off, with no manual cleanup.

Upstream Pinchflat is built around archival (download everything matching a filter, retain by age). This fork rebalances toward a curated, self-trimming, presentation-quality library.

Most of the epics below are not speculative. They already exist as external sidecar tools running against Pinchflat's SQLite DB and media tree on the `arr-matey` VM (see [Reference: existing sidecars](#reference-existing-sidecars)). Each one patches a specific Pinchflat gap. Baking them in natively is the point of the fork - and it removes the schema-coupling risk the sidecars carry (they read/write undocumented columns against a `:latest`-pinned image that can change under them).

## Foundations we build on

Confirmed facts about upstream's architecture that shape what's cheap vs expensive to build:

- **A `MediaItem` row is created for every indexed video, not just downloads.** `SlowIndexingHelpers.index_and_enqueue_download_for_media_items` calls `create_media_item_from_backend_attrs` for the whole collection. Each row already stores `title`, `description`, `duration_seconds`, `uploaded_at`, `short_form_content`, `livestream`, and `playlist_index`. So the metadata needed for histograms, list views, and filter previews is largely already in the DB.
- **Filters are non-destructive query-time predicates.** `MediaQuery.pending` composes `download_cutoff_date`, `title_filter_regex` (SQLite `regexp_like`), and `min/max_duration_seconds` as dynamic SQL over stored rows. Changing a filter changes which rows match - it does not delete or re-fetch anything. This is the foundation that makes live "would download / keep / delete" previews a query problem, not a data-capture problem.
- **Retention/culling primitives already exist:** `prevent_download`, `prevent_culling`, `culled_at`, `download_cutoff_date`, and `media_retention_worker.ex`. The retention sidecar reuses exactly these.
- **Output paths are liquid-to-yt-dlp templates** (`OutputPathBuilder`). Pinchflat-computed values use `{{ }}` syntax (e.g. `{{ media_upload_date_index }}`) and are resolved by Pinchflat; date-derived season/episode parts use `%(upload_date>%Y)S` and are resolved by **yt-dlp, per file, at download time**. yt-dlp has no view of the whole collection, which is why contiguous season numbering cannot be expressed in a template today.

## Cross-cutting principle: safe, reversible mutations

Every feature that mutates files or DB state must be reversible and previewable. The sidecars already converged on this harness, and the fork should adopt the spirit of it natively (where in-app transactions make it strictly safer than an external tool):

- Preview / dry-run for anything destructive, before it runs.
- An audit trail of mutations (old/new pairs) so changes can be rolled back.
- Idempotent operations (re-running is a no-op).
- A pin/protect flag to exempt specific items (`prevent_culling` already exists).
- Never touch in-flight downloads (skip `.part`/`.ytdl`).

Doing this in-app means we get transactions and a single source of truth instead of snapshotting SQLite from outside.

---

## Epic 0 - Metadata foundation (first focus)

**Goal:** Guarantee that rich per-video metadata is captured and queryable for every indexed video, including ones we filter out and never download. Everything in Epics 3, 4, 5, and 6 reads from this.

**What already exists:** Most of it. Rows are created for all indexed videos with title/description/duration/uploaded_at/etc. (see Foundations). Filters are already query predicates.

**Gaps to close:**

- **Confirm completeness of the back catalog.** Repeat slow-index runs use a download archive + `--break-on-existing` to stop early once known IDs are hit (`build_download_archive_options`), so subsequent runs are incremental. The _first_ index of a channel has no archive and pulls the full list. Need to confirm that for an existing source we can get full historical metadata on demand (a "reindex metadata" action), since previews and histograms want the whole catalog, not just the recent window.
- **Index-without-download as a first-class flow.** The user wants to explore real metadata _while configuring_ a subscription. Today you add the source, then it indexes, then it downloads. We need a clean "add with download disabled -> index -> tune filters against real data -> enable download" path, or a pre-add preview index. Decide which.
- **Description retention for templating.** `description` is already stored on the row - good for Epic 5's description extraction. Confirm it survives and is full-text, not truncated.

**Why first:** It is the data layer every UX epic depends on, and it is the cheapest to land because upstream already does 80% of it. Mostly verification + a reindex action + the index-without-download flow.

---

## Epic 1 - Count/size retention with eviction policy

**Goal:** Per-source retention budgets beyond `retention_period_days`: `keep_count` and `keep_bytes` (most restrictive wins), with a configurable eviction strategy when the budget is exceeded.

**Reference implementation:** `pinchflat-retention` sidecar, already deployed. Port its logic natively:

- Walk newest-first by `uploaded_at`, evict beyond the budget.
- On eviction: delete on-disk files (media, subs, thumb, `.info.json`, `.nfo`), mark the row culled (`prevent_download=1`, clear paths), and advance `download_cutoff_date` as a backstop so a DB rebuild does not re-pull the back catalog.
- Eviction strategies: oldest-first, shortest-first, and a "preserve sequential order" option. (The sidecar does newest-keep/oldest-evict; the fork should make the strategy configurable per the original ask.)

**Safety rails to bring over:** `max_delete_percent` refusal (abort if one run would remove more than X% of a source), audit log, dry-run, and respect `prevent_culling` as a pin. Snapshots become unnecessary if we do this transactionally in-app.

**Why it matters:** This is the core "TV shuffle" / hands-off disk-management goal. `retention_period_days` alone is useless for high-cadence channels (a kids' show dropping multiple livestreams a day). Upstream FRs #551/#850/#451 never landed.

**Extends:** `media_retention_worker.ex`, `MediaQuery.deletable_based_on_source_cutoff`, the culling fields.

---

## Epic 2 - Selection windows

**Goal:** Richer control over what to download than a single cutoff date: "last N episodes", "N after a date", explicit start-to-end date range.

**What already exists:** `download_cutoff_date`, `min_duration_seconds`, `max_duration_seconds` as per-source query predicates.

**What to build:** Generalize the windowing model into the same predicate system (`MediaQuery.pending`), so a window is just another composable filter. Pairs naturally with Epic 4 (a window is a rule) and Epic 1 (a count window and a keep-count are related but distinct - one bounds downloads, the other bounds retention).

---

## Epic 3 - Metadata-driven config UX

**Goal:** Use indexed metadata to make configuration legible instead of blind.

**What to build:**

- **Upload-cadence histogram** over a source's lifetime (counts of uploads over time), used as the interactive control for picking date ranges/cutoffs. Lets you see cadence, gaps, and when a channel slowed down. Reads straight from `media_items.uploaded_at`.
- **Browsable compact list** of indexed videos (title, duration, upload date, other metadata) so you can actually see what you are filtering. YouTube makes a flat list of a channel's videos hard to get; we already have the data.

**Depends on:** Epic 0 (full catalog metadata).

---

## Epic 4 - Filter rule builder with live preview

**Goal:** Replace the single `title_filter_regex` field with a real rule set, and show the impact live against indexed data.

**What to build:**

- **Rule set** with multiple rules combined via AND/OR: title contains/excludes, length thresholds, date windows, short/livestream flags, etc. Each rule compiles down to a dynamic Ecto predicate (the existing `MediaQuery` fragments are the template; `regexp_like` already proves arbitrary regex works in SQLite).
- **Live preview**: as you edit rules, show counts and the actual matched videos - "would download 27, keep 12, delete 10" - computed by running the composed predicate against stored rows. The delete count means reconciling currently-downloaded items that no longer match (generalize `deletable_based_on_source_cutoff` to the full rule set).
- **Active filtering in the list view** (from Epic 3): type a rule, watch matches/exclusions update, so you can confidently target the genuinely awful YouTube titles (compilation spam, emoji, SEO keyword soup).

**Depends on:** Epics 0 and 3.

---

## Epic 5 - Output naming and templating with preview

**Goal:** Full control over filenames/folders, derived from rules rather than raw YouTube titles, with a preview that maps the template across real indexed videos before applying.

**What to build:**

- Richer templating, including **extraction from the description** (e.g. a series' boilerplate footer that contains the real episode title).
- **Preview** that renders the resulting filenames for a set of sample indexed videos (including filtered-out ones) before the template is committed. The current `OutputPathBuilder` is liquid-to-yt-dlp; a preview needs Pinchflat to resolve enough of the template to show a realistic result (custom `{{ }}` vars are resolved by us; `%(...)S` vars need either sample metadata substitution or a yt-dlp simulate pass).
- Fix the **"NA" filename bug**: videos with a missing `uploaded_at` render `%(upload_date>...)S` as `NA`. Handle missing dates explicitly.

**Note on unification with Epic 7:** naming (what the file is called) and title sanitization (what Plex reads from tags/nfo) are two halves of one feature - "decide the clean title once, apply it consistently to filename, embedded tags, and sidecar files." Worth designing together.

**Extends:** `OutputPathBuilder`, `output_path/` parser, `output_path_template_override`.

---

## Epic 6 - Season modeling and numbering

**Goal:** Real control over how a source maps to seasons/episodes, so a show opens to a flat episode list in Plex instead of a year-picker.

**Root cause to fix:** Upstream's only fully working template bakes the upload year into folder and filename (`season_by_year__episode_by_date_and_index`). Dropping the year does not work because contiguous numbering needs a whole-collection view, and yt-dlp resolves `%(upload_date>...)S` per file with no such view. The native fix is to **compute season/episode numbers in Pinchflat and inject them as a `{{ }}` template var**, exactly like `media_upload_date_index` is computed today.

**Reference implementation:** the `normalize-seasons.py` sidecar (uncommitted, your current intent) folds flatten + contiguous `s01e01..s01eN` renumbering by `uploaded_at`, rewriting filenames, `.nfo` tags, and DB paths. The deployed `flatten-seasons.py` only removes the `Season YYYY/` subdir.

**Open product decisions (carry into design):**

- **Layout:** flat single season vs per-year split - which is the default?
- **Numbering model:** contiguous `1..N` (clean, but culls + new downloads renumber survivors) vs stable numbering keyed on `uploaded_at` (no churn, but gaps after culls). The sidecar does contiguous and pays the renumber cost; a native impl can choose.

---

## Epic 7 - Title / metadata sanitization

**Goal:** Clean the title/plot that media-center apps read, so Plex/Jellyfin do not inherit emojis, `@handles`, "Full Episode", brand tags ("Disney Jr.", "PBS KIDS"), and hashtags from raw YouTube titles.

**Reference implementation:** `pinchflat-titleclean` sidecar. It cleans across the four sources Plex reads, in priority order: embedded mp4 iTunes tags (via mutagen - the load-bearing one), `.info.json`, `.nfo`, and the filename, then renames files and updates the DB row. Per-source aliases + `extra_strip` regex config; an idempotency marker makes reruns no-ops.

**What to build natively:** configurable strip-rule pipeline applied at download time (and re-appliable on demand), writing the cleaned title consistently across the same layers. See Epic 5 - design the "derive clean title once" pipeline jointly. Decided: the fork owns embedded mp4 tag writing, so `titleclean` is fully replaced.

**Depends on:** Epic 10 (the refresh trigger after a tag rewrite).

---

## Epic 8 - Artwork / poster management

**Goal:** Set custom show posters for YouTube "shows", which upstream has no concept of.

**Reference implementation:** `poster-manager` on-demand web UI - lists shows under the media tree, drag-drop/paste a `poster.jpg`, triggers Plex/Jellyfin refresh.

**What to build natively:** per-source artwork (poster/fanart/banner already exist as `*_filepath` columns on `Source` for metadata-sourced images; this adds user-supplied overrides) with a management UI, plus a refresh trigger after artwork changes.

**Depends on:** Epic 10 (the Plex/Jellyfin refresh trigger).

---

## Epic 9 - Channel discovery and search (research spike)

**Goal:** Add a source by searching, not by pasting a URL; autocomplete channel metadata.

**Reality check - this is the weak one.** There is no clean path:

- YouTube Data API `search.list?type=channel` works but needs a Google API key and burns quota.
- yt-dlp `ytsearch` works but channel search quality is mediocre.
- There is **no** public recommendation / "similar channels" API. Third-party sources for that are unreliable and break often.

Scope as a spike, build last, and do not commit to the recommendations half until a viable data source is proven.

---

## Epic 10 - Media-center integration layer

**Goal:** A shared layer that connects the fork to Plex and Jellyfin: per-instance config (URL + API token), and a refresh-trigger API that other epics call after they mutate files.

**Why it exists:** Decided that the fork owns media-center integration (not a pure downloader). Both Epic 7 (after a tag/title rewrite) and Epic 8 (after an artwork change) need to tell Plex/Jellyfin to rescan. Centralize that here rather than duplicating per-app HTTP calls. The `poster-manager` sidecar already does Plex + Jellyfin refresh and is the reference for the API calls.

**What to build:** connection settings + credential storage, a thin client per media-center app, and a "refresh this library/section" call that Epics 7 and 8 invoke. Keep it debounced/idempotent so a batch of changes triggers one refresh, not hundreds.

**Net-new:** upstream has no concept of this. New dependency surface (per-app API quirks, token management) - the cost of the "fork owns it" decision.

---

## Open product decisions

Resolved:

- **Scope boundary:** the fork **owns media-center integration** - native mp4 tag writing (Epic 7), artwork (Epic 8), and Plex/Jellyfin refresh triggers (Epic 10). The sidecars are fully replaced, not just complemented.

Still open (deferred to design phase):

1. **Season numbering model** (Epic 6): contiguous vs stable. Affects whether survivors renumber after culls. Explicitly deferred to the seasons design.
2. **Season layout default** (Epic 6): flat vs per-year.
3. **Title-cleaning depth** (Epic 7): how aggressive the default strip rules are (the layers - mp4 tags / `.info.json` / `.nfo` / filename / DB - are all in scope per the decision above).

## Suggested sequencing

1. **Epic 0** - metadata foundation (unblocks everything; mostly verification + reindex + index-without-download).
2. **Epic 1** - retention + eviction (highest standalone value, has a working reference impl, extends existing culling).
3. **Epics 3 + 4** - config UX + filter rule builder (the big quality-of-life leap; both read from Epic 0).
4. **Epic 2** - selection windows (folds into the Epic 4 predicate system).
5. **Epics 5 + 6 + 7** - naming, seasons, sanitization (design together as the "library presentation" layer).
6. **Epic 10** - media-center integration layer (build alongside Epic 7, since tag rewrites need the refresh trigger; Epic 8 reuses it).
7. **Epic 8** - posters.
8. **Epic 9** - channel search spike (last, lowest confidence).

## Reference: existing sidecars

All cron-driven sidecars on `arr-matey`, working against Pinchflat's SQLite DB and media tree. They are the de-facto spec for the native features above.

| Tool                                                      | Fills gap                                      | Maps to |
| --------------------------------------------------------- | ---------------------------------------------- | ------- |
| `pinchflat-retention/`                                    | count/size retention (vs days-only)            | Epic 1  |
| `pinchflat-titleclean/`                                   | clean titles across mp4 tags/json/nfo/filename | Epic 7  |
| `scripts/` (`flatten-seasons.py`, `normalize-seasons.py`) | flatten + contiguous season renumber           | Epic 6  |
| `poster-manager/`                                         | custom show posters + media-center refresh     | Epic 8  |

Shared harness (the safe-mutation pattern): online SQLite snapshot before each run, append-only JSONL audit log, dry-run everywhere, lock-protected single-instance, idempotent, skip in-flight downloads. Documented risk: schema coupling to undocumented columns on a `:latest`-pinned image. Folding these into the fork removes that risk.
