defmodule Pinchflat.MediaCenter do
  @moduledoc """
  Triggers a library refresh on Plex and/or Jellyfin so newly organized files and
  replaced posters show up without waiting for the media center's own scan. Connection
  details live in Settings; a server with blank settings is skipped.

  Library-wide refreshes (cheap; the servers only re-read changed files) - per-show
  refresh would need looking up internal IDs.
  """

  require Logger

  alias Pinchflat.Settings

  @doc "Refreshes both configured servers. Returns :ok."
  def refresh do
    refresh_plex()
    refresh_jellyfin()
    :ok
  end

  @doc "Refreshes in a detached task so callers never block on a slow server."
  def refresh_async do
    Task.start(fn -> refresh() end)
    :ok
  end

  def refresh_plex do
    url = Settings.get!(:plex_url)
    token = Settings.get!(:plex_token)
    section = Settings.get!(:plex_library_section)

    if present?(url) && present?(token) && present?(section) do
      endpoint = "#{String.trim_trailing(url, "/")}/library/sections/#{section}/refresh?force=1"
      log("Plex", http_client().get(endpoint, [{"X-Plex-Token", token}]))
    else
      :skip
    end
  end

  def refresh_jellyfin do
    url = Settings.get!(:jellyfin_url)
    token = Settings.get!(:jellyfin_token)

    if present?(url) && present?(token) do
      endpoint = "#{String.trim_trailing(url, "/")}/Library/Refresh"
      log("Jellyfin", http_client().post(endpoint, [{"Authorization", "MediaBrowser Token=#{token}"}]))
    else
      :skip
    end
  end

  defp present?(value), do: is_binary(value) && String.trim(value) != ""

  defp log(name, {:ok, _}), do: Logger.info("#{name} library refresh triggered")

  defp log(name, {:error, reason}) do
    Logger.warning("#{name} library refresh failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp http_client, do: Application.get_env(:pinchflat, :http_client, Pinchflat.HTTP.HTTPClient)
end
