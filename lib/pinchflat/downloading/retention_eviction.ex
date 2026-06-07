defmodule Pinchflat.Downloading.RetentionEviction do
  @moduledoc """
  Append-only audit record of a media item evicted by a source's count/size
  retention budget. Captures what was evicted, when, how much space it freed,
  and a snapshot of the budget that triggered it. Denormalized (media_id/title)
  so the record stays meaningful even if the media_item later changes or is removed.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem

  @allowed_fields ~w(
    source_id
    media_item_id
    media_id
    title
    bytes_freed
    eviction_strategy
    keep_count
    keep_bytes
  )a

  @required_fields ~w(source_id)a

  schema "retention_evictions" do
    field :media_id, :string
    field :title, :string
    field :bytes_freed, :integer
    field :eviction_strategy, :string
    field :keep_count, :integer
    field :keep_bytes, :integer

    belongs_to :source, Source
    belongs_to :media_item, MediaItem

    timestamps(updated_at: false, type: :utc_datetime)
  end

  @doc false
  def changeset(record, attrs) do
    record
    |> cast(attrs, @allowed_fields)
    |> validate_required(@required_fields)
  end

  @doc """
  Returns the most recent evictions for a source, newest first.
  """
  def recent_for(%Source{} = source, limit \\ 50) do
    from(e in __MODULE__,
      where: e.source_id == ^source.id,
      order_by: [desc: e.inserted_at, desc: e.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Records an eviction for the given source/media_item, snapshotting the budget.

  Returns {:ok, %RetentionEviction{}} | {:error, %Ecto.Changeset{}}.
  """
  def record(%Source{} = source, %MediaItem{} = media_item) do
    %__MODULE__{}
    |> changeset(%{
      source_id: source.id,
      media_item_id: media_item.id,
      media_id: media_item.media_id,
      title: media_item.title,
      bytes_freed: media_item.media_size_bytes || 0,
      eviction_strategy: to_string(source.eviction_strategy),
      keep_count: source.keep_count,
      keep_bytes: source.keep_bytes
    })
    |> Repo.insert()
  end
end
