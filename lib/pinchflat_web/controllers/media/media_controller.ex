defmodule PinchflatWeb.Media.MediaController do
  use PinchflatWeb, :controller

  @doc """
  The global, cross-source media page. Server-rendered (so it gets the app layout/sidebar)
  and embeds the shared MediaTableLive with no source - the table spans all sources. An
  optional `?view=` seeds the initial preset/saved view so the URL is shareable.
  """
  def index(conn, params) do
    render(conn, :index, page_title: "Media", view: params["view"])
  end
end
