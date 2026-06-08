defmodule Pinchflat.Media.TablePresets do
  @moduledoc """
  Built-in, read-only media table views. Each preset is a `%{slug, name, config}` with the
  same `config` shape as a saved `TableView`, so presets and saved views are interchangeable
  in the switcher. The four leading presets map directly onto the persisted statuses.
  """

  @presets [
    %{
      slug: "pending",
      name: "Pending downloads",
      config: %{
        "status" => "pending",
        "columns" => ["title", "uploaded_at", "duration"],
        "sort" => %{"key" => "uploaded_at", "direction" => "desc"}
      }
    },
    %{
      slug: "downloaded",
      name: "Downloaded",
      config: %{
        "status" => "downloaded",
        "columns" => ["title", "uploaded_at", "size", "downloaded_at"],
        "sort" => %{"key" => "media_downloaded_at", "direction" => "desc"}
      }
    },
    %{
      slug: "filtered",
      name: "Skipped / filtered",
      config: %{
        "status" => "filtered",
        "columns" => ["title", "reason", "uploaded_at", "duration"],
        "sort" => %{"key" => "uploaded_at", "direction" => "desc"}
      }
    },
    %{
      slug: "evicted",
      name: "Evicted / culled",
      config: %{
        "status" => "culled",
        "columns" => ["title", "evicted_at", "freed", "reason"],
        "sort" => %{"key" => "last_evicted_at", "direction" => "desc"}
      }
    },
    %{
      slug: "all",
      name: "All media",
      config: %{
        "status" => "all",
        "columns" => ["title", "status", "reason", "uploaded_at"],
        "sort" => %{"key" => "uploaded_at", "direction" => "desc"}
      }
    },
    %{
      slug: "ignored",
      name: "Ignored",
      config: %{
        "status" => "ignored",
        "columns" => ["title", "uploaded_at"],
        "sort" => %{"key" => "uploaded_at", "direction" => "desc"}
      }
    },
    %{
      slug: "errored",
      name: "Errored",
      config: %{
        "status" => "errored",
        "columns" => ["title", "reason", "uploaded_at"],
        "sort" => %{"key" => "uploaded_at", "direction" => "desc"}
      }
    }
  ]

  @default_slug "all"

  @doc "All presets, in display order."
  def all, do: @presets

  @doc "The slug used when no view is specified."
  def default_slug, do: @default_slug

  @doc "The preset for a slug, or nil."
  def get(slug) do
    Enum.find(@presets, fn preset -> preset.slug == slug end)
  end

  @doc "The default preset's config."
  def default_config, do: get(@default_slug).config
end
