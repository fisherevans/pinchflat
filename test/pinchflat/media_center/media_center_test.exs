defmodule Pinchflat.MediaCenterTest do
  use Pinchflat.DataCase

  alias Pinchflat.Settings
  alias Pinchflat.MediaCenter

  setup :verify_on_exit!

  defp configure(attrs), do: {:ok, _} = Settings.update_setting(Settings.record(), attrs)

  describe "refresh_plex/0" do
    test "GETs the section refresh endpoint with the token header when configured" do
      configure(%{plex_url: "http://plex:32400/", plex_token: "tok123", plex_library_section: "4"})

      expect(HTTPClientMock, :get, fn url, headers ->
        assert url == "http://plex:32400/library/sections/4/refresh?force=1"
        assert {"X-Plex-Token", "tok123"} in headers
        {:ok, ""}
      end)

      assert :ok = MediaCenter.refresh_plex() |> then(fn _ -> :ok end)
    end

    test "is skipped when not configured" do
      configure(%{plex_url: "", plex_token: "", plex_library_section: ""})
      assert :skip = MediaCenter.refresh_plex()
    end
  end

  describe "refresh_jellyfin/0" do
    test "POSTs the library refresh with the MediaBrowser token when configured" do
      configure(%{jellyfin_url: "http://jelly:8096", jellyfin_token: "key456"})

      expect(HTTPClientMock, :post, fn url, headers ->
        assert url == "http://jelly:8096/Library/Refresh"
        assert {"Authorization", "MediaBrowser Token=key456"} in headers
        {:ok, ""}
      end)

      MediaCenter.refresh_jellyfin()
    end

    test "is skipped when not configured" do
      configure(%{jellyfin_url: "", jellyfin_token: ""})
      assert :skip = MediaCenter.refresh_jellyfin()
    end
  end
end
