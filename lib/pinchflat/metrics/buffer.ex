defmodule Pinchflat.Metrics.Buffer do
  @moduledoc """
  Aggregates emitted metrics in memory and flushes them to the configured backend on a timer.

  - counts are summed by `{name, tags}` over the flush window
  - gauges keep the last value by `{name, tags}`
  - events and logs are kept as bounded lists

  Buffers are bounded so a stalled/slow backend can never grow memory without limit - excess
  is dropped and counted. Flushing is isolated per stream: a backend error on one stream does
  not crash the buffer or lose the others. Started only when metrics are enabled.
  """

  use GenServer
  require Logger

  @flush_interval :timer.seconds(15)
  @max_series_keys 5_000
  @max_events 500
  @max_logs 2_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Record a normalized emission (called by the facade; fire-and-forget)."
  def record(message, server \\ __MODULE__), do: GenServer.cast(server, {:record, message})

  @doc "Force a synchronous flush. Mainly for tests."
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :flush_interval, @flush_interval)
    schedule_flush(interval)
    {:ok, %{interval: interval, counts: %{}, gauges: %{}, events: [], logs: [], dropped: 0}}
  end

  @impl true
  def handle_cast({:record, message}, state), do: {:noreply, accumulate(message, state)}

  @impl true
  def handle_info(:flush, state) do
    state = do_flush(state)
    schedule_flush(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, do_flush(state)}

  defp accumulate({:count, name, value, tags}, state) do
    key = {name, tags}

    if Map.has_key?(state.counts, key) or map_size(state.counts) < @max_series_keys do
      update_in(state.counts, &Map.update(&1, key, value, fn acc -> acc + value end))
    else
      %{state | dropped: state.dropped + 1}
    end
  end

  defp accumulate({:gauge, name, value, tags}, state) do
    key = {name, tags}

    if Map.has_key?(state.gauges, key) or map_size(state.gauges) < @max_series_keys do
      put_in(state.gauges[key], value)
    else
      %{state | dropped: state.dropped + 1}
    end
  end

  defp accumulate({:event, title, text, alert_type, tags}, state) do
    if length(state.events) < @max_events do
      event = %{title: title, text: text, alert_type: alert_type, tags: tags, timestamp: now()}
      %{state | events: [event | state.events]}
    else
      %{state | dropped: state.dropped + 1}
    end
  end

  defp accumulate({:log, level, message, tags}, state) do
    if length(state.logs) < @max_logs do
      %{state | logs: [%{level: level, message: message, tags: tags, timestamp: now()} | state.logs]}
    else
      %{state | dropped: state.dropped + 1}
    end
  end

  defp accumulate(_unknown, state), do: state

  defp do_flush(state) do
    backend = Application.get_env(:pinchflat, :metrics_backend, Pinchflat.Metrics.Backends.Noop)
    ts = now()

    series =
      build_points(state.counts, :count, ts) ++ build_points(state.gauges, :gauge, ts)

    safe_ship(backend, :ship_series, series)
    safe_ship(backend, :ship_events, Enum.reverse(state.events))
    safe_ship(backend, :ship_logs, Enum.reverse(state.logs))

    if state.dropped > 0 do
      Logger.debug("Pinchflat.Metrics.Buffer dropped #{state.dropped} emissions (buffer full)")
    end

    %{state | counts: %{}, gauges: %{}, events: [], logs: [], dropped: 0}
  end

  defp build_points(map, type, ts) do
    Enum.map(map, fn {{name, tags}, value} ->
      %{name: name, type: type, value: value, tags: tags, timestamp: ts}
    end)
  end

  # Empty streams skip the network entirely. Backend errors are swallowed (and logged at
  # :debug only, to avoid feeding the log-forwarding loop).
  defp safe_ship(_backend, _fun, []), do: :ok

  defp safe_ship(backend, fun, payload) do
    case apply(backend, fun, [payload]) do
      :ok -> :ok
      {:error, reason} -> Logger.debug("Pinchflat.Metrics #{fun} failed: #{inspect(reason)}")
    end
  rescue
    err -> Logger.debug("Pinchflat.Metrics #{fun} raised: #{inspect(err)}")
  catch
    kind, reason -> Logger.debug("Pinchflat.Metrics #{fun} threw: #{inspect({kind, reason})}")
  end

  defp schedule_flush(interval), do: Process.send_after(self(), :flush, interval)

  defp now, do: System.system_time(:second)
end
