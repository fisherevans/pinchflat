defmodule Pinchflat.Downloading.RetentionPolicyTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Sources.Source
  alias Pinchflat.Downloading.RetentionPolicy

  # Five items, one per day, ascending. Sizes and durations vary so each strategy
  # produces a distinct ordering.
  defp sample_items do
    [
      item(id: 1, uploaded_at: ~U[2024-01-01 00:00:00Z], media_size_bytes: 50, duration_seconds: 100),
      item(id: 2, uploaded_at: ~U[2024-01-02 00:00:00Z], media_size_bytes: 50, duration_seconds: 400),
      item(id: 3, uploaded_at: ~U[2024-01-03 00:00:00Z], media_size_bytes: 50, duration_seconds: 200),
      item(id: 4, uploaded_at: ~U[2024-01-04 00:00:00Z], media_size_bytes: 50, duration_seconds: 500),
      item(id: 5, uploaded_at: ~U[2024-01-05 00:00:00Z], media_size_bytes: 50, duration_seconds: 300)
    ]
  end

  defp item(attrs) do
    struct(MediaItem, Keyword.merge([media_filepath: "/video/x.mp4", prevent_culling: false], attrs))
  end

  defp source(attrs), do: struct(Source, attrs)

  defp evicted_ids(source, items) do
    source |> RetentionPolicy.eviction_candidates(items) |> Enum.map(& &1.id) |> Enum.sort()
  end

  describe "eviction_candidates/2 - no budget" do
    test "returns nothing when neither budget is set" do
      assert RetentionPolicy.eviction_candidates(source(%{}), sample_items()) == []
    end
  end

  describe "eviction_candidates/2 - keep_count" do
    test "keeps the most recent N and evicts the rest (oldest strategy)" do
      src = source(%{keep_count: 2, eviction_strategy: :oldest})
      # keeps 5, 4 -> evicts 1, 2, 3
      assert evicted_ids(src, sample_items()) == [1, 2, 3]
    end

    test "keep_count of 0 evicts everything" do
      src = source(%{keep_count: 0, eviction_strategy: :oldest})
      assert evicted_ids(src, sample_items()) == [1, 2, 3, 4, 5]
    end

    test "keep_count larger than the library evicts nothing" do
      src = source(%{keep_count: 99, eviction_strategy: :oldest})
      assert evicted_ids(src, sample_items()) == []
    end
  end

  describe "eviction_candidates/2 - keep_bytes" do
    test "keeps the most recent items that fit, evicts the rest" do
      # 50 bytes each, budget 120 -> keep 2 newest (100 bytes), third would hit 150 > 120
      src = source(%{keep_bytes: 120, eviction_strategy: :oldest})
      assert evicted_ids(src, sample_items()) == [1, 2, 3]
    end

    test "evicts a contiguous tail rather than backfilling leftover space" do
      items = [
        item(id: 1, uploaded_at: ~U[2024-01-01 00:00:00Z], media_size_bytes: 30),
        item(id: 2, uploaded_at: ~U[2024-01-02 00:00:00Z], media_size_bytes: 60),
        item(id: 3, uploaded_at: ~U[2024-01-03 00:00:00Z], media_size_bytes: 60)
      ]

      # oldest strategy keeps newest-first: 3 (60), 2 would hit 120 > 100 -> evict 2 and 1.
      # Item 1 (30 bytes) would fit in leftover space but is NOT backfilled.
      src = source(%{keep_bytes: 100, eviction_strategy: :oldest})
      assert evicted_ids(src, items) == [1, 2]
    end
  end

  describe "eviction_candidates/2 - most restrictive wins" do
    test "count and bytes together evict the union" do
      # keep_count 3 alone -> evict [1,2]; keep_bytes 120 alone -> evict [1,2,3].
      # Most restrictive (bytes) wins.
      src = source(%{keep_count: 3, keep_bytes: 120, eviction_strategy: :oldest})
      assert evicted_ids(src, sample_items()) == [1, 2, 3]
    end
  end

  describe "eviction_candidates/2 - strategies" do
    test "newest evicts newest first (keeps earliest)" do
      src = source(%{keep_count: 2, eviction_strategy: :newest})
      # keeps 1, 2 -> evicts 3, 4, 5
      assert evicted_ids(src, sample_items()) == [3, 4, 5]
    end

    test "shortest evicts shortest first (keeps longest)" do
      src = source(%{keep_count: 2, eviction_strategy: :shortest})
      # durations: 4=500, 2=400, 5=300, 3=200, 1=100 -> keep 4,2 -> evict 1,3,5
      assert evicted_ids(src, sample_items()) == [1, 3, 5]
    end

    test "longest evicts longest first (keeps shortest)" do
      src = source(%{keep_count: 2, eviction_strategy: :longest})
      # durations asc: 1=100, 3=200, 5=300, 2=400, 4=500 -> keep 1,3 -> evict 2,4,5
      assert evicted_ids(src, sample_items()) == [2, 4, 5]
    end
  end

  describe "eviction_candidates/2 - exclusions" do
    test "never evicts pinned (prevent_culling) items" do
      items =
        sample_items()
        |> List.update_at(0, &%{&1 | prevent_culling: true})

      src = source(%{keep_count: 0, eviction_strategy: :oldest})
      # item 1 is pinned, so even with keep_count 0 it survives
      assert evicted_ids(src, items) == [2, 3, 4, 5]
    end

    test "ignores items that aren't downloaded" do
      items =
        sample_items()
        |> List.update_at(4, &%{&1 | media_filepath: nil})

      src = source(%{keep_count: 1, eviction_strategy: :oldest})
      # only 4 downloaded items (1-4); keep newest (4) -> evict 1,2,3. Item 5 isn't counted.
      assert evicted_ids(src, items) == [1, 2, 3]
    end
  end

  describe "summarize/2" do
    test "reports everything kept when no budget is set" do
      summary = RetentionPolicy.summarize(source(%{}), sample_items())
      assert summary == %{total: 5, keep: 5, evict: 0, bytes_to_free: 0}
    end

    test "reports keep/evict counts and bytes freed for a budget" do
      src = source(%{keep_count: 2, eviction_strategy: :oldest})
      summary = RetentionPolicy.summarize(src, sample_items())

      # 5 total, keep 2, evict 3 at 50 bytes each
      assert summary == %{total: 5, keep: 2, evict: 3, bytes_to_free: 150}
    end

    test "counts pinned items as kept" do
      items = List.update_at(sample_items(), 0, &%{&1 | prevent_culling: true})
      src = source(%{keep_count: 0, eviction_strategy: :oldest})
      summary = RetentionPolicy.summarize(src, items)

      assert summary.total == 5
      assert summary.keep == 1
      assert summary.evict == 4
    end
  end

  describe "eviction_candidates/2 - nil handling" do
    test "treats nil size as zero bytes" do
      items = [
        item(id: 1, uploaded_at: ~U[2024-01-01 00:00:00Z], media_size_bytes: nil),
        item(id: 2, uploaded_at: ~U[2024-01-02 00:00:00Z], media_size_bytes: nil)
      ]

      # nil sizes contribute 0, so a positive byte budget evicts nothing
      src = source(%{keep_bytes: 10, eviction_strategy: :oldest})
      assert evicted_ids(src, items) == []
    end

    test "treats nil upload date as oldest" do
      items = [
        item(id: 1, uploaded_at: nil, media_size_bytes: 50),
        item(id: 2, uploaded_at: ~U[2024-01-02 00:00:00Z], media_size_bytes: 50)
      ]

      # oldest strategy keeps newest; nil date is oldest so item 1 is evicted
      src = source(%{keep_count: 1, eviction_strategy: :oldest})
      assert evicted_ids(src, items) == [1]
    end

    test "falls back to :oldest for a nil/unknown strategy instead of crashing" do
      items = sample_items()
      src = source(%{keep_count: 2, eviction_strategy: nil})

      # behaves like :oldest - keep the 2 most recent (4, 5), evict the rest
      assert evicted_ids(src, items) == [1, 2, 3]
    end
  end
end
