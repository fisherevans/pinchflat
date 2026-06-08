defmodule Pinchflat.Metadata.Mp4TaggerTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Metadata.Mp4Tagger

  setup do
    dir = Path.join(System.tmp_dir!(), "mp4_tagger_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "write_tags/2" do
    test "errors when the file is missing", %{dir: dir} do
      assert {:error, :enoent} = Mp4Tagger.write_tags(Path.join(dir, "nope.mp4"), title: "x")
    end

    test "no-ops (returns ok) for a non-mp4 file without invoking ffmpeg", %{dir: dir} do
      path = Path.join(dir, "notes.txt")
      File.write!(path, "hello")

      assert {:ok, ^path} = Mp4Tagger.write_tags(path, title: "x")
      # untouched
      assert File.read!(path) == "hello"
    end
  end
end
