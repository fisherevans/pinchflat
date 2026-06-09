defmodule Pinchflat.Metrics.Backends.DatadogTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Metrics.Backends.Datadog

  @config [
    api_key: "secret",
    site: "datadoghq.com",
    service: "pinchflat",
    env: "prod",
    tags: "team:media, region:us",
    hostname: "nas-1"
  ]

  describe "series_entry/2" do
    test "namespaces the metric, maps the type, and merges global tags + host" do
      point = %{name: "download.completed", type: :count, value: 3, tags: ["source_id:1"], timestamp: 1_700_000_000}

      entry = Datadog.series_entry(point, @config)

      assert entry.metric == "pinchflat.download.completed"
      assert entry.type == 1
      assert entry.points == [%{timestamp: 1_700_000_000, value: 3}]
      assert entry.resources == [%{name: "nas-1", type: "host"}]
      assert "source_id:1" in entry.tags
      assert "service:pinchflat" in entry.tags
      assert "env:prod" in entry.tags
      assert "team:media" in entry.tags
      assert "region:us" in entry.tags
    end

    test "maps gauge to type 3" do
      point = %{name: "downloads.executing", type: :gauge, value: 2, tags: [], timestamp: 1}
      assert Datadog.series_entry(point, @config).type == 3
    end
  end

  describe "event_entry/2" do
    test "carries title/text/alert_type and merged tags" do
      event = %{
        title: "Download failed",
        text: "Sign in",
        alert_type: "error",
        tags: ["reason:auth_needed"],
        timestamp: 5
      }

      entry = Datadog.event_entry(event, @config)

      assert entry.title == "Download failed"
      assert entry.alert_type == "error"
      assert entry.date_happened == 5
      assert "reason:auth_needed" in entry.tags
      assert "service:pinchflat" in entry.tags
    end
  end

  describe "log_entry/2" do
    test "sets ddsource/service/status and comma-joined ddtags" do
      log = %{level: :error, message: "boom", tags: ["media_item_id:42"], timestamp: 9}

      entry = Datadog.log_entry(log, @config)

      assert entry.ddsource == "pinchflat"
      assert entry.service == "pinchflat"
      assert entry.status == "error"
      assert entry.message == "boom"
      assert entry.ddtags =~ "media_item_id:42"
      assert entry.ddtags =~ "service:pinchflat"
    end
  end

  describe "urls" do
    test "default site" do
      assert Datadog.metrics_url(@config) == "https://api.datadoghq.com/api/v2/series"
      assert Datadog.events_url(@config) == "https://api.datadoghq.com/api/v1/events"
      assert Datadog.logs_url(@config) == "https://http-intake.logs.datadoghq.com/api/v2/logs"
    end

    test "eu site" do
      eu = Keyword.put(@config, :site, "datadoghq.eu")
      assert Datadog.metrics_url(eu) == "https://api.datadoghq.eu/api/v2/series"
      assert Datadog.logs_url(eu) == "https://http-intake.logs.datadoghq.eu/api/v2/logs"
    end
  end

  describe "empty batches" do
    test "ship_* are no-ops on empty input (no network)" do
      assert Datadog.ship_series([]) == :ok
      assert Datadog.ship_events([]) == :ok
      assert Datadog.ship_logs([]) == :ok
    end
  end
end
