defmodule Pinchflat.Organizing.MediaOrganizerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Organizing.MediaOrganizer
  alias Pinchflat.Utils.FilesystemUtils

  @media_dir Application.compile_env(:pinchflat, :media_directory)

  setup :verify_on_exit!

  defp show_dir do
    dir = Path.join([@media_dir, "shows", "Danny Go #{:rand.uniform(1_000_000)}"])
    File.mkdir_p!(dir)
    dir
  end

  defp touch(path) do
    FilesystemUtils.write_p!(path, "data")
    path
  end

  defp clean_source(attrs \\ %{}) do
    source_fixture(Map.merge(%{title_clean_enabled: true, custom_name: "Danny Go"}, attrs))
  end

  defp item(source, media_filepath, attrs) do
    nfo = "#{Path.rootname(media_filepath)}.nfo"
    touch(media_filepath)
    touch(nfo)

    defaults = %{
      source_id: source.id,
      media_filepath: media_filepath,
      nfo_filepath: nfo,
      uploaded_at: ~U[2023-09-25 00:00:00Z],
      upload_date_index: 99
    }

    media_item_fixture(Map.merge(defaults, attrs))
  end

  describe "organize_media_item/2 - title cleaning (strategy :none)" do
    test "renames the media + nfo to the cleaned title, preserving the season prefix" do
      expect(Mp4TaggerRunnerMock, :write_tags, fn path, tags ->
        assert tags[:title] == "Magnet MANIA!"
        {:ok, path}
      end)

      source = clean_source()
      dir = show_dir()
      current = Path.join(dir, "s2023e092599 - Magnet MANIA  Danny Go.mp4")

      media_item =
        item(source, current, %{title: "Magnet MANIA!", original_title: "Magnet MANIA! | Danny Go!"})

      assert :ok = MediaOrganizer.organize_media_item(media_item)

      desired = Path.join(dir, "s2023e092599 - Magnet MANIA!.mp4")
      assert File.exists?(desired)
      refute File.exists?(current)
      assert File.exists?(Path.join(dir, "s2023e092599 - Magnet MANIA!.nfo"))

      reloaded = Repo.get!(MediaItem, media_item.id)
      assert reloaded.media_filepath == desired
      assert reloaded.nfo_filepath == Path.join(dir, "s2023e092599 - Magnet MANIA!.nfo")
    end

    test "writes the cleaned title and season/episode into the nfo" do
      expect(Mp4TaggerRunnerMock, :write_tags, fn path, _tags -> {:ok, path} end)

      source = clean_source()
      dir = show_dir()
      current = Path.join(dir, "s2023e092599 - raw.mp4")
      media_item = item(source, current, %{title: "Clean Name", original_title: "raw"})

      MediaOrganizer.organize_media_item(media_item)

      nfo = File.read!(Path.join(dir, "s2023e092599 - Clean Name.nfo"))
      assert nfo =~ "<title>Clean Name</title>"
      assert nfo =~ "<season>2023</season>"
      assert nfo =~ "<episode>092599</episode>"
    end

    test "is idempotent - a second run makes no further changes" do
      expect(Mp4TaggerRunnerMock, :write_tags, fn path, _tags -> {:ok, path} end)

      source = clean_source()
      dir = show_dir()
      media_item = item(source, Path.join(dir, "s2023e092599 - raw.mp4"), %{title: "Clean", original_title: "raw"})

      MediaOrganizer.organize_media_item(media_item)
      # No further retag expectation - a second run must be a no-op
      assert :skip = MediaOrganizer.organize_media_item(Repo.get!(MediaItem, media_item.id))
    end

    test "skips when an in-flight download is present in the directory" do
      source = clean_source()
      dir = show_dir()
      current = Path.join(dir, "s2023e092599 - raw.mp4")
      media_item = item(source, current, %{title: "Clean", original_title: "raw"})
      touch(Path.join(dir, "something.mp4.part"))

      assert :skip = MediaOrganizer.organize_media_item(media_item)
      assert File.exists?(current)
    end
  end

  describe "organize_media_item/2 - season strategy" do
    test ":single_season renumbers to a flat s01e prefix" do
      expect(Mp4TaggerRunnerMock, :write_tags, fn path, _tags -> {:ok, path} end)

      profile = media_profile_fixture(%{season_strategy: :single_season})
      source = clean_source(%{media_profile_id: profile.id})
      dir = show_dir()
      current = Path.join(dir, "s2023e092599 - Some Title.mp4")
      media_item = item(source, current, %{title: "Some Title", original_title: "Some Title | Danny Go!"})

      MediaOrganizer.organize_media_item(media_item)

      assert File.exists?(Path.join(dir, "s01e23092599 - Some Title.mp4"))
      refute File.exists?(current)
    end
  end

  describe "organize_source/2" do
    test "does nothing for a source that hasn't opted in" do
      source = source_fixture(%{title_clean_enabled: false})
      dir = show_dir()
      current = Path.join(dir, "s2023e092599 - raw.mp4")
      item(source, current, %{title: "raw", original_title: "raw"})

      assert {:ok, 0} = MediaOrganizer.organize_source(source)
      assert File.exists?(current)
    end
  end
end
