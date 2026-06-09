defmodule Pinchflat.Metrics do
  @moduledoc """
  Public API for emitting behavioral metrics, events, and error logs to a third-party
  observability backend (Datadog, etc.) without a local agent.

  Off by default - everything here is a near-free no-op unless `:metrics_enabled` is set
  (which happens when `DATADOG_API_KEY` is present; see `config/runtime.exs`). When enabled,
  emissions are handed to `Pinchflat.Metrics.Buffer` (async, aggregated, batched).

  Design contract: **emitting a metric must never affect application behavior.** Every call
  is wrapped so a bug or a down backend can never raise into or block a caller (e.g. a
  download worker). Tags are a plain map; values are coerced to Datadog tag strings.

  Examples:

      Metrics.count("download.completed", 1, %{source_id: source.id})
      Metrics.count("download.bytes", size, %{source_id: id})
      Metrics.gauge("downloads.executing", n, %{queue: "media_fetching"})
      Metrics.event("Download failed", message, alert_type: "error", tags: %{reason: :auth_needed})
      Metrics.log(:error, "yt-dlp error ...", %{media_item_id: id})
  """

  alias Pinchflat.Metrics.Buffer

  @doc "Whether metrics export is enabled."
  def enabled?, do: Application.get_env(:pinchflat, :metrics_enabled, false)

  @doc "Increment a counter. `value` is summed over the flush window."
  def count(name, value \\ 1, tags \\ %{}), do: emit({:count, name, value, normalize_tags(tags)})

  @doc "Set a gauge to the latest value."
  def gauge(name, value, tags \\ %{}), do: emit({:gauge, name, value, normalize_tags(tags)})

  @doc """
  Emit a discrete event. `opts`: `:alert_type` ("error"/"warning"/"info"/"success",
  default "info") and `:tags` (a map).
  """
  def event(title, text, opts \\ []) do
    alert_type = Keyword.get(opts, :alert_type, "info")
    tags = opts |> Keyword.get(:tags, %{}) |> normalize_tags()
    emit({:event, to_string(title), to_string(text), alert_type, tags})
  end

  @doc "Forward a log line (used by the Logger handler; level + message + tag-able metadata)."
  def log(level, message, metadata \\ %{}), do: emit({:log, level, to_string(message), normalize_tags(metadata)})

  defp emit(message) do
    if enabled?() do
      # Fire-and-forget. Guard against the buffer being absent or any unexpected error so a
      # metric emission can never propagate a failure into the caller.
      try do
        Buffer.record(message)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # Tags come in as a map (e.g. %{source_id: 5, reason: :auth_needed}) and become a sorted
  # list of "key:value" strings, both for the aggregation key and the Datadog tag format.
  defp normalize_tags(tags) when is_map(tags) do
    tags
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> "#{k}:#{v}" end)
    |> Enum.sort()
  end

  defp normalize_tags(tags) when is_list(tags), do: tags |> Enum.map(&to_string/1) |> Enum.sort()
  defp normalize_tags(_), do: []
end
