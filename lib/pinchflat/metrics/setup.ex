defmodule Pinchflat.Metrics.Setup do
  @moduledoc """
  Wires the metrics subsystem into the application: the buffer child process and the
  telemetry/logger handlers. Everything here is gated on `:metrics_enabled`, so when metrics
  are off nothing is started or attached and there is zero overhead.
  """

  @doc "Supervision children for the metrics subsystem (the buffer), or [] when disabled."
  def children do
    if enabled?(), do: [Pinchflat.Metrics.Buffer], else: []
  end

  @doc """
  Attaches the telemetry handlers and logger handler. Called once at app start. No-op when
  disabled. Handlers are added incrementally as instrumentation lands.
  """
  def attach do
    if enabled?() do
      :ok
    end

    :ok
  end

  defp enabled?, do: Application.get_env(:pinchflat, :metrics_enabled, false)
end
