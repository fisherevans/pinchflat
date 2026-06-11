defmodule Pinchflat.Repo.Migrations.AddGlobalTitleCleaning do
  use Ecto.Migration

  # A global title-cleaning chain configured in Settings that runs BEFORE each source's own
  # chain. Per-source `title_clean_use_global` (default true) opts a source out of it. Same
  # shape as a source chain: %{"steps" => [...]}. See Pinchflat.Metadata.TitleCleanEngine.
  def change do
    alter table(:settings) do
      add :title_clean_global_chain, :map, default: %{"steps" => []}
    end

    alter table(:sources) do
      add :title_clean_use_global, :boolean, default: true, null: false
    end
  end
end
