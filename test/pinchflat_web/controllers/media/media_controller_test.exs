defmodule PinchflatWeb.Media.MediaControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  describe "index" do
    test "renders the global media page", %{conn: conn} do
      conn = get(conn, ~p"/media")
      assert html_response(conn, 200) =~ "Media"
    end

    test "spans all sources", %{conn: conn} do
      source = source_fixture()
      item = media_item_fixture(%{source_id: source.id, media_filepath: nil})

      conn = get(conn, ~p"/media")
      assert html_response(conn, 200) =~ item.title
    end
  end
end
