defmodule Pinchflat.Media.TableViews do
  @moduledoc """
  CRUD for user-saved media table views (`media_table_views`). Scope is "global" (the
  /media page) or "source" (a single source's table). Slugs are generated from the name
  and unique within a scope/source.
  """

  import Ecto.Query

  alias Pinchflat.Repo
  alias Pinchflat.Media.TableView
  alias Pinchflat.Media.TablePresets

  @doc "Saved views for a scope, ordered for the switcher. `source_id` is nil for global."
  def list_views(scope, source_id \\ nil) do
    from(v in TableView,
      where: v.scope == ^scope,
      order_by: [asc: v.position, asc: v.name]
    )
    |> scope_source(source_id)
    |> Repo.all()
  end

  @doc "A saved view by slug within a scope, or nil."
  def get_view(scope, source_id, slug) do
    from(v in TableView, where: v.scope == ^scope and v.slug == ^slug)
    |> scope_source(source_id)
    |> Repo.one()
  end

  @doc "A saved view by id, or nil."
  def get_view_by_id(id), do: Repo.get(TableView, id)

  @doc """
  Creates a saved view. Derives a unique slug from `:name` within the scope/source.
  `attrs` should include `:name`, `:scope`, `:config`, and (for source scope) `:source_id`.
  """
  def create_view(attrs) do
    attrs = normalize_keys(attrs)
    slug = unique_slug(attrs["name"] || "", attrs["scope"], attrs["source_id"])

    %TableView{}
    |> TableView.changeset(Map.put(attrs, "slug", slug))
    |> Repo.insert()
  end

  @doc "Deletes a saved view."
  def delete_view(%TableView{} = view), do: Repo.delete(view)

  @doc """
  Resolves a slug to a config map: a built-in preset first, then a saved view, falling back
  to the default preset. Returns `{config, resolved_slug}` so the caller knows what actually
  applied (e.g. an unknown slug resolves to the default).
  """
  def resolve_config(scope, source_id, slug) do
    cond do
      preset = TablePresets.get(slug) ->
        {preset.config, preset.slug}

      view = slug && get_view(scope, source_id, slug) ->
        {view.config, view.slug}

      true ->
        {TablePresets.default_config(), TablePresets.default_slug()}
    end
  end

  defp scope_source(query, nil), do: where(query, [v], is_nil(v.source_id))
  defp scope_source(query, source_id), do: where(query, [v], v.source_id == ^source_id)

  defp unique_slug(name, scope, source_id) do
    base = slugify(name)

    if slug_taken?(base, scope, source_id) do
      base <> "-" <> Integer.to_string(System.unique_integer([:positive]))
    else
      base
    end
  end

  defp slug_taken?(slug, scope, source_id) do
    # presets share the slug namespace, so don't let a saved view shadow one
    not is_nil(TablePresets.get(slug)) or not is_nil(get_view(scope, source_id, slug))
  end

  defp slugify(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    if slug == "", do: "view", else: slug
  end

  defp normalize_keys(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end
end
