defmodule PinchflatWeb.Posters.PosterController do
  use PinchflatWeb, :controller

  def index(conn, _params) do
    render(conn, :index, page_title: "Posters")
  end
end
