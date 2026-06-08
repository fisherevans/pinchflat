defmodule PinchflatWeb.Posters.PosterLive do
  use PinchflatWeb, :live_view

  import Ecto.Query

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Sources
  alias Pinchflat.MediaCenter
  alias Pinchflat.Sources.Source
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Metadata.MetadataFileHelpers

  @accept ~w(.jpg .jpeg .png .webp)
  @max_size 15_000_000

  def mount(_params, _session, socket) do
    socket
    |> assign(selected_id: nil, cache_bust: System.system_time(:second), sources: load_sources())
    |> allow_upload(:poster,
      accept: @accept,
      max_entries: 1,
      max_file_size: @max_size,
      auto_upload: true,
      progress: &handle_progress/3
    )
    |> then(&{:ok, &1})
  end

  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_id, String.to_integer(id))}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  # auto_upload fires this as the entry uploads; consume + save once it's done.
  def handle_progress(:poster, entry, socket) do
    if entry.done? do
      source = Enum.find(socket.assigns.sources, &(&1.id == socket.assigns.selected_id))
      result = consume_uploaded_entry(socket, entry, fn %{path: tmp} -> save_poster(source, tmp) end)

      socket =
        case result do
          {:ok, _target} ->
            socket
            |> put_flash(:info, "Poster updated for #{source.custom_name}. Refreshing media center.")
            |> assign(cache_bust: System.system_time(:second), sources: load_sources())

          {:error, message} ->
            put_flash(socket, :error, message)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Returns {:ok, {:ok, path}} | {:ok, {:error, msg}} shape expected by consume.
  defp save_poster(nil, _tmp), do: {:ok, {:error, "Select a source first"}}

  defp save_poster(source, tmp) do
    case series_directory(source) do
      {:ok, dir} ->
        target = Path.join(dir, "poster.jpg")
        staging = target <> ".uploading"
        FilesystemUtils.cp_p!(tmp, staging)
        File.rename!(staging, target)
        {:ok, _} = Sources.update_source(source, %{poster_filepath: target})
        MediaCenter.refresh_async()
        {:ok, {:ok, target}}

      :error ->
        {:ok, {:error, "Couldn't determine a folder for #{source.custom_name} - download something first"}}
    end
  end

  defp series_directory(%Source{series_directory: dir}) when is_binary(dir) do
    if File.dir?(dir), do: {:ok, dir}, else: :error
  end

  defp series_directory(source) do
    case Media.list_downloaded_media_items_for(source) do
      [%{media_filepath: path} | _] when is_binary(path) ->
        case MetadataFileHelpers.series_directory_from_media_filepath(path) do
          {:ok, dir} -> {:ok, dir}
          {:error, _} -> dir_if_exists(Path.dirname(path))
        end

      _ ->
        :error
    end
  end

  defp dir_if_exists(dir), do: if(File.dir?(dir), do: {:ok, dir}, else: :error)

  defp load_sources do
    Repo.all(
      from s in Source,
        where: is_nil(s.marked_for_deletion_at),
        order_by: [asc: fragment("? COLLATE NOCASE", s.custom_name)]
    )
  end

  defp upload_error(:too_large), do: "Image is too large (max 15MB)"
  defp upload_error(:not_accepted), do: "Only JPG, PNG, or WEBP images"
  defp upload_error(_), do: "Invalid file"

  def render(assigns) do
    ~H"""
    <div>
      <p class="mb-5 text-sm text-bodydark">
        Replace a show's <code>poster.jpg</code>. Pick a source, then drop or choose an image; Pinchflat writes it to
        the show folder and refreshes Plex/Jellyfin.
      </p>

      <div class="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4">
        <div
          :for={source <- @sources}
          phx-click="select"
          phx-value-id={source.id}
          class={[
            "cursor-pointer rounded-xl border bg-white p-3 transition dark:bg-boxdark",
            (@selected_id == source.id && "border-primary ring-2 ring-primary") ||
              "border-stroke dark:border-strokedark hover:border-primary"
          ]}
        >
          <div class="relative mb-2 aspect-[2/3] overflow-hidden rounded-lg bg-meta-4/40">
            <img
              src={~p"/sources/#{source.id}/poster?v=#{@cache_bust}"}
              class="h-full w-full object-cover"
              onerror="this.style.display='none'; this.nextElementSibling.style.display='flex'"
            />
            <div class="absolute inset-0 hidden items-center justify-center text-xs text-bodydark2">
              no poster
            </div>
          </div>
          <div class="flex items-center gap-2">
            <.source_avatar name={source.custom_name} seed={source.id} size="h-6 w-6" />
            <span class="truncate text-sm font-medium text-black dark:text-white">{source.custom_name}</span>
          </div>

          <form
            :if={@selected_id == source.id}
            phx-change="validate"
            phx-drop-target={@uploads.poster.ref}
            class="mt-3 rounded-lg border-2 border-dashed border-primary/60 p-3 text-center"
          >
            <label class="block cursor-pointer text-xs text-primary">
              Drop or click to upload <.live_file_input upload={@uploads.poster} class="sr-only" />
            </label>
            <div :for={entry <- @uploads.poster.entries} class="mt-2 text-xs text-bodydark2">
              uploading {entry.progress}%
            </div>
            <div :for={err <- upload_errors(@uploads.poster)} class="mt-1 text-xs text-meta-1">
              {upload_error(err)}
            </div>
          </form>
        </div>
      </div>

      <p :if={@sources == []} class="text-sm text-bodydark2">No sources yet.</p>
    </div>
    """
  end
end
