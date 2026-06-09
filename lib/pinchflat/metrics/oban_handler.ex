defmodule Pinchflat.Metrics.ObanHandler do
  @moduledoc """
  Translates Oban's built-in job telemetry into per-queue job metrics, giving free
  success/failure/duration coverage of every worker. Attached once at boot when metrics are
  enabled. Duration is emitted as a summed counter (`job.duration_ms.sum`) so an average can
  be derived in the backend as `sum / job.completed`.
  """

  alias Pinchflat.Metrics

  @handler_id "pinchflat-metrics-oban"
  @events [[:oban, :job, :stop], [:oban, :job, :exception]]

  def attach do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
  end

  def handle_event([:oban, :job, :stop], measurements, %{job: job}, _config) do
    emit("job.completed", measurements, job)
  end

  def handle_event([:oban, :job, :exception], measurements, %{job: job}, _config) do
    emit("job.failed", measurements, job)
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  defp emit(name, measurements, job) do
    tags = %{queue: job.queue, worker: job.worker}
    Metrics.count(name, 1, tags)
    Metrics.count("job.duration_ms.sum", duration_ms(measurements), tags)
  end

  defp duration_ms(%{duration: duration}), do: System.convert_time_unit(duration, :native, :millisecond)
  defp duration_ms(_), do: 0
end
