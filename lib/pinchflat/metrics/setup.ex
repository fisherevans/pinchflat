defmodule Pinchflat.Metrics.Setup do
  @moduledoc """
  Wires the metrics subsystem into the application: the buffer child process and the
  telemetry/logger handlers. Everything here is gated on `:metrics_enabled`, so when metrics
  are off nothing is started or attached and there is zero overhead.
  """

  @doc "Supervision children for the metrics subsystem, or [] when disabled."
  def children do
    if enabled?() do
      [
        Pinchflat.Metrics.Buffer,
        {:telemetry_poller,
         name: Pinchflat.Metrics.Poller,
         period: :timer.seconds(15),
         measurements: [{Pinchflat.Metrics.Poller, :measure, []}]}
      ]
    else
      []
    end
  end

  @doc """
  Attaches the telemetry handlers (and, later, the logger handler). Called once at app start.
  No-op when disabled.
  """
  def attach do
    if enabled?() do
      Pinchflat.Metrics.ObanHandler.attach()
    end

    :ok
  end

  defp enabled?, do: Application.get_env(:pinchflat, :metrics_enabled, false)
end
