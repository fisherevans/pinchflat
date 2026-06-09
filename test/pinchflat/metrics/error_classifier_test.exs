defmodule Pinchflat.Metrics.ErrorClassifierTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Metrics.ErrorClassifier

  describe "classify/1" do
    tests = [
      {:auth_needed, "ERROR: [youtube] abc: Sign in to confirm you're not a bot"},
      {:auth_needed, "Sign in to confirm your age"},
      {:members_only, "This video is available to this channel's members on level: ..."},
      {:unavailable, "ERROR: [youtube] abc: Video unavailable"},
      {:unavailable, "Private video. Sign in if you've been granted access"},
      {:unavailable, "This video has been removed by the uploader"},
      {:unavailable, "The uploader has not made this video available in your country"},
      {:rate_limited, "ERROR: HTTP Error 429: Too Many Requests"},
      {:forbidden, "ERROR: unable to download video data: HTTP Error 403: Forbidden"},
      {:other, "ERROR: unable to write data: [Errno 28] No space left on device"},
      {:other, ""}
    ]

    for {expected, message} <- tests do
      test "classifies #{inspect(expected)} for #{inspect(message)}" do
        assert ErrorClassifier.classify(unquote(message)) == unquote(expected)
      end
    end

    test "is case-insensitive and tolerates non-strings" do
      assert ErrorClassifier.classify("SIGN IN TO CONFIRM") == :auth_needed
      assert ErrorClassifier.classify(nil) == :other
    end
  end
end
