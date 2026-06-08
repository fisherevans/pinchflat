defmodule Pinchflat.Organizing.MediaOrganizer do
  @moduledoc """
  Reconciles a downloaded media item's on-disk layout with the source's title-clean
  rules and the profile's season strategy. This is the native replacement for the
  titleclean + normalize-seasons sidecars: it computes each item's desired path
  (cleaned title + stable season/episode prefix), then renames the media + subtitle
  files, rewrites the mp4's embedded tags and the `.nfo`, and updates the DB - all in
  one pass.

  Idempotent: an item already at its desired path is left alone (unless `force: true`,
  used by the reprocess action to re-apply rule changes that don't move the file, e.g.
  a plot edit or an embedded-tag refresh).

  A source-level run vacates every moving item to a temp name before placing any at its
  final name, so a renumber can't collide on a name another item still holds. Items with
  an in-flight download alongside them (`.part`/`.ytdl`/`.temp.mp4`) are skipped.

  Only acts on sources that opt in - title cleaning enabled, or a season strategy other
  than `:none` - so it never churns files for sources that haven't asked for it.
  """

  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Sources.Source
  alias Pinchflat.Metadata.TitleCleaner
  alias Pinchflat.Metadata.NfoBuilder
  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.Utils.FilesystemUtils

  @inflight_suffixes ~w(.part .ytdl .temp.mp4)

  @doc "Organizes every downloaded item for a source. Returns {:ok, count_changed}."
  def organize_source(%Source{} = source, opts \\ []) do
    source = Repo.preload(source, :media_profile)

    if organizing_enabled?(source) do
      plans =
        source
        |> Media.list_downloaded_media_items_for()
        |> Enum.map(&%{&1 | source: source})
        |> Enum.map(&plan_for(&1, opts))
        |> Enum.reject(&is_nil/1)

      plans |> Enum.map(&vacate/1) |> Enum.each(&place/1)
      {:ok, length(plans)}
    else
      {:ok, 0}
    end
  end

  @doc "Organizes a single media item. Returns :ok | :skip."
  def organize_media_item(%MediaItem{} = media_item, opts \\ []) do
    media_item = Repo.preload(media_item, source: :media_profile)

    case plan_for(media_item, opts) do
      nil -> :skip
      plan -> plan |> vacate() |> place() |> then(fn _ -> :ok end)
    end
  end

  @doc "Whether the organizer would touch this source at all."
  def organizing_enabled?(%Source{} = source) do
    source = Repo.preload(source, :media_profile)
    source.title_clean_enabled || season_strategy(source) != :none
  end

  # --- planning ---

  defp plan_for(%MediaItem{media_filepath: nil}, _opts), do: nil

  defp plan_for(%MediaItem{} = media_item, opts) do
    current = media_item.media_filepath
    force = Keyword.get(opts, :force, false)

    cond do
      not File.exists?(current) -> nil
      inflight?(current) -> nil
      true -> build_plan(media_item, current, force)
    end
  end

  defp build_plan(media_item, current, force) do
    desired = desired_media_filepath(media_item)
    move? = not same_path?(current, desired)

    cond do
      move? ->
        plan_with_move(media_item, current, desired)

      force ->
        %{media_item: media_item, move?: false, media: current, nfo: nfo_path(current), subs: existing_subs(media_item)}

      true ->
        nil
    end
  end

  defp plan_with_move(media_item, current, desired) do
    ext = Path.extname(current)
    old_stem = Path.basename(current, ext)
    new_stem = Path.basename(desired, Path.extname(desired))

    subs =
      Enum.map(media_item.subtitle_filepaths || [], fn [lang, path] ->
        suffix = String.replace_prefix(Path.basename(path), old_stem, "")
        new_path = Path.join(Path.dirname(desired), new_stem <> suffix)
        %{lang: lang, current: path, desired: new_path, tmp: path <> ".organizing"}
      end)

    %{
      media_item: media_item,
      move?: true,
      media: desired,
      media_current: current,
      media_tmp: current <> ".organizing",
      nfo: nfo_path(desired),
      nfo_current: media_item.nfo_filepath,
      subs: subs
    }
  end

  # --- two-phase execution ---

  # Phase 1: free up the current names so a renumber can't collide on a name another
  # item still holds. Only moving items have temps.
  defp vacate(%{move?: true} = plan) do
    if File.exists?(plan.media_current), do: File.rename(plan.media_current, plan.media_tmp)
    Enum.each(plan.subs, fn s -> if File.exists?(s.current), do: File.rename(s.current, s.tmp) end)
    plan
  end

  defp vacate(plan), do: plan

  # Phase 2: place media + subs at their final names, retag the mp4, rewrite the .nfo,
  # and persist the new paths.
  defp place(%{move?: true} = plan) do
    FilesystemUtils.cp_p!(plan.media_tmp, plan.media)
    File.rm(plan.media_tmp)

    Enum.each(plan.subs, fn s ->
      if File.exists?(s.tmp) do
        FilesystemUtils.cp_p!(s.tmp, s.desired)
        File.rm(s.tmp)
      end
    end)

    if plan.nfo_current && not same_path?(plan.nfo_current, plan.nfo) do
      FilesystemUtils.delete_file_and_remove_empty_directories(plan.nfo_current)
    end

    finalize(plan)
  end

  defp place(plan), do: finalize(plan)

  defp finalize(plan) do
    media_item = plan.media_item
    retag_mp4(plan.media, media_item)
    write_nfo(plan.nfo, media_item)

    subtitle_filepaths = Enum.map(plan.subs, fn s -> [s.lang, s[:desired] || s.current] end)

    {:ok, _} =
      Media.update_media_item(media_item, %{
        media_filepath: plan.media,
        nfo_filepath: plan.nfo,
        subtitle_filepaths: subtitle_filepaths
      })

    plan
  end

  # --- desired path ---

  defp desired_media_filepath(media_item) do
    current = media_item.media_filepath
    ext = Path.extname(current)
    show_dir = show_directory(current)
    prefix = episode_prefix(media_item, season_strategy(media_item.source))
    title = TitleCleaner.sanitize_filename(media_item.title || media_item.original_title || "")

    Path.join(show_dir, "#{prefix} - #{title}#{ext}")
  end

  defp show_directory(path) do
    case MetadataFileHelpers.series_directory_from_media_filepath(path) do
      {:ok, dir} -> dir
      {:error, _} -> Path.dirname(path)
    end
  end

  # :none preserves the existing sNNeNN prefix (clean-title rename only); the others
  # renumber stably from the upload date so the layout never reshuffles on a cull/add.
  defp episode_prefix(media_item, :none) do
    case Regex.run(~r/^(s\d+e\d+)/i, Path.basename(media_item.media_filepath)) do
      [_, prefix] -> prefix
      _ -> episode_prefix(media_item, :single_season)
    end
  end

  defp episode_prefix(media_item, :single_season), do: "s01e" <> date(media_item, "%y%m%d") <> idx(media_item)

  defp episode_prefix(media_item, :by_year),
    do: "s" <> date(media_item, "%Y") <> "e" <> date(media_item, "%m%d") <> idx(media_item)

  defp episode_prefix(media_item, :by_month),
    do: "s" <> date(media_item, "%Y%m") <> "e" <> date(media_item, "%d") <> idx(media_item)

  defp date(%{uploaded_at: uploaded_at}, fmt), do: uploaded_at |> DateTime.to_date() |> Calendar.strftime(fmt)

  defp idx(%{upload_date_index: index}), do: String.pad_leading(to_string(index || 0), 2, "0")

  # --- file/metadata writes ---

  defp retag_mp4(media_filepath, media_item) do
    tags = [
      title: media_item.title || "",
      description: clean_plot(media_item),
      comment: "",
      synopsis: ""
    ]

    case mp4_tagger().write_tags(media_filepath, tags) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("Could not retag #{media_filepath}: #{inspect(reason)}")
    end
  end

  defp write_nfo(nfo_filepath, media_item) do
    metadata = %{
      "title" => media_item.title,
      "uploader" => media_item.source.collection_name || media_item.source.custom_name,
      "id" => media_item.media_id,
      "description" => clean_plot(media_item),
      "upload_date" => Calendar.strftime(DateTime.to_date(media_item.uploaded_at), "%Y%m%d")
    }

    NfoBuilder.build_and_store_for_media_item(nfo_filepath, metadata)
  end

  defp clean_plot(media_item) do
    TitleCleaner.clean_plot(media_item.original_description || media_item.description)
  end

  # --- helpers ---

  defp same_path?(a, b), do: Path.expand(a) == Path.expand(b)

  defp nfo_path(media_filepath), do: "#{Path.rootname(media_filepath)}.nfo"

  defp existing_subs(media_item) do
    Enum.map(media_item.subtitle_filepaths || [], fn [lang, path] -> %{lang: lang, current: path} end)
  end

  defp season_strategy(%Source{media_profile: %{season_strategy: strategy}}), do: strategy
  defp season_strategy(_source), do: :none

  defp inflight?(media_filepath) do
    dir = Path.dirname(media_filepath)

    case File.ls(dir) do
      {:ok, entries} -> Enum.any?(entries, fn e -> String.ends_with?(e, @inflight_suffixes) end)
      _ -> false
    end
  end

  defp mp4_tagger, do: Application.get_env(:pinchflat, :mp4_tagger_runner)
end
