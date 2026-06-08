defmodule Pinchflat.Media do
  @moduledoc """
  The Media context.
  """

  import Ecto.Query, warn: false
  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Tasks
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Media.FilterRules
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Metadata.MediaMetadata
  alias Pinchflat.Metadata.TitleCleaner

  alias Pinchflat.Lifecycle.UserScripts.CommandRunner, as: UserScriptRunner

  # Some fields should only be set on insert and not on update.
  @fields_to_drop_on_update [:playlist_index]

  @doc """
  Returns the list of media_items.

  Returns [%MediaItem{}, ...].
  """
  def list_media_items do
    Repo.all(MediaItem)
  end

  @doc """
  Returns a list of media_items that are upgradeable based on the redownload delay
  of the media_profile their source belongs to. In this context, upgradeable means
  that it's been long enough since upload that the video may be in a higher quality
  or have better sponsorblock segments (or similar).

  The logic is that a media_item is past_redownload_delay if the media_item's uploaded_at is
  at least redownload_delay_days ago AND `media_downloaded_at` - `redownload_delay_days`
  is before the media_item's `uploaded_at`.

  This logic grabs media that we've recently downloaded AND is recently uploaded, but
  doesn't grab media that we've recently downloaded and was uploaded a long time ago.
  This also makes things work as expected when downloading media from a source for the
  first time.

  Returns [%MediaItem{}, ...]
  """
  def list_upgradeable_media_items do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^MediaQuery.upgradeable())
    |> Repo.all()
  end

  @doc """
  Returns a list of pending media_items for a given source, where
  pending means the media_item satisfies `MediaQuery.pending`. You
  should really check out that function if you need to know more
  because it has a lot going on.

  Returns [%MediaItem{}, ...].
  """
  def list_pending_media_items_for(%Source{} = source) do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.pending()))
    |> FilterRules.apply_rules(source)
    |> Repo.all()
  end

  @doc """
  Returns the downloaded media_items for a source (those with a media_filepath).
  Used by retention budgeting and its preview.

  Returns [%MediaItem{}, ...].
  """
  def list_downloaded_media_items_for(%Source{} = source) do
    MediaQuery.new()
    |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.downloaded()))
    |> Repo.all()
  end

  @doc """
  Returns all indexed media_items for a source (anything with an upload date, i.e. it
  has metadata), downloaded or not. Used by the retention curve to model the whole
  prospective library, not just what's been pulled to disk yet.

  Returns [%MediaItem{}, ...].
  """
  def list_indexed_media_items_for(%Source{} = source) do
    MediaQuery.new()
    |> where(^dynamic(^MediaQuery.for_source(source)))
    |> where([m], not is_nil(m.uploaded_at))
    |> Repo.all()
  end

  @doc """
  Returns the upload cadence for a source: a contiguous month-by-month series of
  how many indexed media items were uploaded each month, from the earliest to the
  latest upload. Months with no uploads are included with a count of 0 so the time
  axis is continuous (gaps and slowdowns are visible). Counts all indexed media,
  not just downloaded, so it reflects the full catalog.

  Returns [%{month: "YYYY-MM", count: integer}, ...].
  """
  def upload_cadence_by_month_for(%Source{} = source) do
    counts =
      from(m in MediaItem,
        where: m.source_id == ^source.id and not is_nil(m.uploaded_at),
        group_by: fragment("strftime('%Y-%m', ?)", m.uploaded_at),
        select: {fragment("strftime('%Y-%m', ?)", m.uploaded_at), count(m.id)}
      )
      |> Repo.all()
      |> Map.new()

    case counts |> Map.keys() |> Enum.sort() do
      [] ->
        []

      months ->
        List.first(months)
        |> months_through(List.last(months))
        |> Enum.map(fn ym -> %{month: ym, count: Map.get(counts, ym, 0)} end)
    end
  end

  @doc """
  Given a source and a set of (unsaved) content filters - an include regex, an exclude
  regex, a structured rule config, and optional `:min_duration`/`:max_duration` bounds
  (seconds) - returns a breakdown of how the source's indexed media splits into matched
  (would download) vs excluded (filtered out):

    %{
      total, matched, excluded,
      cadence: [%{month, matched, excluded}, ...],     # contiguous monthly, for a stacked bar
      durations: %{axis_max, bin_seconds, bins: [...]}, # length distribution, for the slider
      matched_titles: [%{title, duration}, ...],        # capped lists of real items
      excluded_titles: [%{title, duration}, ...]
    }

  Powers the live filter feedback on the source form. Raises on an invalid regex
  (the caller turns that into an error state).
  """
  def filter_breakdown(%Source{} = source, include, exclude, config, opts \\ []) do
    min_dur = Keyword.get(opts, :min_duration)
    max_dur = Keyword.get(opts, :max_duration)
    base = from(m in MediaItem, where: m.source_id == ^source.id and not is_nil(m.uploaded_at))

    rows =
      base
      |> select([m], %{
        id: m.id,
        title: m.title,
        duration: m.duration_seconds,
        month: fragment("strftime('%Y-%m', ?)", m.uploaded_at)
      })
      |> order_by([m], desc: m.uploaded_at)
      |> Repo.all()

    matching =
      base
      |> filter_regex(include, :include)
      |> filter_regex(exclude, :exclude)
      |> filter_duration(:min, min_dur)
      |> filter_duration(:max, max_dur)
      |> FilterRules.apply_rules(%{source | filter_config: config})
      |> select([m], m.id)
      |> Repo.all()
      |> MapSet.new()

    {matched, excluded} = Enum.split_with(rows, &MapSet.member?(matching, &1.id))

    %{
      total: length(rows),
      matched: length(matched),
      excluded: length(excluded),
      cadence: breakdown_cadence(rows, matching),
      durations: duration_histogram(rows |> Enum.map(& &1.duration) |> Enum.reject(&is_nil/1)),
      matched_titles: titles(matched),
      excluded_titles: titles(excluded),
      include: field_breakdown(base, include),
      exclude: field_breakdown(base, exclude)
    }
  end

  @breakdown_title_limit 250

  defp titles(rows) do
    rows
    |> Enum.take(@breakdown_title_limit)
    |> Enum.map(&%{title: &1.title, duration: &1.duration})
  end

  # Per-pattern feedback for a single title regex, independent of the other filters:
  # how many of the channel's titles match this one pattern, plus a sample of them.
  # Lets the form show "42 of 300 titles match" right under each regex field.
  defp field_breakdown(_base, nil), do: nil
  defp field_breakdown(_base, ""), do: nil

  defp field_breakdown(base, pattern) do
    rows =
      base
      |> where([m], fragment("regexp_like(?, ?)", m.title, ^pattern))
      |> order_by([m], desc: m.uploaded_at)
      |> select([m], %{title: m.title, duration: m.duration_seconds})
      |> Repo.all()

    %{count: length(rows), titles: titles(rows)}
  end

  defp filter_regex(query, nil, _kind), do: query
  defp filter_regex(query, "", _kind), do: query
  defp filter_regex(query, pattern, :include), do: where(query, [m], fragment("regexp_like(?, ?)", m.title, ^pattern))

  defp filter_regex(query, pattern, :exclude),
    do: where(query, [m], not fragment("regexp_like(?, ?)", m.title, ^pattern))

  defp filter_duration(query, _which, nil), do: query
  defp filter_duration(query, :min, seconds), do: where(query, [m], m.duration_seconds >= ^seconds)
  defp filter_duration(query, :max, seconds), do: where(query, [m], m.duration_seconds <= ^seconds)

  # Buckets video lengths into a fixed number of bins for the duration range slider's
  # backdrop histogram. The axis is capped near the 95th percentile so a single long
  # outlier (a 6-hour livestream) doesn't flatten the rest; anything past the cap lands
  # in the top bin.
  @duration_bin_count 32
  @nice_steps [5, 10, 15, 30, 60, 120, 180, 300, 600, 900, 1800, 3600]

  defp duration_histogram([]), do: %{axis_max: 0, bin_seconds: 0, bins: []}

  defp duration_histogram(durations) do
    sorted = Enum.sort(durations)
    target = max(percentile(sorted, 0.95), 60)
    bin_seconds = nice_step(max(1, ceil(target / @duration_bin_count)))
    axis_max = bin_seconds * @duration_bin_count

    bins =
      Enum.reduce(durations, List.duplicate(0, @duration_bin_count), fn d, acc ->
        idx = min(@duration_bin_count - 1, div(trunc(d), bin_seconds))
        List.update_at(acc, idx, &(&1 + 1))
      end)

    %{axis_max: axis_max, bin_seconds: bin_seconds, bins: bins}
  end

  defp nice_step(seconds), do: Enum.find(@nice_steps, List.last(@nice_steps), &(&1 >= seconds))

  defp percentile(sorted, p) do
    n = length(sorted)
    Enum.at(sorted, min(n - 1, round(p * (n - 1))))
  end

  defp breakdown_cadence(rows, matching) do
    by_month = Enum.group_by(rows, & &1.month)

    case by_month |> Map.keys() |> Enum.sort() do
      [] ->
        []

      months ->
        List.first(months)
        |> months_through(List.last(months))
        |> Enum.map(fn ym ->
          items = Map.get(by_month, ym, [])
          matched = Enum.count(items, &MapSet.member?(matching, &1.id))
          %{month: ym, matched: matched, excluded: length(items) - matched}
        end)
    end
  end

  defp months_through(start_ym, end_ym) do
    {start_y, start_m} = parse_year_month(start_ym)
    {end_y, end_m} = parse_year_month(end_ym)

    {start_y, start_m}
    |> Stream.iterate(fn
      {year, 12} -> {year + 1, 1}
      {year, month} -> {year, month + 1}
    end)
    |> Enum.take_while(fn ym -> ym <= {end_y, end_m} end)
    |> Enum.map(fn {year, month} -> "#{year}-#{String.pad_leading(Integer.to_string(month), 2, "0")}" end)
  end

  defp parse_year_month(year_month) do
    [year, month] = String.split(year_month, "-")
    {String.to_integer(year), String.to_integer(month)}
  end

  @doc """
  For a given media_item, tells you if it is pending download. This is defined as
  the media_item satisfying `MediaQuery.pending` which you should really check out.

  Intentionally does not take the `download_media` setting of the source into account.

  Returns boolean()
  """
  def pending_download?(%MediaItem{} = media_item) do
    media_item = Repo.preload(media_item, source: :media_profile)

    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic([m, s, mp], m.id == ^media_item.id and ^MediaQuery.pending()))
    |> FilterRules.apply_rules(media_item.source)
    |> Repo.exists?()
  end

  @doc """
  Returns a list of media_items that match the search term. Adds a `matching_search_term`
  virtual field to the result set.

  Has explit handling for blank search terms because SQLite doesn't like empty MATCH clauses.

  Returns [%MediaItem{}, ...].
  """
  def search(_search_term, _opts \\ [])
  def search("", _opts), do: []
  def search(nil, _opts), do: []

  def search(search_term, opts) do
    limit = Keyword.get(opts, :limit, 50)

    MediaQuery.new()
    |> MediaQuery.matching_search_term(search_term)
    |> Repo.maybe_limit(limit)
    |> Repo.all()
  end

  @doc """
  Gets a single media_item.

  Returns %MediaItem{}. Raises `Ecto.NoResultsError` if the Media item does not exist.
  """
  def get_media_item!(id), do: Repo.get!(MediaItem, id)

  @doc """
  Creates a media_item.

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def create_media_item(attrs) do
    %MediaItem{}
    |> MediaItem.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a media item from the attributes returned by the video backend
  (read: yt-dlp).

  Unlike `create_media_item`, this will attempt an update if the media_item
  already exists. This is so that future indexing can pick up attributes that
  we may not have asked for in the past (eg: uploaded_at)

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def create_media_item_from_backend_attrs(source, media_attrs_struct) do
    attrs =
      %{source_id: source.id}
      |> Map.merge(Map.from_struct(media_attrs_struct))
      |> apply_title_cleaning(source)

    %MediaItem{}
    |> MediaItem.changeset(attrs)
    |> Repo.insert(
      on_conflict: [
        set:
          attrs
          |> Map.drop(@fields_to_drop_on_update)
          |> Map.to_list()
      ],
      conflict_target: [:source_id, :media_id]
    )
  end

  # Preserves the raw title/description, and (when the source enables it) overwrites
  # `title` with the cleaned value so everything downstream uses the clean title.
  # Description/plot cleaning happens at the NFO-write step, not here, so the stored
  # description stays full-text for search/feeds/filtering.
  defp apply_title_cleaning(attrs, source) do
    original_title = Map.get(attrs, :title)

    attrs =
      attrs
      |> Map.put(:original_title, original_title)
      |> Map.put(:original_description, Map.get(attrs, :description))

    if source.title_clean_enabled && is_binary(original_title) do
      Map.put(attrs, :title, TitleCleaner.clean_title(original_title, TitleCleaner.config_for(source)))
    else
      attrs
    end
  end

  @doc """
  Updates a media_item.

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def update_media_item(%MediaItem{} = media_item, attrs) do
    update_attrs = Map.drop(attrs, @fields_to_drop_on_update)

    media_item
    |> MediaItem.changeset(update_attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a media_item, its associated tasks, and our internal metadata files.
  Can optionally delete the media_item's media files (media, thumbnail, subtitles, etc).

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def delete_media_item(%MediaItem{} = media_item, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, false)

    Tasks.delete_tasks_for(media_item)

    if delete_files do
      {:ok, _} = do_delete_media_files(media_item)
      run_user_script(:media_deleted, media_item)
    end

    # Should delete these no matter what
    delete_internal_metadata_files(media_item)
    Repo.delete(media_item)
  end

  @doc """
  Deletes the tasks and media files associated with a media_item but leaves the
  media_item in the database. Does not delete anything to do with associated metadata.

  Optionally accepts a second argument `addl_attrs` which will be merged into the
  media_item before it is updated. Useful for setting things like `prevent_download`
  and `culled_at`, if wanted

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def delete_media_files(%MediaItem{} = media_item, addl_attrs \\ %{}) do
    filepath_attrs = MediaItem.filepath_attribute_defaults()

    Tasks.delete_tasks_for(media_item)
    {:ok, _} = do_delete_media_files(media_item)
    run_user_script(:media_deleted, media_item)

    update_media_item(media_item, Map.merge(filepath_attrs, addl_attrs))
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking media_item changes.
  """
  def change_media_item(%MediaItem{} = media_item, attrs \\ %{}) do
    MediaItem.changeset(media_item, attrs)
  end

  defp do_delete_media_files(media_item) do
    mapped_struct = Map.from_struct(media_item)

    MediaItem.filepath_attributes()
    |> Enum.map(fn
      :subtitle_filepaths = field -> Enum.map(mapped_struct[field], fn [_, filepath] -> filepath end)
      field -> List.wrap(mapped_struct[field])
    end)
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.each(&FilesystemUtils.delete_file_and_remove_empty_directories/1)

    {:ok, media_item}
  end

  defp delete_internal_metadata_files(media_item) do
    metadata = Repo.preload(media_item, :metadata).metadata || %MediaMetadata{}
    mapped_struct = Map.from_struct(metadata)

    MediaMetadata.filepath_attributes()
    |> Enum.map(fn field -> mapped_struct[field] end)
    |> Enum.filter(&is_binary/1)
    |> Enum.each(&FilesystemUtils.delete_file_and_remove_empty_directories/1)
  end

  defp run_user_script(event, media_item) do
    runner = Application.get_env(:pinchflat, :user_script_runner, UserScriptRunner)

    runner.run(event, media_item)
  end
end
