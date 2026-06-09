defmodule Pinchflat.Metrics.LoggerHandler do
  @moduledoc """
  An OTP `:logger` handler that forwards log records at or above a threshold (default
  `:warning`, via `DATADOG_LOG_LEVEL`) to the metrics pipeline, which ships them to the
  backend's logs intake. This is how error detail (the "why") gets to Datadog without a
  log-collecting agent - the existing `Logger.error` download/index lines come along with
  whatever `source_id`/`media_item_id` metadata they carry.

  Attached (gated) at boot by `Pinchflat.Metrics.Setup`. Self-protecting: it never raises out
  of the log callback (a raising handler gets detached by OTP) and it drops records emitted by
  the metrics subsystem itself, so a shipping failure can never feed back into the log stream.
  """

  alias Pinchflat.Metrics

  @handler_id :pinchflat_metrics_logs
  @tag_keys [:source_id, :media_item_id, :media_id, :source]

  @doc "Registers the handler with a level threshold from config (default :warning)."
  def attach do
    level = Application.get_env(:pinchflat, :metrics_log_level, :warning)
    :logger.add_handler(@handler_id, __MODULE__, %{level: level})
  end

  @doc "Removes the handler (used in tests)."
  def detach, do: :logger.remove_handler(@handler_id)

  # The `:logger` handler callback.
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    unless from_metrics?(meta) do
      Metrics.log(level, format_message(msg), extract_tags(meta))
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp from_metrics?(%{mfa: {module, _fun, _arity}}) do
    module |> Atom.to_string() |> String.starts_with?("Elixir.Pinchflat.Metrics")
  end

  defp from_metrics?(_meta), do: false

  defp extract_tags(meta) do
    @tag_keys
    |> Enum.flat_map(fn key ->
      case Map.get(meta, key) do
        nil -> []
        value -> [{key, value}]
      end
    end)
    |> Map.new()
  end

  defp format_message({:string, chardata}), do: IO.chardata_to_string(chardata)
  defp format_message({:report, report}), do: inspect(report)

  defp format_message({format, args}) when is_list(args) do
    format |> :io_lib.format(args) |> IO.chardata_to_string()
  end

  defp format_message(other), do: inspect(other)
end
