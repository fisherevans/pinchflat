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

    test "skips items whose directory has an in-flight download (one cached listing)" do
      source = clean_source()
      dir = show_dir()
      c1 = Path.join(dir, "s2023e092599 - raw one.mp4")
      c2 = Path.join(dir, "s2023e092598 - raw two.mp4")
      item(source, c1, %{title: "One", original_title: "raw one", upload_date_index: 99})
      item(source, c2, %{title: "Two", original_title: "raw two", upload_date_index: 98})
      touch(Path.join(dir, "downloading.mp4.part"))

      assert {:ok, 0} = MediaOrganizer.organize_source(source)
      assert File.exists?(c1)
      assert File.exists?(c2)
    end
  end

  describe "NFS hardening" do
    test "moves the media file with a rename (preserves inode), never a copy" do
      expect(Mp4TaggerRunnerMock, :write_tags, fn path, _tags -> {:ok, path} end)

      profile = media_profile_fixture(%{season_strategy: :single_season})
      source = clean_source(%{media_profile_id: profile.id})
      dir = show_dir()
      current = Path.join(dir, "s2023e092599 - Some Title.mp4")
      media_item = item(source, current, %{title: "Some Title", original_title: "Some Title | Danny Go!"})
      inode_before = File.stat!(current).inode

      MediaOrganizer.organize_media_item(media_item)

      desired = Path.join(dir, "s01e23092599 - Some Title.mp4")
      assert File.exists?(desired)
      refute File.exists?(current)
      # A copy would create a new inode; a rename keeps it. This is the no-copy guarantee.
      assert File.stat!(desired).inode == inode_before
    end

    test "does not re-mux the mp4 on a pure renumber (title/plot unchanged)" do
      # First organize (strategy :none) writes tags once and records the hash.
      expect(Mp4TaggerRunnerMock, :write_tags, 1, fn path, _tags -> {:ok, path} end)

      source = clean_source()
      dir = show_dir()
      current = Path.join(dir, "s2023e092599 - raw.mp4")
      media_item = item(source, current, %{title: "Clean Name", original_title: "raw"})
      MediaOrganizer.organize_media_item(media_item)

      # Flip the season strategy and reprocess: the filename renumbers, but title/plot don't
      # change, so verify_on_exit asserts write_tags is NOT called a second time.
      profile = Repo.get!(Pinchflat.Profiles.MediaProfile, source.media_profile_id)
      {:ok, _} = Pinchflat.Profiles.update_media_profile(profile, %{season_strategy: :single_season})

      reloaded = Repo.get!(MediaItem, media_item.id)
      assert :ok = MediaOrganizer.organize_media_item(reloaded, force: true)

      assert File.exists?(Path.join(dir, "s01e23092599 - Clean Name.mp4"))
    end

    test "re-muxes the mp4 when the title changes" do
      expect(Mp4TaggerRunnerMock, :write_tags, 2, fn path, _tags -> {:ok, path} end)

      source = clean_source()
      dir = show_dir()
      media_item = item(source, Path.join(dir, "s2023e092599 - raw.mp4"), %{title: "First", original_title: "raw"})
      MediaOrganizer.organize_media_item(media_item)

      reloaded = Repo.get!(MediaItem, media_item.id)
      {:ok, _} = Pinchflat.Media.update_media_item(reloaded, %{title: "Second"})

      reloaded = Repo.get!(MediaItem, media_item.id)
      assert :ok = MediaOrganizer.organize_media_item(reloaded, force: true)
    end
  end
end
