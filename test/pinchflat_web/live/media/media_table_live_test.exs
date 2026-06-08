defmodule PinchflatWeb.Media.MediaTableLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias PinchflatWeb.Media.MediaTableLive

  defp pending_item(source, attrs \\ %{}) do
    attrs
    |> Map.merge(%{source_id: source.id})
    |> Map.put_new(:media_filepath, nil)
    |> media_item_fixture()
  end

  describe "per-source rendering" do
    test "shows an empty state with no records", %{conn: conn} do
      source = source_fixture()
      {:ok, _view, html} = live_isolated(conn, MediaTableLive, session: %{"source_id" => source.id})

      assert html =~ "Nothing here."
    end

    test "renders rows and the status filter", %{conn: conn} do
      source = source_fixture()
      item = pending_item(source)

      {:ok, _view, html} = live_isolated(conn, MediaTableLive, session: %{"source_id" => source.id})

      assert html =~ "Showing"
      assert html =~ item.title
      assert html =~ "All statuses"
    end
  end

  describe "status filtering" do
    test "filters to a single status", %{conn: conn} do
      source = source_fixture()
      downloaded = media_item_fixture(%{source_id: source.id})
      pending = pending_item(source)

      {:ok, view, _html} = live_isolated(conn, MediaTableLive, session: %{"source_id" => source.id})

      html = view |> element("form[phx-change=filter_status]") |> render_change(%{"status" => "pending"})
      assert html =~ pending.title
      refute html =~ downloaded.title

      html = view |> element("form[phx-change=filter_status]") |> render_change(%{"status" => "downloaded"})
      assert html =~ downloaded.title
      refute html =~ pending.title
    end
  end

  describe "column toggling" do
    test "adds a column when toggled on", %{conn: conn} do
      source = source_fixture()
      pending_item(source)

      {:ok, view, html} = live_isolated(conn, MediaTableLive, session: %{"source_id" => source.id})
      # The picker lists every column label, so assert on the actual column header instead.
      refute html =~ ~s(phx-value-sort_key="media_id")

      html = view |> element("input[phx-value-key=media_id]") |> render_click()
      assert html =~ ~s(phx-value-sort_key="media_id")
    end
  end

  describe "preset + saved views" do
    test "switching to a preset applies its status filter", %{conn: conn} do
      source = source_fixture()
      downloaded = media_item_fixture(%{source_id: source.id})
      pending = pending_item(source)

      {:ok, view, _html} = live_isolated(conn, MediaTableLive, session: %{"source_id" => source.id})

      html = view |> element("button[phx-value-slug=downloaded]") |> render_click()
      assert html =~ downloaded.title
      refute html =~ pending.title
    end

    test "saving a view persists it and shows it in the switcher", %{conn: conn} do
      source = source_fixture()
      pending_item(source)

      {:ok, view, _html} = live_isolated(conn, MediaTableLive, session: %{"source_id" => source.id})

      html = view |> element("form[phx-submit=save_view]") |> render_submit(%{"name" => "My Saved View"})
      assert html =~ "My Saved View"

      assert Pinchflat.Media.TableViews.list_views("source", source.id) |> Enum.map(& &1.name) == ["My Saved View"]
    end
  end

  describe "sorting" do
    test "toggles sort direction on a sortable header", %{conn: conn} do
      source = source_fixture()
      a = pending_item(source, %{title: "AAA"})
      z = pending_item(source, %{title: "ZZZ"})

      {:ok, view, _html} = live_isolated(conn, MediaTableLive, session: %{"source_id" => source.id})

      # Default sort is uploaded_at desc; clicking the Title header sorts by title asc.
      html = view |> element("th[phx-value-sort_key=title]") |> render_click()
      assert String.match?(html, ~r/#{a.title}.*#{z.title}/s)
    end
  end
end
