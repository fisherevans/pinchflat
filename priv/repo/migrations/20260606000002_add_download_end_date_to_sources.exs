defmodule Pinchflat.Repo.Migrations.AddDownloadEndDateToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      # Upper bound for the download window. `download_cutoff_date` is the lower bound
      # ("only after X"); this is the upper bound ("only on/before Y"). Together they
      # give an explicit start-to-end date range.
      add :download_end_date, :date
    end
  end
end
