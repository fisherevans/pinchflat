defmodule Pinchflat.Metadata.Mp4Tagger do
  @moduledoc """
  Rewrites an mp4/m4a's embedded metadata tags with bundled ffmpeg, using a
  stream copy (`-c copy`) so there's no re-encode. Plex and Jellyfin read these
  embedded tags before the `.nfo`, so this is how a cleaned title actually shows
  up in the media center.

  Writes to a temp sibling file and atomically renames over the original, so an
  interrupted run never leaves a half-written file in place. Only mp4-family
  containers are touched; anything else is a no-op.
  """

  @behaviour Pinchflat.Metadata.Mp4TaggerCommandRunner

  require Logger

  @mp4_extensions ~w(.mp4 .m4a .m4v .m4b)

  @impl Pinchflat.Metadata.Mp4TaggerCommandRunner
  def write_tags(filepath, tags) do
    cond do
      not File.exists?(filepath) ->
        {:error, :enoent}

      String.downcase(Path.extname(filepath)) not in @mp4_extensions ->
        {:ok, filepath}

      true ->
        do_write_tags(filepath, tags)
    end
  end

  defp do_write_tags(filepath, tags) do
    tmp = "#{Path.rootname(filepath)}.retag#{Path.extname(filepath)}"

    metadata_args =
      Enum.flat_map(tags, fn {key, value} -> ["-metadata", "#{key}=#{value}"] end)

    args = ["-y", "-i", filepath, "-map", "0", "-c", "copy"] ++ metadata_args ++ [tmp]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_out, 0} ->
        File.rename!(tmp, filepath)
        {:ok, filepath}

      {out, status} ->
        File.rm(tmp)
        Logger.error("ffmpeg retag failed (#{status}) for #{filepath}: #{String.slice(out, -500, 500)}")
        {:error, {:ffmpeg_failed, status}}
    end
  end
end
