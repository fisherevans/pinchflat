defmodule Pinchflat.Sources.Source do
  @moduledoc """
  The Source schema.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Pinchflat.Utils.ChangesetUtils

  alias __MODULE__
  alias Pinchflat.Repo
  alias Pinchflat.Tasks.Task
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Metadata.SourceMetadata
  alias Pinchflat.Metadata.TitleCleanEngine

  @allowed_fields ~w(
    enabled
    collection_name
    collection_id
    collection_type
    custom_name
    description
    nfo_filepath
    poster_filepath
    fanart_filepath
    banner_filepath
    series_directory
    index_frequency_minutes
    fast_index
    cookie_behaviour
    download_media
    last_indexed_at
    original_url
    download_cutoff_date
    download_end_date
    retention_period_days
    keep_count
    keep_bytes
    eviction_strategy
    max_delete_percent
    title_filter_regex
    title_exclude_regex
    filter_config
    title_clean_chain
    title_clean_use_global
    media_profile_id
    output_path_template_override
    marked_for_deletion_at
    min_duration_seconds
    max_duration_seconds
  )a

  # Expensive API calls are made when a source is inserted/updated so
  # we want to ensure that the source is valid before making the call.
  # This way, we check that the other attributes are valid before ensuring
  # that all fields are valid. This is still only one DB insert but it's
  # a two-stage validation process to fail fast before the API call.
  @initially_required_fields ~w(
    index_frequency_minutes
    fast_index
    download_media
    original_url
    media_profile_id
  )a

  @pre_insert_required_fields @initially_required_fields ++
                                ~w(
                                  uuid
                                  custom_name
                                  collection_name
                                  collection_id
                                  collection_type
                                )a

  schema "sources" do
    field :enabled, :boolean, default: true
    # This is _not_ used as the primary key or internally in the database
    # relations. This is only used to prevent an enumeration attack on the streaming
    # and RSS feed endpoints since those _must_ be public (ie: no basic auth)
    field :uuid, Ecto.UUID

    field :custom_name, :string
    field :description, :string
    field :collection_name, :string
    field :collection_id, :string
    field :collection_type, Ecto.Enum, values: [:channel, :playlist]
    field :index_frequency_minutes, :integer, default: 60 * 24
    field :fast_index, :boolean, default: false
    field :cookie_behaviour, Ecto.Enum, values: [:disabled, :when_needed, :all_operations], default: :disabled
    field :download_media, :boolean, default: true
    field :last_indexed_at, :utc_datetime
    # Only download media items that were published after this date
    field :download_cutoff_date, :date
    # Only download media items that were published on or before this date (upper bound)
    field :download_end_date, :date
    field :retention_period_days, :integer
    # Count/size retention budgets. When a source exceeds either budget, downloaded media
    # is evicted (files deleted, prevent_download set) until it's back under budget. The most
    # restrictive budget wins. `eviction_strategy` decides which media is evicted first.
    field :keep_count, :integer
    field :keep_bytes, :integer
    field :eviction_strategy, Ecto.Enum, values: [:oldest, :newest, :shortest, :longest], default: :oldest
    # Safety guard: skip budget eviction for a source if a single run would evict more than
    # this percentage of its downloaded media. Leave blank to disable the guard.
    field :max_delete_percent, :integer
    field :original_url, :string
    field :title_filter_regex, :string
    field :title_exclude_regex, :string
    field :filter_config, :map, default: %{}
    # Per-source title cleaning: an ordered chain of rules run over the raw title before it's
    # used in filenames/NFO/metadata. Shape is %{"steps" => [step, ...]} where each step is a
    # self-contained find/replace (or preset) + optional condition. A source is "cleaning
    # enabled" iff it has >= 1 enabled step. See Pinchflat.Metadata.TitleCleanEngine.
    field :title_clean_chain, :map, default: %{"steps" => []}
    # When true, the global title-clean chain (Settings) runs before this source's chain.
    field :title_clean_use_global, :boolean, default: true
    field :output_path_template_override, :string

    field :min_duration_seconds, :integer
    field :max_duration_seconds, :integer

    field :series_directory, :string
    field :nfo_filepath, :string
    field :poster_filepath, :string
    field :fanart_filepath, :string
    field :banner_filepath, :string

    field :marked_for_deletion_at, :utc_datetime

    belongs_to :media_profile, MediaProfile

    has_one :metadata, SourceMetadata, on_replace: :update

    has_many :tasks, Task
    has_many :media_items, MediaItem, foreign_key: :source_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(source, attrs, validation_stage) do
    # See above for rationale
    required_fields =
      if validation_stage == :initial do
        @initially_required_fields
      else
        @pre_insert_required_fields
      end

    source
    |> cast(attrs, @allowed_fields)
    |> dynamic_default(:custom_name, fn cs -> get_field(cs, :collection_name) end)
    |> dynamic_default(:uuid, fn _ -> Ecto.UUID.generate() end)
    |> validate_required(required_fields)
    |> validate_regex_field(:title_filter_regex)
    |> validate_regex_field(:title_exclude_regex)
    |> validate_filter_config()
    |> validate_title_clean_chain()
    |> validate_min_and_max_durations()
    |> validate_number(:retention_period_days, greater_than_or_equal_to: 0)
    |> validate_number(:keep_count, greater_than_or_equal_to: 0)
    |> validate_number(:keep_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:max_delete_percent, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    # Ensures it ends with `.{{ ext }}` or `.%(ext)s` or similar (with a little wiggle room)
    |> validate_format(:output_path_template_override, MediaProfile.ext_regex(), message: "must end with .{{ ext }}")
    |> validate_format(:original_url, youtube_channel_or_playlist_regex(), message: "must be a channel or playlist URL")
    |> cast_assoc(:metadata, with: &SourceMetadata.changeset/2, required: false)
    |> unique_constraint([:collection_id, :media_profile_id, :title_filter_regex], error_key: :original_url)
  end

  @doc false
  def index_frequency_when_fast_indexing do
    # 30 days in minutes
    60 * 24 * 30
  end

  @doc false
  def fast_index_frequency do
    # minutes
    10
  end

  @doc false
  def filepath_attributes do
    ~w(nfo_filepath fanart_filepath poster_filepath banner_filepath)a
  end

  @doc false
  def json_exluded_fields do
    ~w(__meta__ __struct__ metadata tasks media_items)a
  end

  def youtube_channel_or_playlist_regex do
    # Validate that the original URL is not a video URL
    # Also matches if the string does NOT contain youtube.com or youtu.be. This preserves my tenuous support
    # for non-youtube sources.
    ~r<^(?:(?!youtube\.com/(watch|shorts|embed)|youtu\.be).)*$>
  end

  defp validate_regex_field(changeset, field) do
    case get_change(changeset, field) do
      regex when is_binary(regex) ->
        case Ecto.Adapters.SQL.query(Repo, "SELECT regexp_like('', ?)", [regex]) do
          {:ok, _} -> changeset
          _ -> add_error(changeset, field, "is invalid")
        end

      _ ->
        changeset
    end
  end

  # The structured filter rules compile to `regexp_like(...)` against media titles
  # and descriptions. An invalid pattern would raise mid-query and crash every
  # `list_pending_media_items_for`/`pending_download?` call, so reject it at save time -
  # the same probe used for the standalone regex fields.
  defp validate_filter_config(changeset) do
    case get_change(changeset, :filter_config) do
      %{"rules" => rules} when is_list(rules) ->
        if Enum.all?(rules, &valid_filter_rule?/1) do
          changeset
        else
          add_error(changeset, :filter_config, "contains an invalid filter rule pattern")
        end

      _ ->
        changeset
    end
  end

  defp valid_filter_rule?(%{"field" => field, "value" => value})
       when field in ["title", "description"] and is_binary(value) and value != "" do
    match?({:ok, _}, Ecto.Adapters.SQL.query(Repo, "SELECT regexp_like('', ?)", [value]))
  end

  defp valid_filter_rule?(_rule), do: true

  # Each chain step carries a regex `find` and an optional condition, both compiled by the
  # engine. Reject malformed steps at save time so cleaning can't silently no-op on a bad rule.
  defp validate_title_clean_chain(changeset) do
    case get_change(changeset, :title_clean_chain) do
      %{"steps" => steps} when is_list(steps) ->
        if Enum.all?(steps, &TitleCleanEngine.valid_step?/1) do
          changeset
        else
          add_error(changeset, :title_clean_chain, "contains an invalid rule")
        end

      _ ->
        changeset
    end
  end

  defp validate_min_and_max_durations(changeset) do
    min_duration = get_change(changeset, :min_duration_seconds)
    max_duration = get_change(changeset, :max_duration_seconds)

    case {min_duration, max_duration} do
      {min, max} when is_nil(min) or is_nil(max) -> changeset
      {min, max} when min >= max -> add_error(changeset, :max_duration_seconds, "must be greater than minumum duration")
      _ -> changeset
    end
  end

  defimpl Jason.Encoder, for: Source do
    def encode(value, opts) do
      value
      |> Repo.preload(:media_profile)
      |> Map.drop(Source.json_exluded_fields())
      |> Jason.Encode.map(opts)
    end
  end
end
