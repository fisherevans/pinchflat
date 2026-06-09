defmodule Pinchflat.Organizing.PressureGuard do
  @moduledoc """
  A "is it safe to run a heavy `/media` job right now?" backstop for the NFS homelab
  deployment, where a bulk organize colliding with an active download - or running while the
  box is already memory/CPU pressured - has wedged the host hard enough to need a reset.

  `check/0` returns `:ok` or `{:snooze, seconds}` so a worker can defer back to Oban instead
  of pushing a heavy run onto a stressed box. The thresholds mirror the sidecars this replaces
  (MemAvailable floor, load vs nproc, skip while a download is in flight). On non-Linux hosts
  (local dev / CI) the `/proc` probes are absent and it never reports memory/load pressure.
  """

  import Ecto.Query

  alias Pinchflat.Repo

  @mem_floor_mb 700
  @snooze_seconds 60
  @download_snooze_seconds 30

  @doc "Returns :ok when it is safe to run a heavy /media job, else {:snooze, seconds}."
  def check do
    cond do
      low_memory?() -> {:snooze, @snooze_seconds}
      high_load?() -> {:snooze, @snooze_seconds}
      downloads_active?() -> {:snooze, @download_snooze_seconds}
      true -> :ok
    end
  end

  defp low_memory? do
    case mem_available_mb() do
      nil -> false
      mb -> mb < @mem_floor_mb
    end
  end

  defp high_load? do
    case load_avg_1min() do
      nil -> false
      load -> load > 2 * System.schedulers_online()
    end
  end

  defp downloads_active? do
    Repo.exists?(from(j in "oban_jobs", where: j.state == "executing" and j.queue == "media_fetching"))
  rescue
    _ -> false
  end

  defp mem_available_mb do
    with {:ok, content} <- File.read("/proc/meminfo"),
         [_, kb] <- Regex.run(~r/MemAvailable:\s+(\d+)\s+kB/, content) do
      kb |> String.to_integer() |> div(1024)
    else
      _ -> nil
    end
  end

  defp load_avg_1min do
    with {:ok, content} <- File.read("/proc/loadavg"),
         [first | _] <- String.split(content, " "),
         {load, _} <- Float.parse(first) do
      load
    else
      _ -> nil
    end
  end
end
