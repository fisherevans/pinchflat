defmodule Pinchflat.Downloading.MediaRetentionWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :local_data,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing]],
    tags: ["media_item", "local_data"]

  use Pinchflat.Media.MediaQuery

  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Sources.Source
  alias Pinchflat.Downloading.RetentionPolicy
  alias Pinchflat.Downloading.RetentionEviction

  @doc """
  Deletes media items that are past their retention date or that exceed a source's
  count/size retention budget, and prevents them from being re-downloaded.

  Runs three passes:
    - retention-period culling (media older than `retention_period_days`)
    - source-cutoff culling (media uploaded before `download_cutoff_date`)
    - count/size budget eviction (media beyond `keep_count` / `keep_bytes`)

  This worker is scheduled to run daily via the Oban Cron plugin.

  Returns :ok
  """
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cull_cullable_media_items()
    delete_media_items_from_before_cutoff()
    cull_over_budget_media_items()

    :ok
  end

  defp cull_cullable_media_items do
    cullable_media =
      MediaQuery.new()
      |> MediaQuery.require_assoc(:source)
      |> where(^MediaQuery.cullable())
      |> Repo.all()

    Logger.info("Culling #{length(cullable_media)} media items past their retention date")

    Enum.each(cullable_media, fn media_item ->
      # Setting `prevent_download` does what it says on the tin, but `culled_at` is purely informational.
      # We don't actually do anything with that in terms of queries and it gets set to nil if the media item
      # gets re-downloaded.
      Media.delete_media_files(media_item, %{
        prevent_download: true,
        culled_at: DateTime.utc_now()
      })
    end)
  end

  # NOTE: Since this is a date and not a datetime, we can't add logic to have to-the-minute
  # comparison like we can with retention periods. We can only compare to the day.
  defp delete_media_items_from_before_cutoff do
    deletable_media =
      MediaQuery.new()
      |> MediaQuery.require_assoc(:source)
      |> where(^MediaQuery.deletable_based_on_source_cutoff())
      |> Repo.all()

    Logger.info("Deleting #{length(deletable_media)} media items that are from before the source cutoff")

    Enum.each(deletable_media, fn media_item ->
      # Note that I'm not setting `prevent_download` on the media_item here.
      # That's because cutoff_date can easily change and it's a valid behavior to re-download older
      # media items if the cutoff_date changes.
      # Download is ultimately prevented because `MediaQuery.pending()` only returns media items
      # from after the cutoff date (among other things), so it's not like the media will just immediately
      # be re-downloaded.
      Media.delete_media_files(media_item, %{
        culled_at: DateTime.utc_now()
      })
    end)
  end

  # Evicts downloaded media that exceeds a source's count/size budget. Unlike the
  # cutoff pass, this sets `prevent_download` so evicted media isn't immediately
  # re-downloaded next cycle (which would otherwise loop forever while over budget).
  # We don't advance `download_cutoff_date` as a backstop - `prevent_download` is
  # durable in our own DB, so it's sufficient on its own.
  defp cull_over_budget_media_items do
    sources_with_budget()
    |> Enum.each(fn source ->
      downloaded = Media.list_downloaded_media_items_for(source)
      candidates = RetentionPolicy.eviction_candidates(source, downloaded)

      if within_delete_guard?(source, candidates, downloaded) do
        Logger.info("Evicting #{length(candidates)} media items over budget for source #{source.id}")

        Enum.each(candidates, fn media_item ->
          Media.delete_media_files(media_item, %{
            prevent_download: true,
            culled_at: DateTime.utc_now()
          })

          RetentionEviction.record(source, media_item)
        end)
      else
        Logger.warning(
          "Skipping budget eviction for source #{source.id}: would evict " <>
            "#{length(candidates)}/#{length(downloaded)} items, exceeding max_delete_percent=#{source.max_delete_percent}"
        )
      end
    end)
  end

  defp sources_with_budget do
    Repo.all(from s in Source, where: not is_nil(s.keep_count) or not is_nil(s.keep_bytes))
  end

  defp within_delete_guard?(%Source{max_delete_percent: nil}, _candidates, _downloaded), do: true
  defp within_delete_guard?(_source, [], _downloaded), do: true

  defp within_delete_guard?(source, candidates, downloaded) do
    case length(downloaded) do
      0 -> true
      total -> length(candidates) / total * 100 <= source.max_delete_percent
    end
  end
end
