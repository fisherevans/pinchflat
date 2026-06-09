defmodule Pinchflat.Metrics.Poller do
  @moduledoc """
  Periodically samples point-in-time system state into gauges. Currently the number of
  currently-executing Oban jobs per queue - notably `media_fetching`, the concurrent-downloads
  gauge. Driven by a `telemetry_poller` child started (gated) in `Pinchflat.Metrics.Setup`.
  """

  import Ecto.Query

  alias Pinchflat.Repo
  alias Pinchflat.Metrics

  # Report all of these every tick (including 0) so a gauge correctly falls to zero when a
  # queue goes idle, rather than going stale at its last non-zero value.
  @queues ~w(media_fetching fast_indexing media_collection_indexing remote_metadata local_data default)

  @doc "Called by telemetry_poller each period."
  def measure do
    counts =
      from(j in "oban_jobs", where: j.state == "executing", group_by: j.queue, select: {j.queue, count(j.id)})
      |> Repo.all()
      |> Map.new()

    Enum.each(@queues, fn queue ->
      Metrics.gauge("jobs.executing", Map.get(counts, queue, 0), %{queue: queue})
    end)
  rescue
    # Never let a transient DB error take down the poller.
    _ -> :ok
  end
end
