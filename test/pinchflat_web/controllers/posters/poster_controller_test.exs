defmodule PinchflatWeb.Posters.PosterControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.SourcesFixtures

  describe "index" do
    test "renders the posters page", %{conn: conn} do
      conn = get(conn, ~p"/posters")
      assert html_response(conn, 200) =~ "Posters"
    end
  end

  describe "poster" do
    test "404s when the source has no poster on disk", %{conn: conn} do
      source = source_fixture()
      conn = get(conn, ~p"/sources/#{source.id}/poster")
      assert response(conn, 404)
    end
  end
end
