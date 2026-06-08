defmodule Pinchflat.Media.DownloadStatusTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Media.DownloadStatus

  # Builds an item under `source` with media_filepath cleared by default (so it isn't
  # auto-"downloaded"), then reloads it with the source/profile preloaded so compute/2
  # has everything it needs for full-fidelity reasons.
  defp item(source, attrs \\ %{}) do
    attrs
    |> Map.merge(%{source_id: source.id})
    |> Map.put_new(:media_filepath, nil)
    |> media_item_fixture()
    |> Repo.preload(source: :media_profile)
  end

  describe "compute/2 precedence" do
    setup do
      %{source: source_fixture()}
    end

    test "downloaded wins over everything", %{source: source} do
      mi = item(source, %{media_filepath: "/video/x.mp4", culled_at: now(), prevent_download: true})
      assert {:downloaded, nil} = DownloadStatus.compute(mi, mi.source)
    end

    test "culled (files deleted by retention) when culled_at is set", %{source: source} do
      mi = item(source, %{culled_at: now(), prevent_download: true})
      assert {:culled, "culled_retention"} = DownloadStatus.compute(mi, mi.source)
    end

    test "culled is tagged as a budget eviction when last_evicted_at is set", %{source: source} do
      mi = item(source, %{culled_at: now(), prevent_download: true, last_evicted_at: now()})
      assert {:culled, "evicted_budget"} = DownloadStatus.compute(mi, mi.source)
    end

    test "culled is tagged as cutoff when the item predates the source cutoff", %{source: _source} do
      source = source_fixture(%{download_cutoff_date: ~D[2030-01-01]})
      mi = item(source, %{culled_at: now(), uploaded_at: ~U[2020-01-01 00:00:00Z]})
      assert {:culled, "culled_cutoff"} = DownloadStatus.compute(mi, mi.source)
    end

    test "ignored when the user prevented download (and not culled)", %{source: source} do
      mi = item(source, %{prevent_download: true})
      assert {:ignored, "manually_ignored"} = DownloadStatus.compute(mi, mi.source)
    end

    test "pending when eligible and no error", %{source: source} do
      mi = item(source)
      assert {:pending, nil} = DownloadStatus.compute(mi, mi.source)
    end

    test "errored when eligible but the last attempt failed", %{source: source} do
      mi = item(source, %{last_error: "boom"})
      assert {:errored, "boom"} = DownloadStatus.compute(mi, mi.source)
    end

    test "an error on an item the source no longer wants reads as filtered, not errored" do
      source = source_fixture(%{title_exclude_regex: "skipme"})
      mi = item(source, %{title: "skipme please", last_error: "boom"})
      assert {:filtered, "title_exclude"} = DownloadStatus.compute(mi, mi.source)
    end
  end

  describe "compute/2 filtered reasons" do
    test "title include filter" do
      source = source_fixture(%{title_filter_regex: "keepme"})
      mi = item(source, %{title: "something else"})
      assert {:filtered, "title_filter"} = DownloadStatus.compute(mi, mi.source)
    end

    test "title exclude filter" do
      source = source_fixture(%{title_exclude_regex: "nope"})
      mi = item(source, %{title: "this is a nope"})
      assert {:filtered, "title_exclude"} = DownloadStatus.compute(mi, mi.source)
    end

    test "duration below the minimum" do
      source = source_fixture(%{min_duration_seconds: 600})
      mi = item(source, %{duration_seconds: 30})
      assert {:filtered, "duration"} = DownloadStatus.compute(mi, mi.source)
    end

    test "format preference excludes shorts" do
      profile = media_profile_fixture(%{shorts_behaviour: :exclude})
      source = source_fixture(%{media_profile_id: profile.id})
      mi = item(source, %{short_form_content: true})
      assert {:filtered, "format_preference"} = DownloadStatus.compute(mi, mi.source)
    end

    test "before the start cutoff" do
      source = source_fixture(%{download_cutoff_date: ~D[2030-01-01]})
      mi = item(source, %{uploaded_at: ~U[2020-01-01 00:00:00Z]})
      assert {:filtered, "cutoff_start"} = DownloadStatus.compute(mi, mi.source)
    end

    test "after the end cutoff" do
      source = source_fixture(%{download_end_date: ~D[2000-01-01]})
      mi = item(source, %{uploaded_at: ~U[2020-01-01 00:00:00Z]})
      assert {:filtered, "cutoff_end"} = DownloadStatus.compute(mi, mi.source)
    end

    test "excluded by a structured filter rule" do
      config = %{"match" => "all", "rules" => [%{"field" => "title", "operator" => "excludes", "value" => "blocked"}]}
      source = source_fixture(%{filter_config: config})
      mi = item(source, %{title: "blocked content"})
      assert {:filtered, "filter_rule"} = DownloadStatus.compute(mi, mi.source)
    end
  end

  describe "create/update hooks persist status" do
    test "create_media_item sets download_status" do
      source = source_fixture()
      mi = item(source)
      assert mi.download_status == "pending"
    end

    test "update_media_item recomputes status after a change" do
      source = source_fixture()
      mi = item(source)
      assert mi.download_status == "pending"

      {:ok, updated} = Media.update_media_item(mi, %{media_filepath: "/video/now.mp4"})
      assert updated.download_status == "downloaded"

      {:ok, ignored} = Media.update_media_item(updated, %{media_filepath: nil, prevent_download: true})
      assert ignored.download_status == "ignored"
    end
  end

  describe "recompute_download_status_for_source/1" do
    test "reclassifies items when a filter changes" do
      source = source_fixture()
      mi = item(source, %{title: "regular title"})
      assert mi.download_status == "pending"

      {:ok, source} = Pinchflat.Sources.update_source(source, %{title_exclude_regex: "regular"})
      count = DownloadStatus.recompute_download_status_for_source(source)
      assert count >= 1

      assert Repo.reload(mi).download_status == "filtered"
    end
  end

  describe "consistency with list_pending_media_items_for/1" do
    test "the eligible set (pending + errored) equals the live pending query" do
      source = source_fixture(%{title_exclude_regex: "block", min_duration_seconds: 60})

      # A spread across the precedence table.
      _downloaded = item(source, %{media_filepath: "/video/d.mp4"})
      pending = item(source, %{title: "good one", duration_seconds: 120})
      errored = item(source, %{title: "good two", duration_seconds: 120, last_error: "boom"})
      _filtered_title = item(source, %{title: "block this", duration_seconds: 120})
      _filtered_duration = item(source, %{title: "good three", duration_seconds: 5})
      _ignored = item(source, %{title: "good four", duration_seconds: 120, prevent_download: true})

      eligible_ids =
        from(m in Pinchflat.Media.MediaItem,
          where: m.source_id == ^source.id and m.download_status in ["pending", "errored"],
          select: m.id
        )
        |> Repo.all()
        |> MapSet.new()

      live_pending_ids = source |> Media.list_pending_media_items_for() |> MapSet.new(& &1.id)

      assert eligible_ids == live_pending_ids
      assert MapSet.equal?(eligible_ids, MapSet.new([pending.id, errored.id]))
    end
  end
end
