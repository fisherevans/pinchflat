defmodule Pinchflat.Metrics.Backends.Datadog do
  @moduledoc """
  Pushes metrics, events, and logs straight to Datadog's HTTP intake APIs - no Datadog agent.

    - series -> `POST https://api.{site}/api/v2/series`        (type 1 = count, 3 = gauge)
    - events -> `POST https://api.{site}/api/v1/events`
    - logs   -> `POST https://http-intake.logs.{site}/api/v2/logs`

  Authenticated with the `DD-API-KEY` header. Transport is the already-supervised
  `Pinchflat.Finch` pool. Config comes from `:pinchflat, Pinchflat.Metrics.Backends.Datadog`
  (set in `config/runtime.exs` from `DATADOG_*` env): `api_key`, `site` (default
  `datadoghq.com`), `service`, `env`, `tags`, `hostname`. All metric names are namespaced
  `pinchflat.`; `service`/`env` are appended as tags.

  Every callback is resilient: HTTP/transport failures return `{:error, reason}` (the buffer
  swallows it) and are never raised. The payload builders are pure and unit-tested.
  """

  @behaviour Pinchflat.Metrics.Backend

  @namespace "pinchflat."
  @count_type 1
  @gauge_type 3

  @impl true
  def ship_series([]), do: :ok

  def ship_series(points) do
    body = %{series: Enum.map(points, &series_entry(&1, config()))}
    deliver(metrics_url(config()), Jason.encode!(body))
  end

  @impl true
  def ship_events([]), do: :ok

  def ship_events(events) do
    # The events API takes one event per request; ship them individually.
    Enum.each(events, fn event ->
      deliver(events_url(config()), Jason.encode!(event_entry(event, config())))
    end)

    :ok
  end

  @impl true
  def ship_logs([]), do: :ok

  def ship_logs(logs) do
    body = Enum.map(logs, &log_entry(&1, config()))
    deliver(logs_url(config()), Jason.encode!(body))
  end

  # ----- pure payload builders (tested directly) -----

  @doc false
  def series_entry(%{name: name, type: type, value: value, tags: tags, timestamp: ts}, config) do
    %{
      metric: @namespace <> name,
      type: datadog_type(type),
      points: [%{timestamp: ts, value: value}],
      tags: tags ++ global_tags(config),
      resources: [%{name: hostname(config), type: "host"}]
    }
  end

  @doc false
  def event_entry(%{title: title, text: text, alert_type: alert_type, tags: tags, timestamp: ts}, config) do
    %{
      title: title,
      text: text,
      alert_type: alert_type,
      date_happened: ts,
      tags: tags ++ global_tags(config),
      host: hostname(config)
    }
  end

  @doc false
  def log_entry(%{level: level, message: message, tags: tags, timestamp: _ts}, config) do
    %{
      ddsource: "pinchflat",
      service: service(config),
      hostname: hostname(config),
      status: to_string(level),
      message: message,
      ddtags: Enum.join(tags ++ global_tags(config), ",")
    }
  end

  @doc false
  def metrics_url(config), do: "https://api.#{site(config)}/api/v2/series"
  @doc false
  def events_url(config), do: "https://api.#{site(config)}/api/v1/events"
  @doc false
  def logs_url(config), do: "https://http-intake.logs.#{site(config)}/api/v2/logs"

  defp datadog_type(:count), do: @count_type
  defp datadog_type(:gauge), do: @gauge_type
  defp datadog_type(_), do: 0

  defp global_tags(config) do
    base = config |> Keyword.get(:tags, "") |> parse_tag_string()

    env_tags =
      case Keyword.get(config, :env) do
        nil -> []
        "" -> []
        env -> ["env:#{env}"]
      end

    ["service:#{service(config)}"] ++ env_tags ++ base
  end

  defp parse_tag_string(nil), do: []
  defp parse_tag_string(""), do: []

  defp parse_tag_string(str) do
    str |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  defp site(config), do: Keyword.get(config, :site, "datadoghq.com")
  defp service(config), do: Keyword.get(config, :service, "pinchflat")
  defp hostname(config), do: Keyword.get(config, :hostname, "pinchflat")

  defp config, do: Application.get_env(:pinchflat, __MODULE__, [])

  # ----- transport -----

  defp deliver(url, body) do
    headers = [
      {"DD-API-KEY", Keyword.get(config(), :api_key, "")},
      {"Content-Type", "application/json"}
    ]

    case Finch.build(:post, url, headers, body) |> Finch.request(Pinchflat.Finch) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, "datadog #{status}: #{String.slice(to_string(resp_body), 0, 200)}"}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    err -> {:error, err}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
