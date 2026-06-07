defmodule Pinchflat.Downloading.RetentionEvictionTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.RetentionEviction

  describe "record/2 and recent_for/2" do
    test "records evictions and returns them newest first" do
      source = source_fixture(%{keep_count: 5, eviction_strategy: :oldest})
      mi1 = media_item_fixture(%{source_id: source.id, media_size_bytes: 100})
      mi2 = media_item_fixture(%{source_id: source.id, media_size_bytes: 200})

      {:ok, _} = RetentionEviction.record(source, mi1)
      {:ok, _} = RetentionEviction.record(source, mi2)

      assert [first, second] = RetentionEviction.recent_for(source)
      # mi2 was recorded last, so it comes first
      assert first.media_id == mi2.media_id
      assert first.bytes_freed == 200
      assert first.keep_count == 5
      assert first.eviction_strategy == "oldest"
      assert second.media_id == mi1.media_id
    end

    test "only returns evictions for the given source" do
      source = source_fixture()
      other = source_fixture()
      media_item = media_item_fixture(%{source_id: source.id})
      RetentionEviction.record(source, media_item)

      assert RetentionEviction.recent_for(other) == []
    end
  end
end
