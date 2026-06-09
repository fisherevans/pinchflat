defmodule Pinchflat.Organizing.MediaOrganizeWorker do
  @moduledoc """
  Runs the media organizer over a source's downloaded items (clean titles + season
  strategy reconcile). Enqueued after a download and by the "Reprocess Media" action
  (event-driven; there is no organize cron). `unique` per source so repeated enqueues
  collapse to one pending run.

  Runs on its own `organizing` queue at concurrency 1 - one organize run at a time
  app-wide (the in-app equivalent of the old sidecar's global lock), so it can't fan out
  across sources or contend with retention/backfill over the NFS media mount. Before doing
  work it consults `PressureGuard` and snoozes when the box is memory/CPU pressured or a
  download is in flight.
  """

  use Oban.Worker,
    queue: :organizing,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable], keys: [:id, :force]],
    tags: ["media_source", "organizing"]

  require Logger

  alias __MODULE__
  alias Pinchflat.Tasks
  alias Pinchflat.Sources
  alias Pinchflat.Organizing.MediaOrganizer
  alias Pinchflat.Organizing.PressureGuard

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
    case pressure_guard().check() do
      {:snooze, seconds} ->
        Logger.info("#{__MODULE__} snoozing organize for source #{source_id} for #{seconds}s (system under pressure)")
        {:snooze, seconds}

      :ok ->
        source = Sources.get_source!(source_id)
        MediaOrganizer.organize_source(source, force: Map.get(args, "force", false))
        :ok
    end
  rescue
    Ecto.NoResultsError -> Logger.info("#{__MODULE__} discarded: source #{source_id} not found")
  end

  # Swappable so tests can drive the snooze/run branches deterministically without depending
  # on the host's real memory/load.
  defp pressure_guard, do: Application.get_env(:pinchflat, :organizer_pressure_guard, PressureGuard)
end
