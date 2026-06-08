defmodule Pinchflat.Media.DownloadStatus do
  @moduledoc """
  Computes and persists a media item's derived lifecycle status (`download_status`)
  and a human-readable `status_reason`.

  There is no stored "status" coming out of yt-dlp - it's derived from the item's
  files/flags plus the source's filters. This module is the single source of truth
  for that derivation. It deliberately reuses the existing predicates rather than
  re-deriving them: the pending/filtered split runs through `Media.pending_download?/1`
  (which wraps `MediaQuery.pending` + `FilterRules`), so the persisted status can never
  drift from the logic the downloader actually uses.

  Status precedence (first match wins), capturing the overlap between `prevent_download`
  (set both by the user "ignore" action and by the retention worker) and `culled_at`:

    1. downloaded - has a file on disk
    2. culled     - files deleted by retention (row persists); reason sub-types the pass
    3. ignored    - user set prevent_download (and not culled)
    4. pending    - passes the download-eligibility predicate, no error
    5. errored    - passes the eligibility predicate but the last attempt errored
    6. filtered   - excluded by a source filter/cutoff/cap; reason names the gate

  `pending` + `errored` together are exactly the set the downloader will attempt
  (== `Media.list_pending_media_items_for/1`). The `status_reason` field is advisory:
  the status itself is always exact, but the precise gate behind `filtered` is computed
  in-memory from the source/profile and may be coarse for the cap/structured-rule cases.
  """

  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Sources.Source
  alias Pinchflat.Downloading.RetentionEviction

  @doc """
  Computes `{status_atom, reason | nil}` for a media item. `source` must be the item's
  source; reasons that need the media profile read `source.media_profile`, so preload it
  for full-fidelity reasons (the status is correct regardless).
  """
  def compute(%MediaItem{} = media_item, %Source{} = source) do
    cond do
      not is_nil(media_item.media_filepath) -> {:downloaded, nil}
      not is_nil(media_item.culled_at) -> {:culled, cull_reason(media_item, source)}
      media_item.prevent_download -> {:ignored, "manually_ignored"}
      Media.pending_download?(media_item) -> eligible_status(media_item)
      true -> {:filtered, filter_reason(media_item, source)}
    end
  end

  @doc """
  Computes the given item's status and persists the three status fields.

  Computes on a copy with the source/profile preloaded, but writes via a changeset on the
  passed struct, so the returned struct keeps whatever association shape the caller had
  (e.g. a preloaded `metadata`). Bypasses `Media.update_media_item/2` (where the recompute
  hook lives) to avoid recursion.

  The caller is responsible for passing a struct with trustworthy scalar fields - the
  `on_conflict` insert path reloads first, since that struct can carry default values for
  columns it didn't set. Returns `{:ok, %MediaItem{}}`.
  """
  def recompute_and_persist(%MediaItem{} = media_item) do
    with_assocs = Repo.preload(media_item, source: :media_profile)
    {status, reason} = compute(with_assocs, with_assocs.source)

    media_item
    |> Ecto.Changeset.change(%{
      download_status: to_string(status),
      status_reason: reason,
      status_computed_at: now()
    })
    |> Repo.update()
  end

  @doc """
  Recomputes status for every item in a source in one pass. Set-wise: it resolves the
  download-eligible set once (instead of a per-item pending query) and classifies each
  row against it. Used by the boot-time backfill and whenever a source's filters/profile
  change. Returns the number of rows updated.
  """
  def recompute_download_status_for_source(%Source{} = source) do
    source = Repo.preload(source, :media_profile)
    items = Repo.all(from(m in MediaItem, where: m.source_id == ^source.id))
    eligible_ids = source |> Media.list_pending_media_items_for() |> MapSet.new(& &1.id)

    Enum.reduce(items, 0, fn item, acc ->
      {status, reason} = classify(item, source, eligible_ids)

      item
      |> Ecto.Changeset.change(%{
        download_status: to_string(status),
        status_reason: reason,
        status_computed_at: now()
      })
      |> Repo.update!()

      acc + 1
    end)
  end

  # Same precedence as compute/2, but uses set membership for the eligibility check so the
  # bulk path avoids a per-item query. Kept in lockstep with compute/2.
  defp classify(item, source, eligible_ids) do
    cond do
      not is_nil(item.media_filepath) -> {:downloaded, nil}
      not is_nil(item.culled_at) -> {:culled, cull_reason(item, source)}
      item.prevent_download -> {:ignored, "manually_ignored"}
      MapSet.member?(eligible_ids, item.id) -> eligible_status(item)
      true -> {:filtered, filter_reason(item, source)}
    end
  end

  defp eligible_status(%MediaItem{last_error: nil}), do: {:pending, nil}
  defp eligible_status(%MediaItem{last_error: error}), do: {:errored, error}

  defp cull_reason(media_item, source) do
    cond do
      not is_nil(media_item.last_evicted_at) -> "evicted_budget"
      Repo.exists?(from(e in RetentionEviction, where: e.media_item_id == ^media_item.id)) -> "evicted_budget"
      culled_by_cutoff?(media_item, source) -> "culled_cutoff"
      true -> "culled_retention"
    end
  end

  defp culled_by_cutoff?(%MediaItem{uploaded_at: nil}, _source), do: false
  defp culled_by_cutoff?(_media_item, %Source{download_cutoff_date: nil}), do: false

  defp culled_by_cutoff?(media_item, source) do
    Date.compare(DateTime.to_date(media_item.uploaded_at), source.download_cutoff_date) == :lt
  end

  # Advisory, in-memory derivation of which gate excluded an item. The precise gates
  # (cutoff/title/duration/format) are exact; the cap/structured-rule case is coarse
  # because those depend on cross-row ranking and compiled JSON rules.
  defp filter_reason(media_item, source) do
    cond do
      before_cutoff_start?(media_item, source) -> "cutoff_start"
      after_cutoff_end?(media_item, source) -> "cutoff_end"
      title_include_fails?(media_item, source) -> "title_filter"
      title_exclude_fails?(media_item, source) -> "title_exclude"
      duration_fails?(media_item, source) -> "duration"
      format_fails?(media_item, source) -> "format_preference"
      not is_nil(source.keep_count) -> "keep_count_cap"
      has_filter_rules?(source) -> "filter_rule"
      true -> "filtered"
    end
  end

  defp before_cutoff_start?(%MediaItem{uploaded_at: nil}, _source), do: false
  defp before_cutoff_start?(_media_item, %Source{download_cutoff_date: nil}), do: false

  defp before_cutoff_start?(media_item, source) do
    Date.compare(DateTime.to_date(media_item.uploaded_at), source.download_cutoff_date) == :lt
  end

  defp after_cutoff_end?(%MediaItem{uploaded_at: nil}, _source), do: false
  defp after_cutoff_end?(_media_item, %Source{download_end_date: nil}), do: false

  defp after_cutoff_end?(media_item, source) do
    Date.compare(DateTime.to_date(media_item.uploaded_at), source.download_end_date) == :gt
  end

  defp title_include_fails?(_media_item, %Source{title_filter_regex: nil}), do: false
  defp title_include_fails?(media_item, source), do: not regex_matches?(source.title_filter_regex, media_item.title)

  defp title_exclude_fails?(_media_item, %Source{title_exclude_regex: nil}), do: false
  defp title_exclude_fails?(media_item, source), do: regex_matches?(source.title_exclude_regex, media_item.title)

  defp duration_fails?(media_item, source) do
    below_min?(media_item, source) or above_max?(media_item, source)
  end

  defp below_min?(_media_item, %Source{min_duration_seconds: nil}), do: false
  defp below_min?(%MediaItem{duration_seconds: nil}, _source), do: false
  defp below_min?(media_item, source), do: media_item.duration_seconds < source.min_duration_seconds

  defp above_max?(_media_item, %Source{max_duration_seconds: nil}), do: false
  defp above_max?(%MediaItem{duration_seconds: nil}, _source), do: false
  defp above_max?(media_item, source), do: media_item.duration_seconds > source.max_duration_seconds

  # Mirrors MediaQuery.format_matching_profile_preference/0 in Elixir.
  defp format_fails?(media_item, source) do
    case source.media_profile do
      %{shorts_behaviour: shorts, livestream_behaviour: livestream} ->
        not format_allowed?(media_item, shorts, livestream)

      _ ->
        false
    end
  end

  defp format_allowed?(media_item, :only, :only), do: media_item.livestream or media_item.short_form_content
  defp format_allowed?(media_item, :only, _), do: media_item.short_form_content
  defp format_allowed?(media_item, _, :only), do: media_item.livestream

  defp format_allowed?(media_item, :exclude, :exclude),
    do: not media_item.short_form_content and not media_item.livestream

  defp format_allowed?(media_item, :exclude, _), do: not media_item.short_form_content
  defp format_allowed?(media_item, _, :exclude), do: not media_item.livestream
  defp format_allowed?(_media_item, _, _), do: true

  defp has_filter_rules?(%Source{filter_config: %{"rules" => rules}}) when is_list(rules), do: rules != []
  defp has_filter_rules?(_source), do: false

  defp regex_matches?(pattern, value) when is_binary(pattern) and is_binary(value) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, value)
      {:error, _} -> false
    end
  end

  defp regex_matches?(_pattern, _value), do: false

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
