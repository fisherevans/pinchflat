defmodule Pinchflat.Metrics.LoggerHandlerTest do
  use ExUnit.Case, async: false

  import Mox

  alias Pinchflat.Metrics.Buffer
  alias Pinchflat.Metrics.LoggerHandler

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
    stub(MetricsBackendMock, :ship_series, fn _ -> :ok end)
    stub(MetricsBackendMock, :ship_events, fn _ -> :ok end)
    :ok
  end

  test "forwards a log record with level, message, and metadata tags" do
    parent = self()
    expect(MetricsBackendMock, :ship_logs, fn logs -> send(parent, {:logs, logs}) && :ok end)

    event = %{
      level: :error,
      msg: {:string, "yt-dlp error for media item #42"},
      meta: %{source_id: 7, media_item_id: 42}
    }

    assert :ok = LoggerHandler.log(event, %{})
    Buffer.flush()

    assert_receive {:logs, [log]}
    assert log.level == :error
    assert log.message =~ "yt-dlp error"
    assert "source_id:7" in log.tags
    assert "media_item_id:42" in log.tags
  end

  test "formats {format, args} messages" do
    parent = self()
    expect(MetricsBackendMock, :ship_logs, fn logs -> send(parent, {:logs, logs}) && :ok end)

    LoggerHandler.log(%{level: :warning, msg: {~c"count is ~p", [3]}, meta: %{}}, %{})
    Buffer.flush()

    assert_receive {:logs, [log]}
    assert log.message =~ "count is 3"
  end

  test "drops records emitted by the metrics subsystem itself (loop guard)" do
    # No ship_logs expectation: if the guard failed and this forwarded, the empty-flush below
    # would not call ship_logs anyway, but the record would be present. Assert nothing ships.
    expect(MetricsBackendMock, :ship_logs, 0, fn _ -> :ok end)

    event = %{level: :error, msg: {:string, "datadog down"}, meta: %{mfa: {Pinchflat.Metrics.Buffer, :flush, 1}}}
    assert :ok = LoggerHandler.log(event, %{})
    Buffer.flush()
  end
end
