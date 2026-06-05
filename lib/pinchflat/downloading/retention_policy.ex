defmodule Pinchflat.Downloading.RetentionPolicy do
  @moduledoc """
  Pure logic for count/size based retention.

  Given a source's retention budgets (`keep_count`, `keep_bytes`) and its downloaded
  media items, decides which items should be evicted to bring the source back under
  budget. Execution (deleting files, marking rows culled) lives in
  `Pinchflat.Downloading.MediaRetentionWorker` - this module has no side effects.

  The most restrictive budget wins: items are kept in preference order until either the
  count or the cumulative-size budget is hit, then the remainder is evicted. Keeping a
  contiguous preferred run (rather than backfilling leftover space with smaller items)
  keeps the kept set predictable - e.g. "the most recent N that fit".

  `eviction_strategy` controls the keep-preference order:

    - `:oldest`   - evict oldest first (keep the most recent)
    - `:newest`   - evict newest first (keep the earliest)
    - `:shortest` - evict shortest first (keep the longest)
    - `:longest`  - evict longest first (keep the shortest)
  """

  alias Pinchflat.Sources.Source

  @doc """
  Returns the media items that should be evicted for the given source.

  Only considers downloaded items that aren't pinned via `prevent_culling`. Returns
  an empty list when the source has no count or size budget configured.
  """
  def eviction_candidates(%Source{keep_count: nil, keep_bytes: nil}, _media_items), do: []

  def eviction_candidates(%Source{} = source, media_items) do
    media_items
    |> Enum.filter(&downloaded?/1)
    |> Enum.reject(& &1.prevent_culling)
    |> sort_for_keeping(source.eviction_strategy)
    |> Enum.with_index()
    |> Enum.reduce({[], 0, false}, fn {item, index}, {to_evict, kept_bytes, evicting} ->
      next_bytes = kept_bytes + size_bytes(item)

      if evicting or over_count?(source.keep_count, index) or over_bytes?(source.keep_bytes, next_bytes) do
        {[item | to_evict], kept_bytes, true}
      else
        {to_evict, next_bytes, false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc """
  Summarizes what a budget would do to a source's downloaded media, for previewing
  before saving. Returns a map with total downloaded count, how many would be kept
  vs evicted, and the bytes that eviction would free.
  """
  def summarize(%Source{} = source, media_items) do
    candidates = eviction_candidates(source, media_items)
    total = Enum.count(media_items, &downloaded?/1)
    evict = length(candidates)

    %{
      total: total,
      keep: total - evict,
      evict: evict,
      bytes_to_free: candidates |> Enum.map(&size_bytes/1) |> Enum.sum()
    }
  end

  defp over_count?(nil, _index), do: false
  defp over_count?(keep_count, index), do: index >= keep_count

  defp over_bytes?(nil, _bytes), do: false
  defp over_bytes?(keep_bytes, bytes), do: bytes > keep_bytes

  # Pre-sort by id so ties are broken deterministically (Enum.sort_by is stable).
  defp sort_for_keeping(items, strategy) do
    items
    |> Enum.sort_by(& &1.id)
    |> do_sort(strategy)
  end

  defp do_sort(items, :oldest), do: Enum.sort_by(items, &uploaded_key/1, :desc)
  defp do_sort(items, :newest), do: Enum.sort_by(items, &uploaded_key/1, :asc)
  defp do_sort(items, :shortest), do: Enum.sort_by(items, &duration_key/1, :desc)
  defp do_sort(items, :longest), do: Enum.sort_by(items, &duration_key/1, :asc)

  defp downloaded?(media_item), do: not is_nil(media_item.media_filepath)

  defp size_bytes(%{media_size_bytes: nil}), do: 0
  defp size_bytes(%{media_size_bytes: bytes}), do: bytes

  # nil dates are treated as the oldest possible (least keepable).
  defp uploaded_key(%{uploaded_at: nil}), do: 0
  defp uploaded_key(%{uploaded_at: dt}), do: DateTime.to_unix(dt)

  defp duration_key(%{duration_seconds: nil}), do: 0
  defp duration_key(%{duration_seconds: seconds}), do: seconds
end
