defmodule Pinchflat.Repo.Migrations.ReplaceTitleCleaningOnSources do
  use Ecto.Migration

  # Title Cleaning v2: drop the old per-source alias/extra_strip lists and the enabled flag
  # in favor of a single ordered rule chain. A chain is %{"steps" => [step, ...]} where each
  # step references a clean_rules row or inlines its own find/replace + condition. A source is
  # "cleaning enabled" iff it has at least one enabled step. See Pinchflat.CleanRules.Engine.
  def change do
    alter table(:sources) do
      remove :title_clean_enabled, :boolean, default: false, null: false
      remove :title_clean_aliases, {:array, :string}, default: []
      remove :title_clean_extra_strip, {:array, :string}, default: []

      add :title_clean_chain, :map, default: %{"steps" => []}
    end
  end
end
