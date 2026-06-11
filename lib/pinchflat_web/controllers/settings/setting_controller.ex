defmodule PinchflatWeb.Settings.SettingController do
  use PinchflatWeb, :controller

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Metadata.TitleCleanPreview

  def show(conn, _params) do
    setting = Settings.record()
    changeset = Settings.change_setting(setting)

    render(conn, "show.html", page_title: "Settings", changeset: changeset)
  end

  def update(conn, %{"setting" => setting_params}) do
    setting = Settings.record()

    case Settings.update_setting(setting, normalize_setting_params(setting_params)) do
      {:ok, _} ->
        conn
        |> put_flash(:info, "Settings updated successfully.")
        |> redirect(to: ~p"/settings")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "show.html", page_title: "Settings", changeset: changeset)
    end
  end

  # The global title-clean chain is submitted as a JSON string (same tactic as the source chain)
  # so reordering/clearing reliably overwrites the stored map.
  defp normalize_setting_params(%{"title_clean_global_chain_json" => json} = params) do
    params
    |> Map.put("title_clean_global_chain", %{"steps" => TitleCleanPreview.parse_steps(json)})
    |> Map.delete("title_clean_global_chain_json")
  end

  defp normalize_setting_params(params), do: params

  # Runs the (unsaved) global chain against recent indexed titles across all sources, so the
  # Settings editor can preview the effect of the global rules.
  def title_clean_preview(conn, params) do
    global_steps = TitleCleanPreview.parse_steps(params["chain"])
    limit = TitleCleanPreview.clamp_limit(params["limit"])

    indexed_query = from(m in MediaItem, where: not is_nil(m.uploaded_at))
    indexed_total = Repo.aggregate(indexed_query, :count)

    indexed =
      indexed_query
      |> order_by([m], desc: m.uploaded_at)
      |> select([m], %{title: m.original_title, fallback: m.title, duration_seconds: m.duration_seconds})
      |> limit(^limit)
      |> Repo.all()
      |> Enum.map(fn row -> %{title: row.title || row.fallback, duration_seconds: row.duration_seconds} end)

    samples = TitleCleanPreview.parse_test_titles(params["titles"]) ++ indexed
    # The global chain being edited runs in the "source" position - there's no further prefix.
    results = TitleCleanPreview.run([], global_steps, samples)

    json(conn, %{
      total: length(results),
      changed: Enum.count(results, & &1.changed),
      indexed_shown: length(indexed),
      indexed_total: indexed_total,
      indexed_cap: TitleCleanPreview.max_limit(),
      samples: results
    })
  rescue
    _ -> json(conn, %{error: true})
  end

  def app_info(conn, _params) do
    render(conn, "app_info.html", page_title: "App Info")
  end

  def download_logs(conn, _params) do
    log_path = Application.get_env(:pinchflat, :log_path)

    if log_path && File.exists?(log_path) do
      send_download(conn, {:file, log_path}, filename: "pinchflat-logs-#{Date.utc_today()}.txt")
    else
      conn
      |> put_flash(:error, "Log file couldn't be found")
      |> redirect(to: ~p"/app_info")
    end
  end
end
