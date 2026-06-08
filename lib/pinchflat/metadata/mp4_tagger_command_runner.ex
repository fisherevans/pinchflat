defmodule Pinchflat.Metadata.Mp4TaggerCommandRunner do
  @moduledoc """
  Behaviour for rewriting an mp4/m4a container's embedded metadata tags. Swappable
  so tests can stub it (real impl shells out to ffmpeg).
  """

  @doc """
  Rewrites the given file's embedded metadata. `tags` is a keyword list of
  metadata key => value; an empty-string value clears that tag. Returns the
  filepath on success.
  """
  @callback write_tags(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
end
