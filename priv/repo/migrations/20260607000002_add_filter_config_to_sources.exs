defmodule Pinchflat.Repo.Migrations.AddFilterConfigToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      # A structured filter rule set: %{"match" => "all" | "any", "rules" => [%{"field", "operator", "value"}]}.
      # Stored as JSON. The single title_filter_regex/title_exclude_regex fields remain as a simple
      # entry point; these rules are an additional, composable layer.
      add :filter_config, :map, default: %{}
    end
  end
end
