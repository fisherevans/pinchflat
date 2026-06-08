defmodule Pinchflat.Organizing.MediaOrganizeWorker do
  @moduledoc """
  Runs the media organizer over a source's downloaded items (clean titles + season
  strategy reconcile). Enqueued after a download, by the daily cron, and by the
  "Reprocess Media" action. `unique` per source so repeated enqueues collapse to one
  pending run.
  """

  use Oban.Worker,
    queue: :local_data,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable], keys: [:id, :force]],
    tags: ["media_source", "local_data"]

  require Logger

  alias __MODULE__
  alias Pinchflat.Tasks
  alias Pinchflat.Sources
  alias Pinchflat.Organizing.MediaOrganizer

  @doc """
  Enqueues an organize run for a source and attaches a task. `job_args` may include
  `force: true` to re-apply rule changes that don't move files (the reprocess action).
  """
  def kickoff_with_task(source, job_args \\ %{}, job_opts \\ []) do
    %{id: source.id}
    |> Map.merge(job_args)
    |> MediaOrganizeWorker.new(job_opts)
    |> Tasks.create_job_with_task(source)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => source_id} = args}) do
    source = Sources.get_source!(source_id)
    MediaOrganizer.organize_source(source, force: Map.get(args, "force", false))
    :ok
  rescue
    Ecto.NoResultsError -> Logger.info("#{__MODULE__} discarded: source #{source_id} not found")
  end
end
