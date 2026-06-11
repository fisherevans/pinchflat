defmodule PinchflatWeb.Media.MediaTableLive do
  @moduledoc """
  The shared media table. Used two ways:

    - embedded per-source (via `live_render` from the source show page) with a `source_id`
      in the session
    - standalone at `/media` across all sources (Phase 5), with no source_id

  Status/columns/sort/search/pagination are all driven server-side off the persisted
  `download_status`, so the table is just a thin view over `Media.list_media_items/1`.
  """

  use PinchflatWeb, :live_view

  alias Pinchflat.Media
  alias Pinchflat.Sources
  alias Pinchflat.Media.MediaTableColumns
  alias Pinchflat.Media.TableViews
  alias Pinchflat.Media.TablePresets

  @default_page_size 25

  def mount(params, session, socket) do
    PinchflatWeb.Endpoint.subscribe("media_table")

    # When embedded via live_render (no router), params is :not_mounted_at_router.
    params = if is_map(params), do: params, else: %{}
    source_id = normalize_source_id(session["source_id"] || params["source_id"])
    source = source_id && Sources.get_source!(source_id)
    scope = if source_id, do: "source", else: "global"
    slug = session["view"] || params["view"] || TablePresets.default_slug()

    socket =
      socket
      |> assign(
        source_id: source_id,
        source: source,
        scope: scope,
        page: 1,
        page_size: @default_page_size,
        search: nil,
        source_ids: [],
        # Options for the global "Shows" multi-select. Only loaded for the cross-source table.
        sources: if(scope == "global", do: source_options(), else: []),
        views: TableViews.list_views(scope, source_id)
      )
      |> apply_view(slug)
      |> load_records()

    {:ok, socket}
  end

  def handle_event("search_term", params, socket) do
    {:noreply, socket |> assign(search: blank_to_nil(params["q"]), page: 1) |> load_records()}
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, socket |> assign(status: status, active_view: nil, page: 1) |> load_records()}
  end

  def handle_event("toggle_source", %{"id" => id}, socket) do
    case normalize_source_option_id(id) do
      [id] ->
        current = socket.assigns.source_ids
        ids = if id in current, do: List.delete(current, id), else: [id | current]
        {:noreply, socket |> assign(source_ids: ids, active_view: nil, page: 1) |> load_records()}

      [] ->
        {:noreply, socket}
    end
  end

  def handle_event("clear_sources", _params, socket) do
    {:noreply, socket |> assign(source_ids: [], active_view: nil, page: 1) |> load_records()}
  end

  def handle_event("page_change", %{"direction" => direction}, socket) do
    delta = if direction == "inc", do: 1, else: -1
    {:noreply, socket |> assign(page: socket.assigns.page + delta) |> load_records()}
  end

  def handle_event("sort_update", %{"sort_key" => key}, socket) do
    {:noreply,
     socket |> assign(sort: toggle_sort(socket.assigns.sort, key), active_view: nil, page: 1) |> load_records()}
  end

  def handle_event("toggle_column", %{"key" => key}, socket) do
    {:noreply,
     socket |> assign(columns: toggle_column(socket.assigns.columns, key), active_view: nil) |> load_records()}
  end

  def handle_event("select_view", %{"slug" => slug}, socket) do
    {:noreply, socket |> apply_view(slug) |> load_records()}
  end

  def handle_event("save_view", %{"name" => name}, socket) do
    a = socket.assigns

    case TableViews.create_view(%{name: name, scope: a.scope, source_id: a.source_id, config: current_config(a)}) do
      {:ok, view} ->
        socket =
          socket
          |> assign(views: TableViews.list_views(a.scope, a.source_id))
          |> apply_view(view.slug)
          |> load_records()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't save that view.")}
    end
  end

  def handle_event("delete_view", %{"id" => id}, socket) do
    a = socket.assigns

    case TableViews.get_view_by_id(id) do
      nil ->
        {:noreply, socket}

      view ->
        TableViews.delete_view(view)
        next_slug = if a.active_view == view.slug, do: TablePresets.default_slug(), else: a.active_view

        socket =
          socket
          |> assign(views: TableViews.list_views(a.scope, a.source_id))
          |> apply_view(next_slug)
          |> load_records()

        {:noreply, socket}
    end
  end

  def handle_event("reload_page", _params, socket) do
    PinchflatWeb.Endpoint.broadcast("media_table", "reload", nil)
    {:noreply, socket}
  end

  def handle_info(%{topic: "media_table", event: "reload"}, socket) do
    {:noreply, load_records(socket)}
  end

  defp load_records(socket) do
    a = socket.assigns

    result =
      Media.list_media_items(%{
        source_id: a.source_id,
        source_ids: a.source_ids,
        status: a.status,
        search: a.search,
        sort: a.sort,
        page: a.page,
        page_size: a.page_size,
        columns: a.columns
      })

    assign(socket,
      records: result.records,
      total: result.total,
      filtered_total: result.filtered_total,
      page: result.page,
      total_pages: result.total_pages,
      counts: Media.media_status_counts(a.source_id)
    )
  end

  defp toggle_sort(%{key: current, direction: dir}, key) do
    if to_string(current) == key do
      %{key: key, direction: if(dir == :asc, do: :desc, else: :asc)}
    else
      %{key: key, direction: :asc}
    end
  end

  defp toggle_column(columns, key) do
    if key in columns do
      # keep at least one column so the table never collapses to nothing
      case Enum.reject(columns, &(&1 == key)) do
        [] -> columns
        rest -> rest
      end
    else
      MediaTableColumns.sanitize(columns ++ [key])
    end
  end

  # Resolves a view slug (preset or saved view) into table state. Unknown slugs fall back
  # to the default preset. Columns/status are sanitized so a stale saved view degrades
  # gracefully rather than erroring.
  defp apply_view(socket, slug) do
    {config, resolved_slug} = TableViews.resolve_config(socket.assigns.scope, socket.assigns.source_id, slug)

    assign(socket,
      active_view: resolved_slug,
      status: config["status"] || "all",
      columns: resolve_columns(config["columns"], socket.assigns.source_id),
      sort: resolve_sort_config(config["sort"]),
      source_ids: resolve_source_ids(config["source_ids"]),
      page_size: config["page_size"] || @default_page_size,
      page: 1
    )
  end

  # Sources for the global "Shows" multi-select, alphabetized by display name.
  defp source_options do
    Sources.list_sources()
    |> Enum.sort_by(&String.downcase(&1.custom_name || ""))
  end

  defp resolve_source_ids(ids) when is_list(ids), do: Enum.flat_map(ids, &normalize_source_option_id/1)
  defp resolve_source_ids(_), do: []

  defp normalize_source_option_id(id) when is_integer(id), do: [id]

  defp normalize_source_option_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> [n]
      _ -> []
    end
  end

  defp normalize_source_option_id(_), do: []

  defp resolve_columns(columns, source_id) do
    columns = MediaTableColumns.sanitize(columns || [])
    # The global table always wants the source column so rows are attributable.
    if is_nil(source_id) and "source" not in columns, do: ["source" | columns], else: columns
  end

  defp resolve_sort_config(%{"key" => key, "direction" => dir}) when is_binary(key) do
    %{key: key, direction: if(dir == "asc", do: :asc, else: :desc)}
  end

  defp resolve_sort_config(_sort), do: %{key: "uploaded_at", direction: :desc}

  defp current_config(assigns) do
    %{
      "status" => assigns.status,
      "columns" => assigns.columns,
      "sort" => %{"key" => to_string(assigns.sort.key), "direction" => to_string(assigns.sort.direction)},
      "source_ids" => assigns.source_ids,
      "page_size" => assigns.page_size
    }
  end

  defp normalize_source_id(nil), do: nil
  defp normalize_source_id(id) when is_integer(id), do: id

  defp normalize_source_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  # ----- render -----

  def render(assigns) do
    ~H"""
    <div>
      <nav class="mb-4 flex flex-wrap items-center gap-2 border-b border-stroke pb-3 dark:border-strokedark">
        <button
          :for={preset <- TablePresets.all()}
          type="button"
          phx-click="select_view"
          phx-value-slug={preset.slug}
          class={["rounded-full px-3 py-1 text-sm", view_pill_class(@active_view == preset.slug)]}
        >
          {preset.name}
          <span class="ml-1 opacity-70">{preset_count(@counts, preset)}</span>
        </button>

        <span
          :for={view <- @views}
          class={[
            "flex items-center gap-1 rounded-full py-1 pl-3 pr-1.5 text-sm",
            view_pill_class(@active_view == view.slug)
          ]}
        >
          <button type="button" phx-click="select_view" phx-value-slug={view.slug}>{view.name}</button>
          <button
            type="button"
            phx-click="delete_view"
            phx-value-id={view.id}
            data-confirm="Delete this saved view?"
            title="Delete view"
            class="opacity-70 hover:opacity-100"
          >
            &times;
          </button>
        </span>

        <div class="relative ml-auto" x-data="{ open: false }">
          <button
            type="button"
            x-on:click="open = !open"
            class="flex items-center gap-1 rounded border border-stroke px-3 py-1 text-sm dark:border-strokedark"
          >
            <.icon name="hero-bookmark" class="h-4 w-4" /> Save view
          </button>
          <form
            phx-submit="save_view"
            x-show="open"
            x-cloak
            x-on:click.outside="open = false"
            class="absolute right-0 z-10 mt-1 flex w-64 gap-2 rounded border border-stroke bg-boxdark p-3 shadow-lg dark:border-strokedark"
          >
            <input
              type="text"
              name="name"
              required
              placeholder="Name this view"
              class="min-w-0 flex-1 rounded border border-stroke bg-transparent px-2 py-1 text-sm dark:border-strokedark dark:bg-meta-4"
            />
            <button type="submit" class="rounded bg-primary px-3 py-1 text-sm text-white">Save</button>
          </form>
        </div>
      </nav>

      <header class="mb-4 flex flex-wrap items-center justify-between gap-3">
        <span class="flex items-center">
          <.icon_button icon_name="hero-arrow-path" class="h-10 w-10" phx-click="reload_page" tooltip="Refresh" />
          <span class="ml-2">
            Showing <.localized_number number={length(@records)} /> of <.localized_number number={@filtered_total} />
          </span>
        </span>

        <div class="flex flex-wrap items-center gap-2">
          <div :if={@scope == "global"} class="relative" x-data="{ open: false }">
            <button
              type="button"
              x-on:click="open = !open"
              class="flex items-center gap-1 rounded border border-stroke px-3 py-2 dark:border-strokedark dark:bg-meta-4"
            >
              <.icon name="hero-tv" class="h-5 w-5" /> Shows
              <span :if={@source_ids != []} class="ml-1 rounded-full bg-primary px-1.5 text-xs text-white">
                {length(@source_ids)}
              </span>
            </button>
            <div
              x-show="open"
              x-cloak
              x-on:click.outside="open = false"
              class="absolute left-0 z-10 mt-1 w-72 rounded border border-stroke bg-boxdark p-3 shadow-lg dark:border-strokedark"
            >
              <div class="mb-2 flex items-center justify-between text-xs text-bodydark2">
                <span>{if @source_ids == [], do: "All shows", else: "#{length(@source_ids)} selected"}</span>
                <button :if={@source_ids != []} type="button" phx-click="clear_sources" class="text-primary hover:underline">
                  Clear
                </button>
              </div>
              <div class="max-h-72 overflow-y-auto">
                <label
                  :for={src <- @sources}
                  class="flex cursor-pointer items-center gap-2 py-1 text-sm"
                  title={src.custom_name}
                >
                  <input type="checkbox" checked={src.id in @source_ids} phx-click="toggle_source" phx-value-id={src.id} />
                  <span class="truncate">{src.custom_name}</span>
                </label>
              </div>
            </div>
          </div>

          <form phx-change="filter_status">
            <select
              name="status"
              class="rounded border border-stroke bg-transparent px-3 py-2 dark:border-strokedark dark:bg-meta-4"
            >
              <option value="all" selected={@status == "all"}>All statuses</option>
              <option :for={status <- status_options()} value={status} selected={@status == status}>
                {humanize_status(status)}
              </option>
            </select>
          </form>

          <div class="relative" x-data="{ open: false }">
            <button
              type="button"
              x-on:click="open = !open"
              class="flex items-center gap-1 rounded border border-stroke px-3 py-2 dark:border-strokedark dark:bg-meta-4"
            >
              <.icon name="hero-view-columns" class="h-5 w-5" /> Columns
            </button>
            <div
              x-show="open"
              x-cloak
              x-on:click.outside="open = false"
              class="absolute right-0 z-10 mt-1 w-56 rounded border border-stroke bg-boxdark p-3 shadow-lg dark:border-strokedark"
            >
              <label
                :for={{key, spec} <- MediaTableColumns.all()}
                class="flex cursor-pointer items-center gap-2 py-1 text-sm"
              >
                <input type="checkbox" checked={key in @columns} phx-click="toggle_column" phx-value-key={key} />
                {spec.label}
              </label>
            </div>
          </div>

          <div class="rounded-md bg-meta-4">
            <div class="relative">
              <span class="absolute left-2 top-1/2 flex -translate-y-1/2">
                <.icon name="hero-magnifying-glass" />
              </span>
              <form phx-change="search_term" phx-submit="search_term">
                <input
                  type="text"
                  name="q"
                  value={@search}
                  placeholder="Search in table..."
                  class="w-full border-0 bg-transparent pl-9 pr-4 focus:outline-none focus:ring-0"
                  phx-debounce="200"
                />
              </form>
            </div>
          </div>
        </div>
      </header>

      <div :if={@filtered_total == 0} class="py-8 text-center text-bodydark2">
        Nothing here.
      </div>

      <.table
        :if={@filtered_total > 0}
        rows={@records}
        table_class="text-white"
        sort_key={@sort.key}
        sort_direction={@sort.direction}
      >
        <:col :let={item} :for={key <- @columns} label={MediaTableColumns.label(key)} sort_key={sort_key_for(key)}>
          <.cell column={key} item={item} />
        </:col>
        <:col :let={item} label="" class="flex justify-end">
          <.icon_link href={~p"/sources/#{item.source_id}/media/#{item.id}/edit"} icon="hero-pencil-square" class="mr-2" />
        </:col>
      </.table>

      <section :if={@total_pages > 1} class="mt-5 flex justify-center">
        <.live_pagination_controls page_number={@page} total_pages={@total_pages} />
      </section>
    </div>
    """
  end

  attr :column, :string, required: true
  attr :item, :any, required: true

  defp cell(%{column: "title"} = assigns) do
    ~H"""
    <section class="flex items-center space-x-1">
      <.tooltip :if={@item.last_error} tooltip={@item.last_error} position="bottom-right" tooltip_class="w-64">
        <.icon name="hero-exclamation-circle-solid" class="text-red-500" />
      </.tooltip>
      <span class="max-w-xs truncate">
        <.subtle_link href={~p"/sources/#{@item.source_id}/media/#{@item.id}"}>{@item.title}</.subtle_link>
      </span>
    </section>
    """
  end

  defp cell(%{column: "original_title"} = assigns) do
    ~H"""
    <span class="max-w-xs truncate">{@item.original_title || @item.title}</span>
    """
  end

  defp cell(%{column: "status"} = assigns) do
    ~H"""
    <span class={["inline-block rounded px-2 py-1 text-xs font-medium", status_class(@item.download_status)]}>
      {humanize_status(@item.download_status)}
    </span>
    """
  end

  defp cell(%{column: "reason"} = assigns) do
    ~H"""
    {humanize_reason(@item.status_reason)}
    """
  end

  defp cell(%{column: "source"} = assigns) do
    ~H"""
    <.subtle_link :if={@item.source} href={~p"/sources/#{@item.source_id}"}>{@item.source.custom_name}</.subtle_link>
    """
  end

  defp cell(%{column: "uploaded_at"} = assigns) do
    ~H"""
    {maybe_date(@item.uploaded_at)}
    """
  end

  defp cell(%{column: "downloaded_at"} = assigns) do
    ~H"""
    {maybe_date(@item.media_downloaded_at)}
    """
  end

  defp cell(%{column: "evicted_at"} = assigns) do
    ~H"""
    {maybe_date(@item.last_evicted_at)}
    """
  end

  defp cell(%{column: "duration"} = assigns) do
    ~H"""
    {format_duration(@item.duration_seconds)}
    """
  end

  defp cell(%{column: "size"} = assigns) do
    ~H"""
    <.readable_filesize :if={@item.media_size_bytes} byte_size={@item.media_size_bytes} />
    <span :if={is_nil(@item.media_size_bytes)}>-</span>
    """
  end

  defp cell(%{column: "freed"} = assigns) do
    ~H"""
    <.readable_filesize :if={@item.last_bytes_freed} byte_size={@item.last_bytes_freed} />
    <span :if={is_nil(@item.last_bytes_freed)}>-</span>
    """
  end

  defp cell(%{column: "media_id"} = assigns) do
    ~H"""
    <.subtle_link href={@item.original_url}>{@item.media_id}</.subtle_link>
    """
  end

  defp cell(%{column: column} = assigns) when column in ["short_form", "livestream", "ignored"] do
    ~H"""
    <.icon name={if bool_field(@item, @column), do: "hero-check", else: "hero-x-mark"} />
    """
  end

  defp cell(assigns), do: ~H""

  defp bool_field(item, "short_form"), do: item.short_form_content
  defp bool_field(item, "livestream"), do: item.livestream
  defp bool_field(item, "ignored"), do: item.prevent_download

  defp sort_key_for(key) do
    if MediaTableColumns.sort_field(key), do: key, else: nil
  end

  defp view_pill_class(true), do: "bg-primary text-white"
  defp view_pill_class(false), do: "bg-meta-4 text-bodydark hover:text-white"

  defp preset_count(counts, preset), do: Map.get(counts, preset.config["status"], 0)

  defp maybe_date(nil), do: "-"
  defp maybe_date(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d")

  defp format_duration(nil), do: "-"

  defp format_duration(seconds) when is_integer(seconds) do
    hours = div(seconds, 3600)
    minutes = seconds |> rem(3600) |> div(60)
    secs = rem(seconds, 60)

    if hours > 0 do
      "#{hours}:#{pad(minutes)}:#{pad(secs)}"
    else
      "#{minutes}:#{pad(secs)}"
    end
  end

  defp pad(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

  defp status_options, do: MediaTableColumns.statuses()

  defp humanize_status(nil), do: "-"
  defp humanize_status(status), do: status |> String.replace("_", " ") |> String.capitalize()

  defp humanize_reason(nil), do: "-"
  defp humanize_reason(reason), do: reason |> String.replace("_", " ") |> String.capitalize()

  defp status_class("downloaded"), do: "bg-green-900 text-green-200"
  defp status_class("pending"), do: "bg-blue-900 text-blue-200"
  defp status_class("filtered"), do: "bg-gray-700 text-gray-200"
  defp status_class("culled"), do: "bg-yellow-900 text-yellow-200"
  defp status_class("ignored"), do: "bg-gray-700 text-gray-300"
  defp status_class("errored"), do: "bg-red-900 text-red-200"
  defp status_class(_), do: "bg-gray-700 text-gray-200"
end
