defmodule Pinchflat.Media.MediaTableColumns do
  @moduledoc """
  Declarative column registry for the media table. Each column maps to the DB fields it
  needs (so the query only selects what's on screen - a big win on large libraries), a
  label, and an optional sort field (the sort whitelist; unknown sort keys are rejected).

  This module is the data contract shared by the query layer (`Media.list_media_items/1`)
  and the LiveView. The per-cell rendering lives in the LiveView, keyed by the same column
  keys, so HEEx stays out of the context layer.
  """

  # Always selected regardless of visible columns: row identity, links, status-driven
  # styling, and the near-universal title + error affordances.
  @always_select [:id, :uuid, :source_id, :download_status, :title, :last_error]

  # Order here is the canonical column order in pickers.
  @columns [
    {"title", %{label: "Title", select: [:title, :last_error], sort: :title}},
    {"original_title", %{label: "Original title", select: [:original_title], sort: :original_title}},
    {"status", %{label: "Status", select: [:download_status, :status_reason], sort: :download_status}},
    {"reason", %{label: "Reason", select: [:status_reason], sort: :status_reason}},
    {"source", %{label: "Source", select: [:source_id], sort: :source, needs_source: true}},
    {"uploaded_at", %{label: "Uploaded", select: [:uploaded_at], sort: :uploaded_at}},
    {"duration", %{label: "Duration", select: [:duration_seconds], sort: :duration_seconds}},
    {"size", %{label: "Size", select: [:media_size_bytes], sort: :media_size_bytes}},
    {"downloaded_at", %{label: "Downloaded", select: [:media_downloaded_at], sort: :media_downloaded_at}},
    {"evicted_at", %{label: "Evicted", select: [:last_evicted_at, :last_bytes_freed], sort: :last_evicted_at}},
    {"freed", %{label: "Freed", select: [:last_bytes_freed], sort: :last_bytes_freed}},
    {"short_form", %{label: "Short?", select: [:short_form_content], sort: :short_form_content}},
    {"livestream", %{label: "Live?", select: [:livestream], sort: :livestream}},
    {"ignored", %{label: "Ignored?", select: [:prevent_download], sort: :prevent_download}},
    {"media_id", %{label: "Video ID", select: [:media_id, :original_url], sort: :media_id}}
  ]

  @columns_map Map.new(@columns)
  @keys Enum.map(@columns, fn {key, _} -> key end)

  @doc "All columns as an ordered list of `{key, spec}`."
  def all, do: @columns

  @doc "All known column keys, in canonical order."
  def keys, do: @keys

  @doc "Whether `key` is a known column."
  def known?(key), do: Map.has_key?(@columns_map, key)

  @doc "The spec map for a column key, or nil."
  def spec(key), do: Map.get(@columns_map, key)

  @doc "Display label for a column key (falls back to the key)."
  def label(key) do
    case spec(key) do
      %{label: label} -> label
      _ -> key
    end
  end

  @doc "Keeps only known column keys, preserving caller order. Falls back to `default/0` when empty."
  def sanitize(keys) when is_list(keys) do
    case Enum.filter(keys, &known?/1) do
      [] -> default()
      valid -> valid
    end
  end

  def sanitize(_keys), do: default()

  @doc "A sensible default column set."
  def default, do: ["title", "status", "reason", "uploaded_at"]

  @doc "The DB fields to select for the given visible columns (union + the always-on set)."
  def select_fields(column_keys) do
    column_keys
    |> Enum.flat_map(fn key -> (spec(key) || %{}) |> Map.get(:select, []) end)
    |> Enum.concat(@always_select)
    |> Enum.uniq()
  end

  @doc "The sort field atom for a sort key, or nil if it isn't a sortable column."
  def sort_field(key) do
    case spec(to_string(key)) do
      %{sort: field} -> field
      _ -> nil
    end
  end

  @doc "Whether any visible column requires the source association (for preload/sort joins)."
  def needs_source?(column_keys) do
    Enum.any?(column_keys, fn key -> match?(%{needs_source: true}, spec(key)) end)
  end
end
