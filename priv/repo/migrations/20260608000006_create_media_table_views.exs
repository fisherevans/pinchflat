defmodule Pinchflat.Repo.Migrations.CreateMediaTableViews do
  use Ecto.Migration

  def change do
    create table(:media_table_views) do
      add :name, :string, null: false
      add :slug, :string, null: false
      # "global" (the /media page) or "source" (a single source's table)
      add :scope, :string, null: false
      add :source_id, references(:sources, on_delete: :delete_all)
      # JSON: status, ordered columns, sort, page_size (see Pinchflat.Media.TableView)
      add :config, :map, null: false, default: %{}
      add :position, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:media_table_views, [:scope, :source_id, :slug])
    create index(:media_table_views, [:scope])
  end
end
