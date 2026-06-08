defmodule Pinchflat.Media.TableView do
  @moduledoc """
  A user-saved media table view: a named, slugged bundle of table config (status filter,
  visible columns + order, sort, page size) scoped either to the global `/media` page or
  to a single source. Stored server-side so the same view is reachable from any device.

  Built-in presets are not stored here - they live in `Pinchflat.Media.TablePresets`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Pinchflat.Sources.Source

  @scopes ~w(global source)

  @allowed_fields ~w(name slug scope source_id config position)a
  @required_fields ~w(name slug scope config)a

  schema "media_table_views" do
    field :name, :string
    field :slug, :string
    field :scope, :string
    field :config, :map, default: %{}
    field :position, :integer, default: 0

    belongs_to :source, Source

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(view, attrs) do
    view
    |> cast(attrs, @allowed_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:scope, @scopes)
    |> validate_scope_source_consistency()
    |> unique_constraint([:scope, :source_id, :slug])
  end

  # global views have no source; source views must have one
  defp validate_scope_source_consistency(changeset) do
    case get_field(changeset, :scope) do
      "source" ->
        validate_required(changeset, [:source_id])

      "global" ->
        if get_field(changeset, :source_id),
          do: add_error(changeset, :source_id, "must be empty for a global view"),
          else: changeset

      _ ->
        changeset
    end
  end
end
