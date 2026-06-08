defmodule Pinchflat.Media.TableViewsTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Media.TableViews

  @config %{"status" => "pending", "columns" => ["title", "uploaded_at"]}

  describe "create_view/1 + list_views/2" do
    test "creates a global view and lists it" do
      {:ok, view} = TableViews.create_view(%{name: "My Global", scope: "global", config: @config})

      assert view.slug == "my-global"
      assert view.scope == "global"
      assert is_nil(view.source_id)
      assert TableViews.list_views("global") |> Enum.map(& &1.id) == [view.id]
    end

    test "creates a source-scoped view isolated from global and other sources" do
      source = source_fixture()
      {:ok, view} = TableViews.create_view(%{name: "Src View", scope: "source", source_id: source.id, config: @config})

      assert view.source_id == source.id
      assert TableViews.list_views("source", source.id) |> Enum.map(& &1.id) == [view.id]
      assert TableViews.list_views("source", source_fixture().id) == []
      assert TableViews.list_views("global") == []
    end

    test "avoids slug collisions with presets and existing views" do
      # "pending" is a preset slug, so a view named "Pending" must not reuse it
      {:ok, view} = TableViews.create_view(%{name: "Pending", scope: "global", config: @config})
      refute view.slug == "pending"

      {:ok, dup} = TableViews.create_view(%{name: "Same Name", scope: "global", config: @config})
      {:ok, dup2} = TableViews.create_view(%{name: "Same Name", scope: "global", config: @config})
      refute dup.slug == dup2.slug
    end
  end

  describe "resolve_config/3" do
    test "prefers a preset, then a saved view, then the default" do
      {preset_config, slug} = TableViews.resolve_config("global", nil, "pending")
      assert slug == "pending"
      assert preset_config["status"] == "pending"

      {:ok, view} = TableViews.create_view(%{name: "Saved", scope: "global", config: @config})
      {config, resolved} = TableViews.resolve_config("global", nil, view.slug)
      assert resolved == view.slug
      assert config == @config

      {_default_config, default_slug} = TableViews.resolve_config("global", nil, "does-not-exist")
      assert default_slug == "all"
    end
  end

  describe "delete_view/1" do
    test "removes a saved view" do
      {:ok, view} = TableViews.create_view(%{name: "Temp", scope: "global", config: @config})
      assert {:ok, _} = TableViews.delete_view(view)
      assert TableViews.get_view("global", nil, view.slug) == nil
    end
  end
end
