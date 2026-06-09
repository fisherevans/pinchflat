defmodule Pinchflat.YtDlp.UpdateWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :local_data,
    tags: ["local_data"]

  require Logger

  alias __MODULE__
  alias Pinchflat.Metrics
  alias Pinchflat.Settings

  @doc """
  Starts the yt-dlp update worker. Does not attach it to a task like `kickoff_with_task/2`

  Returns {:ok, %Oban.Job{}} | {:error, %Ecto.Changeset{}}
  """
  def kickoff do
    Oban.insert(UpdateWorker.new(%{}))
  end

  @doc """
  Updates yt-dlp and saves the version to the settings.

  This worker is scheduled to run via the Oban Cron plugin as well as on app boot.

  Returns :ok
  """
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("Updating yt-dlp")

    yt_dlp_runner().update()

    {:ok, yt_dlp_version} = yt_dlp_runner().version()
    Settings.set(yt_dlp_version: yt_dlp_version)

    Metrics.count("ytdlp.update.success")
    :ok
  rescue
    err ->
      Metrics.count("ytdlp.update.failed")
      Metrics.event("yt-dlp update failed", Exception.message(err), alert_type: "error")
      reraise err, __STACKTRACE__
  end

  defp yt_dlp_runner do
    Application.get_env(:pinchflat, :yt_dlp_runner)
  end
end
