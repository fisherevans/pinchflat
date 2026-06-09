defmodule Pinchflat.Metrics.Backend do
  @moduledoc """
  Pluggable sink for a flushed batch of metrics, events, and logs. Implement this behaviour
  to add a destination (Datadog today; Grafana/OTLP/etc. later) and point `:metrics_backend`
  at it.

  Callbacks receive already-aggregated, vendor-neutral data and translate it to their wire
  format. They may do network I/O but must be resilient: return `:ok | {:error, reason}` and
  never raise. The buffer isolates failures, but backends should not depend on that.

  Shapes:
    - series points: `%{name: String.t, type: :count | :gauge, value: number, tags: [String.t], timestamp: integer}`
      (`timestamp` is unix seconds; `count` values are summed over the flush window, `gauge` is the last value)
    - events: `%{title: String.t, text: String.t, tags: [String.t], alert_type: String.t, timestamp: integer}`
    - logs:   `%{level: atom, message: String.t, tags: [String.t], timestamp: integer}`
  """

  @callback ship_series(points :: [map()]) :: :ok | {:error, term()}
  @callback ship_events(events :: [map()]) :: :ok | {:error, term()}
  @callback ship_logs(logs :: [map()]) :: :ok | {:error, term()}
end
