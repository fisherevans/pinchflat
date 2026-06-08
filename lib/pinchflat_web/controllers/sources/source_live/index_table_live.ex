defmodule PinchflatWeb.Sources.SourceLive.IndexTableLive do
  use PinchflatWeb, :live_view
  use Pinchflat.Media.MediaQuery
  use Pinchflat.Sources.SourcesQuery

  import PinchflatWeb.Helpers.SortingHelpers
  import PinchflatWeb.Helpers.PaginationHelpers

  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Downloading.RetentionEviction

  @sparkline_weeks 52

  def mount(_params, session, socket) do
    limit = session["results_per_page"]

    initial_params =
      Map.merge(
        %{
          sort_key: session["initial_sort_key"],
          sort_direction: session["initial_sort_direction"]
        },
        get_pagination_attributes(sources_query(), 1, limit)
      )

    socket
    |> assign(initial_params)
    |> assign(:summary, summary_stats())
    |> set_sources()
    |> then(&{:ok, &1})
  end

  def handle_event("page_change", %{"direction" => direction}, %{assigns: assigns} = socket) do
    new_page = update_page_number(assigns.page, direction, assigns.total_pages)

    socket
    |> assign(get_pagination_attributes(sources_query(), new_page, assigns.limit))
    |> set_sources()
    |> then(&{:noreply, &1})
  end

  def handle_event("sort_update", %{"sort_key" => sort_key}, %{assigns: assigns} = socket) do
    new_sort_key = String.to_existing_atom(sort_key)

    new_params = %{
      sort_key: new_sort_key,
      sort_direction: get_sort_direction(assigns.sort_key, new_sort_key, assigns.sort_direction)
    }

    socket
    |> assign(new_params)
    |> set_sources()
    |> then(&{:noreply, &1})
  end

  def status(%{enabled: false}), do: :paused
  def status(_source), do: :active

  defp sort_attr(:pending_count), do: dynamic([s, mp, dl, pe], pe.pending_count)
  defp sort_attr(:downloaded_count), do: dynamic([s, mp, dl], dl.downloaded_count)
  defp sort_attr(:media_size_bytes), do: dynamic([s, mp, dl], dl.media_size_bytes)
  defp sort_attr(:media_profile_name), do: dynamic([s, mp], fragment("? COLLATE NOCASE", mp.name))
  defp sort_attr(:custom_name), do: dynamic([s], fragment("? COLLATE NOCASE", s.custom_name))
  defp sort_attr(:enabled), do: dynamic([s], s.enabled)

  defp set_sources(%{assigns: assigns} = socket) do
    sources =
      sources_query()
      |> order_by(^[{assigns.sort_direction, sort_attr(assigns.sort_key)}, asc: :id])
      |> limit(^assigns.limit)
      |> offset(^assigns.offset)
      |> Repo.all()

    sparklines = sparklines_for(Enum.map(sources, & &1.id))

    sources =
      Enum.map(
        sources,
        &Map.put(&1, :download_sparkline, Map.get(sparklines, &1.id, List.duplicate(0, @sparkline_weeks)))
      )

    assign(socket, %{sources: sources})
  end

  defp sources_query do
    cutoff = week_cutoff()

    downloaded_subquery =
      from(
        m in MediaItem,
        select: %{downloaded_count: count(m.id), source_id: m.source_id, media_size_bytes: sum(m.media_size_bytes)},
        where: ^MediaQuery.downloaded(),
        group_by: m.source_id
      )

    pending_subquery =
      from(
        m in MediaItem,
        inner_join: s in assoc(m, :source),
        inner_join: mp in assoc(s, :media_profile),
        select: %{pending_count: count(m.id), source_id: m.source_id},
        where: ^MediaQuery.pending(),
        group_by: m.source_id
      )

    recent_dl_subquery =
      from(m in MediaItem,
        select: %{recent_count: count(m.id), source_id: m.source_id},
        where: not is_nil(m.media_downloaded_at) and m.media_downloaded_at >= ^cutoff,
        group_by: m.source_id
      )

    recent_cull_subquery =
      from(e in RetentionEviction,
        select: %{recent_count: count(e.id), source_id: e.source_id},
        where: e.inserted_at >= ^cutoff,
        group_by: e.source_id
      )

    from s in Source,
      as: :source,
      inner_join: mp in assoc(s, :media_profile),
      left_join: d in subquery(downloaded_subquery),
      on: d.source_id == s.id,
      left_join: p in subquery(pending_subquery),
      on: p.source_id == s.id,
      left_join: rd in subquery(recent_dl_subquery),
      on: rd.source_id == s.id,
      left_join: rc in subquery(recent_cull_subquery),
      on: rc.source_id == s.id,
      where: is_nil(s.marked_for_deletion_at) and is_nil(mp.marked_for_deletion_at),
      preload: [media_profile: mp],
      select: map(s, ^Source.__schema__(:fields)),
      select_merge: %{
        downloaded_count: coalesce(d.downloaded_count, 0),
        pending_count: coalesce(p.pending_count, 0),
        media_size_bytes: coalesce(d.media_size_bytes, 0),
        recent_downloaded_count: coalesce(rd.recent_count, 0),
        recent_culled_count: coalesce(rc.recent_count, 0)
      }
  end

  # Builds a per-source list of weekly download counts for the last @sparkline_weeks weeks,
  # oldest first. Computed in Elixir from raw download timestamps so we avoid fragile
  # week-number SQL.
  defp sparklines_for([]), do: %{}

  defp sparklines_for(source_ids) do
    cutoff = DateTime.add(DateTime.utc_now(), -@sparkline_weeks * 7, :day)

    rows =
      from(m in MediaItem,
        select: {m.source_id, m.media_downloaded_at},
        where: m.source_id in ^source_ids and not is_nil(m.media_downloaded_at) and m.media_downloaded_at >= ^cutoff
      )
      |> Repo.all()

    now = DateTime.utc_now()
    empty = List.duplicate(0, @sparkline_weeks)

    Enum.reduce(rows, %{}, fn {sid, dt}, acc ->
      week_index = @sparkline_weeks - 1 - min(@sparkline_weeks - 1, div(DateTime.diff(now, dt, :day), 7))
      buckets = Map.get(acc, sid, empty)
      Map.put(acc, sid, List.update_at(buckets, week_index, &(&1 + 1)))
    end)
  end

  defp summary_stats do
    cutoff = week_cutoff()
    downloaded = MediaQuery.new() |> where(^MediaQuery.downloaded())

    %{
      source_count: Repo.aggregate(active_sources(), :count),
      active_count: Repo.aggregate(from(s in active_sources(), where: s.enabled == true), :count),
      downloaded: Repo.aggregate(downloaded, :count),
      total_bytes: Repo.aggregate(downloaded, :sum, :media_size_bytes) || 0,
      week_new: Repo.aggregate(from(m in MediaItem, where: m.media_downloaded_at >= ^cutoff), :count),
      week_culled: Repo.aggregate(from(e in RetentionEviction, where: e.inserted_at >= ^cutoff), :count),
      week_freed: Repo.aggregate(from(e in RetentionEviction, where: e.inserted_at >= ^cutoff), :sum, :bytes_freed) || 0
    }
  end

  defp active_sources do
    from(s in Source, where: is_nil(s.marked_for_deletion_at))
  end

  defp week_cutoff, do: DateTime.add(DateTime.utc_now(), -7, :day)
end
