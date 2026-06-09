defmodule Pinchflat.Metrics.BufferTest do
  # async: false - mutates the global :metrics_enabled/:metrics_backend env and uses the
  # singleton-named Buffer with Mox in global mode.
  use ExUnit.Case, async: false

  import Mox

  alias Pinchflat.Metrics
  alias Pinchflat.Metrics.Buffer

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    prev_enabled = Application.get_env(:pinchflat, :metrics_enabled)
    prev_backend = Application.get_env(:pinchflat, :metrics_backend)
    Application.put_env(:pinchflat, :metrics_backend, MetricsBackendMock)

    on_exit(fn ->
      Application.put_env(:pinchflat, :metrics_enabled, prev_enabled)
      Application.put_env(:pinchflat, :metrics_backend, prev_backend)
    end)

    # Long flush interval so only the explicit Buffer.flush() in each test triggers a flush.
    start_supervised!({Buffer, flush_interval: 60_000})
    :ok
  end

  defp enable, do: Application.put_env(:pinchflat, :metrics_enabled, true)

  describe "facade gating" do
    test "no-ops and never calls the backend when disabled" do
      Application.put_env(:pinchflat, :metrics_enabled, false)
      # If the facade emitted while disabled, this 0-call expectation would fail verification.
      expect(MetricsBackendMock, :ship_series, 0, fn _ -> :ok end)

      Metrics.count("download.completed", 5, %{source_id: 1})
      Buffer.flush()
    end
  end

  describe "aggregation + flush" do
    setup do
      enable()
      stub(MetricsBackendMock, :ship_events, fn _ -> :ok end)
      stub(MetricsBackendMock, :ship_logs, fn _ -> :ok end)
      :ok
    end

    test "counts are summed by name+tags and shipped as count points" do
      parent = self()
      expect(MetricsBackendMock, :ship_series, fn points -> send(parent, {:series, points}) && :ok end)

      Metrics.count("download.completed", 1, %{source_id: 1})
      Metrics.count("download.completed", 2, %{source_id: 1})
      Metrics.count("download.completed", 1, %{source_id: 2})

      Buffer.flush()

      assert_receive {:series, points}
      s1 = Enum.find(points, &(&1.tags == ["source_id:1"]))
      s2 = Enum.find(points, &(&1.tags == ["source_id:2"]))
      assert %{name: "download.completed", type: :count, value: 3} = s1
      assert %{name: "download.completed", type: :count, value: 1} = s2
    end

    test "gauges keep the last value" do
      parent = self()
      expect(MetricsBackendMock, :ship_series, fn points -> send(parent, {:series, points}) && :ok end)

      Metrics.gauge("downloads.executing", 1, %{queue: "media_fetching"})
      Metrics.gauge("downloads.executing", 3, %{queue: "media_fetching"})

      Buffer.flush()

      assert_receive {:series, points}
      gauge = Enum.find(points, &(&1.type == :gauge))
      assert %{name: "downloads.executing", value: 3, tags: ["queue:media_fetching"]} = gauge
    end

    test "events and logs are forwarded" do
      parent = self()
      stub(MetricsBackendMock, :ship_series, fn _ -> :ok end)
      expect(MetricsBackendMock, :ship_events, fn events -> send(parent, {:events, events}) && :ok end)
      expect(MetricsBackendMock, :ship_logs, fn logs -> send(parent, {:logs, logs}) && :ok end)

      Metrics.event("Download failed", "Sign in to confirm", alert_type: "error", tags: %{reason: :auth_needed})
      Metrics.log(:error, "yt-dlp error", %{media_item_id: 42})

      Buffer.flush()

      assert_receive {:events, [event]}
      assert event.title == "Download failed" and event.alert_type == "error"
      assert "reason:auth_needed" in event.tags

      assert_receive {:logs, [log]}
      assert log.level == :error and log.message =~ "yt-dlp error"
      assert "media_item_id:42" in log.tags
    end

    test "a flush clears the buffer (no double-counting on the next flush)" do
      parent = self()

      expect(MetricsBackendMock, :ship_series, fn points -> send(parent, {:first, points}) && :ok end)
      Metrics.count("download.completed", 4)
      Buffer.flush()
      assert_receive {:first, [%{value: 4}]}

      # Nothing emitted since; the next flush ships an empty series (backend not called).
      expect(MetricsBackendMock, :ship_series, 0, fn _ -> :ok end)
      Buffer.flush()
    end

    test "a backend failure does not crash the buffer" do
      expect(MetricsBackendMock, :ship_series, fn _ -> raise "datadog is down" end)
      Metrics.count("download.completed", 1)

      Buffer.flush()
      # The buffer is still alive and serving after the backend blew up.
      assert :ok = Buffer.flush()
    end
  end
end
