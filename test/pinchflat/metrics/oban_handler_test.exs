defmodule Pinchflat.Metrics.ObanHandlerTest do
  use ExUnit.Case, async: false

  import Mox

  alias Pinchflat.Metrics.Buffer
  alias Pinchflat.Metrics.ObanHandler

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    prev_enabled = Application.get_env(:pinchflat, :metrics_enabled)
    prev_backend = Application.get_env(:pinchflat, :metrics_backend)
    Application.put_env(:pinchflat, :metrics_enabled, true)
    Application.put_env(:pinchflat, :metrics_backend, MetricsBackendMock)

    on_exit(fn ->
      Application.put_env(:pinchflat, :metrics_enabled, prev_enabled)
      Application.put_env(:pinchflat, :metrics_backend, prev_backend)
    end)

    start_supervised!({Buffer, flush_interval: 60_000})
    stub(MetricsBackendMock, :ship_events, fn _ -> :ok end)
    stub(MetricsBackendMock, :ship_logs, fn _ -> :ok end)
    :ok
  end

  defp job, do: %Oban.Job{queue: "media_fetching", worker: "Pinchflat.Downloading.MediaDownloadWorker"}
  defp measurements, do: %{duration: System.convert_time_unit(250, :millisecond, :native)}

  test "a job stop emits job.completed + duration tagged by queue/worker" do
    parent = self()
    expect(MetricsBackendMock, :ship_series, fn points -> send(parent, {:series, points}) && :ok end)

    ObanHandler.handle_event([:oban, :job, :stop], measurements(), %{job: job()}, nil)
    Buffer.flush()

    assert_receive {:series, points}
    completed = Enum.find(points, &(&1.name == "job.completed"))
    duration = Enum.find(points, &(&1.name == "job.duration_ms.sum"))

    assert completed.value == 1
    assert "queue:media_fetching" in completed.tags
    assert "worker:Pinchflat.Downloading.MediaDownloadWorker" in completed.tags
    assert duration.value == 250
  end

  test "a job exception emits job.failed" do
    parent = self()
    expect(MetricsBackendMock, :ship_series, fn points -> send(parent, {:series, points}) && :ok end)

    ObanHandler.handle_event([:oban, :job, :exception], measurements(), %{job: job()}, nil)
    Buffer.flush()

    assert_receive {:series, points}
    assert Enum.find(points, &(&1.name == "job.failed")).value == 1
  end
end
