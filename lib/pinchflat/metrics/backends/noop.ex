defmodule Pinchflat.Metrics.Backends.Noop do
  @moduledoc "The default backend: drops everything. Used when metrics are disabled."

  @behaviour Pinchflat.Metrics.Backend

  @impl true
  def ship_series(_points), do: :ok

  @impl true
  def ship_events(_events), do: :ok

  @impl true
  def ship_logs(_logs), do: :ok
end
