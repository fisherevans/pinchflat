defmodule Pinchflat.Repo.Migrations.AddTitleExcludeRegexToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      # Inverse of title_filter_regex: media whose title matches this regex is NOT downloaded.
      # Use alternation (foo|bar) to exclude multiple terms in one pattern.
      add :title_exclude_regex, :string
    end
  end
end
