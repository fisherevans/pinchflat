defmodule Pinchflat.Settings.Setting do
  @moduledoc """
  The Setting schema.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Pinchflat.Metadata.TitleCleanEngine

  @allowed_fields [
    :onboarding,
    :pro_enabled,
    :yt_dlp_version,
    :apprise_version,
    :apprise_server,
    :video_codec_preference,
    :audio_codec_preference,
    :youtube_api_key,
    :extractor_sleep_interval_seconds,
    :download_throughput_limit,
    :restrict_filenames,
    :plex_url,
    :plex_token,
    :plex_library_section,
    :jellyfin_url,
    :jellyfin_token,
    :title_clean_global_chain
  ]

  @required_fields [
    :onboarding,
    :pro_enabled,
    :video_codec_preference,
    :audio_codec_preference,
    :extractor_sleep_interval_seconds
  ]

  schema "settings" do
    field :onboarding, :boolean, default: true
    field :pro_enabled, :boolean, default: false
    field :yt_dlp_version, :string
    field :apprise_version, :string
    field :apprise_server, :string
    field :youtube_api_key, :string
    field :route_token, :string
    field :extractor_sleep_interval_seconds, :integer, default: 0
    # This is a string because it accepts values like "100K" or "4.2M"
    field :download_throughput_limit, :string
    field :restrict_filenames, :boolean, default: false

    field :video_codec_preference, :string
    field :audio_codec_preference, :string

    # Media-center integration: a library refresh is fired after media is reorganized
    # or a poster is replaced. Blank values disable the respective server.
    field :plex_url, :string
    field :plex_token, :string
    field :plex_library_section, :string
    field :jellyfin_url, :string
    field :jellyfin_token, :string

    # Global title-cleaning chain run before every source's own chain (unless the source opts
    # out via title_clean_use_global). Shape: %{"steps" => [...]}. See TitleCleanEngine.
    field :title_clean_global_chain, :map, default: %{"steps" => []}
  end

  @doc false
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, @allowed_fields)
    |> validate_required(@required_fields)
    |> validate_number(:extractor_sleep_interval_seconds, greater_than_or_equal_to: 0)
    |> validate_title_clean_global_chain()
  end

  defp validate_title_clean_global_chain(changeset) do
    case get_change(changeset, :title_clean_global_chain) do
      %{"steps" => steps} when is_list(steps) ->
        if Enum.all?(steps, &TitleCleanEngine.valid_step?/1) do
          changeset
        else
          add_error(changeset, :title_clean_global_chain, "contains an invalid rule")
        end

      _ ->
        changeset
    end
  end
end
