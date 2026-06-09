defmodule Pinchflat.Metrics.ErrorClassifier do
  @moduledoc """
  Buckets a raw yt-dlp error string into a small, stable set of reasons so failures can be
  tagged and alerted on by cause (e.g. monitor `download.failed{reason:auth_needed}` to know
  when cookies/re-auth are needed). Reasons:

    :auth_needed   - bot/sign-in/age check; usually fixed by fresh cookies
    :members_only  - channel-members-only content
    :unavailable   - private/removed/region-blocked/taken down
    :rate_limited  - HTTP 429 / too many requests (possible IP throttling)
    :forbidden     - HTTP 403 / access denied
    :other         - anything else

  Patterns are derived from the existing handling in `media_downloader.ex`
  (`recoverable_cookie_errors`) and `media_download_worker.ex` (`non_retryable_errors`).
  """

  @type reason :: :auth_needed | :members_only | :unavailable | :rate_limited | :forbidden | :other

  @spec classify(term()) :: reason()
  def classify(message) do
    msg = message |> to_string() |> String.downcase()

    cond do
      contains_any?(msg, ["sign in to confirm", "confirm you're not a bot", "confirm your age", "age-restricted"]) ->
        :auth_needed

      contains_any?(msg, ["available to this channel's members", "members-only", "members only"]) ->
        :members_only

      contains_any?(msg, [
        "video unavailable",
        "private video",
        "has been removed",
        "no longer available",
        "removed by the uploader",
        "available in your country",
        "this video is unavailable"
      ]) ->
        :unavailable

      contains_any?(msg, ["http error 429", "too many requests"]) ->
        :rate_limited

      contains_any?(msg, ["http error 403", "forbidden", "access denied"]) ->
        :forbidden

      true ->
        :other
    end
  end

  defp contains_any?(message, needles), do: Enum.any?(needles, &String.contains?(message, &1))
end
