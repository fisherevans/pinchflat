defmodule Pinchflat.Media.RecomputeDownloadStatusWorker do
  @moduledoc """
  Recomputes the persisted `download_status` for every media item in a source.

  Enqueued when a source's filters/profile/cutoff/caps change (which can flip many items
  between pending and filtered), by the "Reprocess Media" action, and once per source by
  the post-boot backfill. `unique` per source so repeated enqueues collapse to one run.
  """

  use Oban.Worker,
    queue: :local_data,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable], keys: [:id]],
    tags: ["media_source", "local_data"]

  require Logger

  alias __MODULE__
  alias Pinchflat.Sources
  alias Pinchflat.Media.DownloadStatus

  @doc "Enqueues a recompute for the given source."
  def kickoff(source, job_opts \\ []) do
    %{id: source.id}
    |> RecomputeDownloadStatusWorker.new(job_opts)
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => source_id}}) do
    source = Sources.get_source!(source_id)
    count = DownloadStatus.recompute_download_status_for_source(source)
    Logger.info("Recomputed download_status for #{count} media items in source #{source_id}")

    :ok
  rescue
    Ecto.NoResultsError -> Logger.info("#{__MODULE__} discarded: source #{source_id} not found")
  end
end
