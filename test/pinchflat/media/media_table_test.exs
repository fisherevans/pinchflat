defmodule Pinchflat.Media.MediaTableTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Media

  defp pending_item(source, attrs \\ %{}) do
    attrs
    |> Map.merge(%{source_id: source.id})
    |> Map.put_new(:media_filepath, nil)
    |> media_item_fixture()
  end

  describe "list_media_items/1 scoping + status" do
    test "filters by source and by persisted status" do
      source = source_fixture()
      other = source_fixture()

      downloaded = media_item_fixture(%{source_id: source.id})
      pending = pending_item(source)
      _other_source = pending_item(other)

      result = Media.list_media_items(%{source_id: source.id, status: "pending"})
      assert Enum.map(result.records, & &1.id) == [pending.id]

      result = Media.list_media_items(%{source_id: source.id, status: "downloaded"})
      assert Enum.map(result.records, & &1.id) == [downloaded.id]

      result = Media.list_media_items(%{source_id: source.id, status: "all"})
      assert MapSet.new(result.records, & &1.id) == MapSet.new([downloaded.id, pending.id])
    end

    test "no source_id spans all sources" do
      a = pending_item(source_fixture())
      b = pending_item(source_fixture())

      result = Media.list_media_items(%{status: "pending"})
      ids = MapSet.new(result.records, & &1.id)
      assert MapSet.subset?(MapSet.new([a.id, b.id]), ids)
    end
  end

  describe "list_media_items/1 search" do
    test "matches a free-text term against the FTS index" do
      source = source_fixture()
      hit = pending_item(source, %{title: "Unmistakable Zebra Adventure"})
      _miss = pending_item(source, %{title: "Totally different thing"})

      result = Media.list_media_items(%{source_id: source.id, status: "pending", search: "Zebra"})
      assert Enum.map(result.records, & &1.id) == [hit.id]
      assert result.filtered_total == 1
    end
  end

  describe "list_media_items/1 sort" do
    test "sorts by a whitelisted column in both directions" do
      source = source_fixture()
      a = pending_item(source, %{title: "AAA"})
      b = pending_item(source, %{title: "BBB"})
      c = pending_item(source, %{title: "CCC"})

      asc = Media.list_media_items(%{source_id: source.id, status: "pending", sort: %{key: "title", direction: "asc"}})
      assert Enum.map(asc.records, & &1.id) == [a.id, b.id, c.id]

      desc =
        Media.list_media_items(%{source_id: source.id, status: "pending", sort: %{key: "title", direction: "desc"}})

      assert Enum.map(desc.records, & &1.id) == [c.id, b.id, a.id]
    end

    test "falls back to uploaded_at desc for an unknown sort key" do
      source = source_fixture()
      older = pending_item(source, %{uploaded_at: ~U[2020-01-01 00:00:00Z]})
      newer = pending_item(source, %{uploaded_at: ~U[2024-01-01 00:00:00Z]})

      result = Media.list_media_items(%{source_id: source.id, status: "pending", sort: %{key: "not_a_column"}})
      assert Enum.map(result.records, & &1.id) == [newer.id, older.id]
    end
  end

  describe "list_media_items/1 pagination" do
    test "paginates and clamps the page" do
      source = source_fixture()
      for i <- 1..5, do: pending_item(source, %{title: "Item #{i}"})

      page1 = Media.list_media_items(%{source_id: source.id, status: "pending", page: 1, page_size: 2})
      assert length(page1.records) == 2
      assert page1.filtered_total == 5
      assert page1.total_pages == 3
      assert page1.page == 1

      overshoot = Media.list_media_items(%{source_id: source.id, status: "pending", page: 99, page_size: 2})
      assert overshoot.page == 3
      assert length(overshoot.records) == 1
    end
  end

  describe "list_media_items/1 dynamic select" do
    test "only selects fields the visible columns need (plus the always-on set)" do
      source = source_fixture()
      media_item_fixture(%{source_id: source.id, media_size_bytes: 12_345})

      narrow = Media.list_media_items(%{source_id: source.id, status: "downloaded", columns: ["title"]})
      record = hd(narrow.records)
      # always-on
      assert record.id
      assert record.download_status == "downloaded"
      assert is_binary(record.title)
      # not requested -> not loaded
      assert is_nil(record.media_size_bytes)

      wide = Media.list_media_items(%{source_id: source.id, status: "downloaded", columns: ["size"]})
      assert hd(wide.records).media_size_bytes == 12_345
    end

    test "preloads the source association when a source column is shown" do
      source = source_fixture()
      pending_item(source)

      with_source = Media.list_media_items(%{source_id: source.id, status: "pending", columns: ["source"]})
      assert %Pinchflat.Sources.Source{} = hd(with_source.records).source

      without_source = Media.list_media_items(%{source_id: source.id, status: "pending", columns: ["title"]})
      assert %Ecto.Association.NotLoaded{} = hd(without_source.records).source
    end
  end

  describe "media_status_counts/1" do
    test "counts by status within a scope and totals" do
      source = source_fixture()
      media_item_fixture(%{source_id: source.id})
      pending_item(source)
      pending_item(source)

      counts = Media.media_status_counts(source.id)
      assert counts["downloaded"] == 1
      assert counts["pending"] == 2
      assert counts["all"] == 3
    end
  end
end
